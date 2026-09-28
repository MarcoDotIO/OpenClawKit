import Foundation

/// Helpers for decoding Bonjour-escaped service names.
public enum BonjourEscapes {
    /// mDNS / DNS-SD commonly escapes bytes in instance names as `\DDD` (decimal-encoded),
    /// e.g. spaces are `\032`.
    ///
    /// Escaped bytes are decoded as UTF-8, so multibyte names such as `Caf\195\169` become `Café`.
    /// When the escaped bytes are not valid UTF-8, each `\DDD` falls back to the Unicode scalar with
    /// that value. Invalid escapes are kept verbatim.
    public static func decode(_ input: String) -> String {
        var bytes: [UInt8] = []
        var sawEscapedByte = false
        var i = input.startIndex
        while i < input.endIndex {
            if let (value, next) = self.decimalEscape(in: input, at: i) {
                if value <= 0xFF {
                    bytes.append(UInt8(value))
                    sawEscapedByte = true
                } else if let scalar = UnicodeScalar(value) {
                    bytes.append(contentsOf: Array(String(Character(scalar)).utf8))
                } else {
                    bytes.append(contentsOf: Array(input[i..<next].utf8))
                }
                i = next
                continue
            }
            bytes.append(contentsOf: Array(String(input[i]).utf8))
            i = input.index(after: i)
        }
        if let decoded = String(bytes: bytes, encoding: .utf8) {
            return decoded
        }
        return sawEscapedByte ? self.decodeScalars(input) : input
    }

    /// Legacy per-scalar decoding used when escaped bytes are not valid UTF-8.
    private static func decodeScalars(_ input: String) -> String {
        var out = ""
        var i = input.startIndex
        while i < input.endIndex {
            if let (value, next) = self.decimalEscape(in: input, at: i), let scalar = UnicodeScalar(value) {
                out.append(Character(scalar))
                i = next
                continue
            }
            out.append(input[i])
            i = input.index(after: i)
        }
        return out
    }

    /// Parses `\DDD` at `index`, returning the decimal value and the index after the escape.
    private static func decimalEscape(in input: String, at index: String.Index) -> (Int, String.Index)? {
        guard input[index] == "\\",
              let d0 = input.index(index, offsetBy: 1, limitedBy: input.index(before: input.endIndex)),
              let d1 = input.index(index, offsetBy: 2, limitedBy: input.index(before: input.endIndex)),
              let d2 = input.index(index, offsetBy: 3, limitedBy: input.index(before: input.endIndex)),
              input[d0].isASCII, input[d0].isNumber,
              input[d1].isASCII, input[d1].isNumber,
              input[d2].isASCII, input[d2].isNumber,
              let value = Int(String(input[d0...d2]))
        else { return nil }
        return (value, input.index(index, offsetBy: 4))
    }
}
