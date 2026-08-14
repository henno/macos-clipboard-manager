import Foundation

/// Case folding that never changes the byte length.
///
/// Swift's `lowercased()` can change the UTF-8 length of a string, which would
/// desynchronise the folded bytes from the word-boundary bitset computed off the
/// original. Folding byte-wise instead keeps the two arrays index-aligned, and
/// covers everything Estonian needs: ASCII, the Latin-1 supplement (ä ö ü õ) and
/// the two Latin Extended-A pairs (š ž), all of which lowercase within their own
/// encoded length.
enum TextFold {
    static func fold(_ bytes: [UInt8]) -> [UInt8] {
        var out = bytes
        var i = 0
        while i < out.count {
            let b = out[i]
            if b < 0x80 {
                if b >= 0x41 && b <= 0x5A { out[i] = b + 0x20 }  // A-Z
                i += 1
            } else if b == 0xC3, i + 1 < out.count {
                // U+00C0...U+00DE -> +0x20, skipping U+00D7 (multiplication sign)
                let n = out[i + 1]
                if n >= 0x80 && n <= 0x9E && n != 0x97 { out[i + 1] = n + 0x20 }
                i += 2
            } else if b == 0xC5, i + 1 < out.count {
                // Latin Extended-A: uppercase is the even code point of each pair.
                let n = out[i + 1]
                if (n == 0xA0 || n == 0xBD) { out[i + 1] = n + 0x01 }  // Š -> š, Ž -> ž
                i += 2
            } else {
                i += utf8Width(b)
            }
        }
        return out
    }

    static func utf8Width(_ b: UInt8) -> Int {
        if b < 0x80 { return 1 }
        if b >= 0xF0 { return 4 }
        if b >= 0xE0 { return 3 }
        if b >= 0xC0 { return 2 }
        return 1  // continuation byte encountered out of place
    }

    /// A 32-bit summary of which character classes a string contains, used to
    /// reject non-matching candidates before doing any real work.
    /// Bits 0-25: a-z. Bit 26: digits. Bit 27: other ASCII. Bit 28: non-ASCII.
    static func mask(_ folded: [UInt8]) -> UInt32 {
        var m: UInt32 = 0
        for b in folded {
            if b >= 0x61 && b <= 0x7A { m |= 1 << UInt32(b - 0x61) }
            else if b >= 0x30 && b <= 0x39 { m |= 1 << 26 }
            else if b < 0x80 { m |= 1 << 27 }
            else { m |= 1 << 28 }
        }
        return m
    }

    /// Marks positions that start a word: the first byte, anything after a
    /// separator, and the lowercase-to-uppercase transition inside camelCase.
    /// Computed from the *original* bytes, since folding destroys case.
    static func boundaries(original: [UInt8]) -> [UInt8] {
        var bits = [UInt8](repeating: 0, count: (original.count + 7) / 8)
        guard !original.isEmpty else { return bits }

        func setBit(_ i: Int) { bits[i >> 3] |= UInt8(1 << (i & 7)) }
        func isSeparator(_ b: UInt8) -> Bool {
            switch b {
            case 0x20, 0x09, 0x0A, 0x0D,                    // whitespace
                 0x2F, 0x5C, 0x2D, 0x5F, 0x2E, 0x2C, 0x3A,  // / \ - _ . , :
                 0x3B, 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D,  // ; ( ) [ ] { }
                 0x22, 0x27, 0x3C, 0x3E, 0x3D, 0x2B, 0x2A,  // " ' < > = + *
                 0x26, 0x7C, 0x23, 0x40, 0x3F, 0x21, 0x24:  // & | # @ ? ! $
                return true
            default: return false
            }
        }
        func isLowerASCII(_ b: UInt8) -> Bool { b >= 0x61 && b <= 0x7A }
        func isUpperASCII(_ b: UInt8) -> Bool { b >= 0x41 && b <= 0x5A }

        setBit(0)
        for i in 1..<original.count {
            let prev = original[i - 1], cur = original[i]
            if isSeparator(prev) && !isSeparator(cur) { setBit(i) }
            else if isLowerASCII(prev) && isUpperASCII(cur) { setBit(i) }
        }
        return bits
    }

    static func isBoundary(_ bits: [UInt8], _ i: Int) -> Bool {
        let byte = i >> 3
        guard byte < bits.count else { return false }
        return bits[byte] & UInt8(1 << (i & 7)) != 0
    }
}
