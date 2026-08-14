import Foundation

struct SearchHit {
    let item: ClipItem
    let score: Int
    fileprivate let entryIndex: Int
}

/// The in-memory search index: one entry per history row, holding the folded
/// snippet bytes, its word-boundary bitset and a character mask.
///
/// Two things keep typing instant. The mask rejects most candidates with a
/// single AND before any scanning happens. And when the query only grows, we
/// rescore just the previous result set instead of the whole history -- adding a
/// character to a subsequence query can only ever remove matches, never add
/// them, so the narrowing is exact rather than approximate.
final class SearchIndex {
    static let shared = SearchIndex()

    private struct Entry {
        var item: ClipItem
        let folded: [UInt8]
        let boundaries: [UInt8]
        let mask: UInt32
        let appFolded: [UInt8]
    }

    /// Kept in updatedAt-descending order, which is also the display order for
    /// an empty query.
    private var entries: [Entry] = []

    // Incremental-narrowing cache.
    private var cachedTermsKey: String?
    private var cachedAppKey = ""
    private var cachedCandidates: [Int] = []

    // Retained so highlight positions can be recomputed for visible rows only.
    private var activeTerms: [[UInt8]] = []

    private init() {}

    // MARK: - Maintenance

    func rebuild(from items: [ClipItem]) {
        entries = items.map(Self.makeEntry)
        invalidate()
    }

    func insert(_ item: ClipItem) {
        entries.insert(Self.makeEntry(item), at: 0)
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

    /// Rough resident cost of the index, for the metrics readout.
    var approximateBytes: Int {
        entries.reduce(0) { $0 + $1.folded.count + $1.boundaries.count + $1.appFolded.count + 96 }
    }

    private func invalidate() {
        cachedTermsKey = nil
        cachedCandidates = []
    }

    private static func makeEntry(_ item: ClipItem) -> Entry {
        let original = Array(item.snippet.utf8)
        let folded = TextFold.fold(original)
        return Entry(
            item: item,
            folded: folded,
            boundaries: TextFold.boundaries(original: original),
            mask: TextFold.mask(folded),
            appFolded: TextFold.fold(Array((item.sourceName ?? "").utf8)))
    }

    // MARK: - Query

    /// `app:` narrows to a source application; everything else is a fuzzy term,
    /// and every term has to match.
    private struct Query {
        var appKey = ""
        var appFolded: [UInt8] = []
        var termsKey = ""
        var terms: [[UInt8]] = []
        var masks: [UInt32] = []
        var isEmpty: Bool { terms.isEmpty && appFolded.isEmpty }
    }

    private func parse(_ raw: String) -> Query {
        var q = Query()
        var termStrings: [String] = []
        for token in raw.split(separator: " ", omittingEmptySubsequences: true) {
            if token.lowercased().hasPrefix("app:") {
                q.appKey = String(token.dropFirst(4))
                q.appFolded = TextFold.fold(Array(q.appKey.utf8))
            } else {
                termStrings.append(String(token))
            }
        }
        q.termsKey = termStrings.joined(separator: " ")
        q.terms = termStrings.map { TextFold.fold(Array($0.utf8)) }
        q.masks = q.terms.map(TextFold.mask)
        return q
    }

    func search(_ raw: String) -> [SearchHit] {
        let started = CFAbsoluteTimeGetCurrent()
        let q = parse(raw)
        activeTerms = q.terms

        if q.isEmpty {
            invalidate()
            let hits = entries.enumerated().map {
                SearchHit(item: $0.element.item, score: 0, entryIndex: $0.offset)
            }
            record(started: started, candidates: entries.count)
            return hits
        }

        // Reuse the previous result set when the query only grew and the app
        // filter is unchanged; otherwise scan everything.
        let candidates: [Int]
        if let cachedKey = cachedTermsKey,
           cachedAppKey == q.appKey,
           !cachedKey.isEmpty,
           q.termsKey.hasPrefix(cachedKey) {
            candidates = cachedCandidates
        } else {
            candidates = Array(entries.indices)
        }

        var hits: [SearchHit] = []
        hits.reserveCapacity(min(candidates.count, 256))
        var surviving: [Int] = []
        surviving.reserveCapacity(min(candidates.count, 256))

        outer: for idx in candidates {
            let entry = entries[idx]
            if !q.appFolded.isEmpty {
                guard contains(entry.appFolded, q.appFolded) else { continue }
            }
            var total = 0
            for (t, term) in q.terms.enumerated() {
                // One AND rejects most rows without touching the text at all.
                guard q.masks[t] & entry.mask == q.masks[t] else { continue outer }
                guard let s = FuzzyMatcher.score(
                    query: term, text: entry.folded, boundaries: entry.boundaries)
                else { continue outer }
                total += s
            }
            surviving.append(idx)
            hits.append(SearchHit(item: entry.item, score: total, entryIndex: idx))
        }

        cachedTermsKey = q.termsKey
        cachedAppKey = q.appKey
        cachedCandidates = surviving

        // Score first, recency second, so equally good matches stay in the order
        // the user last touched them.
        hits.sort {
            $0.score != $1.score ? $0.score > $1.score : $0.item.updatedAt > $1.item.updatedAt
        }
        record(started: started, candidates: candidates.count)
        return hits
    }

    /// Byte offsets in the snippet to highlight. Recomputed per visible row.
    func highlightPositions(for hit: SearchHit) -> [Int] {
        guard hit.entryIndex < entries.count, !activeTerms.isEmpty else { return [] }
        let entry = entries[hit.entryIndex]
        guard entry.item.id == hit.item.id else { return [] }
        var out: [Int] = []
        for term in activeTerms {
            if let m = FuzzyMatcher.match(
                query: term, text: entry.folded, boundaries: entry.boundaries) {
                out.append(contentsOf: m.positions)
            }
        }
        return out
    }

    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let limit = haystack.count - needle.count
        var i = 0
        while i <= limit {
            var k = 0
            while k < needle.count, haystack[i + k] == needle[k] { k += 1 }
            if k == needle.count { return true }
            i += 1
        }
        return false
    }

    private func record(started: CFAbsoluteTime, candidates: Int) {
        Metrics.shared.recordSearch(
            micros: (CFAbsoluteTimeGetCurrent() - started) * 1_000_000,
            candidates: candidates)
    }
}
