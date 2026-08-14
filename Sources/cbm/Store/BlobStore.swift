import Foundation
import CryptoKit

/// Payloads larger than `inlineLimit` live as files on disk keyed by their
/// SHA-256, so identical bytes are stored exactly once no matter how many
/// history entries reference them.
enum BlobStore {
    /// Below this, a representation is stored inline in the SQLite row. Above
    /// it, a fat blob in the row would bloat every sequential scan of `reps`,
    /// so it goes to a file instead.
    static let inlineLimit = 64 * 1024

    static func hexDigest(_ data: Data) -> String {
        var out = ""
        out.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            out += String(format: "%02x", byte)
        }
        return out
    }

    /// Hashes an ordered set of representations into one stable identity. The
    /// UTI, the length and the bytes all feed in, so two entries collide only
    /// if every representation is byte-identical.
    static func identity(of reps: [Representation]) -> String {
        var hasher = SHA256()
        for rep in reps.sorted(by: { $0.uti < $1.uti }) {
            hasher.update(data: Data(rep.uti.utf8))
            withUnsafeBytes(of: UInt64(rep.data.count).littleEndian) { hasher.update(bufferPointer: $0) }
            hasher.update(data: rep.data)
        }
        var out = ""
        out.reserveCapacity(64)
        for byte in hasher.finalize() { out += String(format: "%02x", byte) }
        return out
    }

    @discardableResult
    static func write(_ data: Data) -> String? {
        let key = hexDigest(data)
        let url = Paths.blobURL(key)
        if FileManager.default.fileExists(atPath: url.path) { return key }
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return key
        } catch {
            Log.error("blob write failed: \(error)")
            return nil
        }
    }

    static func read(_ key: String) -> Data? {
        try? Data(contentsOf: Paths.blobURL(key), options: [.mappedIfSafe])
    }

    static func delete(_ key: String) {
        try? FileManager.default.removeItem(at: Paths.blobURL(key))
    }

    // MARK: thumbnails, keyed by the owning item's identity hash

    static func writeThumb(_ png: Data, itemHash: String) {
        let url = Paths.thumbURL(itemHash)
        do {
            try png.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.error("thumb write failed: \(error)")
        }
    }

    static func thumbURL(itemHash: String) -> URL? {
        let url = Paths.thumbURL(itemHash)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func deleteThumb(itemHash: String) {
        try? FileManager.default.removeItem(at: Paths.thumbURL(itemHash))
    }
}
