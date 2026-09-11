import XCTest
@testable import SharedMic

final class AppVersionTests: XCTestCase {
    func testFormatsShortAndBuild() {
        let bundle = Bundle(for: AppVersionTests.self)
        let version = AppVersion.current(bundle: bundle)
        XCTAssertFalse(version.isEmpty)
    }

    func testMissingKeysFallsBackToQuestionMark() {
        let bundle = Bundle(path: "/tmp") ?? .main
        let version = AppVersion.current(bundle: bundle)
        XCTAssertEqual(version, "?")
    }
}
