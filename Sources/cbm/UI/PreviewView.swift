import AppKit

/// The right-hand pane. Loads the full payload off the main thread and drops
/// stale loads, so holding an arrow key down never queues up work the user has
/// already scrolled past.
final class PreviewView: NSView {
    /// Enough to recognise anything; past this, rendering starts to cost more
    /// than the preview is worth.
    private static let textPreviewLimit = 100_000

    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let imageView = NSImageView()
    private let placeholder = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")

    private var generation = 0
    private let loadQueue = DispatchQueue(label: "ee.henno.cbm.preview", qos: .userInitiated)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        // Scale the image to the pane, never the pane to the image. An image
        // view's intrinsic size is the image's pixel size, so without dropping
        // these priorities a large screenshot would push the whole window wider
        // and taller than the screen.
        imageView.imageScaling = .scaleProportionallyDown
        imageView.isHidden = true
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)

        placeholder.font = .systemFont(ofSize: 12)
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center
        placeholder.isHidden = true

        metaLabel.font = .systemFont(ofSize: 10.5)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail

        // Same reasoning as the image view: a long single-line metadata string
        // or placeholder must truncate, not widen its container.
        for label in [placeholder, metaLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        for v in [scrollView, imageView, placeholder, metaLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            metaLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            metaLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            metaLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: metaLabel.topAnchor, constant: -8),

            imageView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: ClipItem?) {
        generation += 1
        let token = generation

        guard let item else {
            showPlaceholder("No entries")
            metaLabel.stringValue = ""
            return
        }

        metaLabel.stringValue = Self.meta(for: item)

        // Images already have a decoded thumbnail in memory; show it at once so
        // arrowing through a list of screenshots never flashes empty, then swap
        // in the full-size version when it arrives.
        if item.kind == .image, let thumb = ThumbCache.shared.thumbnail(forHash: item.hash) {
            showImage(thumb)
        }

        loadQueue.async { [weak self] in
            guard let self else { return }
            let reps = ItemStore.shared.representations(of: item.id)
            DispatchQueue.main.async {
                guard token == self.generation else { return }
                self.render(item: item, reps: reps)
            }
        }
    }

    private func render(item: ClipItem, reps: [Representation]) {
        func data(_ uti: NSPasteboard.PasteboardType) -> Data? {
            reps.first { $0.uti == uti.rawValue }?.data
        }

        switch item.kind {
        case .image:
            let bytes = data(.png) ?? data(.tiff)
            if let bytes, let image = NSImage(data: bytes) {
                showImage(image)
            } else {
                showPlaceholder("Image data unavailable")
            }

        case .files:
            let list = reps.first { $0.uti == PasteboardReader.fileListType.rawValue }
            let text = list.flatMap { String(data: $0.data, encoding: .utf8) } ?? ""
            let paths = text.split(separator: "\n")
                .compactMap { URL(string: String($0))?.path }
                .joined(separator: "\n")
            showText(paths.isEmpty ? item.snippet : paths)

        case .text, .rich:
            if let plain = data(.string), let text = String(data: plain, encoding: .utf8) {
                showText(text)
            } else if let rtf = data(.rtf),
                      let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil) {
                showText(attributed.string)
            } else {
                showPlaceholder("No text representation")
            }
        }
    }

    private func showText(_ text: String) {
        let clipped: String
        if text.utf8.count > Self.textPreviewLimit {
            let prefix = String(text.prefix(Self.textPreviewLimit / 2))
            clipped = prefix + "\n\n… truncated for preview (\(ByteSize.string(Int64(text.utf8.count))) total)"
        } else {
            clipped = text
        }
        textView.string = clipped
        textView.scroll(.zero)
        scrollView.isHidden = false
        imageView.isHidden = true
        placeholder.isHidden = true
    }

    private func showImage(_ image: NSImage) {
        imageView.image = image
        imageView.isHidden = false
        scrollView.isHidden = true
        placeholder.isHidden = true
    }

    private func showPlaceholder(_ text: String) {
        placeholder.stringValue = text
        placeholder.isHidden = false
        scrollView.isHidden = true
        imageView.isHidden = true
    }

    private static func meta(for item: ClipItem) -> String {
        var parts: [String] = [item.kind.label]
        if item.kind == .image, item.pixelWidth > 0 {
            parts.append("\(item.pixelWidth)×\(item.pixelHeight)")
        }
        parts.append(ByteSize.string(item.totalBytes))
        if let name = item.sourceName, !name.isEmpty { parts.append(name) }
        parts.append(RelativeTime.string(item.updatedAt))
        return parts.joined(separator: "  ·  ")
    }
}
