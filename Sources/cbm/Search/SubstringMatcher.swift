import Foundation

enum SubstringMatcher {
    struct Match {
        let exactTerms: Int
        let wholeTerms: Int
        let span: Int
        let ranges: [Range<Int>]

        func ranksBefore(_ other: Match) -> Bool {
            if exactTerms != other.exactTerms { return exactTerms > other.exactTerms }
            if wholeTerms != other.wholeTerms { return wholeTerms > other.wholeTerms }
            return span < other.span
        }
    }

    /// KMP iterators keep scans linear and memory bounded even when a single
    /// letter occurs millions of times in a long clipboard entry.
    private struct Cursor {
        var offset = 0
        var matched = 0

        mutating func next(in text: SearchText, term: SearchTerm, quality: Int? = nil) -> Range<Int>? {
            guard !term.bytes.isEmpty else { return nil }
            while offset < text.bytes.count {
                let byte = text.bytes[offset]
                while matched > 0, byte != term.bytes[matched] { matched = term.prefix[matched - 1] }
                if byte == term.bytes[matched] { matched += 1 }
                offset += 1
                if matched == term.bytes.count {
                    let range = (offset - matched)..<offset
                    matched = term.prefix[matched - 1]
                    if quality == nil || SubstringMatcher.quality(range, in: text, term: term) == quality {
                        return range
                    }
                }
            }
            return nil
        }
    }

    private static func quality(_ range: Range<Int>, in text: SearchText, term: SearchTerm) -> Int {
        (text.isExact(range, term: term) ? 2 : 0) + (text.isWholeWord(range) ? 1 : 0)
    }

    static func match(terms: [SearchTerm], text: SearchText) -> Match? {
        guard !terms.isEmpty else { return Match(exactTerms: 0, wholeTerms: 0, span: 0, ranges: []) }
        var qualities: [Int] = []
        var cursors: [Cursor] = []
        var current: [Range<Int>] = []
        for term in terms {
            guard !term.bytes.isEmpty, term.mask & text.mask == term.mask else { return nil }
            var cursor = Cursor()
            var best = -1
            var first: Range<Int>?
            var resume = Cursor()
            while let range = cursor.next(in: text, term: term) {
                let rank = quality(range, in: text, term: term)
                if rank > best {
                    best = rank
                    first = range
                    resume = cursor
                }
                if best == 3 { break }
            }
            guard best >= 0 else { return nil }
            qualities.append(best)
            current.append(first!)
            cursors.append(resume)
        }
        var bestRanges = current
        var bestSpan = Int.max
        while true {
            let first = current.indices.min { current[$0].lowerBound < current[$1].lowerBound }!
            let span = current.map(\.upperBound).max()! - current[first].lowerBound
            if span < bestSpan { bestSpan = span; bestRanges = current }
            if terms.count == 1 { break }
            guard let next = cursors[first].next(in: text, term: terms[first], quality: qualities[first]) else { break }
            current[first] = next
        }
        return Match(exactTerms: qualities.filter { $0 >= 2 }.count,
                     wholeTerms: qualities.filter { $0 & 1 != 0 }.count,
                     span: bestSpan, ranges: bestRanges)
    }

    /// Used only for visible labels, so highlighting every contiguous occurrence
    /// never allocates in proportion to the full clipboard payload.
    static func highlightPositions(terms: [SearchTerm], text: SearchText) -> [Int] {
        var positions = Set<Int>()
        for term in terms {
            var cursor = Cursor()
            while let range = cursor.next(in: text, term: term) {
                positions.formUnion(text.originalRange(range))
            }
        }
        return positions.sorted()
    }
}
