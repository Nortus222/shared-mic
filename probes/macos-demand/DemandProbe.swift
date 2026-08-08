// Throwaway probe for spec open question 1: does macOS report per-process
// input device usage well enough to scope demand detection to one device?
//
// Build: swiftc -O -o demand-probe DemandProbe.swift
// Run:   ./demand-probe                one snapshot
//        ./demand-probe --watch        poll twice a second until Ctrl-C
//        ./demand-probe --list-devices full device inventory (id, uid, name)
//        ./demand-probe --self-test    fully automated, three legs:
//                                       1. self-introspection positive (BlackHole),
//                                          measured both via full-sweep and via
//                                          targeted PID->process-object lookup
//                                       2. self-introspection negative control
//                                          (a second, different input device)
//                                       3. cross-process: spawns a genuinely
//                                          separate helper process that opens
//                                          BlackHole, observed from the parent
//                                          via the normal full-sweep path --
//                                          this is the actual production use
//                                          case (observing OTHER processes),
//                                          which legs 1-2 alone do not cover.
//
// --internal-hold-blackhole is a hidden flag used only by --self-test's leg 3
// to re-exec this binary as the helper process; not meant to be run directly.
//
// Never logs or persists captured audio: the input callback does not touch
// the sample buffer at all, it only starts/stops the I/O cycle so the
// process registers as "running input" on the target device.

import CoreAudio
import AudioToolbox
import Foundation

// MARK: - CoreAudio property helpers

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func objectIDs(_ objectID: AudioObjectID,
               _ selector: AudioObjectPropertySelector,
               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> [AudioObjectID] {
    var addr = address(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size) == noErr, size > 0
    else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &ids) == noErr
    else { return [] }
    return ids
}

func uint32Value(_ objectID: AudioObjectID,
                 _ selector: AudioObjectPropertySelector,
                 _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var addr = address(selector, scope)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr
    else { return nil }
    return value
}

func int32Value(_ objectID: AudioObjectID,
                _ selector: AudioObjectPropertySelector) -> Int32? {
    var addr = address(selector)
    var value: Int32 = 0
    var size = UInt32(MemoryLayout<Int32>.size)
    guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr
    else { return nil }
    return value
}

func stringValue(_ objectID: AudioObjectID,
                 _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size) == noErr, size > 0
    else { return nil }
    var value: Unmanaged<CFString>?
    let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
        AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, pointer)
    }
    guard status == noErr, let unmanaged = value else { return nil }
    return unmanaged.takeRetainedValue() as String
}

// MARK: - Formatting helper (no String(format:) / %@ bridging games)

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

// MARK: - Devices

struct Device {
    let id: AudioObjectID
    let uid: String
    let name: String
}

func allDevices() -> [Device] {
    objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).map {
        Device(id: $0,
               uid: stringValue($0, kAudioDevicePropertyDeviceUID) ?? "<no uid>",
               name: stringValue($0, kAudioObjectPropertyName) ?? "<no name>")
    }
}

func hasInputStreams(_ deviceID: AudioObjectID) -> Bool {
    !objectIDs(deviceID, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).isEmpty
}

