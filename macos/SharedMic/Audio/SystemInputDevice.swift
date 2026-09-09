import CoreAudio
import Foundation

public struct SystemInputInfo: Equatable {
    public let name: String
    public let uid: String

    public init(name: String, uid: String) {
        self.name = name
        self.uid = uid
    }

    public var isBlackHole: Bool { BlackHoleDevice.knownUIDs.contains(uid) }
}

/// Reads the Mac's current system input device for the §3.4 menu display.
/// Read-only by construction: no setter exists anywhere in this type, and the
/// agent must never change the system input device.
public enum SystemInputDevice {
    public static func current() -> SystemInputInfo? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &device) == noErr else {
            return nil
        }
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uidSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &uidAddress, 0, nil, &uidSize) == noErr,
              uidSize > 0 else { return nil }
        var uidValue: Unmanaged<CFString>?
        guard withUnsafeMutablePointer(to: &uidValue, {
            AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, $0)
        }) == noErr, let uidUnmanaged = uidValue else { return nil }
        let uid = uidUnmanaged.takeRetainedValue() as String
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var nameSize: UInt32 = 0
        var name = uid
        if AudioObjectGetPropertyDataSize(device, &nameAddress, 0, nil, &nameSize) == noErr,
           nameSize > 0 {
            var nameValue: Unmanaged<CFString>?
            if withUnsafeMutablePointer(to: &nameValue, {
                AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, $0)
            }) == noErr, let nameUnmanaged = nameValue {
                name = nameUnmanaged.takeRetainedValue() as String
            }
        }
        return SystemInputInfo(name: name, uid: uid)
    }
}
