import XCTest
@testable import SharedMic

final class PairingStoreTests: XCTestCase {
    private func sampleRecord() -> PairingRecord {
        PairingRecord(
            host: "192.168.1.42",
            port: 47_800,
            token: Data((0..<32).map { UInt8($0) }),
            certificateFingerprint: String(repeating: "ab", count: 32)
        )
    }

    // MARK: - In-memory

    func testInMemoryStoreStartsEmpty() throws {
        let store = InMemoryPairingStore()
        XCTAssertNil(try store.load())
    }

    func testInMemoryStoreRoundTrips() throws {
        let store = InMemoryPairingStore()
        let record = sampleRecord()
        try store.save(record)
        XCTAssertEqual(try store.load(), record)
    }

    func testInMemoryStoreClears() throws {
        let store = InMemoryPairingStore()
        try store.save(sampleRecord())
        try store.clear()
        XCTAssertNil(try store.load())
    }

    /// Task 13 review, item 1: the hard-stop marker rides along with the rest
    /// of the record so a relaunch can reconstruct `.hardStop` from storage
    /// alone.
    func testInMemoryStoreRoundTripsTheHardStopMarker() throws {
        let store = InMemoryPairingStore()
        let record = PairingRecord(host: "192.168.1.42",
                                   port: 47_800,
                                   token: Data((0..<32).map { UInt8($0) }),
                                   certificateFingerprint: String(repeating: "ab", count: 32),
                                   hardStopPresentedFingerprint: String(repeating: "cd", count: 32))
        try store.save(record)
        let loaded = try store.load()
        XCTAssertEqual(loaded, record)
        XCTAssertEqual(loaded?.hardStopPresentedFingerprint, String(repeating: "cd", count: 32))
    }

    func testTestHostUsesAnInMemoryStore() {
        // Fail-safe for the gating above: if the XCTest detection signal ever
        // goes missing, this fails instead of silently returning a Keychain
        // store that would prompt on every suite run.
        XCTAssertTrue(SharedMicApp.pairingStore() is InMemoryPairingStore)
    }

    // MARK: - Keychain

    private var keychainService: String!

    override func setUp() {
        super.setUp()
        keychainService = "com.sharedmic.tests.\(UUID().uuidString)"
    }

    /// The keychain tests below hit the real login keychain, which prompts
    /// for access — and the prompt reappears on every rebuild because the
    /// test host is ad-hoc signed. They stay available for an explicit
    /// owner-gated run via `SHAREDMIC_TEST_KEYCHAIN=1`, but a default
    /// `xcodebuild test` never touches the keychain.
    private var keychainTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["SHAREDMIC_TEST_KEYCHAIN"] == "1"
    }

    private func requireKeychainTests() throws {
        try XCTSkipUnless(keychainTestsEnabled,
                          "keychain tests are owner-gated: re-run with SHAREDMIC_TEST_KEYCHAIN=1")
    }

    override func tearDown() {
        if keychainTestsEnabled, let service = keychainService {
            try? KeychainPairingStore(service: service, account: "default").clear()
        }
        super.tearDown()
    }

    func testKeychainStoreStartsEmpty() throws {
        try requireKeychainTests()
        let store = KeychainPairingStore(service: keychainService, account: "default")
        XCTAssertNil(try store.load())
    }

    func testKeychainStoreRoundTrips() throws {
        try requireKeychainTests()
        let store = KeychainPairingStore(service: keychainService, account: "default")
        let record = sampleRecord()
        try store.save(record)
        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded, record)
        XCTAssertEqual(loaded.token.count, SharedMicProtocol.tokenBytes)
    }

    func testKeychainSaveOverwritesRatherThanDuplicating() throws {
        try requireKeychainTests()
        let store = KeychainPairingStore(service: keychainService, account: "default")
        try store.save(sampleRecord())
        let replacement = PairingRecord(
            host: "10.0.0.9",
            port: 47_801,
            token: Data(repeating: 0x7f, count: 32),
            certificateFingerprint: String(repeating: "cd", count: 32)
        )
        try store.save(replacement)
        XCTAssertEqual(try store.load(), replacement)
    }

    func testKeychainClearRemovesTheItemAndIsIdempotent() throws {
        try requireKeychainTests()
        let store = KeychainPairingStore(service: keychainService, account: "default")
        try store.save(sampleRecord())
        try store.clear()
        XCTAssertNil(try store.load())
        XCTAssertNoThrow(try store.clear())
    }

    /// Task 13 review, item 1: the hard-stop marker must survive the real
    /// Keychain's JSON-blob serialization, not just the in-memory double.
    func testKeychainStoreRoundTripsTheHardStopMarker() throws {
        try requireKeychainTests()
        let store = KeychainPairingStore(service: keychainService, account: "default")
        let record = PairingRecord(host: "192.168.1.42",
                                   port: 47_800,
                                   token: Data((0..<32).map { UInt8($0) }),
                                   certificateFingerprint: String(repeating: "ab", count: 32),
                                   hardStopPresentedFingerprint: String(repeating: "cd", count: 32))
        try store.save(record)
        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded, record)
        XCTAssertEqual(loaded.hardStopPresentedFingerprint, String(repeating: "cd", count: 32))
    }
}
