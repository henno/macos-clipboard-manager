import AppKit

/// Thumbnails, capped in bytes rather than in count.
///
/// `NSCache` evicts under memory pressure on its own; the explicit limit is what
/// stops a long scroll through a screenshot-heavy history from quietly turning
/// into a hundred megabytes of decoded bitmaps. Full-size images are never put
/// in here -- only the 256px thumbnails written at capture time.
final class ThumbCache {
    static let shared = ThumbCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.totalCostLimit = 8 * 1024 * 1024
    }

    func thumbnail(forHash hash: String) -> NSImage? {
        let key = hash as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = BlobStore.thumbURL(itemHash: hash),
              let image = NSImage(contentsOf: url) else { return nil }
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: key, cost: max(cost, 1))
        return image
    }

    func evict(hash: String) {
        cache.removeObject(forKey: hash as NSString)
    }
}

/// One icon per source application. Bounded by how many apps exist, so a plain
/// dictionary is the right structure -- eviction would only cost us re-reading
/// the same handful of files.
final class AppIconCache {
    static let shared = AppIconCache()

    private var icons: [String: NSImage] = [:]
    private lazy var fallback: NSImage = {
        let image = NSWorkspace.shared.icon(for: .data)
        image.size = NSSize(width: 16, height: 16)
        return image
    }()

    private init() {}

    func icon(bundleID: String?) -> NSImage {
        guard let bundleID, !bundleID.isEmpty else { return fallback }
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            icons[bundleID] = fallback
            return fallback
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        icons[bundleID] = image
        return image
    }
}

enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func string(_ timestamp: Double) -> String {
        let now = Date()
        let date = Date(timeIntervalSince1970: timestamp)
        // Something copied a moment ago rounds to "in 0 seconds" -- future tense
        // for something that already happened. Say "now" and never let a
        // timestamp a few milliseconds ahead of the clock leak through.
        guard now.timeIntervalSince(date) >= 2 else { return "now" }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

enum ByteSize {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        // Otherwise zero renders as "Zero KB", which reads like a bug.
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func string(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }
}
