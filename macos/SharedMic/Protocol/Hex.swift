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
    public static func decode(_ string: String) -> Data? {
        let characters = Array(string)
        guard characters.count % 2 == 0 else { return nil }
        var output = Data(capacity: characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = characters[index].hexDigitValue,
                  let low = characters[index + 1].hexDigitValue,
                  high < 16, low < 16 else { return nil }
            output.append(UInt8(high << 4 | low))
            index += 2
        }
        return output
    }
}
