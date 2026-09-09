import CoreAudio
import XCTest
@testable import SharedMic

private struct FakeDeviceLister: AudioDeviceLister {
    var devices: [OutputAudioDevice]
    func outputDevices() -> [OutputAudioDevice] { devices }
}

final class BlackHoleDeviceTests: XCTestCase {
    private func device(id: AudioObjectID, uid: String, name: String) -> OutputAudioDevice {
        OutputAudioDevice(id: id, uid: uid, name: name)
    }

    func testResolvesBlackHole2chByUID() throws {
        let lister = FakeDeviceLister(devices: [
            device(id: 42, uid: "AppleUSBAudioEngine:Vendor:Device:1234:2", name: "USB Audio"),
            device(id: 99, uid: "BlackHole2ch_UID", name: "BlackHole 2ch"),
        ])
        XCTAssertEqual(try BlackHoleDevice.resolve(with: lister), 99)
        XCTAssertTrue(BlackHoleDevice.isPresent(with: lister))
    }

    func testPrefers2chOverThe16chVariant() throws {
        let lister = FakeDeviceLister(devices: [
            device(id: 101, uid: "BlackHole16ch_UID", name: "BlackHole 16ch"),
            device(id: 99, uid: "BlackHole2ch_UID", name: "BlackHole 2ch"),
        ])
        XCTAssertEqual(try BlackHoleDevice.resolve(with: lister), 99)
    }

    func testFallsBackToThe16chVariantWhen2chIsAbsent() throws {
        let lister = FakeDeviceLister(devices: [
            device(id: 101, uid: "BlackHole16ch_UID", name: "BlackHole 16ch"),
        ])
        XCTAssertEqual(try BlackHoleDevice.resolve(with: lister), 101)
    }

    /// UID-only matching (probe fix note): a device that *calls itself*
    /// BlackHole but carries an unknown UID must never be selected.
    func testSameNameWithUnknownUIDIsNeverSelected() {
        let lister = FakeDeviceLister(devices: [
            device(id: 77, uid: "NotBlackHole_UID", name: "BlackHole 2ch"),
        ])
        XCTAssertThrowsError(try BlackHoleDevice.resolve(with: lister))
        XCTAssertFalse(BlackHoleDevice.isPresent(with: lister))
    }

    func testAbsentDeviceThrowsAGuidanceError() {
        let lister = FakeDeviceLister(devices: [
            device(id: 42, uid: "AppleUSBAudioEngine:Vendor:Device:1234:2", name: "USB Audio"),
        ])
        do {
            _ = try BlackHoleDevice.resolve(with: lister)
            XCTFail("resolving without BlackHole installed must throw")
        } catch let error as BlackHoleDeviceError {
            XCTAssertTrue(error.message.contains("BlackHole"),
                          "the error must name the missing device, not a bare OSStatus")
            XCTAssertTrue(error.message.contains("ExistentialAudio/BlackHole"),
                          "the error must tell the user where to get it")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}
