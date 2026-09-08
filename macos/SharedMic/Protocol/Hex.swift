import Foundation

/// Lowercase hex, the only hex representation this protocol uses:
/// the `GREETING` nonce, the `HELLO` mac, and the pinned certificate
/// fingerprint are all lowercase hex (protocol-v1 §2, §5, §6).
public enum Hex {
    private static let digits: [Character] = Array("0123456789abcdef")

    public static func encode(_ data: Data) -> String {
        var output = String()
        output.reserveCapacity(data.count * 2)
        for byte in data {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0f)])
        }
        return output
    }

    /// Returns nil for odd-length input or any character outside `[0-9a-fA-F]`.
    ///
    /// Validated against the ASCII range explicitly: `Character.hexDigitValue` follows Unicode's
    /// `Hex_Digit` property and also accepts fullwidth digit/letter code points (e.g. U+FF11 "１"),
    /// which this wire format's hex fields (nonce, mac, certificate fingerprint) must never be
    /// silently decoded from.
    public static func decode(_ string: String) -> Data? {
        let characters = Array(string)
        guard characters.count % 2 == 0 else { return nil }
        var output = Data(capacity: characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = asciiHexValue(characters[index]),
                  let low = asciiHexValue(characters[index + 1]) else { return nil }
            output.append(UInt8(high << 4 | low))
            index += 2
        }
        return output
    }

    private static func asciiHexValue(_ character: Character) -> UInt8? {
        guard character.isASCII, let scalar = character.asciiValue else { return nil }
        switch scalar {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return scalar - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return scalar - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return scalar - UInt8(ascii: "A") + 10
        default:
            return nil
        }
    }
}
