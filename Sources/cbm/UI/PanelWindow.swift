import AppKit

/// Borderless panel that can still take keyboard focus.
///
/// `NSWindow` refuses key status for borderless windows unless `canBecomeKey` is
/// overridden, and the search field is useless without it.
final class PanelWindow: NSPanel {
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    var onCancel: (() -> Void)?
    var onResignKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Follow the user across Spaces and sit above full-screen apps, the way
        // a launcher panel is expected to.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        animationBehavior = .none

        // A hard ceiling on the window size. Auto Layout will grow a window to
        // satisfy its content's intrinsic size, and a preview of a 2000px
        // screenshot has an intrinsic size to match -- without this the panel
        // stretches to fill the screen the moment such an image is selected.
        // The views also refuse to push (see PreviewView); this is the backstop.
        contentMinSize = size
        contentMaxSize = size

        let root = RoundedBackgroundView(frame: NSRect(origin: .zero, size: size))
        contentView = root
    }

    /// Cmd-modified keys never reach the field editor's command handling, so
    /// they are caught here instead.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// Opaque, rounded, no vibrancy.
///
/// `NSVisualEffectView` -- the translucent launcher look -- makes the window
/// server re-sample and blur everything behind the panel on every frame it is
/// open. For a panel that exists to be fast, that is the one decoration worth
/// refusing.
final class RoundedBackgroundView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}
