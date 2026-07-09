import Foundation

/// Repairs Cyrillic tags mojibaked by a Latin-1 misread.
///
/// ID3v1 and non-UTF ID3v2 frames carry raw bytes with no declared encoding, so
/// FFmpeg decodes them as Latin-1. Text actually written in Windows-1251 then
/// arrives as `Ñåñòðà Ñàøè` instead of `Сестра Саши` — every Cyrillic byte
/// rendered as the Latin-1 character sharing its value. Re-encoding those
/// characters back to bytes and decoding as CP1251 recovers the original.
///
/// The detection is deliberately strict, because the transform is destructive
/// for genuine Latin text: `Motörhead` would become `Motцrhead`. A string is
/// only repaired when it looks like a Cyrillic *phrase* rather than Latin text
/// with a few accents.
enum TextEncodingRepair {

    static func repair(_ s: String) -> String {
        guard let bytes = latin1Bytes(of: s), looksLikeCyrillicMojibake(s, bytes) else { return s }
        guard let candidate = String(bytes: bytes, encoding: .windowsCP1251),
              !candidate.unicodeScalars.contains("\u{FFFD}") else { return s }

        // Every non-ASCII letter must have become Cyrillic. If some byte decoded
        // to a symbol or another script, this wasn't CP1251 text.
        let highLetters = s.filter { $0.isLetter && !$0.isASCII }.count
        guard candidate.filter(\.isCyrillic).count == highLetters else { return s }
        return candidate
    }

    /// The string's scalars, if every one fits a byte — i.e. it could have come
    /// out of a Latin-1 decode. Any scalar above U+00FF means real Unicode text.
    private static func latin1Bytes(of s: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            guard scalar.value < 0x100 else { return nil }
            bytes.append(UInt8(scalar.value))
        }
        return bytes
    }

    private static func looksLikeCyrillicMojibake(_ s: String, _ bytes: [UInt8]) -> Bool {
        let letters = s.filter(\.isLetter)
        let high = letters.filter { !$0.isASCII }
        // Latin text sprinkles a few accents among ASCII letters ("Motörhead");
        // mojibaked Cyrillic is almost entirely high bytes.
        guard high.count >= 2, Double(high.count) / Double(letters.count) >= 0.6 else { return false }
        // CP1251 puts lowercase Cyrillic at 0xE0…0xFF. Requiring at least one
        // rejects all-caps Latin runs like "ÅÄÖ", whose bytes are all below 0xE0.
        return bytes.contains { $0 >= 0xE0 }
    }
}

private extension Character {
    var isCyrillic: Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else { return false }
        return (0x0400...0x04FF).contains(scalar.value)
    }
}
