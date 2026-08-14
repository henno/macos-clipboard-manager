import Foundation
import os

/// Unified logging, so `log stream --predicate 'subsystem == "ee.henno.cbm"'`
/// works. Nothing on the timer path logs, so building these strings is never in
/// the hot loop.
enum Log {
    private static let captureLog = Logger(subsystem: "ee.henno.cbm", category: "capture")
    private static let storeLog = Logger(subsystem: "ee.henno.cbm", category: "store")
    private static let uiLog = Logger(subsystem: "ee.henno.cbm", category: "ui")

    static func capture(_ message: String) { captureLog.debug("\(message, privacy: .public)") }
    static func store(_ message: String) { storeLog.debug("\(message, privacy: .public)") }
    static func ui(_ message: String) { uiLog.debug("\(message, privacy: .public)") }
    static func error(_ message: String) { storeLog.error("\(message, privacy: .public)") }
}
