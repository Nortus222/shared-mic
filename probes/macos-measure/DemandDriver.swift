// DemandDriver: scriptable BlackHole demand for headless measurement.
//
// Opens BlackHole input (AUHAL, silent callback — never touches sample data)
// for a fixed hold, so `AudioDemandObserver` sees a real cross-process demand
// edge with known timing. The measurement tests spawn this per activation.
//
// Build: swiftc -O -o /tmp/DemandDriver DemandDriver.swift
// Run:   DemandDriver --hold-ms 1500 [--dual]
//
// Stdout protocol (one item per line, parseable):
//   PID <pid>
//   OPEN <unix-ms>        printed after AudioOutputUnitStart returns
//   DUAL ok|miss          only with --dual
//   CLOSE <unix-ms>       printed after AudioOutputUnitStop returns
//
// Exit codes: 0 held and released cleanly; 2 BlackHole not found;
// 3 unit setup/start failed. Never logs or persists captured audio.

import AudioToolbox
import CoreAudio
import Darwin
import Foundation

let knownUIDs = ["BlackHole2ch_UID", "BlackHole16ch_UID", "BlackHole64ch_UID"]
let preferredUID = "BlackHole2ch_UID"

func deviceUID(_ id: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
    var value: Unmanaged<CFString>?
    guard withUnsafeMutablePointer(to: &value, {
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
    }) == noErr, let unwrapped = value else { return nil }
    return unwrapped.takeRetainedValue() as String
}

func resolveBlackHole() -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
          size > 0 else { return nil }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
        return nil
    }
    var fallback: AudioObjectID?
    for id in ids {
        guard let uid = deviceUID(id) else { continue }
        if uid == preferredUID { return id }
        if fallback == nil && knownUIDs.contains(uid) { fallback = id }
    }
    return fallback
}

func defaultInputDevice() -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var device: AudioObjectID = 0
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
        return nil
    }
    return device
}

let silentCallback: AURenderCallback = { _, _, _, _, _, _ in noErr }

func makeInputUnit(device: AudioObjectID) -> AudioUnit? {
    var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                          componentSubType: kAudioUnitSubType_HALOutput,
                                          componentManufacturer: kAudioUnitManufacturer_Apple,
                                          componentFlags: 0,
                                          componentFlagsMask: 0)
    guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }
    var unitOpt: AudioUnit?
    guard AudioComponentInstanceNew(comp, &unitOpt) == noErr, let unit = unitOpt else { return nil }
    var enableIO: UInt32 = 1
    guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                &enableIO, UInt32(MemoryLayout<UInt32>.size)) == noErr else {
        AudioComponentInstanceDispose(unit)
        return nil
    }
    var disableIO: UInt32 = 0
    guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                &disableIO, UInt32(MemoryLayout<UInt32>.size)) == noErr else {
        AudioComponentInstanceDispose(unit)
        return nil
    }
    var dev = device
    guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                &dev, UInt32(MemoryLayout<AudioObjectID>.size)) == noErr else {
        AudioComponentInstanceDispose(unit)
        return nil
    }
    var callback = AURenderCallbackStruct(inputProc: silentCallback, inputProcRefCon: nil)
    guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr else {
        AudioComponentInstanceDispose(unit)
        return nil
    }
    guard AudioUnitInitialize(unit) == noErr else {
        AudioComponentInstanceDispose(unit)
        return nil
    }
    return unit
}

func unixMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000.0) }

var holdMs = 0
var dual = false
var index = 1
while index < CommandLine.arguments.count {
    switch CommandLine.arguments[index] {
    case "--hold-ms" where index + 1 < CommandLine.arguments.count:
        holdMs = Int(CommandLine.arguments[index + 1]) ?? 0
        index += 2
    case "--dual":
        dual = true
        index += 1
    default:
        index += 1
    }
}
guard holdMs > 0 else {
    fputs("usage: DemandDriver --hold-ms <N> [--dual]\n", stderr)
    exit(2)
}
guard let target = resolveBlackHole() else {
    fputs("DemandDriver: BlackHole not found\n", stderr)
    exit(2)
}
guard let unit = makeInputUnit(device: target) else {
    fputs("DemandDriver: unit setup failed\n", stderr)
    exit(3)
}
var secondUnit: AudioUnit?
if dual, let other = defaultInputDevice(), other != target {
    secondUnit = makeInputUnit(device: other)
}

print("PID \(ProcessInfo.processInfo.processIdentifier)"); fflush(stdout)
guard AudioOutputUnitStart(unit) == noErr else {
    fputs("DemandDriver: start failed\n", stderr)
    exit(3)
}
if let second = secondUnit { AudioOutputUnitStart(second) }
print("OPEN \(unixMs())"); fflush(stdout)
if dual { print(secondUnit == nil ? "DUAL miss" : "DUAL ok"); fflush(stdout) }
Thread.sleep(forTimeInterval: Double(holdMs) / 1000.0)
if let second = secondUnit {
    AudioOutputUnitStop(second)
    AudioUnitUninitialize(second)
    AudioComponentInstanceDispose(second)
}
AudioOutputUnitStop(unit)
print("CLOSE \(unixMs())"); fflush(stdout)
AudioUnitUninitialize(unit)
AudioComponentInstanceDispose(unit)
