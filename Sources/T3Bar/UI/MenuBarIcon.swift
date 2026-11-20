import AppKit

/// Draws the menu bar glyph: the provider's logo, then one or two thin gauges
/// for its first windows (usually Session over Weekly). A template image, so
/// macOS tints it for light, dark, and highlighted menu bars.
enum MenuBarIcon {
    private static let logoSide: CGFloat = 15
    private static let gaugeWidth: CGFloat = 16
    private static let gap: CGFloat = 4

    /// Nil when there is nothing to draw (no logo and no gauges).
    static func image(remaining: [Double], logo: NSImage? = nil, gauges: Bool = true) -> NSImage? {
        guard logo != nil || gauges else { return nil }
        let logoWidth = logo == nil ? 0 : logoSide + (gauges ? gap : 0)
        let size = NSSize(width: logoWidth + (gauges ? gaugeWidth : 0), height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            if let logo {
                let box = NSRect(x: 0, y: (rect.height - logoSide) / 2, width: logoSide, height: logoSide)
                logo.draw(in: ProviderIcons.fit(logo, in: box), from: .zero, operation: .sourceOver, fraction: 1)
            }
            if gauges {
                drawGauges(remaining, in: NSRect(x: logoWidth, y: 0, width: gaugeWidth, height: rect.height))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawGauges(_ remaining: [Double], in rect: NSRect) {
        let bars = remaining.isEmpty ? [nil, nil] : remaining.prefix(2).map { Optional($0) }
        let height: CGFloat = bars.count == 1 ? 5 : 4
        let spacing: CGFloat = 3
        let total = CGFloat(bars.count) * height + CGFloat(bars.count - 1) * spacing
        var y = rect.minY + (rect.height + total) / 2 - height

        for value in bars {
            let track = NSRect(x: rect.minX + 0.5, y: y, width: rect.width - 1, height: height)
            let radius = height / 2
            if let value {
                NSColor.black.withAlphaComponent(0.28).setFill()
                NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
                let clamped = min(1, max(0, value))
                if clamped > 0 {
                    var fill = track
                    fill.size.width = max(height, track.width * clamped)
                    NSColor.black.setFill()
                    NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
                }
            } else {
                NSColor.black.withAlphaComponent(0.6).setStroke()
                let path = NSBezierPath(roundedRect: track.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
                path.lineWidth = 1
                path.stroke()
            }
            y -= height + spacing
        }
    }
}
