import AppKit

/// Remembers which app is in front, so the capture path (which runs off the
/// main thread) can attribute a clipboard change without touching NSWorkspace,
/// and so the paste path knows where to return focus.
///
/// Attribution is a heuristic: we learn about a clipboard change up to one poll
/// interval after it happened, so switching apps in that window can misattribute
/// the entry. In exchange we pay nothing to track it.
final class FrontmostTracker {
    static let shared = FrontmostTracker()

    private let lock = NSLock()
    private var _bundleID: String?
    private var _name: String?
    private var _pid: pid_t = 0

    private init() {}

    func start() {
        update(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.update(app)
            // An app switch is a strong hint that a copy just happened; it costs
            // one extra poll and only fires when the user actually switches.
            ClipboardMonitor.shared.pollNow()
        }
    }

    private func update(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lock.lock()
        _bundleID = app.bundleIdentifier
        _name = app.localizedName
        _pid = app.processIdentifier
        lock.unlock()
    }

    var current: (bundleID: String?, name: String?) {
        lock.lock(); defer { lock.unlock() }
        return (_bundleID, _name)
    }

    /// The app to hand focus back to after pasting.
    var target: NSRunningApplication? {
        lock.lock(); let pid = _pid; lock.unlock()
        guard pid != 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }
}
