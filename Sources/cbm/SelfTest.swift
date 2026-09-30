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
        contiguousSearch()
        searchStorage()
        contentIdentity()

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
            sourceBundleID: app.map { "bundle.\($0)" }, sourceName: app, sourceHost: nil,
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

    private static func contentIdentity() {
        section("duplicate detection")

        func rep(_ uti: String, _ text: String) -> Representation {
            Representation(uti: uti, data: Data(text.utf8))
        }
        let plain = "public.utf8-plain-text"
        let html = "public.html"
        let rtf = "public.rtf"
        let png = "public.png"
        let files = PasteboardReader.fileListType.rawValue

        // The case that started this: the same string copied once from a web
        // page (carrying HTML) and once from a plain field must be one entry.
        let withMarkup = BlobStore.contentIdentity(
            kind: .rich, reps: [rep(plain, "93DVYA"), rep(html, "<span>93DVYA</span>")])
        let bare = BlobStore.contentIdentity(kind: .text, reps: [rep(plain, "93DVYA")])
        check("same text with and without markup is one entry", withMarkup == bare)

        let otherMarkup = BlobStore.contentIdentity(
            kind: .rich, reps: [rep(plain, "93DVYA"), rep(rtf, "totally different rtf")])
        check("the markup itself does not affect identity", withMarkup == otherMarkup)

        check("different text stays separate",
              bare != BlobStore.contentIdentity(kind: .text, reps: [rep(plain, "93DVYB")]))

        // Two screenshots of identical dimensions produce the same snippet, so
        // only the bytes can tell them apart.
        let imageA = BlobStore.contentIdentity(kind: .image, reps: [rep(png, "bytes-A")])
        let imageB = BlobStore.contentIdentity(kind: .image, reps: [rep(png, "bytes-B")])
        check("different images stay separate", imageA != imageB)
        check("the same image is one entry",
              imageA == BlobStore.contentIdentity(kind: .image, reps: [rep(png, "bytes-A")]))

        // A Finder copy also carries the path as text; a copy of the same file
        // from elsewhere may not. Both are the same file.
        let fromFinder = BlobStore.contentIdentity(
            kind: .files, reps: [rep(files, "file:///a.png"), rep(plain, "/a.png")])
        let fromElsewhere = BlobStore.contentIdentity(kind: .files, reps: [rep(files, "file:///a.png")])
        check("same file from different apps is one entry", fromFinder == fromElsewhere)

        // Identical bytes in different roles must not collide.
        check("a filename and the same text are separate entries",
              BlobStore.contentIdentity(kind: .files, reps: [rep(files, "x")])
                  != BlobStore.contentIdentity(kind: .text, reps: [rep(plain, "x")]))

        check("an entry with nothing recognisable still gets an identity",
              !BlobStore.contentIdentity(kind: .text, reps: [rep("some.odd.uti", "x")]).isEmpty)
    }

    private static func searchIndex() {
        section("search index")
        let index = SearchIndex.shared

        index.rebuild(from: [item(2, "k o o l"), item(1, "koolimaja")])
        check("search rejects scattered letters and accepts word parts",
              index.search("kool").map(\.item.id) == [1])

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
        // Both occurrences are exact whole words. The new relevance contract
        // breaks this tie by recency rather than by offset within the entry.
        check("equally relevant matches use recency", ranked.first == 2, "\(ranked)")

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

    private static func contiguousSearch() {
        section("contiguous full-text search")
        let index = SearchIndex.shared
        func ids(_ query: String) -> [Int64] { index.search(query).map(\.item.id) }

        index.rebuild(from: [item(3, "k l a a b u d"), item(2, "klaabude"), item(1, "klaabud")])
        check("screenshot query excludes scattered letters", ids("klaabud") == [1, 2])
        check("whole word outranks a newer word part", ids("klaabud").first == 1)
        index.rebuild(from: [item(3, "valge"), item(2, "aed ja valge"), item(1, "valge maja ja aed")])
        check("terms match in either order with intervening words", Set(ids("valge aed")) == [1, 2])
        check("tabs and newlines separate query terms", ids("valge\taed\n") == ids("valge aed"))
        check("repeated query terms do not require repeated text", ids("valge valge") == ids("valge"))
        index.rebuild(from: [item(2, "a.b"), item(1, "axb")])
        check("punctuation in terms is literal", ids("a.b") == [2])

        index.rebuild(from: [item(3, "õun"), item(2, "oun"), item(1, "ÕUN")])
        check("plain query allows accented variants but exact spelling ranks first", ids("oun") == [2, 3, 1])
        check("accented query prefers accented spelling", ids("õun") == [3, 1, 2])
        check("uppercase query is case insensitive", ids("ÕUN") == ids("õun"))
        index.rebuild(from: [item(2, "õun"), item(1, "ounapuu")])
        check("exact spelling outranks a diacritic variant whole word", ids("oun") == [1, 2])
        index.rebuild(from: [item(1, "ÕÄÖÜ ŠŽ café")])
        check("all Estonian diacritics and other accents are optional", ids("oaou sz cafe") == [1])

        index.rebuild(from: [item(2, "valge maja ja aed"), item(1, "valge aed")])
        check("closer terms outrank newer distant terms", ids("valge aed") == [1, 2])
        index.rebuild(from: [item(2, "valge maja ja aed"), item(1, "valge väga kaugel aed; siis valge aed")])
        check("proximity uses later occurrences when they form a better window", ids("valge aed") == [1, 2])
        index.rebuild(from: [item(3, "valge aednik"), item(2, "valgem aed"), item(1, "valge aed")])
        check("whole-word count ranks ahead of word parts", ids("valge aed").first == 1)
        index.rebuild(from: [item(2, "õun oun"), item(1, "oun")])
        check("an exact match later in the text wins over an earlier loose match", ids("oun") == [2, 1])
        check("highlighting shows complete contiguous matches",
              index.highlightPositions(for: index.search("oun")[0]) == Array(0..<4) + Array(5..<8))

        let unicode = "🙂 Õun ja õun"
        index.rebuild(from: [item(1, unicode)])
        let highlights = index.highlightPositions(for: index.search("oun")[0])
        check("highlight offsets survive emoji and accent folding", highlights == Array(5..<9) + Array(13..<17), "\(highlights)")
        let decomposed = "O\u{0303}UN"
        index.rebuild(from: [item(2, "õun"), item(1, decomposed)])
        check("canonically equivalent accents rank equally", ids("õun") == [2, 1])
        check("decomposed accents keep their original highlight range",
              index.highlightPositions(for: index.search("õun")[1]) == Array(0..<decomposed.utf8.count))
        let expanded = SearchText("ßa")
        check("same-length Unicode expansions map partial matches to complete characters",
              expanded.originalRange(1..<3) == 0..<3 && expanded.originalRange(0..<1) == 0..<2)
        index.rebuild(from: [item(1, "straße")])
        check("case folding supports expanded Unicode characters", ids("STRASSE") == [1])
        index.rebuild(from: [item(2, "日本õun語"), item(1, "õun")])
        check("Unicode letters form word boundaries correctly", ids("oun").first == 1)

        let long = String(repeating: "algus ", count: 150) + "🙂 ÕUN valge maja ja aed"
        index.rebuild(from: [item(1, "algus")], texts: [1: long])
        check("search includes text beyond the old 256-byte label", ids("oun aed") == [1])
        let hit = index.search("oun")[0]
        let display = index.display(for: hit)
        check("a distant hit displays matching context", display.text.contains("ÕUN") && display.text.hasPrefix("… "))
        let normalizedLabel = SearchText(display.text)
        check("context highlights map to the matching original characters",
              display.positions == SubstringMatcher.highlightPositions(terms: [SearchTerm("oun")], text: normalizedLabel)
                  && !display.positions.isEmpty)
        check("a context label never replaces the stored item snippet", hit.item.snippet == "algus")
        index.touch(id: 1, updatedAt: 99)
        check("touch preserves the full search text", ids("oun aed") == [1])
        index.insert(item(2, "short"), text: "new text ending in klaabud")
        check("insert prepares complete text and invalidates the candidate cache", ids("klaabud") == [2])
        index.remove(ids: [2])
        check("deletion invalidates full-text candidates", ids("klaabud").isEmpty)

        let longTerm = String(repeating: "a", count: 160)
        index.rebuild(from: [item(1, "algus")], texts: [1: String(repeating: "prefix ", count: 60) + longTerm])
        let longDisplay = index.display(for: index.search(longTerm)[0])
        check("context contains and highlights even a term longer than the usual label",
              longDisplay.text.contains(longTerm) && longDisplay.positions.count == longTerm.utf8.count)

        let fixture = [item(4, "valge aed"), item(3, "valge aednik"), item(2, "õun"), item(1, "ounapuu")]
        let edits = ["v", "val", "valge", "valge a", "valge\taed", "valge valge", "valge",
                     "oun", "õun", "õun oun", "oun", "", "app:safari", "valge aed"]
        index.rebuild(from: fixture)
        var incremental: [[Int64]] = []
        for query in edits { incremental.append(ids(query)) }
        for (query, result) in zip(edits, incremental) {
            index.rebuild(from: fixture)
            check("incremental search equals cold search: \(query)", result == ids(query))
        }
        index.rebuild(from: [item(2, "õun", app: "SÄFARI"), item(1, "õun", app: "Terminal")])
        check("app filter remains compatible with full-text terms", ids("app:safari oun") == [2])
        check("all-whitespace query returns all entries", ids(" \t\n ") == [2, 1])

        let repeated = SearchText(String(repeating: "a", count: 20_000) + " end")
        let overlap = SubstringMatcher.match(terms: [SearchTerm("aaa"), SearchTerm("end")], text: repeated)
        check("overlapping repeated substrings find the closest final window", overlap?.span == 7)
        index.rebuild(from: [])
    }

    private static func searchStorage() {
        section("full-text storage loading")
        do {
            let db = try Database(path: ":memory:")
            try db.exec("CREATE TABLE reps (item_id INTEGER, uti TEXT, inline BLOB, blob_key TEXT)")
            func put(_ id: Int64, _ uti: String, _ text: String?, key: String? = nil) throws {
                let insert = try db.statement("INSERT INTO reps VALUES (?, ?, ?, ?)")
                insert.bind(1, id).bind(2, uti).bind(3, text.map { Data($0.utf8) }).bind(4, key)
                try insert.run()
            }
            let plain = "public.utf8-plain-text"
            let full = String(repeating: "algus ", count: 100) + "klaabud lõpus"
            let blob = String(repeating: "tekst ", count: 12_000) + "õun lõpus"
            try put(1, plain, " \n" + full + "\n ")
            try put(1, "public.html", "<script>not searchable markup</script>")
            try put(2, plain, nil, key: "plain-blob")
            try put(3, "public.png", nil, key: "image-blob")
            try put(4, plain, "not requested")
            try put(5, plain, nil, key: "missing-blob")
            var reads: [String] = []
            let texts = try ItemStore.loadSearchableTexts(db, items: [item(1, "algus"), item(2, "tekst"), item(3, "Image"), item(5, "fallback")]) { key in
                reads.append(key)
                return key == "plain-blob" ? Data(blob.utf8) : nil
            }
            check("inline full text loads without truncation", texts[1] == full)
            check("blob-backed full text loads without truncation", texts[2] == blob)
            check("markup and images are not loaded into search", Set(reads) == ["plain-blob", "missing-blob"])
            check("only requested history rows are loaded", texts[4] == nil)
            check("unavailable text leaves the snippet fallback available", texts[5] == nil)
            let index = SearchIndex.shared
            index.rebuild(from: [item(1, "algus"), item(2, "tekst"), item(5, "fallback")], texts: texts)
            check("existing inline history is searchable at its end", index.search("klaabud lõpus").map(\.item.id) == [1])
            check("existing blob history is searchable at its end", index.search("oun lopus").map(\.item.id) == [2])
            check("missing text falls back to its saved label", index.search("fallback").map(\.item.id) == [5])
            let single = try ItemStore.loadSearchableTexts(db, items: [item(1, "algus")]) { _ in
                check("a single inline insert does not read unrelated blobs", false)
                return nil
            }
            check("single-entry loading is scoped to the new item", single.keys.count == 1 && single[1] == full)
            index.rebuild(from: [])
        } catch {
            check("storage fixtures complete without production services", false, String(describing: error))
        }
    }
}
