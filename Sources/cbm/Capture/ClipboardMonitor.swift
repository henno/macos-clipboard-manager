import AppKit

/// Watches `NSPasteboard.general.changeCount`.
///
/// There is no notification API for the pasteboard, so polling is the only
/// option every clipboard manager has. What we can control is how often we wake
/// the CPU, and wakeups -- not CPU percentage -- are what actually cost battery,
/// because they keep the core out of its deep idle state.
///
/// Three things keep that cost down:
///   * a generous `leeway`, which lets the kernel coalesce our wakeup with
///     wakeups other processes already scheduled, often making ours free;
///   * a cadence derived from the signal we already poll -- copies arrive in
///     bursts, so we poll fast right after one and slow down when nothing has
///     happened for a minute;
///   * an immediate poll on the events that matter (opening the panel, switching
///     apps, waking), so a slow cadence can never mean stale contents when the
///     user actually looks.
///
/// This monitor owns `NSPasteboard.general`: every read and write goes through
/// its serial queue, so no two threads ever touch the pasteboard at once.
final class ClipboardMonitor {
    static let shared = ClipboardMonitor()

    private enum Cadence {
        case burst, normal, idle

        var interval: Double {
            switch self {
            case .burst: return 0.2
            case .normal: return 0.5
            case .idle: return 2.0
            }
        }
        /// Wide on purpose. 600 ms of slop on a 2 s timer is invisible to the
        /// user and lets the kernel merge the wakeup with someone else's.
        var leeway: DispatchTimeInterval {
            .milliseconds(Int(interval * 300))
        }
    }

    private let queue = DispatchQueue(label: "ee.henno.cbm.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var cadence: Cadence?
    private var lastChangeCount = Int.min
    private var lastActivity = CFAbsoluteTimeGetCurrent()
    private var paused = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        queue.async {
            // Int.min means "capture whatever is already on the clipboard".
            self.apply(cadence: .burst)
        }
        observeSystemEvents()
    }

    /// Poll right now, synchronously. Called before the panel opens so the list
    /// always includes whatever was copied a moment ago, regardless of cadence.
    func pollNowAndWait() {
        queue.sync { self.tick(countWakeup: false) }
    }

    func pollNow() {
        queue.async { self.tick(countWakeup: false) }
    }

    /// Writes to the pasteboard on the queue that owns it, and records the
    /// resulting changeCount so we do not re-capture our own write.
    func write(_ body: @escaping (NSPasteboard) -> Void, completion: (() -> Void)? = nil) {
        queue.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            body(pb)
            self.lastChangeCount = pb.changeCount
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    // MARK: - The poll itself

    private func tick(countWakeup: Bool = true) {
        if countWakeup { Metrics.shared.recordWakeup() }
        guard !paused else { return }

        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else {
            adjustCadence()
            return
        }
        lastChangeCount = count
        lastActivity = CFAbsoluteTimeGetCurrent()
        Metrics.shared.recordPasteboardRead()

        if let payload = PasteboardReader.read(pb) {
            ItemStore.shared.insert(payload)
        }
        adjustCadence()
    }

    private func adjustCadence() {
        let since = CFAbsoluteTimeGetCurrent() - lastActivity
        let wanted: Cadence
        if since < 5 { wanted = .burst }
        else if since < 60 { wanted = .normal }
        else { wanted = .idle }
        if wanted != cadence { apply(cadence: wanted) }
    }

    private func apply(cadence new: Cadence) {
        cadence = new
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + new.interval, repeating: new.interval, leeway: new.leeway)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        cadence = nil
    }

    // MARK: - Suspend while nobody can copy anything

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
            [weak self] _ in self?.pause()
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.resume()
        }
        workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) {
            [weak self] _ in self?.pause()
        }
        workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) {
            [weak self] _ in self?.resume()
        }

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.pause() }
        distributed.addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.resume() }
    }

    private func pause() {
        queue.async {
            guard !self.paused else { return }
            self.paused = true
            self.stopTimer()
            Log.capture("paused")
        }
    }

    private func resume() {
        queue.async {
            guard self.paused else { return }
            self.paused = false
            self.lastActivity = CFAbsoluteTimeGetCurrent()
            self.tick(countWakeup: false)
            self.apply(cadence: .burst)
            Log.capture("resumed")
        }
    }
}
