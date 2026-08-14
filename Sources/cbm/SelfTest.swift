import Foundation

/// Tests for the pure logic: case folding, the mask prefilter, match ranking and
/// the search index.
///
/// These live inside the app binary and run via `cbm --self-test` rather than in
/// an XCTest bundle, because XCTest and swift-testing both ship with Xcode and
/// this machine has only the Command Line Tools. The cost is a few kilobytes of
/// unreachable code in the shipped binary; the benefit is tests that actually
/// run here. If a full Xcode ever gets installed, this moves to a test target
/// with a library split and no other changes.
enum SelfTest {
    private static var failures = 0
    private static var passes = 0

    static func run() -> Int32 {
        failures = 0
        passes = 0

        textFolding()
        masks()
        boundaries()
        matching()
        searchIndex()

        print("")
        if failures == 0 {
            print("all \(passes) checks passed")
        } else {
            print("\(failures) of \(passes + failures) checks FAILED")
        }
        return failures == 0 ? 0 : 1
    }

    // MARK: harness

    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            passes += 1
        } else {
            failures += 1
            let extra = detail()
            print("  FAIL  \(name)\(extra.isEmpty ? "" : "  — \(extra)")")
        }
    }

    private static func section(_ title: String) {
        print("\(title)")
    }

    // MARK: helpers

    private static func fold(_ s: String) -> String {
        String(decoding: TextFold.fold(Array(s.utf8)), as: UTF8.self)
    }

    private static func score(_ query: String, _ text: String) -> Int? {
        let original = Array(text.utf8)
        return FuzzyMatcher.score(
            query: TextFold.fold(Array(query.utf8)),
            text: TextFold.fold(original),
            boundaries: TextFold.boundaries(original: original))
    }

    private static func item(_ id: Int64, _ snippet: String, app: String? = nil) -> ClipItem {
        ClipItem(
            id: id, hash: "h\(id)", kind: .text, snippet: snippet,
            sourceBundleID: app.map { "bundle.\($0)" }, sourceName: app,
            createdAt: Double(id), updatedAt: Double(id),
            totalBytes: Int64(snippet.utf8.count),
            hasThumb: false, pixelWidth: 0, pixelHeight: 0)
    }

    // MARK: cases

    private static func textFolding() {
        section("text folding")
        check("ascii lowercases", fold("Hello WORLD 123") == "hello world 123")
        check("estonian vowels fold", fold("ÕÄÖÜ") == "õäöü", fold("ÕÄÖÜ"))
        check("s-caron and z-caron fold", fold("ŠŽ") == "šž", fold("ŠŽ"))
        check("mixed text folds", fold("Tõnu Ärkas") == "tõnu ärkas")

        // The boundary bitset is indexed by byte offset, so a fold that changed
        // the length would silently desynchronise highlighting and scoring.
        for sample in ["ÕÄÖÜŠŽ", "Hello", "ÿ", "日本語", "×÷", "ß", "🙂"] {
            check(
                "folding preserves byte length: \(sample)",
                TextFold.fold(Array(sample.utf8)).count == Array(sample.utf8).count)
        }

        // U+00D7 sits inside the Latin-1 uppercase range but is a maths symbol;
        // shifting it would turn × into ÷.
        check("multiplication sign untouched", fold("2×3") == "2×3", fold("2×3"))
    }

    private static func masks() {
        section("mask prefilter")
        let text = TextFold.mask(TextFold.fold(Array("github.com".utf8)))
        let present = TextFold.mask(TextFold.fold(Array("ghc".utf8)))
        let absent = TextFold.mask(TextFold.fold(Array("ghz".utf8)))
        check("subset query passes", present & text == present)
        check("query with unseen letter is rejected", absent & text != absent)
    }

    private static func boundaries() {
        section("word boundaries")
        let s = Array("git-commit fooBar".utf8)
        let b = TextFold.boundaries(original: s)
        check("string start is a boundary", TextFold.isBoundary(b, 0))
        check("after a hyphen is a boundary", TextFold.isBoundary(b, 4))
        check("after a space is a boundary", TextFold.isBoundary(b, 11))
        check("camelCase hump is a boundary", TextFold.isBoundary(b, 14))
        check("mid-word is not a boundary", !TextFold.isBoundary(b, 1))
    }

    private static func matching() {
        section("fuzzy matching")
        check("subsequence matches", score("gthb", "github.com") != nil)
        check("empty query matches", score("", "anything") != nil)
        check("absent characters reject", score("zzz", "github.com") == nil)
        check("order is respected", score("bug", "github.com") == nil)
        check("query longer than text rejects", score("longer than text", "short") == nil)
        check("matching is case insensitive", score("GITHUB", "github.com") != nil)

        if let consecutive = score("com", "commit message"), let scattered = score("com", "c o m") {
            check("consecutive beats scattered", consecutive > scattered,
                  "\(consecutive) vs \(scattered)")
        } else {
            check("consecutive beats scattered", false, "one side did not match")
        }

        if let atStart = score("com", "git commit"), let midWord = score("com", "incomparable") {
            check("word start beats mid-word", atStart > midWord, "\(atStart) vs \(midWord)")
        } else {
            check("word start beats mid-word", false, "one side did not match")
        }

        check("estonian query, uppercase text", score("tõnu", "TÕNU ÄRKAS") != nil)
        check("estonian uppercase query, lowercase text", score("ÄRKAS", "tõnu ärkas") != nil)

        let text = Array("github.com".utf8)
        let m = FuzzyMatcher.match(
            query: TextFold.fold(Array("git".utf8)),
            text: TextFold.fold(text),
            boundaries: TextFold.boundaries(original: text))
        check("positions are reported", m?.positions == [0, 1, 2], String(describing: m?.positions))
    }

    private static func searchIndex() {
        section("search index")
        let index = SearchIndex.shared

        index.rebuild(from: [item(3, "third"), item(2, "second"), item(1, "first")])
        check("empty query returns everything newest first",
              index.search("").map(\.item.id) == [3, 2, 1])

        index.rebuild(from: [
            item(3, "unrelated text"),
            item(2, "some github mirror"),
            item(1, "github.com/example"),
        ])
        let ranked = index.search("github").map(\.item.id)
        check("non-matching entries are dropped", Set(ranked) == [1, 2], "\(ranked)")
        check("word-start match ranks first", ranked.first == 1, "\(ranked)")

        index.rebuild(from: [item(2, "git commit message"), item(1, "git push")])
        check("every term must match", index.search("git commit").map(\.item.id) == [2])

        // The narrowing optimisation must be exact: growing a query has to give
        // precisely what a cold search for the same string gives.
        let many = (1...200).map { item(Int64($0), "entry number \($0) github commit") }
        index.rebuild(from: many)
        _ = index.search("g")
        _ = index.search("gi")
        _ = index.search("git")
        let narrowed = index.search("gith").map(\.item.id)
        index.rebuild(from: many)
        let cold = index.search("gith").map(\.item.id)
        check("incremental narrowing equals cold search", narrowed == cold)
        check("narrowing found something", !narrowed.isEmpty)

        // Shrinking the query has to widen the candidate set again.
        index.rebuild(from: many)
        _ = index.search("gith")
        let widened = index.search("git").map(\.item.id)
        index.rebuild(from: many)
        check("shrinking the query re-widens", widened == index.search("git").map(\.item.id))

        index.rebuild(from: [item(2, "hello", app: "Safari"), item(1, "hello", app: "Terminal")])
        check("app filter narrows by source", index.search("app:safari").map(\.item.id) == [2])
        check("app filter combines with terms",
              index.search("app:term hello").map(\.item.id) == [1])

        index.rebuild(from: [item(2, "b"), item(1, "a")])
        index.touch(id: 1, updatedAt: 99)
        check("touch moves an entry to the front", index.search("").map(\.item.id) == [1, 2])

        index.rebuild(from: [item(2, "b"), item(1, "a")])
        index.remove(ids: [2])
        check("remove drops an entry", index.search("").map(\.item.id) == [1])

        index.rebuild(from: [])
    }
}
