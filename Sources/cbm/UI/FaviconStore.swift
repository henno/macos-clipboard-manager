import AppKit

/// Site icons for entries copied from a browser.
///
/// Everything here is local. Chrome already keeps a favicon database on disk,
/// so there is no reason to ask the network — which would tell every site you
/// copy from that you just did so, and when. cbm makes no network requests at
/// all, and this feature does not change that.
///
/// The database is read from a copy: Chrome writes to the original while it
/// runs, and reading a file mid-write is how you get corrupt rows rather than
/// an error.
final class FaviconStore {
    static let shared = FaviconStore()

    private let queue = DispatchQueue(label: "ee.henno.cbm.favicon", qos: .utility)
    private let lock = NSLock()
    private var icons: [String: NSImage] = [:]
    /// Hosts already looked up and not found, so a miss costs one lookup rather
    /// than one per redraw.
    private var misses = Set<String>()
    private var snapshotTakenAt: Date?

    private init() {}

    /// Cache-only, safe to call while drawing a row.
    func icon(forHost host: String?) -> NSImage? {
        guard let host, !host.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        return icons[host]
    }

    /// Resolves any host not yet known, then calls back on the main queue if
    /// anything new was found. One pass over the database serves every host.
    func warm(hosts: Set<String>, completion: @escaping (Bool) -> Void) {
        lock.lock()
        let wanted = hosts.filter { !$0.isEmpty && icons[$0] == nil && !misses.contains($0) }
        lock.unlock()

        guard !wanted.isEmpty else { completion(false); return }

        queue.async {
            let found = self.resolve(wanted)
            self.lock.lock()
            for (host, image) in found { self.icons[host] = image }
            for host in wanted where found[host] == nil { self.misses.insert(host) }
            self.lock.unlock()
            DispatchQueue.main.async { completion(!found.isEmpty) }
        }
    }

    // MARK: - Reading Chrome's database

    private func resolve(_ hosts: Set<String>) -> [String: NSImage] {
        guard let path = snapshot() else { return [:] }
        guard let db = try? Database(path: path) else { return [:] }
        defer { db.close() }

        do {
            // One scan counts, per host, how many pages point at each icon.
            // Counting rather than collecting matters: a single OAuth redirect
            // under github.com is mapped to Google's icon, and it would win any
            // ordering that did not weigh how typical an icon is for the host.
            var votesForHost: [String: [Int64: Int]] = [:]
            let mapping = try db.statement("SELECT page_url, icon_id FROM icon_mapping")
            while try mapping.step() {
                guard let page = mapping.string(0),
                      let host = URL(string: page)?.host?.lowercased()
                else { continue }
                let key: String
                if hosts.contains(host) { key = host }
                else if hosts.contains(stripWWW(host)) { key = stripWWW(host) }
                else { continue }
                votesForHost[key, default: [:]][mapping.int64(1), default: 0] += 1
            }

            var out: [String: NSImage] = [:]
            for (host, votes) in votesForHost {
                for (iconID, _) in votes.sorted(by: { $0.value > $1.value }) {
                    // Within one icon: sites commonly ship a light and a dark
                    // variant and Chrome caches whichever matched its own theme,
                    // so prefer the one not named "dark", then the largest,
                    // which scales down more cleanly than a 16px original.
                    let q = try db.statement(
                        """
                        SELECT b.image_data FROM favicon_bitmaps b
                        JOIN favicons f ON f.id = b.icon_id
                        WHERE b.icon_id = ? AND length(b.image_data) > 0
                        ORDER BY (f.url LIKE '%dark%') ASC, b.width DESC
                        """)
                    q.bind(1, iconID)
                    var picked: NSImage?
                    while try q.step() {
                        guard let data = q.data(0), let image = NSImage(data: data) else { continue }
                        // A variant that is essentially white reads as a blank
                        // row. Keep looking, and failing that let the next icon
                        // — or the application icon — stand.
                        guard isVisible(image) else { continue }
                        picked = image
                        break
                    }
                    if let picked {
                        picked.size = NSSize(width: 16, height: 16)
                        out[host] = picked
                        break
                    }
                }
            }
            Log.ui("favicons: resolved \(out.count) of \(hosts.count) hosts")
            return out
        } catch {
            Log.error("favicon lookup failed: \(error)")
            return [:]
        }
    }

    /// Averages the icon down to a single pixel and asks whether anything would
    /// actually be seen: a fully transparent icon, or one that is white on white
    /// like GitHub's dark-mode mark, draws as an empty row.
    private func isVisible(_ image: NSImage) -> Bool {
        var rect = NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return false
        }
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let alpha = Double(pixel[3]) / 255
        guard alpha > 0.15 else { return false }  // essentially transparent
        // Un-premultiply before judging brightness, or a faint icon reads dark.
        let r = Double(pixel[0]) / 255 / alpha
        let g = Double(pixel[1]) / 255 / alpha
        let b = Double(pixel[2]) / 255 / alpha
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance < 0.92
    }

    private func stripWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Copies Chrome's favicon database next to our own data, at most once every
    /// ten minutes. Returns nil when Chrome is not installed.
    private func snapshot() -> String? {
        let destination = Paths.root.appendingPathComponent("chrome-favicons.db")
        let fm = FileManager.default

        if let taken = snapshotTakenAt,
           Date().timeIntervalSince(taken) < 600,
           fm.fileExists(atPath: destination.path) {
            return destination.path
        }

        guard let source = newestChromeFaviconDB() else { return nil }
        do {
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: source, to: destination)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            snapshotTakenAt = Date()
            return destination.path
        } catch {
            Log.error("could not copy Chrome favicon database: \(error)")
            return nil
        }
    }

    /// Chrome keeps one database per profile; take whichever was written last.
    private func newestChromeFaviconDB() -> URL? {
        let support = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Application Support/Google/Chrome", isDirectory: true)
        guard let profiles = try? FileManager.default.contentsOfDirectory(
            at: support, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }

        var best: (url: URL, date: Date)?
        for profile in profiles {
            let candidate = profile.appendingPathComponent("Favicons")
            guard let values = try? candidate.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate else { continue }
            if best == nil || date > best!.date { best = (candidate, date) }
        }
        return best?.url
    }
}
