import AppKit
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

    /// The identity used to recognise "the same thing copied again".
    ///
    /// Only the payload that carries the meaning counts: the plain text, the
    /// image bytes, the list of files. Hashing every representation instead
    /// would split one entry in two whenever the same text arrives once with
    /// formatting attached and once without — which is exactly what a user
    /// reads as a duplicate.
    ///
    /// Rich text and plain text share a class deliberately, so copying the same
    /// sentence from a web page and from a text editor lands on one entry.
    static func contentIdentity(kind: ItemKind, reps: [Representation]) -> String {
        let cls: String
        let candidates: [String]
        switch kind {
        case .files:
            cls = "files"
            candidates = [PasteboardReader.fileListType.rawValue]
        case .image:
            cls = "image"
            candidates = [NSPasteboard.PasteboardType.png.rawValue,
                          NSPasteboard.PasteboardType.tiff.rawValue]
        case .text, .rich:
            cls = "text"
            candidates = [NSPasteboard.PasteboardType.string.rawValue]
        }

        for uti in candidates {
            guard let rep = reps.first(where: { $0.uti == uti }) else { continue }
            var hasher = SHA256()
            hasher.update(data: Data(cls.utf8))
            hasher.update(data: rep.data)
            var out = ""
            out.reserveCapacity(64)
            for byte in hasher.finalize() { out += String(format: "%02x", byte) }
            return out
        }
        // Nothing recognisable to key on: fall back to the whole set, which at
        // worst behaves the way this used to.
        return identity(of: reps)
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
