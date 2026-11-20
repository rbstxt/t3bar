import AppKit

/// The popover, built with AppKit views only: a fixed 340 pt column with a
/// header, a scrolling list of providers and, when the numbers are stale, a
/// warning strip. Sizes itself from the measured content, up to a screen limit.
@MainActor
final class PopoverViewController: NSViewController {
    private let store: UsageStore
    private let prefs: Preferences
    private let openT3: () -> Void
    private let quit: () -> Void

    /// Called whenever the measured content size changes, so the popover can follow.
    var onSizeChange: ((NSSize) -> Void)?

    private static let width: CGFloat = 340
    /// Remembered across openings so the popover opens at its last size.
    private static var lastHeight: CGFloat = 240

    private let header = PopoverHeaderView()
    private let bodyContainer = NSView()
    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    private let listCanvas = PopoverListCanvasView()
    private var bodyHeight: NSLayoutConstraint!
    private var scrollHeight: NSLayoutConstraint?
    /// Kept so switching between the live (flush) and banner layouts can turn
    /// the same constraint off instead of adding a new one every rebuild.
    private var scrollBottom: NSLayoutConstraint?

    private var started = false
    private var firstLayout = true
    private var lastShownHeight: CGFloat = 0
    private var lastLaidOutHeight: CGFloat = 0
    private var tokens: [ObserverToken] = []
    private var timer: Timer?
    private var highContrastObserver: NSObjectProtocol?

    init(store: UsageStore, prefs: Preferences, openT3: @escaping () -> Void, quit: @escaping () -> Void) {
        self.store = store
        self.prefs = prefs
        self.openT3 = openT3
        self.quit = quit
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: Self.width, height: Self.lastHeight)
        lastShownHeight = min(Self.lastHeight, Self.listLimit(for: NSScreen.main))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Teardown lives in `stopUpdates()`, called from `popoverDidClose` and
    // `viewDidDisappear`. There is deliberately no `deinit` cleanup: the
    // controller is released through the popover delegate, and `deinit` is
    // nonisolated, so touching the timer or tokens there would be an unsafe
    // main-actor access.

