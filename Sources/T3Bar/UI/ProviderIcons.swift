import AppKit
import SwiftUI

/// Provider logos as NSImages, decoded once from the SVGs in ProviderIconData.
@MainActor
enum ProviderIcons {
    enum Variant { case light, dark, template }

    private static var cache: [String: NSImage] = [:]

    static func has(_ driver: String) -> Bool { ProviderIconData.byDriver[driver] != nil }

    static func image(_ driver: String, _ variant: Variant) -> NSImage? {
        let key = "\(driver)/\(variant)"
        if let cached = cache[key] { return cached }
        guard let icon = ProviderIconData.byDriver[driver] else { return nil }
        let svg: String
        switch variant {
        case .light: svg = icon.light
        case .dark: svg = icon.dark
        case .template: svg = icon.template
        }
        guard let image = NSImage(data: Data(svg.utf8)) else { return nil }
        image.isTemplate = variant == .template
        cache[key] = image
        return image
    }

    /// The largest rect with the image's aspect ratio that fits in `box`, centered.
    nonisolated static func fit(_ image: NSImage, in box: NSRect) -> NSRect {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
    }
}

/// A provider's logo in its own colors, following light and dark mode.
struct ProviderLogo: View {
    let driver: String
    var size: CGFloat = 14
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let image = ProviderIcons.image(driver, scheme == .dark ? .dark : .light) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        }
    }
}
