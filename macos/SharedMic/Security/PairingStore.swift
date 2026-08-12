import Foundation
import Security

/// Everything pairing established: where the Windows agent is, the shared token
/// (protocol-v1 §11.1), and the pinned certificate fingerprint (§2).
public struct PairingRecord: Equatable {
    public let host: String
    public let port: UInt16
    public let token: Data
    public let certificateFingerprint: String
    /// Non-nil means the pinned peer's most recent certificate did not match
    /// `certificateFingerprint` — the "presented" side of a hard stop, kept
    /// alongside the "expected" `certificateFingerprint` above so a relaunch can
    /// reconstruct `.hardStop` from the stored record alone rather than dialing
    /// the mismatching peer again to rediscover it. Set only by
    /// `ConnectionCoordinator` on a `fingerprintMismatch` event; cleared by any
    /// record a successful `pair(...)` produces (the explicit user pairing
    /// action the spec sanctions) and by `unpair()` clearing the whole record.
    public let hardStopPresentedFingerprint: String?

    public init(host: String,
               port: UInt16,
               token: Data,
               certificateFingerprint: String,
               hardStopPresentedFingerprint: String? = nil) {
        self.host = host
        self.port = port
        self.token = token
        self.certificateFingerprint = certificateFingerprint.lowercased()
        self.hardStopPresentedFingerprint = hardStopPresentedFingerprint?.lowercased()
    }
}

public protocol PairingStore: AnyObject {
    func save(_ record: PairingRecord) throws
    func load() throws -> PairingRecord?
    func clear() throws
}

/// Test double. Never used by the shipping app.
public final class InMemoryPairingStore: PairingStore {
    private var record: PairingRecord?
    private let lock = NSLock()

    public init() {}

    public func save(_ record: PairingRecord) throws {
        lock.lock(); defer { lock.unlock() }
        self.record = record
    }

    public func load() throws -> PairingRecord? {
        lock.lock(); defer { lock.unlock() }
        return record
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        record = nil
    }
}

public enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case corruptRecord
}

/// Design spec §7.1: the Mac stores the token and the pinned fingerprint in the
/// Keychain.
///
/// Serialized as a small JSON object in a single `kSecClassGenericPassword` item
/// so the whole record is written and read atomically — a half-updated pairing
/// (new token, old fingerprint) would be indistinguishable from an attack.
/// The token is stored hex-encoded inside that blob and is never logged.
public final class KeychainPairingStore: PairingStore {
    private let service: String
    private let account: String

    public init(service: String = "com.sharedmic.SharedMic.pairing",
                account: String = "default") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public func save(_ record: PairingRecord) throws {
        var payload: [String: Any] = [
            "host": record.host,
            "port": Int(record.port),
            "tokenHex": Hex.encode(record.token),
            "certificateFingerprint": record.certificateFingerprint
        ]
        if let hardStopPresentedFingerprint = record.hardStopPresentedFingerprint {
            payload["hardStopPresentedFingerprint"] = hardStopPresentedFingerprint
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        // Delete-then-add keeps save idempotent and avoids a partial update.
        SecItemDelete(baseQuery as CFDictionary)

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrDescription as String] = "SharedMic pairing"

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func load() throws -> PairingRecord? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = object["host"] as? String,
              let port = (object["port"] as? NSNumber)?.intValue,
              let tokenHex = object["tokenHex"] as? String,
              let token = Hex.decode(tokenHex),
              token.count == SharedMicProtocol.tokenBytes,
              let fingerprint = object["certificateFingerprint"] as? String else {
            throw KeychainError.corruptRecord
        }
        return PairingRecord(host: host,
                             port: UInt16(truncatingIfNeeded: port),
                             token: token,
                             certificateFingerprint: fingerprint,
                             hardStopPresentedFingerprint: object["hardStopPresentedFingerprint"] as? String)
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
