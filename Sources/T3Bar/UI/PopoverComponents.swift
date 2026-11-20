import AppKit

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

/// Fonts and labels shared by the popover, matching the SwiftUI version's sizes.
enum PopoverStyle {
    static func font(size: CGFloat, weight: NSFont.Weight = .regular,
                     rounded: Bool = false, monoDigits: Bool = false) -> NSFont {
        let base = monoDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        guard rounded, let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor, rounded: Bool = false, monoDigits: Bool = false,
                      lines: Int = 1, truncation: NSLineBreakMode = .byTruncatingTail,
                      alignment: NSTextAlignment = .left) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font(size: size, weight: weight, rounded: rounded, monoDigits: monoDigits)
        label.textColor = color
        label.alignment = alignment
        label.lineBreakMode = truncation
        label.maximumNumberOfLines = lines
        label.cell?.usesSingleLineMode = lines == 1
        if lines != 1 {
            label.cell?.wraps = true
            label.cell?.isScrollable = false
            label.cell?.truncatesLastVisibleLine = true
        }
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = .secondaryLabelColor) -> NSImageView? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        let view = NSImageView(image: image)
        view.contentTintColor = color
        view.imageScaling = .scaleProportionallyDown
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }
}

/// An empty flexible view that lets a stack push its neighbours apart.
final class SpacerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Origin at the top-left, so a scroll view starts at the first row.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Root of the popover; tells the controller to redraw when light/dark switches.
final class PopoverRootView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// The 1 pt divider under the header and between the rows of a card.
final class SeparatorView: NSView {
    private let opacity: CGFloat

    init(opacity: CGFloat) {
        self.opacity = opacity
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(opacity).setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The pale orange strip that says the numbers are not live.
final class BannerView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemOrange.withAlphaComponent(0.08).setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The 6 pt dot beside the connection line.
final class DotView: NSView {
    var color: NSColor = .systemGreen { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 6).isActive = true
        heightAnchor.constraint(equalToConstant: 6).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

