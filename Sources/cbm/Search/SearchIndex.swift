import Foundation

struct SearchHit {
    let item: ClipItem
    fileprivate let entryIndex: Int
    fileprivate let relevance: SubstringMatcher.Match
}

/// Full text is loaded and normalized only when the index changes. Keystrokes
/// scan prepared bytes and never read clipboard representations from disk.
final class SearchIndex {
    static let shared = SearchIndex()

    private struct Entry {
        var item: ClipItem
        let text: SearchText
        let appFolded: String
    }

    private var entries: [Entry] = []
    private var cachedTerms: [[UInt8]] = []
    private var cachedApp = ""
    private var cachedCandidates: [Int] = []
    private var activeTerms: [SearchTerm] = []

    private init() {}

    // MARK: - Maintenance

    func rebuild(from items: [ClipItem], texts: [Int64: String] = [:]) {
        entries = items.map { Self.makeEntry($0, text: texts[$0.id]) }
        invalidate()
    }

    func insert(_ item: ClipItem, text: String? = nil) {
        entries.insert(Self.makeEntry(item, text: text), at: 0)
        invalidate()
    }

    func touch(id: Int64, updatedAt: Double) {
        guard let idx = entries.firstIndex(where: { $0.item.id == id }) else { return }
        var entry = entries.remove(at: idx)
        let i = entry.item
        entry.item = ClipItem(
            id: i.id, hash: i.hash, kind: i.kind, snippet: i.snippet,
            sourceBundleID: i.sourceBundleID, sourceName: i.sourceName, sourceHost: i.sourceHost,
            createdAt: i.createdAt, updatedAt: updatedAt, totalBytes: i.totalBytes,
            hasThumb: i.hasThumb, pixelWidth: i.pixelWidth, pixelHeight: i.pixelHeight)
        entries.insert(entry, at: 0)
        invalidate()
    }

    func remove(ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.item.id) }
        invalidate()
    }

    var count: Int { entries.count }

    var approximateBytes: Int {
        entries.reduce(0) { $0 + $1.text.approximateBytes + $1.appFolded.utf8.count + 96 }
    }

    private func invalidate() {
        cachedTerms = []
        cachedCandidates = []
    }

    private static func makeEntry(_ item: ClipItem, text: String?) -> Entry {
        Entry(item: item, text: SearchText(text ?? item.snippet),
              appFolded: SearchText.fold(item.sourceName ?? ""))
    }

    // MARK: - Query

    private struct Query {
        var app = ""
        var terms: [SearchTerm] = []
        var isEmpty: Bool { terms.isEmpty && app.isEmpty }
    }

    private func parse(_ raw: String) -> Query {
        var query = Query()
        var seen = Set<String>()
        for token in raw.split(whereSeparator: { $0.isWhitespace }) {
            if token.lowercased().hasPrefix("app:") {
                query.app = SearchText.fold(String(token.dropFirst(4)))
            } else {
                let term = SearchTerm(String(token))
                if !term.bytes.isEmpty, seen.insert(term.exactString).inserted {
                    query.terms.append(term)
                }
            }
        }
        return query
    }

    func search(_ raw: String) -> [SearchHit] {
        let started = CFAbsoluteTimeGetCurrent()
        let query = parse(raw)
        activeTerms = query.terms
        let keys = query.terms.map(\.bytes)

        if query.isEmpty {
            invalidate()
            let relevance = SubstringMatcher.Match(exactTerms: 0, wholeTerms: 0, span: 0, ranges: [])
            let hits = entries.enumerated().map {
                SearchHit(item: $0.element.item, entryIndex: $0.offset, relevance: relevance)
            }
            record(started: started, candidates: entries.count)
            return hits
        }

        // A cache is safe only when every previous term is still a prefix of
        // the corresponding new term. Editing whitespace or dropping duplicate
        // terms must not hide results that a cold search would find.
        let narrows = !cachedTerms.isEmpty && cachedApp == query.app
            && keys.count >= cachedTerms.count
            && zip(cachedTerms, keys).allSatisfy { old, new in new.starts(with: old) }
        let candidates = narrows ? cachedCandidates : Array(entries.indices)
        var hits: [SearchHit] = []
        var surviving: [Int] = []
        for idx in candidates {
            let entry = entries[idx]
            guard query.app.isEmpty || entry.appFolded.contains(query.app),
                  let relevance = SubstringMatcher.match(terms: query.terms, text: entry.text) else { continue }
            surviving.append(idx)
            hits.append(SearchHit(item: entry.item, entryIndex: idx, relevance: relevance))
        }
        cachedTerms = keys
        cachedApp = query.app
        cachedCandidates = surviving
        hits.sort {
            if $0.relevance.ranksBefore($1.relevance) { return true }
            if $1.relevance.ranksBefore($0.relevance) { return false }
            if $0.item.updatedAt != $1.item.updatedAt { return $0.item.updatedAt > $1.item.updatedAt }
            return $0.item.id > $1.item.id
        }
        record(started: started, candidates: candidates.count)
        return hits
    }

    /// A hit beyond the original label gets a short context around the best
    /// match. The original item is retained for preview, copying and pasting.
    func display(for hit: SearchHit) -> (text: String, positions: [Int]) {
        guard hit.entryIndex < entries.count else { return (hit.item.snippet, []) }
        let entry = entries[hit.entryIndex]
        guard entry.item.id == hit.item.id, !activeTerms.isEmpty else { return (hit.item.snippet, []) }
        let ranges = hit.relevance.ranges.map(entry.text.originalRange)
        let label: String
        if ranges.allSatisfy({ $0.upperBound <= hit.item.snippet.utf8.count }) {
            label = hit.item.snippet
        } else if let first = ranges.min(by: { $0.lowerBound < $1.lowerBound }) {
            let original = entry.text.original
            let byteIndex = original.utf8.index(original.utf8.startIndex, offsetBy: first.lowerBound)
            let anchor = String.Index(byteIndex, within: original) ?? original.startIndex
            let start = original.index(anchor, offsetBy: -24, limitedBy: original.startIndex) ?? original.startIndex
            let contextEnd = original.index(start, offsetBy: 120, limitedBy: original.endIndex) ?? original.endIndex
            let matchByteEnd = original.utf8.index(original.utf8.startIndex, offsetBy: first.upperBound)
            let matchEnd = String.Index(matchByteEnd, within: original) ?? original.endIndex
            let end = max(contextEnd, matchEnd)
            label = (start > original.startIndex ? "… " : "") + original[start..<end]
                + (end < original.endIndex ? " …" : "")
        } else {
            label = hit.item.snippet
        }
        return (label, SubstringMatcher.highlightPositions(terms: activeTerms, text: SearchText(label)))
    }

    func highlightPositions(for hit: SearchHit) -> [Int] {
        guard hit.entryIndex < entries.count, entries[hit.entryIndex].item.id == hit.item.id else { return [] }
        return SubstringMatcher.highlightPositions(terms: activeTerms, text: SearchText(hit.item.snippet))
    }

    private func record(started: CFAbsoluteTime, candidates: Int) {
        Metrics.shared.recordSearch(
            micros: (CFAbsoluteTimeGetCurrent() - started) * 1_000_000,
            candidates: candidates)
    }
}
