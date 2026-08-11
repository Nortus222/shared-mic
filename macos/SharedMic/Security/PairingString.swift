import Foundation

public enum PairingStringError: Error, Equatable {
    case invalidBase32
    case wrongDecodedLength(Int)
}

extension PairingStringError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidBase32:
            return "That pairing string could not be decoded. Check it against the Windows tray and retype it."
        case .wrongDecodedLength(let count):
            return "That pairing string decodes to \(count) bytes; a valid one decodes to 32. It looks truncated or over-long."
        }
    }
}

/// protocol-v1 §11.2.
///
/// Display: base32 (RFC 4648), uppercase, unpadded, hyphen-grouped in runs of 8.
/// 32 bytes -> 52 characters + 6 hyphens = 58 characters.
///
/// Input: uppercase first, delete every character outside `[A-Z2-7]`, decode,
/// then require exactly 32 bytes. **No confusable-character mapping** — a typed
/// `0` or `1` is deleted, and the length check then rejects the result. Adding a
/// mapping here would accept strings the Windows implementation rejects.
public enum PairingString {
    private static let alphabet: Set<Character> = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func encode(token: Data) -> String {
        let raw = Base32.encode(token)
        var groups: [String] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            let end = raw.index(index, offsetBy: SharedMicProtocol.pairingGroupSize,
                                limitedBy: raw.endIndex) ?? raw.endIndex
            groups.append(String(raw[index..<end]))
            index = end
        }
        return groups.joined(separator: "-")
    }

    public static func decode(_ text: String) throws -> Data {
        let cleaned = String(text.uppercased().filter { alphabet.contains($0) })
        guard !cleaned.isEmpty, let token = Base32.decode(cleaned) else {
            throw PairingStringError.invalidBase32
        }
        guard token.count == SharedMicProtocol.tokenBytes else {
            throw PairingStringError.wrongDecodedLength(token.count)
        }
        return token
    }
}