/// Finds a device to use as the self-test's negative control: some
/// input-capable device that is NOT the target (BlackHole). Preferred over
/// literally requiring "the built-in mic" because not every Mac has one
/// (e.g. Mac Studio, Mac mini) -- this machine doesn't. When a built-in mic
/// exists (transport == kAudioDeviceTransportTypeBuiltIn) it is preferred;
/// otherwise any other non-virtual (real hardware) input device is used,
/// and failing that, any other input-capable device at all. Matched by
/// transport type / input-stream presence only, never by display name.
func negativeControlInputDevice(_ devices: [Device], excluding targetID: AudioObjectID) -> Device? {
    let candidates = devices.filter { $0.id != targetID && hasInputStreams($0.id) }
    if let builtin = candidates.first(where: {
        uint32Value($0.id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn
    }) {
        return builtin
    }
    if let hardware = candidates.first(where: {
        uint32Value($0.id, kAudioDevicePropertyTransportType) != kAudioDeviceTransportTypeVirtual
    }) {
        return hardware
    }
    return candidates.first
}

// MARK: - Process objects

// IMPORTANT (see Finding in the findings doc, "IsRunningInput does not
// reliably re-trigger"): kAudioProcessPropertyIsRunningInput was found
// during this probe's development to correctly report `true` only on a
// process's FIRST input stream in its lifetime -- it silently stays
// `false` on the second, third, ... activation, even while the process is
// actively streaming from the device. kAudioProcessPropertyDevices
// (input-scope device-list membership) and the general, non-scoped
// kAudioProcessPropertyIsRunning were both found to re-trigger correctly
// on every cycle. For that reason `inputDeviceIDs` membership -- not
// `runningInput` -- is the authoritative demand signal used everywhere in
// this probe. `runningInput` and `runningGeneral` are both still read and
// reported for diagnostic visibility, but neither gates a pass/fail
// decision or `demandCount`.
struct ProcessInfoRow {
    let pid: Int32
    let bundleID: String
    let runningInput: Bool
    let runningGeneral: Bool
    let inputDeviceIDs: [AudioObjectID]
}

/// Full-sweep enumeration: lists every process object Core Audio is
/// tracking (~40 on this machine) and reads properties on each. This is
/// the mechanism `report()`/`--watch` use, and it is the production-shaped
/// mechanism for the real use case: discovering an *unknown* process that
/// just started recording, which you can't look up by PID because you
/// don't know it in advance.
func processRows() -> [ProcessInfoRow] {
    objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        .map { processObject in
            ProcessInfoRow(
                pid: int32Value(processObject, kAudioProcessPropertyPID) ?? -1,
                bundleID: stringValue(processObject, kAudioProcessPropertyBundleID) ?? "<none>",
                runningInput: (uint32Value(processObject, kAudioProcessPropertyIsRunningInput) ?? 0) != 0,
                runningGeneral: (uint32Value(processObject, kAudioProcessPropertyIsRunning) ?? 0) != 0,
                inputDeviceIDs: objectIDs(processObject,
                                          kAudioProcessPropertyDevices,
                                          kAudioObjectPropertyScopeInput)
            )
        }
}

/// Translates a PID directly to its Core Audio process object via
/// kAudioHardwarePropertyTranslatePIDToProcessObject, skipping the full
/// enumeration sweep entirely. Only usable when the PID of interest is
/// already known (true for the self-test, which controls the PID it's
/// checking) -- not a substitute for processRows() in the general
/// "which process is this" discovery case.
func processObjectForPID(_ pid: Int32) -> AudioObjectID? {
    var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var pidValue = pid_t(pid)
    var outObject: AudioObjectID = 0
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = withUnsafeMutablePointer(to: &pidValue) { qualifier -> OSStatus in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                    UInt32(MemoryLayout<pid_t>.size), qualifier,
                                    &size, &outObject)
    }
    guard status == noErr, outObject != kAudioObjectUnknown else { return nil }
    return outObject
}

/// Targeted single-object read for a known PID: one property-translate
/// call plus 4 property reads on exactly that object, instead of ~40
/// objects x 4 properties. Isolates Core Audio's genuine state-propagation
/// latency from full-sweep enumeration cost -- see Finding 2 in the
/// findings doc for why that distinction matters for a debounce budget.
func targetedRow(forPID pid: Int32) -> ProcessInfoRow? {
    guard let obj = processObjectForPID(pid) else { return nil }
    return ProcessInfoRow(
        pid: int32Value(obj, kAudioProcessPropertyPID) ?? pid,
        bundleID: stringValue(obj, kAudioProcessPropertyBundleID) ?? "<none>",
        runningInput: (uint32Value(obj, kAudioProcessPropertyIsRunningInput) ?? 0) != 0,
        runningGeneral: (uint32Value(obj, kAudioProcessPropertyIsRunning) ?? 0) != 0,
        inputDeviceIDs: objectIDs(obj, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput)
    )
}

