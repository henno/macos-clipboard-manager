import Foundation

/// User-tunable limits. Kept deliberately small: every knob here is one the
/// retention sweep or the capture path actually reads.
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("cbm.settingsDidChange")

    private enum Key {
        static let maxItems = "maxItems"
        static let maxAgeDays = "maxAgeDays"
        static let imageMaxAgeDays = "imageMaxAgeDays"
        static let maxItemSizeMB = "maxItemSizeMB"
        static let hasAskedAboutLogin = "hasAskedAboutLogin"
        static let suppressTrustAlert = "suppressTrustAlert"
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.maxItems: 1000,
            Key.maxAgeDays: 0,          // 0 == keep forever
            Key.imageMaxAgeDays: 30,    // images are the expensive ones
            Key.maxItemSizeMB: 10,
            Key.hasAskedAboutLogin: false,
        ])
    }

    var maxItems: Int {
        get { max(10, defaults.integer(forKey: Key.maxItems)) }
        set { set(Key.maxItems, max(10, newValue)) }
    }

    /// 0 means no age limit.
    var maxAgeDays: Int {
        get { max(0, defaults.integer(forKey: Key.maxAgeDays)) }
        set { set(Key.maxAgeDays, max(0, newValue)) }
    }

    /// 0 means images live as long as anything else.
    var imageMaxAgeDays: Int {
        get { max(0, defaults.integer(forKey: Key.imageMaxAgeDays)) }
        set { set(Key.imageMaxAgeDays, max(0, newValue)) }
    }

    var maxItemSizeMB: Int {
        get { max(1, defaults.integer(forKey: Key.maxItemSizeMB)) }
        set { set(Key.maxItemSizeMB, max(1, newValue)) }
    }

    var maxItemSizeBytes: Int { maxItemSizeMB * 1_048_576 }

    /// Registering a login item changes persistent system state, so we ask once
    /// rather than deciding for the user on first launch.
    var hasAskedAboutLogin: Bool {
        get { defaults.bool(forKey: Key.hasAskedAboutLogin) }
        set { defaults.set(newValue, forKey: Key.hasAskedAboutLogin) }
    }

    /// Set once the user has said they are happy pasting with ⌘V themselves.
    var suppressTrustAlert: Bool {
        get { defaults.bool(forKey: Key.suppressTrustAlert) }
        set { defaults.set(newValue, forKey: Key.suppressTrustAlert) }
    }

    private func set(_ key: String, _ value: Int) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
    }
}
