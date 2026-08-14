import AppKit

/// One row of the history list. Recycled by `NSTableView`, so only the ~10 rows
/// actually on screen exist at any moment no matter how long the history is.
final class ItemRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("cbm.row")
    static let height: CGFloat = 46

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 3
        iconView.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.usesSingleLineMode = true

        subtitleLabel.font = .systemFont(ofSize: 10.5)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.cell?.usesSingleLineMode = true

        for v in [iconView, titleLabel, subtitleLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var item: ClipItem?
    private var positions: [Int] = []

    /// Re-render on selection so the highlight colour stays legible against the
    /// selected-row background.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { render() }
    }

    func configure(with item: ClipItem, highlight positions: [Int]) {
        self.item = item
        self.positions = positions
        render()
    }

    private func render() {
        guard let item else { return }
        let selected = backgroundStyle == .emphasized

        // A thumbnail says more than any icon; a site's favicon says more than
        // the browser's own icon, which would be identical on every row.
        if item.kind == .image, item.hasThumb, let thumb = ThumbCache.shared.thumbnail(forHash: item.hash) {
            iconView.image = thumb
        } else if let favicon = FaviconStore.shared.icon(forHost: item.sourceHost) {
            iconView.image = favicon
        } else {
            iconView.image = AppIconCache.shared.icon(bundleID: item.sourceBundleID)
        }

        titleLabel.attributedStringValue = Self.title(
            for: item, positions: positions, selected: selected)

        var parts: [String] = []
        if let name = item.sourceName, !name.isEmpty { parts.append(name) }
        parts.append(RelativeTime.string(item.updatedAt))
        if item.kind != .text { parts.append(item.kind.label) }
        subtitleLabel.stringValue = parts.joined(separator: " · ")
        subtitleLabel.textColor = selected
            ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.75)
            : .secondaryLabelColor
    }

    // MARK: - Highlighting

    /// Search positions arrive as byte offsets into the snippet's UTF-8, because
    /// that is what the matcher works in. Attributed strings want UTF-16 ranges,
    /// so we walk the scalars once and translate.
    private static func title(
        for item: ClipItem, positions: [Int], selected: Bool
    ) -> NSAttributedString {
        // Control characters become spaces, one byte for one byte, so the
        // offsets computed above stay valid.
        let flattened = String(item.snippet.map { $0 == "\n" || $0 == "\r" || $0 == "\t" ? " " : $0 })

        let base = NSMutableAttributedString(
            string: flattened,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: selected ? NSColor.selectedMenuItemTextColor : NSColor.labelColor,
            ])
        guard !positions.isEmpty else { return base }

        let wanted = Set(positions)
        var byteOffset = 0
        var utf16Offset = 0
        let highlightColor = selected ? NSColor.selectedMenuItemTextColor : NSColor.controlAccentColor
        let boldFont = NSFont.systemFont(ofSize: 13, weight: .bold)

        for scalar in flattened.unicodeScalars {
            let byteWidth = UTF8.encodedLength(of: scalar)
            let utf16Width = UTF16.width(of: scalar)
            if wanted.contains(byteOffset) {
                let range = NSRange(location: utf16Offset, length: utf16Width)
                if range.upperBound <= base.length {
                    base.addAttributes([.font: boldFont, .foregroundColor: highlightColor], range: range)
                }
            }
            byteOffset += byteWidth
            utf16Offset += utf16Width
        }
        return base
    }
}

private extension UTF8 {
    static func encodedLength(of scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0..<0x80: return 1
        case 0x80..<0x800: return 2
        case 0x800..<0x10000: return 3
        default: return 4
        }
    }
}

private extension UTF16 {
    static func width(of scalar: Unicode.Scalar) -> Int {
        scalar.value > 0xFFFF ? 2 : 1
    }
}
