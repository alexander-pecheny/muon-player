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
        guard let bytes = latin1Bytes(of: s), looksLikeCyrillicMojibake(bytes) else { return s }
        guard let candidate = String(bytes: bytes, encoding: .windowsCP1251) else { return s }

        // CP1251 is a single-byte code page, so the decode is one scalar per byte
        // and the two line up. Every high byte must have become a Cyrillic letter,
        // or punctuation the two code pages share («», the CP1251 apostrophe).
        // Anything else — a Latin letter, another script — means this wasn't
        // CP1251 text and the transform would corrupt it.
        let decoded = Array(candidate.unicodeScalars)
        guard decoded.count == bytes.count else { return s }
        for (byte, scalar) in zip(bytes, decoded) where byte >= 0x80 {
            guard scalar.isCyrillic || !scalar.properties.isAlphabetic else { return s }
        }
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

    /// Mojibaked Cyrillic arrives as whole words — unbroken runs of high bytes.
    /// Latin text sprinkles accents one at a time among ASCII (`Motörhead`,
    /// `Sigur Rós`), so a run of three tells the two apart without a dictionary.
    ///
    /// Counting *bytes* rather than letters matters: a `ч` mojibakes to `÷`, which
    /// is a division sign, and a title like `Áîí÷ Áðó Áîí÷ @ VIP PARTY` is mostly
    /// ASCII by letter count yet unmistakably Cyrillic by run length.
    private static func looksLikeCyrillicMojibake(_ bytes: [UInt8]) -> Bool {
        var run = 0
        var longest = 0
        for byte in bytes {
            run = byte >= 0x80 ? run + 1 : 0
            longest = max(longest, run)
        }
        // CP1251 puts lowercase Cyrillic at 0xE0…0xFF. Requiring at least one
        // rejects all-caps Latin runs like "ÅÄÖ", whose bytes are all below 0xE0.
        return longest >= 3 && bytes.contains { $0 >= 0xE0 }
    }
}

private extension Unicode.Scalar {
    var isCyrillic: Bool { (0x0400...0x04FF).contains(value) }
}
