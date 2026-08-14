import Foundation
import ServiceManagement

/// Launch-at-login via `SMAppService`, which registers the bundle itself -- no
/// helper app and no login-items plist to leave behind.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            Log.error("login item change failed: \(error)")
            return false
        }
    }
}
