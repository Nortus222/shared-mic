// Throwaway probe for spec open question 1: does macOS report per-process
// input device usage well enough to scope demand detection to one device?
//
// Build: swiftc -O -o demand-probe DemandProbe.swift
// Run:   ./demand-probe                one snapshot
//        ./demand-probe --watch        poll twice a second until Ctrl-C
//        ./demand-probe --list-devices full device inventory (id, uid, name)
//        ./demand-probe --self-test    fully automated: opens input on BlackHole
//                                       and on the built-in mic from *this*
//                                       process and checks kAudioProcessPropertyDevices
//                                       reports the right device for each.
//
// Never logs or persists captured audio: the self-test's input callback does
// not touch the sample buffer at all, it only starts/stops the I/O cycle so
// this process registers as "running input" on the target device.

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

struct ProcessInfoRow {
    let pid: Int32
    let bundleID: String
    let runningInput: Bool
    let inputDeviceIDs: [AudioObjectID]
}

func processRows() -> [ProcessInfoRow] {
    objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        .map { processObject in
            ProcessInfoRow(
                pid: int32Value(processObject, kAudioProcessPropertyPID) ?? -1,
                bundleID: stringValue(processObject, kAudioProcessPropertyBundleID) ?? "<none>",
                runningInput: (uint32Value(processObject, kAudioProcessPropertyIsRunningInput) ?? 0) != 0,
                inputDeviceIDs: objectIDs(processObject,
                                          kAudioProcessPropertyDevices,
                                          kAudioObjectPropertyScopeInput)
            )
        }
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
    for row in rows where row.runningInput || !row.inputDeviceIDs.isEmpty {
        let onTarget = row.inputDeviceIDs.contains(target.id)
        // Normal reporting mode deliberately excludes the probe's own PID
        // from the demand count: the probe itself is not a "real" demand
        // signal outside of --self-test, where this exclusion is bypassed.
        let counts = row.runningInput && onTarget && row.pid != ourPID
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
    print("device-scoped demandCount = \(demandCount)")
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

enum AUError: Error { case step(String, OSStatus) }

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
        return nil
    }

    var disableIO: UInt32 = 0
    status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Output, 0,
                                   &disableIO, UInt32(MemoryLayout<UInt32>.size))
    guard status == noErr else {
        print("  makeInputUnit: EnableIO(output) failed, status=\(status)")
        return nil
    }

    var dev = device
    status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0,
                                   &dev, UInt32(MemoryLayout<AudioObjectID>.size))
    guard status == noErr else {
        print("  makeInputUnit: CurrentDevice failed, status=\(status)")
        return nil
    }

    var callback = AURenderCallbackStruct(inputProc: silentInputCallback, inputProcRefCon: nil)
    status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                                   kAudioUnitScope_Global, 0,
                                   &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    guard status == noErr else {
        print("  makeInputUnit: SetInputCallback failed, status=\(status)")
        return nil
    }

    status = AudioUnitInitialize(unit)
    guard status == noErr else {
        print("  makeInputUnit: AudioUnitInitialize failed, status=\(status)")
        return nil
    }

    return unit
}

func teardown(_ unit: AudioUnit) {
    AudioOutputUnitStop(unit)
    AudioUnitUninitialize(unit)
    AudioComponentInstanceDispose(unit)
}

struct CheckResult {
    let passed: Bool
    let message: String
}

