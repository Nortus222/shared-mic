import Foundation

/// RFC 4648 base32 with the standard alphabet (`A`-`Z` then `2`-`7`).
///
/// Written by hand because Foundation has no base32. `encode` emits unpadded
/// uppercase output, which is what protocol-v1 §11.2 specifies for display;
/// `decode` expects input already filtered to the alphabet and tolerates the
/// missing padding, so 52 characters decode to 32 bytes with the 4 trailing bits
/// discarded exactly as `base64.b32decode` does after re-padding.
public enum Base32 {
    private static let alphabet: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    private static func value(of character: Character) -> UInt64? {
        if let ascii = character.asciiValue {
            switch ascii {
            case 0x41...0x5a: return UInt64(ascii - 0x41)          // A-Z -> 0-25
            case 0x32...0x37: return UInt64(ascii - 0x32) + 26     // 2-7 -> 26-31
            default: return nil
            }
        }
        return nil
    }

    public static func encode(_ data: Data) -> String {
        var output = String()
        output.reserveCapacity((data.count * 8 + 4) / 5)
        var buffer: UInt64 = 0
        var bitsInBuffer = 0
        for byte in data {
            buffer = (buffer << 8) | UInt64(byte)
            bitsInBuffer += 8
            while bitsInBuffer >= 5 {
                let index = Int((buffer >> UInt64(bitsInBuffer - 5)) & 0x1f)
                output.append(alphabet[index])
                bitsInBuffer -= 5
            }
        }
        if bitsInBuffer > 0 {
            let index = Int((buffer << UInt64(5 - bitsInBuffer)) & 0x1f)
            output.append(alphabet[index])
        }
        return output
    }

    /// Returns nil if any character is outside the alphabet.
    public static func decode(_ text: String) -> Data? {
        var output = Data(capacity: text.count * 5 / 8)
        var buffer: UInt64 = 0
        var bitsInBuffer = 0
        for character in text {
            guard let symbol = value(of: character) else { return nil }
            buffer = (buffer << 5) | symbol
            bitsInBuffer += 5
            if bitsInBuffer >= 8 {
                output.append(UInt8((buffer >> UInt64(bitsInBuffer - 8)) & 0xff))
                bitsInBuffer -= 8
            }
        }
        return output
    }
}