func defaultInputDeviceID() -> AudioObjectID? {
    var addr = address(kAudioHardwarePropertyDefaultInputDevice)
    var dev: AudioObjectID = 0
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr
    else { return nil }
    return dev
}

// MARK: - Reporting (normal / --watch mode)

func report(target: Device, devicesByID: [AudioObjectID: Device]) {
    let rows = processRows()
    let ourPID = ProcessInfo.processInfo.processIdentifier

    print("target device: \(target.name)  uid=\(target.uid)  id=\(target.id)")
    print("process objects reported: \(rows.count)")
    print(String(repeating: "-", count: 78))
    print("  " + pad("PID", 7) + pad("runningInput", 14) + pad("onTarget", 10) + "bundle / input devices")

    var demandCount = 0
    for row in rows where row.runningInput || row.runningGeneral || !row.inputDeviceIDs.isEmpty {
        let onTarget = row.inputDeviceIDs.contains(target.id)
        // Normal reporting mode deliberately excludes the probe's own PID
        // from the demand count: the probe itself is not a "real" demand
        // signal outside of --self-test, where this exclusion is bypassed.
        //
        // demandCount is gated on device-list membership (onTarget) alone,
        // NOT on runningInput: kAudioProcessPropertyIsRunningInput was
        // found not to reliably re-trigger past a process's first input
        // activation (see the findings doc). onTarget does not have that
        // problem in this probe's testing, so it is the authoritative
        // signal here. runningInput is still printed for visibility.
        let counts = onTarget && row.pid != ourPID
        if counts { demandCount += 1 }
        let deviceNames = row.inputDeviceIDs
            .map { devicesByID[$0]?.name ?? "id=\($0)" }
            .joined(separator: ", ")
        let line = "  " + pad(String(row.pid), 7)
                        + pad(row.runningInput ? "yes" : "no", 14)
                        + pad(onTarget ? "YES" : "-", 10)
                        + "\(row.bundleID)  [\(deviceNames)]"
        print(line)
    }
    print(String(repeating: "-", count: 78))
    print("device-scoped demandCount = \(demandCount)  (gated on device-list membership, not on runningInput -- see findings doc)")
    print("")
}

func listDevices(_ devices: [Device]) {
    print("id     uid                                       name")
    for d in devices {
        // pad() doesn't truncate, so a long UID would otherwise run
        // straight into the name column with no separator -- always force
        // at least one space so columns stay parseable.
        print(pad(String(d.id), 7) + pad(d.uid, 42) + " " + d.name)
    }
}

// MARK: - Self-test: open real input streams from this process and verify
// kAudioProcessPropertyDevices reports the right device, and only the right
// device, for this process's own PID.

/// AURenderCallback that intentionally does nothing with the captured
/// buffer. We never call AudioUnitRender, so no sample data is ever read,
/// copied, or written anywhere -- we only need the AUHAL's I/O cycle
/// running so this process registers as an active input client.
func silentInputCallback(inRefCon: UnsafeMutableRawPointer,
                          ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                          inTimeStamp: UnsafePointer<AudioTimeStamp>,
                          inBusNumber: UInt32,
                          inNumberFrames: UInt32,
                          ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    noErr
}

