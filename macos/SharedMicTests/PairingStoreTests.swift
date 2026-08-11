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

    // MARK: - Keychain

    private var keychainService: String!

    override func setUp() {
        super.setUp()
        keychainService = "com.sharedmic.tests.\(UUID().uuidString)"
    }

    override func tearDown() {
        if let service = keychainService {
            try? KeychainPairingStore(service: service, account: "default").clear()
        }
        super.tearDown()
    }

    func testKeychainStoreStartsEmpty() throws {
        let store = KeychainPairingStore(service: keychainService, account: "default")
        XCTAssertNil(try store.load())
    }

    func testKeychainStoreRoundTrips() throws {
        let store = KeychainPairingStore(service: keychainService, account: "default")
        let record = sampleRecord()
        try store.save(record)
        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded, record)
        XCTAssertEqual(loaded.token.count, SharedMicProtocol.tokenBytes)
    }

    func testKeychainSaveOverwritesRatherThanDuplicating() throws {
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
        let store = KeychainPairingStore(service: keychainService, account: "default")
        try store.save(sampleRecord())
        try store.clear()
        XCTAssertNil(try store.load())
        XCTAssertNoThrow(try store.clear())
    }
}
