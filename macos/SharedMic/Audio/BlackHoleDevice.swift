import CoreAudio
import Foundation

/// One output device as Core Audio reports it. `name` is carried for
/// debugging only: resolution matches on `uid` and never on `name`
/// (probe fix note — an earlier probe matched `$0.uid.contains("BlackHole")`
/// with a display-name fallback, which would select an impostor).
public struct OutputAudioDevice: Equatable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String

    public init(id: AudioObjectID, uid: String, name: String) {
        self.id = id
        self.uid = uid
        self.name = name
    }
}

public protocol AudioDeviceLister {
    func outputDevices() -> [OutputAudioDevice]
}

/// The live Core Audio implementation. Never caches the `AudioObjectID`:
/// IDs are unstable across reboots and device replugs, so every `resolve`
/// re-enumerates and matches by UID.
public struct CoreAudioDeviceLister: AudioDeviceLister {
    public init() {}

    public func outputDevices() -> [OutputAudioDevice] {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &devicesAddress, 0, nil, &dataSize) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(0), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &devicesAddress, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id in
            guard let uid = deviceUID(for: id) else { return nil }
            return OutputAudioDevice(id: id, uid: uid, name: deviceName(for: id) ?? uid)
        }
    }

    private func deviceUID(for id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, &uid) == noErr else {
            return nil
        }
        return uid as String?
    }

    private func deviceName(for id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, &name) == noErr else {
            return nil
        }
        return name as String?
    }
}

public struct BlackHoleDeviceError: Error, Equatable {
    public let message: String
}

/// Finds BlackHole by UID for `AudioRenderer` (spec §3.4, §6.4).
///
/// The UID value lives here rather than in `SharedMicProtocol`: that enum is
/// the frozen wire contract, and this is local app config — and keeping the
/// only `BlackHole` references under `macos/SharedMic/Audio/` preserves the
/// device-rule tripwire (`grep -rn "BlackHole" macos/SharedMic` must show
/// hits only under `Audio/` until Phase 3).
///
/// Never touches the default output device: resolution only *reads* the
/// device list, and the renderer sets its unit's device explicitly.
public enum BlackHoleDevice {
    /// Measured on the target Mac (demand-findings probe): the installed
    /// device is `BlackHole 2ch`, `uid=BlackHole2ch_UID`. The 16ch/64ch
    /// variants are recognized as fallbacks; the 2ch device is preferred.
    public static let preferredUID = "BlackHole2ch_UID"

    public static let knownUIDs = [
        "BlackHole2ch_UID",
        "BlackHole16ch_UID",
        "BlackHole64ch_UID",
    ]

    public static let unavailableMessage =
        "BlackHole 2ch was not found. Install it from " +
        "https://github.com/ExistentialAudio/BlackHole " +
        "and restart SharedMic. SharedMic never changes your default output device."

    public static func resolve(with lister: AudioDeviceLister) throws -> AudioObjectID {
        let devices = lister.outputDevices()
        if let preferred = devices.first(where: { $0.uid == preferredUID }) {
            return preferred.id
        }
        if let fallback = devices.first(where: { knownUIDs.contains($0.uid) }) {
            return fallback.id
        }
        throw BlackHoleDeviceError(message: unavailableMessage)
    }

    public static func isPresent(with lister: AudioDeviceLister) -> Bool {
        (try? resolve(with: lister)) != nil
    }
}