/// Builds and initializes (but does not start) an input-enabled AUHAL bound
/// to `device`. Returns nil on any failure, printing the failing step and
/// OSStatus so permission/config problems are visible rather than silently
/// swallowed.
func makeInputUnit(device: AudioObjectID) -> AudioUnit? {
    var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                          componentSubType: kAudioUnitSubType_HALOutput,
                                          componentManufacturer: kAudioUnitManufacturer_Apple,
                                          componentFlags: 0,
                                          componentFlagsMask: 0)
    guard let comp = AudioComponentFindNext(nil, &desc) else {
        print("  makeInputUnit: AudioComponentFindNext found no HALOutput component")
        return nil
    }
    var unitOpt: AudioUnit?
    var status = AudioComponentInstanceNew(comp, &unitOpt)
    guard status == noErr, let unit = unitOpt else {
        print("  makeInputUnit: AudioComponentInstanceNew failed, status=\(status)")
        return nil
    }

    var enableIO: UInt32 = 1
    status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Input, 1,
                                   &enableIO, UInt32(MemoryLayout<UInt32>.size))
    guard status == noErr else {
        print("  makeInputUnit: EnableIO(input) failed, status=\(status)")
        AudioComponentInstanceDispose(unit)
        return nil
    }

    var disableIO: UInt32 = 0
    status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Output, 0,
                                   &disableIO, UInt32(MemoryLayout<UInt32>.size))
    guard status == noErr else {
        print("  makeInputUnit: EnableIO(output) failed, status=\(status)")
        AudioComponentInstanceDispose(unit)
        return nil
    }

    var dev = device
    status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0,
                                   &dev, UInt32(MemoryLayout<AudioObjectID>.size))
    guard status == noErr else {
        print("  makeInputUnit: CurrentDevice failed, status=\(status)")
        AudioComponentInstanceDispose(unit)
        return nil
    }

    var callback = AURenderCallbackStruct(inputProc: silentInputCallback, inputProcRefCon: nil)
    status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                   kAudioUnitScope_Global, 0,
                                   &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    guard status == noErr else {
        print("  makeInputUnit: SetInputCallback failed, status=\(status)")
        AudioComponentInstanceDispose(unit)
        return nil
    }

    status = AudioUnitInitialize(unit)
    guard status == noErr else {
        print("  makeInputUnit: AudioUnitInitialize failed, status=\(status)")
        AudioComponentInstanceDispose(unit)
        return nil
    }

    return unit
}

func teardown(_ unit: AudioUnit) {
    AudioOutputUnitStop(unit)
    AudioUnitUninitialize(unit)
    AudioComponentInstanceDispose(unit)
}

/// Apple's documented teardown order is Stop -> Uninitialize -> Dispose.
/// Used on failure paths where Stop was never reached (the unit was never
/// started) but AudioUnitInitialize may have already succeeded.
func disposeUninitialized(_ unit: AudioUnit) {
    AudioUnitUninitialize(unit)
    AudioComponentInstanceDispose(unit)
}

struct CheckResult {
    let passed: Bool
    let message: String
}

