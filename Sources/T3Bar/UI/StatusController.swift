import AppKit

/// The color the menu bar number should get, kept semantic so it compares
/// cleanly before the attributed title is rebuilt.
enum MenuBarTone: Equatable {
    case normal, warning, critical
}

/// Everything `render` would put on the item. Compared field by field so an
/// unchanged attribute is not written again, and the icon is only redrawn when
/// its drawing inputs (logo, gauges, bar values) actually change.
struct MenuBarItemSnapshot: Equatable {
    struct ImageInput: Equatable {
        var logoDriver: String?
        var bars: [Int]
        var gauges: Bool
    }

    var image: ImageInput?
    var title: String
    var tone: MenuBarTone
    var isDisabled: Bool
    var accessibilityLabel: String
    var tooltip: String
}

/// Owns the menu bar item and its popover.
@MainActor
final class StatusController: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private let prefs: Preferences
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var tokens: [ObserverToken] = []
    private var popoverController: PopoverViewController?
    private var lastSnapshot: MenuBarItemSnapshot?

    init(store: UsageStore, prefs: Preferences) {
        self.store = store
        self.prefs = prefs
        super.init()

        // A transient popover closes on any outside click; the screenshot aid keeps it open.
        popover.behavior = ProcessInfo.processInfo.environment["T3BAR_OPEN_POPOVER"] == "1" ? .applicationDefined : .transient
        popover.animates = true
        popover.delegate = self

        // Read the system's increase-contrast setting on the main thread and
        // keep the cache the colour provider reads up to date.
        Theme.startTrackingHighContrast()

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
        }

        tokens = [
            store.observe { [weak self] in self?.render() },
            prefs.observe { [weak self] in self?.render() },
        ]
        render()
    }

    deinit {
        // `deinit` is nonisolated; the controller is owned by the main actor,
        // so releasing its observer tokens here is safe.
        MainActor.assumeIsolated {
            for token in tokens { token.cancel() }
        }
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

    private func makeSnapshot() -> MenuBarItemSnapshot {
        guard let selection = shownSelection() else {
            return MenuBarItemSnapshot(
                image: nil,
                title: "",
                tone: .normal,
                isDisabled: store.connection != .live,
                accessibilityLabel: "T3Bar",
                tooltip: tooltip(nil))
        }

        let logoDriver = prefs.showsProviderIcon && ProviderIcons.has(selection.group.driver)
            ? selection.group.driver : nil
        let bars = selection.group.windows.prefix(2).map(\.remainingPercent)
        let gauges = prefs.showsGauge
        let imageIsNil = logoDriver == nil && !gauges

        let remaining = selection.window.remainingPercent
        var text = ""
        // A provider without a logo keeps its name, so the number is never anonymous.
        if prefs.showsProviderIcon, logoDriver == nil { text = selection.group.name }
        // With everything turned off, still show the number rather than an empty item.
        if prefs.showsPercent || (imageIsNil && text.isEmpty) {
            text += (text.isEmpty ? "" : " ") + "\(remaining)%"
        }
        let lead = imageIsNil || text.isEmpty ? "" : " "

        // A forecast means some window in the shown provider runs out before its reset.
        let onForecast = selection.group.windows.contains { $0.emptiesAt != nil }
        let tone = Self.tone(remaining: remaining, onForecast: onForecast,
                             colorsWhenLow: prefs.colorsWhenLow, colorsOnForecast: prefs.colorsOnForecast)

        return MenuBarItemSnapshot(
            image: MenuBarItemSnapshot.ImageInput(logoDriver: logoDriver, bars: bars, gauges: gauges),
            title: lead + text,
            tone: tone,
            isDisabled: store.connection != .live,
            accessibilityLabel: "\(selection.group.name) \(selection.window.label) 残り \(remaining)%",
            tooltip: tooltip(selection))
    }

    /// The color the menu bar number gets: red at `Theme.levels.critical`,
    /// orange at `warn` (the boundary counts as low) or when a window is
    /// forecast to run out before its reset, and no color when the user turned
    /// the feature off. Pure and internal, so the rules are directly testable.
    static func tone(remaining: Int, onForecast: Bool,
                     colorsWhenLow: Bool, colorsOnForecast: Bool) -> MenuBarTone {
        guard colorsWhenLow else { return .normal }
        if remaining <= Theme.levels.critical { return .critical }
        if remaining <= Theme.levels.warn { return .warning }
        if colorsOnForecast && onForecast { return .warning }
        return .normal
    }

    private func render() {
        guard let button = item.button else { return }
        let snapshot = makeSnapshot()
        let previous = lastSnapshot

        if snapshot.image != previous?.image {
            button.image = image(for: snapshot.image)
        }

        if snapshot.title != previous?.title || snapshot.tone != previous?.tone {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .baselineOffset: -0.5]
            switch snapshot.tone {
            case .normal: break
            case .warning: attributes[.foregroundColor] = NSColor.systemOrange
            case .critical: attributes[.foregroundColor] = NSColor.systemRed
            }
            button.attributedTitle = NSAttributedString(string: snapshot.title, attributes: attributes)
        }

        if snapshot.isDisabled != previous?.isDisabled {
            button.appearsDisabled = snapshot.isDisabled
        }
        if snapshot.accessibilityLabel != previous?.accessibilityLabel {
            button.setAccessibilityLabel(snapshot.accessibilityLabel)
        }
        if snapshot.tooltip != previous?.tooltip {
            button.toolTip = snapshot.tooltip
        }

        lastSnapshot = snapshot
    }

    private func image(for input: MenuBarItemSnapshot.ImageInput?) -> NSImage? {
        guard let input else { return MenuBarIcon.image(remaining: []) }
        let logo = input.logoDriver.flatMap { ProviderIcons.image($0, .template) }
        return MenuBarIcon.image(remaining: input.bars.map { Double($0) / 100 }, logo: logo, gauges: input.gauges)
    }

    /// The usage lines shared by the menu bar tooltip. Pure, so the 0% reset
    /// wording is directly testable without a status item.
    static func usageTooltipLines(group: DriverGroup, shown: WindowGroup, now: Date) -> [String] {
        var windows = Array(group.windows.prefix(2))
        if !windows.contains(where: { $0.id == shown.id }) { windows.append(shown) }
        var lines = [group.name]
        for w in windows {
            let pooled = w.members.count > 1
            var line = "\(w.label) \(pooled ? "平均" : "")\(w.remainingPercent)%"
            if let reset = w.nextReset { line += "  ↻\(Format.countdown(to: reset, now: now))" }
            for m in w.members {
                let prefix = pooled ? m.account.initials + " " : ""
                if let zero = Depletion.note(remaining: m.remainingPercent,
                                             reset: m.resetsAt, now: now) {
                    line += "  \(prefix)\(zero.short)"
                } else if let empties = m.emptiesAt {
                    line += "  \(prefix)\(Format.countdown(to: empties, now: now))で枯渇"
                }
            }
            lines.append(line)
        }
        return lines
    }

    /// Only what the menu bar shows: the provider, then its gauge windows (and the
    /// window behind the number, if that is not one of them), one line each.
    ///
    /// The countdown text is a snapshot: the tooltip is rebuilt only when the
    /// store (new numbers) or the preferences notify, or when the item is
    /// rendered for another reason. There is no dedicated tooltip timer, so a
    /// hover can be a few tens of seconds stale between pushes.
    private func tooltip(_ selection: (group: DriverGroup, window: WindowGroup)?) -> String {
        let now = Date()
        var lines = selection.map {
            Self.usageTooltipLines(group: $0.group, shown: $0.window, now: now)
        } ?? []
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
        let controller = PopoverViewController(
            store: store, prefs: prefs,
            openT3: { [weak self] in self?.openT3() },
            quit: { NSApp.terminate(nil) })
        controller.onSizeChange = { [weak self] size in self?.popover.contentSize = size }
        popover.contentViewController = controller
        popoverController = controller
        controller.loadViewIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // The single start path: the controller owns the popover lifecycle, so
        // it attaches the feeds here instead of also doing it in viewDidAppear.
        controller.startUpdates()
    }

    func popoverDidClose(_ notification: Notification) {
        // Drop the view tree while closed; the menu bar needs nothing from it.
        popoverController?.stopUpdates()
        popoverController = nil
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
