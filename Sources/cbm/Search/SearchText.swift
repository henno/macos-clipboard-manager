import Foundation

/// Prepared once per clipboard entry. Offset records are limited to folds and
/// composed characters that need mapping; ordinary ASCII shares its buffers.
struct SearchText {
    private struct Change {
        let foldedStart: Int
        let originalStart: Int
        let foldedLength: Int
        let originalLength: Int
    }

    static let locale = Locale(identifier: "en_US_POSIX")
    let original: String
    let bytes: [UInt8]
    let mask: UInt32
    private let originalFolded: [UInt8]
    private let sharesFoldedBytes: Bool
    private let wordBits: [UInt8]
    private let changes: [Change]

    init(_ text: String) {
        original = text
        originalFolded = TextFold.fold(Array(text.utf8))
        var folded: [UInt8] = []
        folded.reserveCapacity(originalFolded.count)
        var words = [UInt8](repeating: 0, count: (originalFolded.count + 7) / 8)
        var offsets: [Change] = []
        var originalOffset = 0
        let utf8 = text.utf8
        var sourceIndex = utf8.startIndex
        var syncedOffset = 0
        var onlyASCII = true
        while originalOffset < originalFolded.count {
            let byte = originalFolded[originalOffset]
            // Plain ASCII needs neither a Character allocation nor a Foundation
            // fold. Hold an ASCII character before non-ASCII back for grapheme
            // processing, so a following combining accent stays attached.
            if byte < 128 && (originalOffset + 1 == originalFolded.count || originalFolded[originalOffset + 1] < 128) {
                let position = folded.count
                folded.append(byte)
                if words.count <= (position >> 3) { words.append(0) }
                if (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 95 {
                    words[position >> 3] |= UInt8(1 << (position & 7))
                }
                originalOffset += 1
                continue
            }
            sourceIndex = utf8.index(sourceIndex, offsetBy: originalOffset - syncedOffset)
            let characterIndex = String.Index(sourceIndex, within: text)!
            let character = text[characterIndex]
            let end = text.index(after: characterIndex).samePosition(in: utf8)!
            let width = utf8.distance(from: sourceIndex, to: end)
            let part: [UInt8]
            if let ascii = character.asciiValue {
                part = [ascii >= 65 && ascii <= 90 ? ascii + 32 : ascii]
            } else {
                onlyASCII = false
                part = Array(Self.fold(String(character)).utf8)
            }
            // Case folding can expand a character without changing its UTF-8
            // length (ß -> ss). A partial match still covers the whole original.
            if part.count != width || character.unicodeScalars.count > 1
                || (character.asciiValue == nil && String(decoding: part, as: UTF8.self).count > 1) {
                offsets.append(Change(foldedStart: folded.count, originalStart: originalOffset,
                                      foldedLength: part.count, originalLength: width))
            }
            let start = folded.count
            folded.append(contentsOf: part)
            while words.count < (folded.count + 7) / 8 { words.append(0) }
            if character.isLetter || character.isNumber || character == "_" {
                for position in start..<folded.count {
                    words[position >> 3] |= UInt8(1 << (position & 7))
                }
            }
            originalOffset += width
            sourceIndex = end
            syncedOffset = originalOffset
        }
        words = Array(words.prefix((folded.count + 7) / 8))
        sharesFoldedBytes = onlyASCII
        bytes = onlyASCII ? originalFolded : folded
        wordBits = words
        changes = offsets
        mask = TextFold.mask(folded)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    }

    var approximateBytes: Int {
        original.utf8.count + originalFolded.count + (sharesFoldedBytes ? 0 : bytes.count) + wordBits.count
            + changes.count * MemoryLayout<Change>.stride
    }

    func isWholeWord(_ range: Range<Int>) -> Bool {
        (range.lowerBound == 0 || !isWord(range.lowerBound - 1))
            && (range.upperBound == bytes.count || !isWord(range.upperBound))
    }

    private func isWord(_ offset: Int) -> Bool {
        wordBits[offset >> 3] & UInt8(1 << (offset & 7)) != 0
    }

    func isExact(_ range: Range<Int>, term: SearchTerm) -> Bool {
        let source = originalRange(range)
        if source.count == term.exact.count,
           originalFolded[source].elementsEqual(term.exact) { return true }
        // Canonically equivalent accents and case folds outside TextFold's
        // byte-preserving alphabet still count as exact spelling.
        guard originalFolded[source].contains(where: { $0 >= 0x80 }) else { return false }
        let value = String(decoding: originalFolded[source], as: UTF8.self)
        return value.folding(options: .caseInsensitive, locale: Self.locale)
            .precomposedStringWithCanonicalMapping == term.exactString
    }

    func originalRange(_ range: Range<Int>) -> Range<Int> {
        originalOffset(range.lowerBound, isEnd: false)..<originalOffset(range.upperBound, isEnd: true)
    }

    private func originalOffset(_ offset: Int, isEnd: Bool) -> Int {
        var low = 0
        var high = changes.count
        while low < high {
            let mid = (low + high) / 2
            if changes[mid].foldedStart < offset
                || (!isEnd && changes[mid].foldedStart == offset) {
                low = mid + 1
            } else { high = mid }
        }
        guard low > 0 else { return offset }
        let change = changes[low - 1]
        let end = change.foldedStart + change.foldedLength
        if offset < end {
            return change.originalStart + (isEnd ? change.originalLength : 0)
        }
        return change.originalStart + change.originalLength + offset - end
    }
}

struct SearchTerm {
    let bytes: [UInt8]
    let exact: [UInt8]
    let exactString: String
    let mask: UInt32
    let prefix: [Int]

    init(_ text: String) {
        bytes = Array(SearchText.fold(text).utf8)
        exactString = text.folding(options: .caseInsensitive, locale: SearchText.locale)
            .precomposedStringWithCanonicalMapping
        exact = Array(exactString.utf8)
        mask = TextFold.mask(bytes)
        var table = [Int](repeating: 0, count: bytes.count)
        var length = 0
        if bytes.count > 1 {
            for i in 1..<bytes.count {
                while length > 0, bytes[i] != bytes[length] { length = table[length - 1] }
                if bytes[i] == bytes[length] { length += 1 }
                table[i] = length
            }
        }
        prefix = table
    }
}
