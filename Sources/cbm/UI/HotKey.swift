import AppKit
import Carbon.HIToolbox

/// A system-wide hotkey via the Carbon Event Manager.
///
/// `RegisterEventHotKey` is the only global hotkey API that does not require
/// Accessibility permission and does not involve running an event tap -- an
/// event tap would put us in the path of every keystroke on the machine, which
/// is both a privacy cost and a real one.
final class HotKey {
    private static var registry: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private var ref: EventHotKeyRef?
    private let id: UInt32
    private let action: () -> Void

    /// - Parameters:
    ///   - keyCode: a `kVK_` virtual key code.
    ///   - modifiers: Carbon modifier mask (`cmdKey`, `optionKey`, ...).
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        self.id = HotKey.nextID
        HotKey.nextID += 1

        HotKey.installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: OSType(0x63626D6B /* 'cbmk' */), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.error("RegisterEventHotKey failed with status \(status)")
            return nil
        }
        self.ref = ref
        HotKey.registry[id] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.registry[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hkID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID)
                guard status == noErr else { return status }
                HotKey.registry[hkID.id]?.action()
                return noErr
            },
            1, &spec, nil, nil)
    }
}

enum HotKeyDefaults {
    /// Cmd+Option+C.
    static let openPanelKeyCode = UInt32(kVK_ANSI_C)
    static let openPanelModifiers = UInt32(cmdKey | optionKey)
    static let openPanelDisplay = "⌘⌥C"
}
