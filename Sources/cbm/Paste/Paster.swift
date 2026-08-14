import AppKit
import Carbon.HIToolbox

/// Puts an entry back on the clipboard and, when allowed, presses Cmd+V in the
/// app the user came from.
///
/// Synthesising a keystroke requires the Accessibility permission. Without it
/// everything still works, minus the final keypress -- the entry lands on the
/// clipboard and the user presses Cmd+V themselves.
enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt. Only ever called from an explicit user action.
    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    enum Mode {
        /// Restore every stored representation, then press Cmd+V.
        case paste
        /// Restore every stored representation, but leave Cmd+V to the user.
        case copyOnly
        /// Restore only the plain-text representation, then press Cmd+V.
        case pastePlain
    }

    /// - Parameter target: the app to return focus to. Captured before the panel
    ///   opened, because by the time we paste we are the frontmost app.
    static func perform(
        item: ClipItem,
        reps: [Representation],
        mode: Mode,
        target: NSRunningApplication?
    ) {
        let payload = mode == .pastePlain ? plainOnly(reps) : reps
        guard !payload.isEmpty else {
            Log.error("nothing to paste for item \(item.id)")
            return
        }

        ClipboardMonitor.shared.write { pb in
            writeItems(payload, kind: item.kind, to: pb)
        } completion: {
            guard mode != .copyOnly else { return }
            guard isTrusted else {
                Log.ui("no Accessibility permission; left it on the clipboard")
                return
            }
            activateAndPaste(target: target)
        }
    }

    private static func plainOnly(_ reps: [Representation]) -> [Representation] {
        reps.filter { $0.uti == NSPasteboard.PasteboardType.string.rawValue }
    }

    private static func writeItems(_ reps: [Representation], kind: ItemKind, to pb: NSPasteboard) {
        // A multi-file selection has to go back as one pasteboard item per file,
        // or the receiving app sees a single file.
        if kind == .files,
           let list = reps.first(where: { $0.uti == PasteboardReader.fileListType.rawValue }),
           let joined = String(data: list.data, encoding: .utf8) {
            let urls = joined.split(separator: "\n").compactMap { URL(string: String($0)) }
            if !urls.isEmpty {
                pb.writeObjects(urls as [NSURL])
                return
            }
        }

        let item = NSPasteboardItem()
        for rep in reps where rep.uti != PasteboardReader.fileListType.rawValue {
            item.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.uti))
        }
        pb.writeObjects([item])
    }

    private static func activateAndPaste(target: NSRunningApplication?) {
        target?.activate()
        // Give the activation a moment to land; posting Cmd+V into a window that
        // is not yet key sends it nowhere.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            sendCommandV()
        }
    }

    private static func sendCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let v = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else { return }
        // Set the flags explicitly rather than OR-ing onto whatever is currently
        // held: a stray Shift still down from the hotkey would turn this into
        // Cmd+Shift+V, which means something else in most apps.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
