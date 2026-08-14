import Foundation

/// Everything cbm writes lives under one directory, created 0700.
enum Paths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("cbm", isDirectory: true)
        ensureDir(dir)
        return dir
    }()

    static let database = root.appendingPathComponent("history.sqlite3")

    static let blobs: URL = {
        let dir = root.appendingPathComponent("blobs", isDirectory: true)
        ensureDir(dir)
        return dir
    }()

    static let thumbs: URL = {
        let dir = root.appendingPathComponent("thumbs", isDirectory: true)
        ensureDir(dir)
        return dir
    }()

    /// Blobs are sharded by the first two hex characters of their key so that a
    /// long history does not produce a single directory with tens of thousands
    /// of entries, which makes every lookup in it slower.
    static func blobURL(_ key: String) -> URL {
        let shard = String(key.prefix(2))
        let dir = blobs.appendingPathComponent(shard, isDirectory: true)
        ensureDir(dir)
        return dir.appendingPathComponent(key)
    }

    static func thumbURL(_ key: String) -> URL {
        let shard = String(key.prefix(2))
        let dir = thumbs.appendingPathComponent(shard, isDirectory: true)
        ensureDir(dir)
        return dir.appendingPathComponent(key + ".png")
    }

    private static func ensureDir(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