/// Polls the process object list (self-test does NOT exclude our own PID --
/// that exclusion is a --watch/default-mode-only convenience) until our PID
/// shows runningInput=true with `mustContain` in its input-scope device list
/// and, if given, `mustNotContain` absent from it. Returns pass/fail plus a
/// human-readable timing/diagnostic message.
func pollForSelf(ourPID: Int32,
                  mustContain: AudioObjectID,
                  mustNotContain: AudioObjectID? = nil,
                  timeout: TimeInterval) -> CheckResult {
    let start = Date()
    var lastSeen: ProcessInfoRow?
    while Date().timeIntervalSince(start) < timeout {
        let rows = processRows()
        if let row = rows.first(where: { $0.pid == ourPID }) {
            lastSeen = row
            let hasTarget = row.inputDeviceIDs.contains(mustContain)
            let hasForbidden = mustNotContain.map { row.inputDeviceIDs.contains($0) } ?? false
            if row.runningInput && hasForbidden {
                return CheckResult(passed: false,
                    message: "FAIL: pid=\(ourPID) runningInput=true but input-device list contains the forbidden device \(mustNotContain!) -- devices=\(row.inputDeviceIDs)")
            }
            if row.runningInput && hasTarget {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                return CheckResult(passed: true,
                    message: "PASS (\(ms)ms): pid=\(ourPID) runningInput=true, input devices=\(row.inputDeviceIDs) contains target \(mustContain)")
            }
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return CheckResult(passed: false,
        message: "FAIL: timed out after \(Int(timeout*1000))ms waiting for pid=\(ourPID). Last seen row: \(String(describing: lastSeen))")
}

/// Polls until our own PID's runningInput goes false (or the row disappears
/// entirely), returning how long that took.
func pollForClear(ourPID: Int32, timeout: TimeInterval) -> String {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        let rows = processRows()
        let row = rows.first(where: { $0.pid == ourPID })
        if row == nil || row?.runningInput == false {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return "cleared after \(ms)ms"
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return "did NOT clear within \(Int(timeout*1000))ms"
}

func selfTest(devices: [Device], blackhole: Device) {
    let ourPID = ProcessInfo.processInfo.processIdentifier
    print("=== self-test: device-scoped demand detection ===")
    print("probe PID: \(ourPID)")
    print("BlackHole: \(blackhole.name)  uid=\(blackhole.uid)  id=\(blackhole.id)")

    guard let negControl = negativeControlInputDevice(devices, excluding: blackhole.id) else {
        print("FAIL: no other input-capable device found besides BlackHole -- cannot run negative control")
        exit(1)
    }
    print("negative-control device: \(negControl.name)  uid=\(negControl.uid)  id=\(negControl.id)")
    print("")

    var overallPass = true

    // -- Positive test: open input on BlackHole from this process ----------
    print("--- positive test: this process opens input on BlackHole ---")
    guard let blackholeUnit = makeInputUnit(device: blackhole.id) else {
        print("FAIL: could not build/initialize AUHAL on BlackHole (see step above). This may be a TCC microphone-permission problem for this terminal.")
        exit(1)
    }
    let startStatus1 = AudioOutputUnitStart(blackholeUnit)
    guard startStatus1 == noErr else {
        print("FAIL: AudioOutputUnitStart on BlackHole returned OSStatus \(startStatus1). If this is -10851/kAudioUnitErr_InvalidElement or similar around first launch, it is very likely the terminal's microphone permission (TCC) has not been granted -- check System Settings > Privacy & Security > Microphone.")
        AudioComponentInstanceDispose(blackholeUnit)
        exit(1)
    }

    let positive = pollForSelf(ourPID: ourPID, mustContain: blackhole.id, timeout: 5.0)
    print(positive.message)
    overallPass = overallPass && positive.passed

    teardown(blackholeUnit)
    let clearedMsg = pollForClear(ourPID: ourPID, timeout: 5.0)
    print("after stopping BlackHole input: \(clearedMsg)")
    print("")

    // -- Negative test: open input on the negative-control device instead --
    print("--- negative test: this process opens input on \(negControl.name); BlackHole must NOT appear ---")
    guard let negUnit = makeInputUnit(device: negControl.id) else {
        print("FAIL: could not build/initialize AUHAL on negative-control device")
        exit(1)
    }
    let startStatus2 = AudioOutputUnitStart(negUnit)
    guard startStatus2 == noErr else {
        print("FAIL: AudioOutputUnitStart on negative-control device returned OSStatus \(startStatus2)")
        AudioComponentInstanceDispose(negUnit)
        exit(1)
    }

    let negative = pollForSelf(ourPID: ourPID, mustContain: negControl.id, mustNotContain: blackhole.id, timeout: 5.0)
    print(negative.message)
    overallPass = overallPass && negative.passed

    teardown(negUnit)
    let clearedMsg2 = pollForClear(ourPID: ourPID, timeout: 5.0)
    print("after stopping negative-control input: \(clearedMsg2)")
    print("")

    print("=== self-test verdict ===")
    if overallPass {
        print("PASS: kAudioProcessPropertyDevices (input scope) correctly scoped this process's demand to the device actually opened, in both directions.")
    } else {
        print("FAIL: device-scoped detection did NOT behave as the design requires. See messages above. This is the most important finding in Phase 0 -- do not soften it.")
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

guard let target = devices.first(where: { $0.uid.contains("BlackHole") || $0.name.contains("BlackHole") })
else {
    print("BlackHole not found. Devices present:")
    devices.forEach { print("  \($0.name)  uid=\($0.uid)") }
    exit(1)
}

if args.contains("--self-test") {
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
