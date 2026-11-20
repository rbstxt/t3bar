import AppKit
import Combine
import SwiftUI

/// Owns the menu bar item and its popover.
@MainActor
final class StatusController: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private let prefs: Preferences
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var subscriptions = Set<AnyCancellable>()

    init(store: UsageStore, prefs: Preferences) {
        self.store = store
        self.prefs = prefs
        super.init()

        // A transient popover closes on any outside click; the screenshot aid keeps it open.
        popover.behavior = ProcessInfo.processInfo.environment["T3BAR_OPEN_POPOVER"] == "1" ? .applicationDefined : .transient
        popover.animates = true
        popover.delegate = self

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
        }

        // objectWillChange fires before the change; hopping to the next run loop reads the new values.
        store.objectWillChange.merge(with: prefs.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &subscriptions)
        render()
    }

    // MARK: Menu bar

    private func shownSelection() -> (group: DriverGroup, window: WindowGroup)? {
        let groups = store.groups.filter { !$0.windows.isEmpty }
        if prefs.menuBarProvider != Preferences.automatic,
           let group = groups.first(where: { $0.driver == prefs.menuBarProvider }),
           let window = group.tightest {
            return (group, window)
        }
        return groups
            .compactMap { group in group.tightest.map { (group, $0) } }
            .min { $0.1.remainingPercent < $1.1.remainingPercent }
    }

    private func render() {
        guard let button = item.button else { return }
        let selection = shownSelection()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        if let selection {
            let bars = selection.group.windows.prefix(2).map { Double($0.remainingPercent) / 100 }
            let logo = prefs.showsProviderIcon ? ProviderIcons.image(selection.group.driver, .template) : nil
            let image = MenuBarIcon.image(remaining: bars, logo: logo, gauges: prefs.showsGauge)
            button.image = image
            let remaining = selection.window.remainingPercent
            var text = ""
            // A provider without a logo keeps its name, so the number is never anonymous.
            if prefs.showsProviderIcon, logo == nil { text = selection.group.name }
            // With everything turned off, still show the number rather than an empty item.
            if prefs.showsPercent || (image == nil && text.isEmpty) {
                text += (text.isEmpty ? "" : " ") + "\(remaining)%"
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .baselineOffset: 0.5]
            if prefs.colorsWhenLow {
                let forecast = prefs.colorsOnForecast && selection.group.windows.contains { $0.emptiesAt != nil }
                if let color = Theme.alert(remaining) ?? (forecast ? .systemOrange : nil) {
                    attributes[.foregroundColor] = color
                }
            }
            let lead = image == nil || text.isEmpty ? "" : " "
            button.attributedTitle = NSAttributedString(string: lead + text, attributes: attributes)
        } else {
            button.image = MenuBarIcon.image(remaining: [])
            button.attributedTitle = NSAttributedString(string: "")
        }
        button.appearsDisabled = store.connection != .live
        button.toolTip = tooltip(selection)
        button.setAccessibilityLabel(selection.map {
            "\($0.group.name) \($0.window.label) 残り \($0.window.remainingPercent)%"
        } ?? "T3Bar")
    }

    /// Only what the menu bar shows: the provider, then its gauge windows (and the
    /// window behind the number, if that is not one of them), one line each.
    private func tooltip(_ selection: (group: DriverGroup, window: WindowGroup)?) -> String {
        var lines: [String] = []
        if let (group, shown) = selection {
            let now = Date()
            var windows = Array(group.windows.prefix(2))
            if !windows.contains(where: { $0.id == shown.id }) { windows.append(shown) }
            lines.append(group.name)
            for w in windows {
                let pooled = w.members.count > 1
                var line = "\(w.label) \(pooled ? "平均" : "")\(w.remainingPercent)%"
                if let reset = w.nextReset { line += "  ↻\(Format.countdown(to: reset, now: now))" }
                for m in w.members {
                    guard let empties = m.emptiesAt else { continue }
                    line += "  \(pooled ? m.account.initials + " " : "")\(Format.countdown(to: empties, now: now))で枯渇"
                }
                lines.append(line)
            }
        }
        if store.connection != .live { lines.append(UsageStore.Connection.statusLabel(store.connection)) }
        return lines.isEmpty ? "T3Bar" : lines.joined(separator: "\n")
    }

    // MARK: Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuickMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard !popover.isShown, let button = item.button else { return }
        let view = PopoverView(store: store, prefs: prefs, openT3: { [weak self] in self?.openT3() },
                               quit: { NSApp.terminate(nil) })
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        // Drop the view tree while closed; the menu bar needs nothing from it.
        popover.contentViewController = nil
    }

    private func showQuickMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "今すぐ再取得", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "T3 Code を開く", action: #selector(openT3), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "T3Bar を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func refreshNow() { store.refresh() }

    /// Development aid: writes the menu bar button, drawn dark and light, to a PNG.
    func dumpButton(to path: String) {
        guard let button = item.button else { return }
        let size = button.bounds.size
        let scale: CGFloat = 4
        let canvas = NSImage(size: NSSize(width: size.width, height: size.height * 2 + 4))
        canvas.lockFocus()
        for (index, name) in [NSAppearance.Name.darkAqua, .aqua].enumerated() {
            let appearance = NSAppearance(named: name)!
            appearance.performAsCurrentDrawingAppearance {
                let y = CGFloat(1 - index) * (size.height + 4)
                (name == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(x: 0, y: y, width: size.width, height: size.height).fill()
                let ink = name == .darkAqua ? NSColor.white : NSColor.black
                if let image = button.image {
                    let tinted = NSImage(size: image.size, flipped: false) { rect in
                        image.draw(in: rect)
                        ink.set()
                        rect.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: NSRect(x: 4, y: y + (size.height - image.size.height) / 2,
                                           width: image.size.width, height: image.size.height))
                }
                let title = NSMutableAttributedString(attributedString: button.attributedTitle)
                title.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: title.length)) { value, range, _ in
                    if value == nil { title.addAttribute(.foregroundColor, value: ink, range: range) }
                }
                title.draw(at: NSPoint(x: 4 + (button.image?.size.width ?? 0), y: y + 3))
            }
        }
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        let scaled = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.size.width * scale),
                                      pixelsHigh: Int(canvas.size.height * scale), bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
        NSGraphicsContext.current?.imageInterpolation = .none
        rep.draw(in: NSRect(x: 0, y: 0, width: scaled.pixelsWide, height: scaled.pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        try? scaled.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        try? (button.toolTip ?? "").write(toFile: path + ".txt", atomically: true, encoding: .utf8)
    }

    @objc func openT3() {
        popover.performClose(nil)
        let workspace = NSWorkspace.shared
        if let url = workspace.urlForApplication(withBundleIdentifier: "com.t3tools.t3code") {
            workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

extension UsageStore.Connection {
    static func statusLabel(_ c: UsageStore.Connection) -> String {
        switch c {
        case .live: "接続中"
        case .connecting: "T3 Code に接続しています…"
        case .serverDown: "T3 Code が起動していません"
        case .authFailed(let m): "認証エラー: \(m)"
        case .incompatible: "未対応の T3 Code バージョン"
        case .failed(let m): "接続エラー: \(m)"
        }
    }
}