/// Shared poll logic: repeatedly calls `lookup(pid)` (either the full-sweep
/// or the targeted-lookup path) until it finds `mustContain` present (and,
/// if given, `mustNotContain` absent) in that PID's input-device list.
///
/// Gated on device-list membership only, NOT on `runningInput` -- see the
/// ProcessInfoRow doc comment. `runningInput`/`runningGeneral` are reported
/// in the message for visibility and to make any recurrence of the
/// IsRunningInput anomaly immediately visible, but they do not gate
/// pass/fail.
func pollUntil(pid: Int32,
               mustContain: AudioObjectID,
               mustNotContain: AudioObjectID? = nil,
               timeout: TimeInterval,
               lookup: (Int32) -> ProcessInfoRow?) -> CheckResult {
    let start = Date()
    var lastSeen: ProcessInfoRow?
    while Date().timeIntervalSince(start) < timeout {
        if let row = lookup(pid) {
            lastSeen = row
            let hasTarget = row.inputDeviceIDs.contains(mustContain)
            let hasForbidden = mustNotContain.map { row.inputDeviceIDs.contains($0) } ?? false
            if hasForbidden {
                return CheckResult(passed: false,
                    message: "FAIL: pid=\(pid) input-device list contains the forbidden device \(mustNotContain!) -- devices=\(row.inputDeviceIDs) (runningInput=\(row.runningInput), runningGeneral=\(row.runningGeneral))")
            }
            if hasTarget {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                let flag = row.runningInput ? "" : "  [note: runningInput=false despite device-list membership -- see IsRunningInput finding]"
                return CheckResult(passed: true,
                    message: "PASS (\(ms)ms): pid=\(pid) input devices=\(row.inputDeviceIDs) contains target \(mustContain) (runningInput=\(row.runningInput), runningGeneral=\(row.runningGeneral))\(flag)")
            }
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return CheckResult(passed: false,
        message: "FAIL: timed out after \(Int(timeout*1000))ms waiting for pid=\(pid). Last seen row: \(String(describing: lastSeen))")
}

/// Shared clear-poll logic: waits until `lookup(pid)` returns nil or the
/// target device is no longer in its input-device list (device-list
/// membership, not runningInput -- same rationale as pollUntil above).
func pollUntilClear(pid: Int32, target: AudioObjectID, timeout: TimeInterval, lookup: (Int32) -> ProcessInfoRow?) -> String {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        let row = lookup(pid)
        if row == nil || !(row!.inputDeviceIDs.contains(target)) {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return "cleared after \(ms)ms"
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return "did NOT clear within \(Int(timeout*1000))ms"
}

/// Full-sweep poll (~40 process objects x 4 properties per poll on this
/// machine). This is the same mechanism `report()`/`--watch` use, and it's
/// the production-shaped path: discovering an unknown process by scanning
/// everything, not by looking up a PID you already know.
func pollSweep(pid: Int32, mustContain: AudioObjectID, mustNotContain: AudioObjectID? = nil, timeout: TimeInterval) -> CheckResult {
    pollUntil(pid: pid, mustContain: mustContain, mustNotContain: mustNotContain, timeout: timeout) { p in
        processRows().first(where: { $0.pid == p })
    }
}

func pollClearSweep(pid: Int32, target: AudioObjectID, timeout: TimeInterval) -> String {
    pollUntilClear(pid: pid, target: target, timeout: timeout) { p in processRows().first(where: { $0.pid == p }) }
}

/// Targeted poll via kAudioHardwarePropertyTranslatePIDToProcessObject:
/// one lookup plus 4 property reads per poll, isolating genuine Core Audio
/// state-propagation latency from full-sweep enumeration overhead.
func pollTargeted(pid: Int32, mustContain: AudioObjectID, mustNotContain: AudioObjectID? = nil, timeout: TimeInterval) -> CheckResult {
    pollUntil(pid: pid, mustContain: mustContain, mustNotContain: mustNotContain, timeout: timeout) { p in
        targetedRow(forPID: p)
    }
}

func pollClearTargeted(pid: Int32, target: AudioObjectID, timeout: TimeInterval) -> String {
    pollUntilClear(pid: pid, target: target, timeout: timeout) { p in targetedRow(forPID: p) }
}

/// Opens BlackHole and holds it until killed (SIGTERM, no graceful
/// teardown -- deliberately, so the parent's clear-latency measurement
/// also incidentally checks that Core Audio's process registry cleans up
/// after an ungraceful exit, not just a cooperative one) or a generous
/// safety-net timeout elapses. Spawned by --self-test's cross-process leg
/// via a re-exec of this same binary; not meant to be run directly.
func holdBlackHoleUntilKilled(blackhole: Device) -> Never {
    guard let unit = makeInputUnit(device: blackhole.id) else { exit(1) }
    guard AudioOutputUnitStart(unit) == noErr else {
        disposeUninitialized(unit)
        exit(1)
    }
    Thread.sleep(forTimeInterval: 30.0)
    teardown(unit)
    exit(0)
}

/// Opens and fully closes BlackHole twice in a row (a real, self-contained
/// second activation, not a listener re-fire), then exits. Spawned by
/// --self-test's leg 4 to check whether a SECOND activation by the same
/// (separate) process is still detected -- this is what exposed the
/// IsRunningInput anomaly during investigation of this probe.
func repeatActivationBlackHole(blackhole: Device) -> Never {
    for _ in 0..<2 {
        guard let unit = makeInputUnit(device: blackhole.id) else { exit(1) }
        guard AudioOutputUnitStart(unit) == noErr else {
            disposeUninitialized(unit)
            exit(1)
        }
        Thread.sleep(forTimeInterval: 1.5)
        teardown(unit)
        Thread.sleep(forTimeInterval: 1.0)
    }
    exit(0)
}

func selfTest(devices: [Device], blackhole: Device) {
    let ourPID = ProcessInfo.processInfo.processIdentifier
    print("=== self-test: device-scoped demand detection ===")
    print("probe PID: \(ourPID)")
    print("BlackHole: \(blackhole.name)  uid=\(blackhole.uid)  id=\(blackhole.id)")

    if let def = defaultInputDeviceID() {
        let note = def == blackhole.id
            ? " (== BlackHole -- see negative-control corroboration note below)"
            : ""
        print("system default input device id: \(def)\(note)")
    }

    guard let negControl = negativeControlInputDevice(devices, excluding: blackhole.id) else {
        print("FAIL: no other input-capable device found besides BlackHole -- cannot run negative control")
        exit(1)
    }
    print("negative-control device: \(negControl.name)  uid=\(negControl.uid)  id=\(negControl.id)")
    print("")

    var overallPass = true

    // -- Leg 1: self-introspection, positive case, BlackHole ---------------
    // Two independent open/close cycles: one measured with the full-sweep
    // poll (same mechanism as report()/--watch), one with the targeted
    // PID-translate poll. Both must pass; the targeted figure is the one
    // to trust as an approximation of genuine propagation latency, the
    // sweep figure is kept for direct contrast (see findings doc).
    print("--- leg 1: self-introspection positive (BlackHole) -- full-sweep vs targeted timing ---")

    guard let sweepUnit = makeInputUnit(device: blackhole.id) else {
        print("FAIL: could not build/initialize AUHAL on BlackHole (see step above). This may be a TCC microphone-permission problem for this terminal.")
        exit(1)
    }
    let sweepStart = AudioOutputUnitStart(sweepUnit)
    guard sweepStart == noErr else {
        print("FAIL: AudioOutputUnitStart on BlackHole returned OSStatus \(sweepStart). If this is around first launch, it is very likely the terminal's microphone permission (TCC) has not been granted -- check System Settings > Privacy & Security > Microphone.")
        disposeUninitialized(sweepUnit)
        exit(1)
    }
    let sweepPositive = pollSweep(pid: ourPID, mustContain: blackhole.id, timeout: 5.0)
    print("  [full-sweep] " + sweepPositive.message)
    overallPass = overallPass && sweepPositive.passed
    teardown(sweepUnit)
    let sweepCleared = pollClearSweep(pid: ourPID, target: blackhole.id, timeout: 5.0)
    print("  [full-sweep] after stopping: \(sweepCleared)")

    guard let targetedUnit = makeInputUnit(device: blackhole.id) else {
        print("FAIL: could not build/initialize AUHAL on BlackHole for targeted-timing cycle")
        exit(1)
    }
    let targetedStart = AudioOutputUnitStart(targetedUnit)
    guard targetedStart == noErr else {
        print("FAIL: AudioOutputUnitStart on BlackHole (targeted cycle) returned OSStatus \(targetedStart)")
        disposeUninitialized(targetedUnit)
        exit(1)
    }
    let targetedPositive = pollTargeted(pid: ourPID, mustContain: blackhole.id, timeout: 5.0)
    print("  [targeted]   " + targetedPositive.message)
    overallPass = overallPass && targetedPositive.passed
    teardown(targetedUnit)
    let targetedCleared = pollClearTargeted(pid: ourPID, target: blackhole.id, timeout: 5.0)
    print("  [targeted]   after stopping: \(targetedCleared)")
    print("")

    // -- Leg 2: self-introspection, negative control ------------------------
    print("--- leg 2: self-introspection negative control (\(negControl.name)); BlackHole must NOT appear (targeted lookup) ---")
    guard let negUnit = makeInputUnit(device: negControl.id) else {
        print("FAIL: could not build/initialize AUHAL on negative-control device")
        exit(1)
    }
    let startStatus2 = AudioOutputUnitStart(negUnit)
    guard startStatus2 == noErr else {
        print("FAIL: AudioOutputUnitStart on negative-control device returned OSStatus \(startStatus2)")
        disposeUninitialized(negUnit)
        exit(1)
    }

    let negative = pollTargeted(pid: ourPID, mustContain: negControl.id, mustNotContain: blackhole.id, timeout: 5.0)
    print(negative.message)
    overallPass = overallPass && negative.passed

    teardown(negUnit)
    let clearedMsg2 = pollClearTargeted(pid: ourPID, target: negControl.id, timeout: 5.0)
    print("after stopping negative-control input: \(clearedMsg2)")
    print("")
    if let def = defaultInputDeviceID(), def == blackhole.id {
        print("note: the system default input device is BlackHole (id \(def)) for the entirety of leg 2. If kAudioProcessPropertyDevices had actually been reporting \"the system default input\" rather than \"the device this AUHAL instance opened\", BlackHole would have appeared in this leg's result even though only \(negControl.name) was open. It did not -- corroborating evidence the property is genuinely per-stream-scoped, not a coarse system-wide signal.")
        print("")
    }

    // -- Leg 3: cross-process test -- the actual production use case -------
    // Everything above is self-introspection: this process observing its
    // own PID. The real Mac agent never does that -- it watches OTHER
    // processes and explicitly skips its own PID. This leg spawns a
    // genuinely separate process that opens BlackHole, then observes it
    // from the parent using the full-sweep path (the same mechanism
    // report()/--watch use), which is what actually gets deployed.
    print("--- leg 3: cross-process test -- a different process opens BlackHole, observed via the normal full-sweep path ---")
    let exePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let child = Process()
    child.executableURL = URL(fileURLWithPath: exePath)
    child.arguments = ["--internal-hold-blackhole"]
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    do {
        try child.run()
    } catch {
        print("FAIL: could not spawn helper process at \(exePath): \(error)")
        overallPass = false
        print("")
        finishSelfTest(overallPass)
    }
    let childPID = child.processIdentifier
    print("helper PID: \(childPID)")

    let cross = pollSweep(pid: childPID, mustContain: blackhole.id, timeout: 5.0)
    print(cross.message)
    overallPass = overallPass && cross.passed

    child.terminate()
    child.waitUntilExit()
    let crossCleared = pollClearSweep(pid: childPID, target: blackhole.id, timeout: 5.0)
    print("after SIGTERM-ing the helper (no graceful teardown -- also checks OS cleanup on ungraceful exit): \(crossCleared)")
    print("")

    // -- Leg 4: repeat-activation reliability, cross-process ----------------
    // A genuinely separate process opens and fully closes BlackHole TWICE.
    // Detection is gated on device-list membership (this probe's
    // authoritative signal, see ProcessInfoRow's doc comment) for both
    // cycles. If runningInput fails to re-trigger on cycle 2 -- which is
    // exactly what happened during this probe's development -- that will
    // show up as an inline note on the cycle-2 PASS message below, without
    // affecting the pass/fail verdict, which is based on the signal this
    // probe found to actually be reliable.
    print("--- leg 4: repeat-activation reliability -- a different process opens+closes BlackHole twice; both activations must be detected ---")
    let child2 = Process()
    child2.executableURL = URL(fileURLWithPath: exePath)
    child2.arguments = ["--internal-repeat-activation-blackhole"]
    child2.standardOutput = FileHandle.nullDevice
    child2.standardError = FileHandle.nullDevice
    do {
        try child2.run()
    } catch {
        print("FAIL: could not spawn repeat-activation helper: \(error)")
        overallPass = false
        print("")
        finishSelfTest(overallPass)
    }
    let child2PID = child2.processIdentifier
    print("helper PID: \(child2PID) (will run two open/close cycles)")

    let cycle1 = pollSweep(pid: child2PID, mustContain: blackhole.id, timeout: 4.0)
    print("cycle 1: " + cycle1.message)
    overallPass = overallPass && cycle1.passed
    let cycle1Cleared = pollClearSweep(pid: child2PID, target: blackhole.id, timeout: 4.0)
    print("cycle 1 cleared: \(cycle1Cleared)")

    let cycle2 = pollSweep(pid: child2PID, mustContain: blackhole.id, timeout: 4.0)
    print("cycle 2: " + cycle2.message)
    overallPass = overallPass && cycle2.passed
    let cycle2Cleared = pollClearSweep(pid: child2PID, target: blackhole.id, timeout: 4.0)
    print("cycle 2 cleared: \(cycle2Cleared)")

    child2.waitUntilExit()
    print("")

    finishSelfTest(overallPass)
}

func finishSelfTest(_ overallPass: Bool) -> Never {
    print("=== self-test verdict ===")
    if overallPass {
        print("PASS: kAudioProcessPropertyDevices (input-scope device-list membership) correctly scoped demand to the device actually opened, for self-introspection, a genuinely separate process, and repeat activations by that process. IMPORTANT CAVEAT: kAudioProcessPropertyIsRunningInput was found NOT to reliably re-trigger past a process's first input activation -- see any \"[note: runningInput=false despite device-list membership]\" lines above and the findings doc. Demand detection must be gated on device-list membership, not on IsRunningInput.")
    } else {
        print("FAIL: device-scoped detection did NOT behave as the design requires even using device-list membership as the gating signal. See messages above. This is the most important finding in Phase 0 -- do not soften it.")
    }
    exit(overallPass ? 0 : 1)
}

// MARK: - main

let devices = allDevices()
let devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })

let args = CommandLine.arguments

if args.contains("--list-devices") {
    listDevices(devices)
    exit(0)
}

// UID-only match against the known BlackHole channel-count variants. Never
// matched by display name -- display names are localised and change.
let knownBlackHoleUIDs: Set<String> = ["BlackHole2ch_UID", "BlackHole16ch_UID", "BlackHole64ch_UID"]
guard let target = devices.first(where: { knownBlackHoleUIDs.contains($0.uid) })
else {
    print("BlackHole not found (looked for uid in \(knownBlackHoleUIDs)). Devices present:")
    devices.forEach { print("  \($0.name)  uid=\($0.uid)") }
    exit(1)
}

if args.contains("--internal-hold-blackhole") {
    // Internal use only: spawned by --self-test's cross-process leg (leg 3)
    // as a genuinely separate process to open BlackHole and hold it. Not
    // meant to be invoked directly.
    holdBlackHoleUntilKilled(blackhole: target)
} else if args.contains("--internal-repeat-activation-blackhole") {
    // Internal use only: spawned by --self-test's leg 4. Not meant to be
    // invoked directly.
    repeatActivationBlackHole(blackhole: target)
} else if args.contains("--self-test") {
    selfTest(devices: devices, blackhole: target)
} else if args.contains("--watch") {
    print("watching every 500 ms; Ctrl-C to stop\n")
    while true {
        report(target: target, devicesByID: devicesByID)
        Thread.sleep(forTimeInterval: 0.5)
    }
} else {
    report(target: target, devicesByID: devicesByID)
}