    override func loadView() {
        let root = PopoverRootView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.lastHeight))
        root.onAppearanceChange = { [weak self] in
            guard let self else { return }
            self.markNeedsDisplay(self.view)
        }
        view = root

        header.onRefresh = { [weak self] in self?.store.refresh() }
        header.onSettings = { [weak self] button in self?.showSettingsMenu(from: button) }

        let divider = SeparatorView(opacity: 0.6)
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(divider)
        root.addSubview(bodyContainer)

        bodyHeight = bodyContainer.heightAnchor.constraint(equalToConstant: max(1, Self.lastHeight))
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bodyContainer.topAnchor.constraint(equalTo: divider.bottomAnchor),
            bodyContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bodyContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bodyHeight,
        ])

        configureScrollView()
        refresh()
    }

    private func configureScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.horizontalScrollElasticity = .none

        documentView.frame = NSRect(x: 0, y: 0, width: Self.width, height: 100)
        scrollView.documentView = documentView

        documentView.addSubview(listCanvas)
        listCanvas.onTogglePin = { [weak self] driver in
            guard let self else { return }
            self.prefs.menuBarProvider = self.prefs.menuBarProvider == driver ? Preferences.automatic : driver
        }
        listCanvas.pinnedDriver = { [weak self] driver in self?.prefs.menuBarProvider == driver }
    }

    // MARK: - Updates

    /// Starts the 30 s redraw of relative times and the store/preferences feeds.
    /// Safe to call more than once. `StatusController.showPopover` is the only
    /// call site: the popover's owner starts the feed explicitly, while
    /// `viewDidAppear` only handles layout. Teardown lives in `stopUpdates()`.
    func startUpdates() {
        guard !started else { return }
        started = true
        Theme.startTrackingHighContrast()
        startHighContrastObservation()
        tokens = [
            store.observe { [weak self] in self?.refresh() },
            prefs.observe { [weak self] in self?.refresh() },
        ]
        let ticker = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        ticker.tolerance = 5
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    /// Repaints while the popover is open when the system contrast setting
    /// changes; the notifications otherwise leave the cached colours stale
    /// until the next appearance change.
    private func startHighContrastObservation() {
        highContrastObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Theme.refreshHighContrast()
                guard let self, self.isViewLoaded else { return }
                self.markNeedsDisplay(self.view)
            }
        }
    }

    /// Stops the timer and drops every observation. Idempotent, so the popover
    /// delegate and `viewDidDisappear` can both call it.
    func stopUpdates() {
        started = false
        timer?.invalidate()
        timer = nil
        if let highContrastObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(highContrastObserver)
            self.highContrastObserver = nil
        }
        for token in tokens { token.cancel() }
        tokens.removeAll()
    }

    /// Test seam: whether store/preference feeds and the 30 s ticker are live.
    var isUpdating: Bool { started }
    var hasUpdateTimer: Bool { timer != nil }
    var observerCount: Int { tokens.count }
    var isObservingHighContrast: Bool { highContrastObserver != nil }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        stopUpdates()
    }

    private func markNeedsDisplay(_ view: NSView) {
        view.needsDisplay = true
        for subview in view.subviews { markNeedsDisplay(subview) }
    }

    private func refresh() {
        guard isViewLoaded else { return }
        header.update(store: store)
        rebuildBody()
        updateSize()
    }

    private var maxListHeight: CGFloat {
        Self.listLimit(for: view.window?.screen ?? NSScreen.main)
    }

    /// The tallest the list may get on a given screen, leaving room for the
    /// header and the menu bar. Screens differ in height, so this is per-screen.
    private static func listLimit(for screen: NSScreen?) -> CGFloat {
        ((screen?.visibleFrame.height ?? 900) - 120).clamped(to: 300...680)
    }

    private func rebuildBody() {
        let now = Date()
        let previousOffset = scrollView.contentView.bounds.origin.y

        scrollHeight?.isActive = false
        scrollHeight = nil
        scrollBottom?.isActive = false
        scrollBottom = nil
        for subview in bodyContainer.subviews { subview.removeFromSuperview() }

        if store.hasData {
            let contentHeight = configureList(now: now)
            Self.lastHeight = contentHeight

            var shown = min(contentHeight, maxListHeight)
            if lastShownHeight > 0, abs(shown - lastShownHeight) <= 0.5 { shown = lastShownHeight }
            lastShownHeight = shown

            bodyContainer.addSubview(scrollView)
            let height = scrollView.heightAnchor.constraint(equalToConstant: shown)
            scrollHeight = height
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
                scrollView.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
                height,
            ])

            if store.connection == .live {
                scrollBottom = scrollView.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor)
                scrollBottom?.isActive = true
                bodyHeight.constant = shown
            } else {
                let banner = makeBanner()
                bodyContainer.addSubview(banner)
                NSLayoutConstraint.activate([
                    banner.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
                    banner.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
                    banner.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
                    banner.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
                ])
                view.layoutSubtreeIfNeeded()
                bodyHeight.constant = shown + banner.fittingSize.height
            }

            view.layoutSubtreeIfNeeded()
            let maxY = max(0, documentView.frame.height - shown)
            let y = firstLayout ? 0 : min(previousOffset, maxY)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            firstLayout = false
        } else {
            let empty = makeEmptyState()
            bodyContainer.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
                empty.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
                empty.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
                // Pin the bottom too: the stack is the whole body here, so
                // leaving it open makes the body height ambiguous.
                empty.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
            ])
            empty.layoutSubtreeIfNeeded()
            bodyHeight.constant = max(empty.fittingSize.height, 1)
        }

        view.layoutSubtreeIfNeeded()
    }

    private func updateSize() {
        header.layoutSubtreeIfNeeded()
        let total = ceil(header.fittingSize.height + 1 + bodyHeight.constant)
        guard lastLaidOutHeight == 0 || abs(total - lastLaidOutHeight) > 0.5 else { return }
        lastLaidOutHeight = total
        let size = NSSize(width: Self.width, height: total)
        preferredContentSize = size
        onSizeChange?(size)
    }

    // MARK: - List

    private func configureList(now: Date) -> CGFloat {
        listCanvas.configure(groups: store.groups, prefs: prefs, now: now)
        let height = max(listCanvas.requiredHeight, 1)
        listCanvas.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        documentView.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        return height
    }

    // MARK: - Empty state and banner

    private func makeEmptyState() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 24, bottom: 28, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        switch store.connection {
        case .connecting:
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.startAnimation(nil)
            stack.addArrangedSubview(spinner)
            stack.addArrangedSubview(centered(PopoverStyle.label("T3 Code に接続しています…", size: 12,
                                                                 color: .secondaryLabelColor)))
        case .live:
            addSymbol("chart.bar.xaxis", to: stack)
            stack.addArrangedSubview(centered(PopoverStyle.label("表示できる使用量がありません", size: 12.5,
                                                                 weight: .semibold)))
            stack.addArrangedSubview(centered(detail("T3 Code で使用量の上限を報告するプロバイダーにログインすると、ここに表示されます。")))
        case .serverDown:
            addSymbol("powerplug", to: stack)
            stack.addArrangedSubview(centered(PopoverStyle.label("T3 Code が起動していません", size: 12.5,
                                                                 weight: .semibold)))
            stack.addArrangedSubview(centered(detail("起動すると自動で接続します。")))
            stack.addArrangedSubview(smallButton("T3 Code を開く", action: #selector(openT3Pressed)))
        case .authFailed(let message):
            addSymbol("key", to: stack)
            stack.addArrangedSubview(centered(PopoverStyle.label("T3 Code に接続できません", size: 12.5,
                                                                 weight: .semibold)))
            stack.addArrangedSubview(centered(detail(message)))
            stack.addArrangedSubview(smallButton("トークンを再発行", action: #selector(resetTokenPressed)))
        case .incompatible:
            addSymbol("arrow.triangle.2.circlepath", to: stack)
            stack.addArrangedSubview(centered(PopoverStyle.label("この T3 Code には未対応です", size: 12.5,
                                                                 weight: .semibold)))
            stack.addArrangedSubview(centered(detail("T3 Code の通信形式が変わりました。T3Bar の更新が必要です。")))
        case .failed(let message):
            addSymbol("exclamationmark.triangle", to: stack)
            stack.addArrangedSubview(centered(PopoverStyle.label("接続が切れました", size: 12.5, weight: .semibold)))
            stack.addArrangedSubview(centered(detail(message)))
            stack.addArrangedSubview(smallButton("再接続", action: #selector(reconnectPressed)))
        }

        return stack
    }

    private func addSymbol(_ name: String, to stack: NSStackView) {
        if let symbol = PopoverStyle.symbol(name, pointSize: 22, weight: .light) {
            stack.addArrangedSubview(symbol)
        }
    }

    private func centered(_ label: NSTextField) -> NSTextField {
        label.alignment = .center
        return label
    }

    private func detail(_ text: String) -> NSTextField {
        let label = PopoverStyle.label(text, size: 11, color: .secondaryLabelColor, lines: 0,
                                       truncation: .byWordWrapping, alignment: .center)
        label.preferredMaxLayoutWidth = 292
        return label
    }

    private func smallButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func makeBanner() -> NSView {
        let banner = BannerView()
        banner.translatesAutoresizingMaskIntoConstraints = false

        let line = NSStackView()
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 6
        if let icon = PopoverStyle.symbol("exclamationmark.triangle.fill", pointSize: 11, color: .systemOrange) {
            line.addArrangedSubview(icon)
        }
        line.addArrangedSubview(PopoverStyle.label(store.connection.bannerText, size: 11,
                                                   color: .secondaryLabelColor))
        line.addArrangedSubview(SpacerView())
        line.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: banner.topAnchor, constant: 8),
            line.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -8),
            line.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -14),
        ])
        return banner
    }

    // MARK: - Menus

    private func showSettingsMenu(from button: NSButton) {
        // `popUp` takes the point in the button's own coordinate space. Buttons
        // are flipped (origin top-left), so "4 pt below the button" is maxY + 4
        // there and minY - 4 in an unflipped control.
        let y = button.isFlipped ? button.bounds.maxY + 4 : button.bounds.minY - 4
        buildSettingsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: button)
    }

    /// Internal so tests can inspect the checks and enabled state this menu
    /// builds without opening a real menu.
    func buildSettingsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(sectionHeader("メニューバー"))

        let providerItem = NSMenuItem(title: "表示するプロバイダー", action: nil, keyEquivalent: "")
        let providerMenu = NSMenu()
        providerMenu.autoenablesItems = false
        providerMenu.addItem(choice("自動（残りが最も少ない）", represented: Preferences.automatic,
                                    checked: prefs.menuBarProvider == Preferences.automatic,
                                    action: #selector(selectProvider(_:))))
        providerMenu.addItem(.separator())
        for group in store.groups where !group.windows.isEmpty {
            providerMenu.addItem(choice(group.name, represented: group.driver,
                                        checked: prefs.menuBarProvider == group.driver,
                                        action: #selector(selectProvider(_:))))
        }
        providerItem.submenu = providerMenu
        menu.addItem(providerItem)

        menu.addItem(toggle("アイコン", on: prefs.showsProviderIcon, action: #selector(toggleShowsIcon)))
        menu.addItem(toggle("グラフ", on: prefs.showsGauge, action: #selector(toggleShowsGauge)))
        menu.addItem(toggle("残り %", on: prefs.showsPercent, action: #selector(toggleShowsPercent)))

        menu.addItem(.separator())
        menu.addItem(sectionHeader("色"))
        menu.addItem(toggle("少ないとき色を付ける", on: prefs.colorsWhenLow, action: #selector(toggleColorsWhenLow)))

        let levelsItem = NSMenuItem(title: "色を付ける目安", action: nil, keyEquivalent: "")
        let levelsMenu = NSMenu()
        levelsMenu.autoenablesItems = false
        for (index, levels) in Preferences.Levels.presets.enumerated() {
            levelsMenu.addItem(choice(levels.label, represented: index, checked: prefs.levels == levels,
                                      action: #selector(selectLevel(_:))))
        }
        levelsItem.submenu = levelsMenu
        menu.addItem(levelsItem)

        let forecast = toggle("枯渇しそうでも色を付ける", on: prefs.colorsOnForecast,
                              action: #selector(toggleColorsOnForecast))
        forecast.isEnabled = prefs.colorsWhenLow
        menu.addItem(forecast)

        menu.addItem(.separator())
        menu.addItem(toggle("ログイン時に起動", on: prefs.launchesAtLogin, action: #selector(toggleLaunchAtLogin)))
        menu.addItem(actionItem("T3 Code を開く", #selector(openT3Pressed)))
        menu.addItem(actionItem("再接続", #selector(reconnectPressed)))
        menu.addItem(.separator())
        menu.addItem(actionItem("T3Bar を終了", #selector(quitPressed)))
        return menu
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    private func toggle(_ title: String, on: Bool, action: Selector) -> NSMenuItem {
        let item = actionItem(title, action)
        item.state = on ? .on : .off
        return item
    }

    private func choice(_ title: String, represented: Any?, checked: Bool, action: Selector) -> NSMenuItem {
        let item = actionItem(title, action)
        item.representedObject = represented
        item.state = checked ? .on : .off
        return item
    }

    // MARK: - Actions

    @objc private func selectProvider(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        prefs.menuBarProvider = value
    }

    @objc private func selectLevel(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int,
              Preferences.Levels.presets.indices.contains(index) else { return }
        prefs.levels = Preferences.Levels.presets[index]
    }

    @objc private func toggleShowsIcon() { prefs.showsProviderIcon.toggle() }
    @objc private func toggleShowsGauge() { prefs.showsGauge.toggle() }
    @objc private func toggleShowsPercent() { prefs.showsPercent.toggle() }
    @objc private func toggleColorsWhenLow() { prefs.colorsWhenLow.toggle() }
    @objc private func toggleColorsOnForecast() { prefs.colorsOnForecast.toggle() }
    @objc private func toggleLaunchAtLogin() { prefs.setLaunchesAtLogin(!prefs.launchesAtLogin) }
    @objc private func openT3Pressed() {
        // Opening T3 closes the popover, which releases this controller.
        withExtendedLifetime(self) { openT3() }
    }
    @objc private func reconnectPressed() { store.reconnect() }
    @objc private func resetTokenPressed() { store.reconnect(resetToken: true) }
    @objc private func quitPressed() { quit() }
}

extension UsageStore.Connection {
    var bannerText: String {
        switch self {
        case .live, .connecting: "接続中… 最後に受け取った値を表示しています"
        case .serverDown: "T3 Code 停止中・最後に受け取った値を表示しています"
        case .authFailed: "認証エラー・最後に受け取った値を表示しています"
        case .incompatible: "未対応の T3 Code・最後に受け取った値を表示しています"
        case .failed: "接続が切れました・最後に受け取った値を表示しています"
        }
    }
}
