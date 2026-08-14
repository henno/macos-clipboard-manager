import Foundation

/// Subsequence matching with positional scoring, in the style of fzf.
///
/// A forward pass finds the earliest position where the whole query has matched,
/// a backward pass tightens the start so the match is as compact as possible,
/// and a final pass scores that window: consecutive runs and word starts are
/// rewarded, gaps are penalised. All three passes are linear in the text length,
/// which is why a 256-byte snippet costs so little to score.
enum FuzzyMatcher {
    private static let scoreMatch = 16
    private static let bonusBoundary = 8
    private static let bonusConsecutive = 4
    private static let bonusFirstCharMultiplier = 2
    private static let gapStart = -3
    private static let gapExtension = -1

    /// Fast path: score only, no allocation.
    static func score(query: [UInt8], text: [UInt8], boundaries: [UInt8]) -> Int? {
        core(query: query, text: text, boundaries: boundaries, wantPositions: false)?.score
    }

    /// Slow path: score plus the matched byte offsets, for highlighting. Only
    /// ever called for the handful of rows actually on screen.
    static func match(query: [UInt8], text: [UInt8], boundaries: [UInt8]) -> (score: Int, positions: [Int])? {
        core(query: query, text: text, boundaries: boundaries, wantPositions: true)
    }

    private static func core(
        query: [UInt8], text: [UInt8], boundaries: [UInt8], wantPositions: Bool
    ) -> (score: Int, positions: [Int])? {
        guard !query.isEmpty else { return (0, []) }
        guard text.count >= query.count else { return nil }

        // Forward: where does the query finish matching, earliest?
        var pidx = 0
        var sidx = -1
        var eidx = -1
        var i = 0
        while i < text.count {
            if text[i] == query[pidx] {
                if sidx < 0 { sidx = i }
                pidx += 1
                if pidx == query.count { eidx = i + 1; break }
            }
            i += 1
        }
        guard eidx >= 0, sidx >= 0 else { return nil }

        // Backward: pull the start forward so the window is as tight as possible.
        pidx = query.count - 1
        var j = eidx - 1
        while j >= sidx {
            if text[j] == query[pidx] {
                pidx -= 1
                if pidx < 0 { sidx = j; break }
            }
            j -= 1
        }

        var score = 0
        var inGap = false
        var consecutive = 0
        var firstBonus = 0
        var qi = 0
        var positions: [Int] = []
        if wantPositions { positions.reserveCapacity(query.count) }

        for k in sidx..<eidx {
            if qi < query.count, text[k] == query[qi] {
                if wantPositions { positions.append(k) }
                score += scoreMatch
                var bonus = TextFold.isBoundary(boundaries, k) ? bonusBoundary : 0
                if consecutive == 0 {
                    firstBonus = bonus
                } else {
                    // A run inherits the best bonus seen at its head, so
                    // "commit" scoring against "git-commit" keeps the word-start
                    // credit across the whole run rather than just its first byte.
                    if bonus >= bonusBoundary { firstBonus = max(firstBonus, bonus) }
                    bonus = max(max(bonus, firstBonus), bonusConsecutive)
                }
                score += qi == 0 ? bonus * bonusFirstCharMultiplier : bonus
                inGap = false
                consecutive += 1
                qi += 1
            } else {
                score += inGap ? gapExtension : gapStart
                inGap = true
                consecutive = 0
                firstBonus = 0
            }
        }

        // Nudge earlier and shorter matches ahead of otherwise equal ones.
        score -= sidx / 4
        score -= text.count / 128
        return (score, positions)
    }
}
