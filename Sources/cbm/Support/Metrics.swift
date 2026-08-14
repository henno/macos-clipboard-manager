import Foundation
import Darwin

/// Live self-measurement. The whole point of this app is a small CPU footprint,
/// and a claim you cannot check is not worth making -- so the numbers behind the
/// claim are visible in Settings.
final class Metrics {
    static let shared = Metrics()

    private let lock = NSLock()
    private var _wakeups: UInt64 = 0
    private var _pasteboardReads: UInt64 = 0
    private var _lastSearchMicros: Double = 0
    private var _lastSearchCandidates: Int = 0
    private let started = Date()

    /// One timer fire. Counted whether or not the clipboard actually changed.
    func recordWakeup() {
        lock.lock(); _wakeups &+= 1; lock.unlock()
    }

    /// A wakeup that found a new changeCount and went on to read the pasteboard.
    func recordPasteboardRead() {
        lock.lock(); _pasteboardReads &+= 1; lock.unlock()
    }

    func recordSearch(micros: Double, candidates: Int) {
        lock.lock()
        _lastSearchMicros = micros
        _lastSearchCandidates = candidates
        lock.unlock()
    }

    struct Snapshot {
        let residentBytes: UInt64
        let wakeups: UInt64
        let wakeupsPerSecond: Double
        let pasteboardReads: UInt64
        let uptime: TimeInterval
        let lastSearchMicros: Double
        let lastSearchCandidates: Int
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let w = _wakeups, r = _pasteboardReads
        let micros = _lastSearchMicros, cands = _lastSearchCandidates
        lock.unlock()
        let up = Date().timeIntervalSince(started)
        return Snapshot(
            residentBytes: Metrics.residentBytes(),
            wakeups: w,
            wakeupsPerSecond: up > 0 ? Double(w) / up : 0,
            pasteboardReads: r,
            uptime: up,
            lastSearchMicros: micros,
            lastSearchCandidates: cands
        )
    }

    /// `phys_footprint` rather than `resident_size`: it is what Activity Monitor
    /// shows as Memory, and it excludes clean pages shared with every other app
    /// (AppKit and friends), which we neither own nor can shrink.
    static func residentBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }
}
