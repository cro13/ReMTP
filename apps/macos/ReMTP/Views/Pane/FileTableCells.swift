import AppKit

extension NSUserInterfaceItemIdentifier {
    static let nameColumn = NSUserInterfaceItemIdentifier("name")
    static let statusColumn = NSUserInterfaceItemIdentifier("status")
    static let modifiedColumn = NSUserInterfaceItemIdentifier("modified")
    static let kindColumn = NSUserInterfaceItemIdentifier("kind")
    static let sizeColumn = NSUserInterfaceItemIdentifier("size")
    static let nameCell = NSUserInterfaceItemIdentifier("nameCell")
    static let statusCell = NSUserInterfaceItemIdentifier("statusCell")
    static let textCell = NSUserInterfaceItemIdentifier("textCell")
    static let stripedRow = NSUserInterfaceItemIdentifier("stripedRow")
}

/// Icon (or QuickLook thumbnail) + name. The text field becomes editable for inline rename.
final class NameCellView: NSTableCellView, FileIconCell {
    static let font = NSFont.systemFont(ofSize: 13)
    static let horizontalInset: CGFloat = 2
    static let iconSize: CGFloat = 18
    static let iconGap: CGFloat = 6

    let iconView = NSImageView()
    let label = NSTextField(labelWithString: "")
    /// Identifies the item a pending thumbnail request is for.
    var representedKey: String?
    var iconImageView: NSImageView { iconView }

    init() {
        super.init(frame: .zero)
        identifier = .nameCell
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        // NSImageView registers for image and file drags itself: over a row's icon, drops would go to
        // it (and be refused) instead of the list.
        iconView.unregisterDraggedTypes()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Self.font
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.usesSingleLineMode = true
        label.cell?.wraps = false
        label.isEditable = false
        label.isSelectable = false
        label.focusRingType = .none
        label.drawsBackground = false
        label.isBordered = false
        addSubview(iconView)
        addSubview(label)
        imageView = iconView
        textField = label
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Self.iconGap),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Date Modified, Kind and Size columns.
final class TextCellView: NSTableCellView {
    var kindProbe: FileKindDetails.Key?
    /// This cell's request for `kindProbe`'s details, while it waits.
    var kindToken: UUID?
    let label = NSTextField(labelWithString: "")

    /// Stops waiting for Kind details (the cell is reused for another row, or its row went away).
    func cancelKindProbe() {
        if let key = kindProbe, let token = kindToken { FileKindDetails.shared.cancel(key, token) }
        kindProbe = nil
        kindToken = nil
    }

    init() {
        super.init(frame: .zero)
        identifier = .textCell
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Draws the comparison symbol or progress ring directly for speed. The text provides its meaning
/// to the tooltip and VoiceOver.
final class StatusCellView: NSTableCellView {
    var status: ItemStatus = .none {
        didSet { if status != oldValue { needsDisplay = true } }
    }
    var missingDirection: MissingStatusDirection? {
        didSet { if missingDirection != oldValue { needsDisplay = true } }
    }
    var text: String? {
        didSet { if text != oldValue { toolTip = text } }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        identifier = .statusCell
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let look = status.visibleLook(missingDirection: missingDirection) else { return }
        let emphasized = backgroundStyle == .emphasized
        let color = emphasized ? NSColor.alternateSelectedControlTextColor : look.color
        let box = NSRect(x: StatusHeaderCell.inset, y: bounds.midY - 7, width: 14, height: 14)
        if let fraction = look.fraction {
            let ring = box.insetBy(dx: 2, dy: 2)
            let track = NSBezierPath(ovalIn: ring)
            track.lineWidth = 2
            (emphasized ? NSColor.white.withAlphaComponent(0.3) : NSColor.quaternaryLabelColor).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: ring.midX, y: ring.midY), radius: ring.width / 2, startAngle: 90,
                          endAngle: 90 - 360 * CGFloat(min(1, max(0.04, fraction))), clockwise: true)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            color.setStroke()
            arc.stroke()
        } else if let name = look.symbol, let image = StatusSymbols.image(name, color: color, size: 12, weight: look.weight) {
            let size = image.size
            image.draw(in: NSRect(x: box.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
        }
    }

    override func accessibilityLabel() -> String? { text }
}

/// Header of the status column: the other side's symbol instead of a title (the tooltip names it).
final class StatusHeaderCell: NSTableHeaderCell {
    /// Where the header symbol and the cells' symbols start, so they line up.
    static let inset: CGFloat = 1
    var symbolName = "laptopcomputer"

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let image = symbol else { return }
        let size = image.size
        // Centred over the rows' symbols (their cells start half the intercell spacing into the column).
        let spacing = (controlView as? NSTableHeaderView)?.tableView?.intercellSpacing.width ?? 0
        let rect = NSRect(x: cellFrame.minX + spacing / 2 + Self.inset + 7 - size.width / 2, y: cellFrame.midY - size.height / 2,
                          width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// The title the symbol stands for ("On Galaxy S23"), as in the tooltip.
    override func accessibilityLabel() -> String? { stringValue }

    /// The symbol as an outline in the header's text colour (a palette colour would fill its screen in).
    private lazy var symbol: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return nil
        }
        return NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            NSColor.secondaryLabelColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }()
}

/// Alternating background for the rows that exist. (The table's own stripes carry on through the empty
/// space below the last row, where they look like rows that are still loading.)
final class StripedRowView: NSTableRowView {
    var striped = false {
        didSet { if striped != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        let colors = NSColor.alternatingContentBackgroundColors
        guard striped, colors.count > 1 else { return }
        colors[1].setFill()
        // The inset style's selection shape.
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 0), xRadius: 5, yRadius: 5).fill()
    }
}
