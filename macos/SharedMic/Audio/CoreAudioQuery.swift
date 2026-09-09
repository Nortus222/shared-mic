import CoreAudio
import Foundation

private final class ListenerBox {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
}

private let demandListenerProc: AudioObjectPropertyListenerProc = { _, _, _, clientData in
    guard let clientData else { return noErr }
    Unmanaged<ListenerBox>.fromOpaque(clientData).takeUnretainedValue().block()
    return noErr
}

public protocol CoreAudioQuery: AnyObject {
    var ownPID: Int32 { get }
    func resolveBlackHole() -> AudioObjectID?
    func processObjectIDs() -> [AudioObjectID]
    func pid(for object: AudioObjectID) -> Int32?
    func bundleID(for object: AudioObjectID) -> String
    func inputDeviceIDs(for object: AudioObjectID) -> [AudioObjectID]
    func processObject(forPID pid: Int32) -> AudioObjectID?
    func addProcessListListener(_ block: @escaping () -> Void) -> Bool
    func addDeviceListener(processObject: AudioObjectID, block: @escaping () -> Void) -> Bool
    func removeDeviceListener(processObject: AudioObjectID)
    func removeAllListeners()
}

public final class LiveCoreAudioQuery: CoreAudioQuery {
    public let ownPID: Int32
    private struct Registration { let object: AudioObjectID; let ptr: UnsafeMutableRawPointer }
    private var processListBoxes: [UnsafeMutableRawPointer] = []
    private var deviceRegistrations: [Registration] = []
    private var processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var deviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyDevices,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)

    public init(ownPID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.ownPID = ownPID
    }

    public func resolveBlackHole() -> AudioObjectID? {
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
            guard let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID) else { continue }
            if uid == BlackHoleDevice.preferredUID { return id }
            if fallback == nil && BlackHoleDevice.knownUIDs.contains(uid) { fallback = id }
        }
        return fallback
    }

    public func processObjectIDs() -> [AudioObjectID] {
        var address = processListAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    public func pid(for object: AudioObjectID) -> Int32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    public func bundleID(for object: AudioObjectID) -> String {
        stringProperty(object, selector: kAudioProcessPropertyBundleID) ?? "<none>"
    }

    public func inputDeviceIDs(for object: AudioObjectID) -> [AudioObjectID] {
        var address = deviceAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    public func processObject(forPID pid: Int32) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pidValue = pid_t(pid)
        var outObject: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pidValue) { qualifier -> OSStatus in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<pid_t>.size), qualifier,
                                       &size, &outObject)
        }
        guard status == noErr, outObject != kAudioObjectUnknown else { return nil }
        return outObject
    }

    public func addProcessListListener(_ block: @escaping () -> Void) -> Bool {
        let box = ListenerBox(block)
        let ptr = Unmanaged.passRetained(box).toOpaque()
        var address = processListAddress
        let status = AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, demandListenerProc, ptr)
        if status == noErr {
            processListBoxes.append(ptr)
            return true
        }
        Unmanaged<ListenerBox>.fromOpaque(ptr).release()
        return false
    }

    public func addDeviceListener(processObject: AudioObjectID, block: @escaping () -> Void) -> Bool {
        let box = ListenerBox(block)
        let ptr = Unmanaged.passRetained(box).toOpaque()
        var address = deviceAddress
        let status = AudioObjectAddPropertyListener(processObject, &address, demandListenerProc, ptr)
        if status == noErr {
            deviceRegistrations.append(Registration(object: processObject, ptr: ptr))
            return true
        }
        Unmanaged<ListenerBox>.fromOpaque(ptr).release()
        return false
    }

    public func removeDeviceListener(processObject: AudioObjectID) {
        var address = deviceAddress
        deviceRegistrations.removeAll { reg in
            guard reg.object == processObject else { return false }
            AudioObjectRemovePropertyListener(reg.object, &address, demandListenerProc, reg.ptr)
            Unmanaged<ListenerBox>.fromOpaque(reg.ptr).release()
            return true
        }
    }

    public func removeAllListeners() {
        var processAddress = processListAddress
        var deviceAddressCopy = deviceAddress
        for ptr in processListBoxes {
            AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &processAddress, demandListenerProc, ptr)
            Unmanaged<ListenerBox>.fromOpaque(ptr).release()
        }
        processListBoxes.removeAll()
        for reg in deviceRegistrations {
            AudioObjectRemovePropertyListener(reg.object, &deviceAddressCopy, demandListenerProc, reg.ptr)
            Unmanaged<ListenerBox>.fromOpaque(reg.ptr).release()
        }
        deviceRegistrations.removeAll()
    }

    private func stringProperty(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let unmanaged = value else { return nil }
        return unmanaged.takeRetainedValue() as String
    }
}
