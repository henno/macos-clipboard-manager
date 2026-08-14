import Foundation

/// The clipboard history. Owns the only `Database` handle and a single serial
/// queue; every read and write goes through that queue. Writes are async so the
/// capture path never blocks, reads are sync but touch at most a few rows.
final class ItemStore {
    static let shared = ItemStore()

    /// Posted on the main queue after the history changes.
    static let didChange = Notification.Name("cbm.storeDidChange")

    /// Fine-grained change callbacks, always delivered on the main queue. The
    /// search index maintains itself from these rather than rebuilding, so a
    /// copy costs one array insert instead of re-folding the whole history.
    var onInsert: ((ClipItem) -> Void)?
    var onTouch: ((Int64, Double) -> Void)?
    var onDelete: ((Set<Int64>) -> Void)?

    private let queue = DispatchQueue(label: "ee.henno.cbm.store", qos: .utility)
    private var db: Database?

    private static let columns = """
        id, hash, kind, snippet, source_bundle_id, source_name, \
        created_at, updated_at, total_bytes, has_thumb, px_w, px_h
        """

    private init() {
        queue.sync {
            do {
                let db = try Database(path: Paths.database.path)
                try db.exec(
                    """
                    PRAGMA journal_mode=WAL;
                    PRAGMA synchronous=NORMAL;
                    PRAGMA temp_store=MEMORY;
                    PRAGMA foreign_keys=ON;
                    -- negative = KiB. Our queries touch a handful of pages; the
                    -- 2 MB default page cache would be pure resident-memory waste.
                    PRAGMA cache_size=-2000;
                    PRAGMA mmap_size=0;
                    """)
                try Self.migrate(db)
                self.db = db
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: Paths.database.path)
            } catch {
                Log.error("store init failed: \(error)")
            }
        }
    }

    private static func migrate(_ db: Database) throws {
        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS items (
                id               INTEGER PRIMARY KEY AUTOINCREMENT,
                hash             TEXT    NOT NULL UNIQUE,
                kind             INTEGER NOT NULL,
                snippet          TEXT    NOT NULL,
                source_bundle_id TEXT,
                source_name      TEXT,
                created_at       REAL    NOT NULL,
                updated_at       REAL    NOT NULL,
                total_bytes      INTEGER NOT NULL,
                has_thumb        INTEGER NOT NULL DEFAULT 0,
                px_w             INTEGER NOT NULL DEFAULT 0,
                px_h             INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_items_updated ON items(updated_at DESC);
            CREATE INDEX IF NOT EXISTS idx_items_kind_updated ON items(kind, updated_at DESC);

            CREATE TABLE IF NOT EXISTS reps (
                item_id  INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                uti      TEXT    NOT NULL,
                bytes    INTEGER NOT NULL,
                inline   BLOB,
                blob_key TEXT,
                PRIMARY KEY (item_id, uti)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS idx_reps_blob ON reps(blob_key) WHERE blob_key IS NOT NULL;
            """)
    }

    // MARK: - Writing

    enum InsertOutcome {
        case inserted(ClipItem)
        /// Same bytes seen again: the existing row moved to the top of the list.
        case touched(id: Int64, updatedAt: Double)
        case rejected
    }

    /// Stores a capture, or bumps the existing identical entry to the top.
    /// `completion` runs on the main queue.
    func insert(_ payload: CapturedPayload, completion: ((InsertOutcome) -> Void)? = nil) {
        queue.async {
            let outcome = self.insertSync(payload)
            switch outcome {
            case .inserted(let item):
                DispatchQueue.main.async { self.onInsert?(item) }
                self.postDidChange()
            case .touched(let id, let updatedAt):
                DispatchQueue.main.async { self.onTouch?(id, updatedAt) }
                self.postDidChange()
            case .rejected:
                break
            }
            if let completion {
                DispatchQueue.main.async { completion(outcome) }
            }
        }
    }

    private func insertSync(_ payload: CapturedPayload) -> InsertOutcome {
        guard let db else { return .rejected }
        let now = Date().timeIntervalSince1970

        do {
            // Already have these exact bytes? Move it to the top instead of
            // creating a duplicate row.
            let find = try db.statement("SELECT id FROM items WHERE hash = ?")
            find.bind(1, payload.hash)
            if try find.step() {
                let id = find.int64(0)
                let touch = try db.statement("UPDATE items SET updated_at = ? WHERE id = ?")
                touch.bind(1, now).bind(2, id)
                try touch.run()
                return .touched(id: id, updatedAt: now)
            }

            // Large representations go to disk before we touch the database, so
            // a failed write cannot leave a row pointing at a missing file.
            var stored: [(uti: String, bytes: Int, inline: Data?, key: String?)] = []
            stored.reserveCapacity(payload.reps.count)
            for rep in payload.reps {
                if rep.data.count > BlobStore.inlineLimit {
                    guard let key = BlobStore.write(rep.data) else { continue }
                    stored.append((rep.uti, rep.data.count, nil, key))
                } else {
                    stored.append((rep.uti, rep.data.count, rep.data, nil))
                }
            }
            guard !stored.isEmpty else { return .rejected }

            var newID: Int64 = 0
            try db.transaction {
                let ins = try db.statement(
                    """
                    INSERT INTO items
                        (hash, kind, snippet, source_bundle_id, source_name,
                         created_at, updated_at, total_bytes, has_thumb, px_w, px_h)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                    """)
                ins.bind(1, payload.hash)
                    .bind(2, payload.kind.rawValue)
                    .bind(3, payload.snippet)
                    .bind(4, payload.sourceBundleID)
                    .bind(5, payload.sourceName)
                    .bind(6, now)
                    .bind(7, now)
                    .bind(8, payload.totalBytes)
                    .bind(9, Int(payload.pixelSize?.width ?? 0))
                    .bind(10, Int(payload.pixelSize?.height ?? 0))
                try ins.run()
                newID = db.lastInsertRowID

                for s in stored {
                    let r = try db.statement(
                        "INSERT OR REPLACE INTO reps (item_id, uti, bytes, inline, blob_key) VALUES (?, ?, ?, ?, ?)")
                    r.bind(1, newID).bind(2, s.uti).bind(3, s.bytes).bind(4, s.inline).bind(5, s.key)
                    try r.run()
                }
            }

            // Thumbnail last: it is the slowest step and a failure here must not
            // cost us the entry itself.
            var hasThumb = false
            if let source = payload.imageForThumb,
               let png = ThumbnailMaker.makePNG(from: source) {
                BlobStore.writeThumb(png, itemHash: payload.hash)
                let upd = try db.statement("UPDATE items SET has_thumb = 1 WHERE id = ?")
                upd.bind(1, newID)
                try upd.run()
                hasThumb = true
            }

            let item = ClipItem(
                id: newID,
                hash: payload.hash,
                kind: payload.kind,
                snippet: payload.snippet,
                sourceBundleID: payload.sourceBundleID,
                sourceName: payload.sourceName,
                createdAt: now,
                updatedAt: now,
                totalBytes: Int64(payload.totalBytes),
                hasThumb: hasThumb,
                pixelWidth: Int(payload.pixelSize?.width ?? 0),
                pixelHeight: Int(payload.pixelSize?.height ?? 0))

            sweepIfNeeded()
            return .inserted(item)
        } catch {
            Log.error("insert failed: \(error)")
            return .rejected
        }
    }

    func delete(ids: [Int64], completion: (() -> Void)? = nil) {
        guard !ids.isEmpty else { completion?(); return }
        queue.async {
            self.deleteSync(ids: ids)
            self.postDidChange()
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    /// Deletes rows and then any blob or thumbnail no longer referenced.
    private func deleteSync(ids: [Int64]) {
        guard let db else { return }
        do {
            var candidateBlobs = Set<String>()
            var hashes: [String] = []

            for id in ids {
                let q = try db.statement("SELECT blob_key FROM reps WHERE item_id = ? AND blob_key IS NOT NULL")
                q.bind(1, id)
                while try q.step() { if let k = q.string(0) { candidateBlobs.insert(k) } }

                let h = try db.statement("SELECT hash FROM items WHERE id = ?")
                h.bind(1, id)
                if try h.step(), let hash = h.string(0) { hashes.append(hash) }
            }

            try db.transaction {
                for id in ids {
                    let dr = try db.statement("DELETE FROM reps WHERE item_id = ?")
                    dr.bind(1, id)
                    try dr.run()
                    let di = try db.statement("DELETE FROM items WHERE id = ?")
                    di.bind(1, id)
                    try di.run()
                }
            }

            // A blob can be shared by several entries; only drop it once the
            // last reference is gone.
            for key in candidateBlobs {
                let q = try db.statement("SELECT 1 FROM reps WHERE blob_key = ? LIMIT 1")
                q.bind(1, key)
                if try q.step() == false { BlobStore.delete(key) }
            }
            for hash in hashes { BlobStore.deleteThumb(itemHash: hash) }

            let removed = Set(ids)
            DispatchQueue.main.async { self.onDelete?(removed) }
        } catch {
            Log.error("delete failed: \(error)")
        }
    }

    func deleteAll(completion: (() -> Void)? = nil) {
        queue.async {
            guard let db = self.db else { return }
            do {
                let q = try db.statement("SELECT id FROM items")
                var ids: [Int64] = []
                while try q.step() { ids.append(q.int64(0)) }
                self.deleteSync(ids: ids)
            } catch {
                Log.error("deleteAll failed: \(error)")
            }
            self.postDidChange()
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    // MARK: - Reading

    func recent(limit: Int = 5000) -> [ClipItem] {
        queue.sync {
            guard let db else { return [] }
            do {
                let q = try db.statement(
                    "SELECT \(Self.columns) FROM items ORDER BY updated_at DESC LIMIT ?")
                q.bind(1, limit)
                var out: [ClipItem] = []
                out.reserveCapacity(min(limit, 1024))
                while try q.step() { out.append(Self.row(q)) }
                return out
            } catch {
                Log.error("recent failed: \(error)")
                return []
            }
        }
    }

    func item(id: Int64) -> ClipItem? {
        queue.sync {
            guard let db else { return nil }
            do {
                let q = try db.statement("SELECT \(Self.columns) FROM items WHERE id = ?")
                q.bind(1, id)
                return try q.step() ? Self.row(q) : nil
            } catch {
                Log.error("item lookup failed: \(error)")
                return nil
            }
        }
    }

    /// Reads every stored representation of an entry. Called on paste and on
    /// preview -- never while merely listing.
    func representations(of id: Int64) -> [Representation] {
        queue.sync {
            guard let db else { return [] }
            do {
                let q = try db.statement("SELECT uti, inline, blob_key FROM reps WHERE item_id = ?")
                q.bind(1, id)
                var out: [Representation] = []
                while try q.step() {
                    guard let uti = q.string(0) else { continue }
                    if let key = q.string(2) {
                        if let data = BlobStore.read(key) { out.append(Representation(uti: uti, data: data)) }
                    } else if let data = q.data(1) {
                        out.append(Representation(uti: uti, data: data))
                    }
                }
                return out
            } catch {
                Log.error("representations failed: \(error)")
                return []
            }
        }
    }

    func count() -> Int {
        queue.sync {
            guard let db else { return 0 }
            do {
                let q = try db.statement("SELECT COUNT(*) FROM items")
                return try q.step() ? q.int(0) : 0
            } catch { return 0 }
        }
    }

    func databaseBytes() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for path in [Paths.database.path, Paths.database.path + "-wal", Paths.database.path + "-shm"] {
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int64 { total += size }
        }
        return total
    }

    func blobBytes() -> Int64 {
        var total: Int64 = 0
        for root in [Paths.blobs, Paths.thumbs] {
            guard let e = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let url as URL in e {
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }

    private static func row(_ q: Statement) -> ClipItem {
        ClipItem(
            id: q.int64(0),
            hash: q.string(1) ?? "",
            kind: ItemKind(rawValue: q.int(2)) ?? .text,
            snippet: q.string(3) ?? "",
            sourceBundleID: q.string(4),
            sourceName: q.string(5),
            createdAt: q.double(6),
            updatedAt: q.double(7),
            totalBytes: q.int64(8),
            hasThumb: q.bool(9),
            pixelWidth: q.int(10),
            pixelHeight: q.int(11))
    }

    // MARK: - Retention

    /// Applies the configured limits. Runs on the store queue after inserts and
    /// on demand from Settings.
    func sweep(completion: (() -> Void)? = nil) {
        queue.async {
            self.sweepIfNeeded(force: true)
            self.postDidChange()
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    private func sweepIfNeeded(force: Bool = false) {
        guard let db else { return }
        let s = Settings.shared
        var doomed: [Int64] = []
        do {
            // Over the count cap: drop the oldest.
            let over = try db.statement(
                """
                SELECT id FROM items
                ORDER BY updated_at DESC
                LIMIT -1 OFFSET ?
                """)
            over.bind(1, s.maxItems)
            while try over.step() { doomed.append(over.int64(0)) }

            let now = Date().timeIntervalSince1970
            if s.maxAgeDays > 0 {
                let cutoff = now - Double(s.maxAgeDays) * 86_400
                let q = try db.statement("SELECT id FROM items WHERE updated_at < ?")
                q.bind(1, cutoff)
                while try q.step() { doomed.append(q.int64(0)) }
            }
            if s.imageMaxAgeDays > 0 {
                let cutoff = now - Double(s.imageMaxAgeDays) * 86_400
                let q = try db.statement("SELECT id FROM items WHERE kind = ? AND updated_at < ?")
                q.bind(1, ItemKind.image.rawValue).bind(2, cutoff)
                while try q.step() { doomed.append(q.int64(0)) }
            }
        } catch {
            Log.error("sweep query failed: \(error)")
            return
        }

        let unique = Array(Set(doomed))
        if !unique.isEmpty {
            deleteSync(ids: unique)
            Log.store("swept \(unique.count) items")
        }
        if force { try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)") }
    }

    /// Removes blobs and thumbnails with no row pointing at them. Only worth
    /// doing at launch, to clean up after a crash mid-write.
    func collectOrphansAtLaunch() {
        queue.async {
            guard let db = self.db else { return }
            do {
                var live = Set<String>()
                let q = try db.statement("SELECT blob_key FROM reps WHERE blob_key IS NOT NULL")
                while try q.step() { if let k = q.string(0) { live.insert(k) } }

                var liveHashes = Set<String>()
                let h = try db.statement("SELECT hash FROM items")
                while try h.step() { if let s = h.string(0) { liveHashes.insert(s) } }

                var removed = 0
                let fm = FileManager.default
                if let e = fm.enumerator(at: Paths.blobs, includingPropertiesForKeys: nil) {
                    for case let url as URL in e where !url.hasDirectoryPath {
                        if !live.contains(url.lastPathComponent) {
                            try? fm.removeItem(at: url); removed += 1
                        }
                    }
                }
                if let e = fm.enumerator(at: Paths.thumbs, includingPropertiesForKeys: nil) {
                    for case let url as URL in e where !url.hasDirectoryPath {
                        let hash = url.deletingPathExtension().lastPathComponent
                        if !liveHashes.contains(hash) {
                            try? fm.removeItem(at: url); removed += 1
                        }
                    }
                }
                if removed > 0 { Log.store("collected \(removed) orphaned files") }
            } catch {
                Log.error("orphan collection failed: \(error)")
            }
        }
    }

    private func postDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: ItemStore.didChange, object: nil)
        }
    }
}
