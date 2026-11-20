import XCTest
@testable import T3Bar

final class LightweightUpdateTests: XCTestCase {
    // MARK: Observer tokens

    @MainActor
    func testObserversNotifyEverySubscriberUntilCancelled() {
        let hub = Observers()
        var first = 0
        var second = 0
        let firstToken = hub.add { first += 1 }
        var secondToken: ObserverToken? = hub.add { second += 1 }
        XCTAssertEqual(hub.count, 2)

        hub.notify()
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1)

        secondToken?.cancel()
        secondToken = nil
        XCTAssertEqual(hub.count, 1)
        hub.notify()
        XCTAssertEqual(first, 2)
        XCTAssertEqual(second, 1, "a cancelled observer hears nothing")

        firstToken.cancel()
        hub.notify()
        XCTAssertEqual(first, 2)
        XCTAssertEqual(hub.count, 0)
    }

    @MainActor
    func testObserverTokenRemovesItselfWhenReleased() {
        let hub = Observers()
        var calls = 0
        var token: ObserverToken? = hub.add { calls += 1 }
        XCTAssertNotNil(token)
        token = nil
        hub.notify()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(hub.count, 0)
    }

    @MainActor
    func testObserverMayUnregisterWhileBeingNotified() {
        let hub = Observers()
        var calls = 0
        var token: ObserverToken?
        token = hub.add {
            calls += 1
            token?.cancel()
            token = nil
        }
        hub.notify()
        hub.notify()
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testObserversNotifyInRegistrationOrder() {
        let hub = Observers()
        var order: [Int] = []
        let first = hub.add { order.append(1) }
        let second = hub.add { order.append(2) }
        let third = hub.add { order.append(3) }

        hub.notify()
        XCTAssertEqual(order, [1, 2, 3], "handlers run in the order they were added")

        second.cancel()
        order.removeAll()
        hub.notify()
        XCTAssertEqual(order, [1, 3])
        XCTAssertEqual(hub.count, 2)
        first.cancel()
        third.cancel()
    }

    @MainActor
    func testObserverAddedDuringNotificationWaitsForTheNextPass() {
        let hub = Observers()
        var order: [Int] = []
        var extra: ObserverToken?
        var added = false
        let token = hub.add {
            order.append(1)
            if !added {
                added = true
                extra = hub.add { order.append(9) }
            }
        }
        hub.notify()
        XCTAssertEqual(order, [1], "the new observer does not hear the current pass")
        XCTAssertEqual(hub.count, 2)
        XCTAssertNotNil(extra)
        hub.notify()
        XCTAssertEqual(order, [1, 1, 9])
        token.cancel()
    }

    // MARK: Preferences

    private static let preferenceKeys = ["menuBarProvider", "showsProviderIcon", "showsGauge",
                                         "showsPercent", "colorsWhenLow", "colorsOnForecast", "warnLevel"]

    @MainActor
    private func withSavedPreferences(_ body: (Preferences) throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let saved = Self.preferenceKeys.map { ($0, defaults.object(forKey: $0)) }
        let savedLevels = Theme.levels
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            Theme.levels = savedLevels
        }
        try body(Preferences())
    }

    @MainActor
    func testPreferencesNotifyAndPersistEachChange() throws {
        let defaults = UserDefaults.standard
        let savedLevels = Theme.levels
        let saved = Self.preferenceKeys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            Theme.levels = savedLevels
        }

        let prefs = Preferences()
        var notifications = 0
        let token = prefs.observe { notifications += 1 }

        prefs.showsGauge.toggle()
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(defaults.object(forKey: "showsGauge") as? Bool, prefs.showsGauge)

        let driver = prefs.menuBarProvider == "codex" ? "claudeAgent" : "codex"
        prefs.menuBarProvider = driver
        XCTAssertEqual(notifications, 2)
        XCTAssertEqual(defaults.string(forKey: "menuBarProvider"), driver)

        let preset = try XCTUnwrap(Preferences.Levels.presets.first { $0 != prefs.levels })
        prefs.levels = preset
        XCTAssertEqual(notifications, 3)
        XCTAssertEqual(defaults.integer(forKey: "warnLevel"), preset.warn)
        XCTAssertEqual(Theme.levels, preset)
        XCTAssertEqual(prefs.levels.label, preset.label)

        // Setting the same value again is not a change.
        prefs.levels = preset
        XCTAssertEqual(notifications, 3)

        token.cancel()
        prefs.showsPercent.toggle()
        XCTAssertEqual(notifications, 3)
        XCTAssertEqual(prefs.observerCount, 0)
        Theme.levels = savedLevels
    }

    // MARK: Theme

    @MainActor
    func testHexAndAlertThresholds() throws {
        let orange = try XCTUnwrap(NSColor(hex: "#D97757")?.usingColorSpace(.sRGB))
        XCTAssertEqual(orange.redComponent, 0xD9 / 255.0, accuracy: 0.001)
        XCTAssertEqual(orange.greenComponent, 0x77 / 255.0, accuracy: 0.001)
        XCTAssertEqual(orange.blueComponent, 0x57 / 255.0, accuracy: 0.001)
        XCTAssertNil(NSColor(hex: "#12345"))
        XCTAssertNil(NSColor(hex: "zzzzzz"))

        let saved = Theme.levels
        defer { Theme.levels = saved }
        Theme.levels = Preferences.Levels(warn: 50, critical: 20)
        XCTAssertTrue(Theme.alert(20)?.isEqual(NSColor.systemRed) == true, "critical includes the boundary")
        XCTAssertTrue(Theme.alert(21)?.isEqual(NSColor.systemOrange) == true)
        XCTAssertTrue(Theme.alert(51) == nil)
        XCTAssertTrue(Theme.levelText(10).isEqual(NSColor.systemRed))
        XCTAssertTrue(Theme.levelText(80).isEqual(NSColor.labelColor))
    }

    @MainActor
    func testEveryLevelPresetHasTheSameAlertBoundaries() {
        let saved = Theme.levels
        defer { Theme.levels = saved }
        for preset in Preferences.Levels.presets {
            Theme.levels = preset
            XCTAssertTrue(Theme.alert(preset.critical)?.isEqual(NSColor.systemRed) == true,
                          "\(preset.label): critical is included")
            XCTAssertTrue(Theme.alert(preset.critical + 1)?.isEqual(NSColor.systemOrange) == true,
                          "\(preset.label): just above critical is a warning")
            XCTAssertTrue(Theme.alert(preset.warn)?.isEqual(NSColor.systemOrange) == true,
                          "\(preset.label): warn is included")
            XCTAssertNil(Theme.alert(preset.warn + 1), "\(preset.label): above warn is normal")
        }
    }

    @MainActor
    func testMenuBarToneFollowsThresholdsAndSwitches() {
        let saved = Theme.levels
        defer { Theme.levels = saved }
        Theme.levels = Preferences.Levels(warn: 50, critical: 20)

        XCTAssertEqual(StatusController.tone(remaining: 20, onForecast: false,
                                             colorsWhenLow: true, colorsOnForecast: false), .critical)
        XCTAssertEqual(StatusController.tone(remaining: 21, onForecast: false,
                                             colorsWhenLow: true, colorsOnForecast: false), .warning)
        XCTAssertEqual(StatusController.tone(remaining: 50, onForecast: false,
                                             colorsWhenLow: true, colorsOnForecast: false), .warning)
        XCTAssertEqual(StatusController.tone(remaining: 51, onForecast: false,
                                             colorsWhenLow: true, colorsOnForecast: false), .normal)

        // A forecast warns only when the user asked for it.
        XCTAssertEqual(StatusController.tone(remaining: 80, onForecast: true,
                                             colorsWhenLow: true, colorsOnForecast: true), .warning)
        XCTAssertEqual(StatusController.tone(remaining: 80, onForecast: true,
                                             colorsWhenLow: true, colorsOnForecast: false), .normal)

        // Critical wins over a forecast, and turning the feature off silences everything.
        XCTAssertEqual(StatusController.tone(remaining: 5, onForecast: true,
                                             colorsWhenLow: true, colorsOnForecast: true), .critical)
        XCTAssertEqual(StatusController.tone(remaining: 5, onForecast: true,
                                             colorsWhenLow: false, colorsOnForecast: true), .normal)

        // The preset moves the boundary.
        Theme.levels = Preferences.Levels(warn: 15, critical: 5)
        XCTAssertEqual(StatusController.tone(remaining: 15, onForecast: false,
                                             colorsWhenLow: true, colorsOnForecast: false), .warning)
        XCTAssertEqual(StatusController.tone(remaining: 30, onForecast: false,
                                             colorsWhenLow: true, colorsOnForecast: false), .normal)
    }

    @MainActor
    func testDriverColorsAreStableAndAppearanceFollowing() throws {
        let codex = DriverGroup(driver: "codex", name: "Codex", plan: nil, accentHex: nil,
                                windows: [], hasManyAccounts: false, notice: nil)
        let unknown = DriverGroup(driver: "newtool", name: "New", plan: nil, accentHex: nil,
                                  windows: [], hasManyAccounts: false, notice: nil)
        let claude = DriverGroup(driver: "claudeAgent", name: "Claude", plan: nil, accentHex: nil,
                                 windows: [], hasManyAccounts: false, notice: nil)

        // Codex and Grok are greys that follow the appearance, so they stay dynamic.
        var lightInk: NSColor?
        var darkInk: NSColor?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            lightInk = Theme.color(for: codex).usingColorSpace(.sRGB)
        }
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            darkInk = Theme.color(for: codex).usingColorSpace(.sRGB)
        }
        XCTAssertLessThan(try XCTUnwrap(lightInk?.redComponent), 0.1, "light mode uses near-black ink")
        XCTAssertGreaterThan(try XCTUnwrap(darkInk?.redComponent), 0.9, "dark mode uses near-white ink")
        XCTAssertEqual(lightInk?.alphaComponent ?? 0, 0.62, accuracy: 0.01)
        XCTAssertEqual(darkInk?.alphaComponent ?? 0, 0.62, accuracy: 0.01)
        // Unknown drivers get a stable hue from their name.
        XCTAssertTrue(Theme.color(for: unknown).isEqual(Theme.color(for: unknown)))
        // Claude uses T3 Code's orange.
        XCTAssertTrue(Theme.color(for: claude).isEqual(NSColor(hex: "#D97757")))
    }

    // MARK: Connection text

    @MainActor
    func testConnectionBannerTextCoversEveryState() {
        XCTAssertEqual(UsageStore.Connection.live.bannerText,
                       "接続中… 最後に受け取った値を表示しています")
        XCTAssertEqual(UsageStore.Connection.connecting.bannerText,
                       "接続中… 最後に受け取った値を表示しています")
        XCTAssertEqual(UsageStore.Connection.serverDown.bannerText,
                       "T3 Code 停止中・最後に受け取った値を表示しています")
        XCTAssertEqual(UsageStore.Connection.authFailed("x").bannerText,
                       "認証エラー・最後に受け取った値を表示しています")
        XCTAssertEqual(UsageStore.Connection.incompatible.bannerText,
                       "未対応の T3 Code・最後に受け取った値を表示しています")
        XCTAssertEqual(UsageStore.Connection.failed("x").bannerText,
                       "接続が切れました・最後に受け取った値を表示しています")

        XCTAssertEqual(UsageStore.Connection.statusLabel(.serverDown), "T3 Code が起動していません")
        XCTAssertEqual(UsageStore.Connection.statusLabel(.authFailed("bad")), "認証エラー: bad")
        XCTAssertEqual(UsageStore.Connection.statusLabel(.failed("gone")), "接続エラー: gone")
        XCTAssertEqual(UsageStore.Connection.statusLabel(.incompatible), "未対応の T3 Code バージョン")
    }

    // MARK: Store notifications

    @MainActor
    func testUsageStoreNotifiesOnlyWhenStateChanges() {
        let store = UsageStore()
        var notifications = 0
        let token = store.observe { notifications += 1 }
        XCTAssertEqual(store.observerCount, 1)

        store.apply(.serverDown)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(store.connection, .serverDown)

        store.apply(.serverDown)
        XCTAssertEqual(notifications, 1, "the same state is not a change")

        store.apply(.connected)
        XCTAssertEqual(notifications, 2)

        // .connecting does not override a live connection.
        store.apply(.connecting)
        XCTAssertEqual(notifications, 2)
        XCTAssertEqual(store.connection, .live)

        token.cancel()
        store.apply(.failed("x"))
        XCTAssertEqual(notifications, 2)
        XCTAssertEqual(store.observerCount, 0)
    }

    // MARK: Reconnect backoff

    func testServerDownBackoffDoublesToAMinute() {
        var delay: TimeInterval = 3
        var sequence: [TimeInterval] = []
        for _ in 0..<8 {
            sequence.append(delay)
            delay = T3Client.nextServerDownDelay(delay)
        }
        XCTAssertEqual(sequence, [3, 6, 12, 24, 48, 60, 60, 60])
    }

    func testRetryBackoffLaddersAndReset() {
        var backoff = RetryBackoff()

        var serverDown: [TimeInterval] = []
        for _ in 0..<8 { serverDown.append(backoff.delayForServerDown()) }
        XCTAssertEqual(serverDown, [3, 6, 12, 24, 48, 60, 60, 60])
        XCTAssertEqual(T3Client.nextServerDownDelay(48), 60)
        XCTAssertEqual(T3Client.nextServerDownDelay(100), 60)

        var general: [TimeInterval] = []
        for _ in 0..<8 { general.append(backoff.delayForFailure(cap: 30)) }
        XCTAssertEqual(general, [1, 2, 4, 8, 16, 30, 30, 30])

        backoff.reset()
        XCTAssertEqual(backoff, RetryBackoff())
        XCTAssertEqual(backoff.general, 1)
        XCTAssertEqual(backoff.serverDown, 3)

        // The general ladder keeps its cap too.
        var auth = RetryBackoff()
        var authDelays: [TimeInterval] = []
        for _ in 0..<9 { authDelays.append(auth.delayForFailure(cap: 120)) }
        XCTAssertEqual(authDelays, [1, 2, 4, 8, 16, 32, 64, 120, 120])
    }

    // MARK: Menu bar diffing

    func testMenuBarSnapshotEqualityTracksOnlyVisibleInputs() {
        let base = MenuBarItemSnapshot(
            image: .init(logoDriver: "claudeAgent", bars: [42, 80], gauges: true),
            title: " 42%",
            tone: .warning,
            isDisabled: false,
            accessibilityLabel: "Claude Session 残り 42%",
            tooltip: "Claude\nSession 42%")

        XCTAssertEqual(base, base)

        var tooltipOnly = base
        tooltipOnly.tooltip = "Claude\nSession 41%"
        XCTAssertNotEqual(base, tooltipOnly, "countdown text is part of the comparison")
        XCTAssertEqual(base.image, tooltipOnly.image, "the icon need not be redrawn")

        var bars = base
        bars.image?.bars = [42, 81]
        XCTAssertNotEqual(base.image, bars.image)

        var logo = base
        logo.image?.logoDriver = nil
        XCTAssertNotEqual(base.image, logo.image)

        var tone = base
        tone.tone = .critical
        XCTAssertNotEqual(base, tone)
    }

    // MARK: Popover controller

    @MainActor
    private func makeGroup(now: Date, remaining: Int = 42) -> DriverGroup {
        let badge = AccountBadge(key: "hana", name: "hana@example", initials: "HE", hue: 0.2)
        return DriverGroup(
            driver: "codex", name: "Codex", plan: "Plus", accentHex: nil,
            windows: [WindowGroup(id: "session", kind: .session, label: "Session",
                                  remainingPercent: remaining, pace: .onTrack,
                                  members: [MemberBar(account: badge, remainingPercent: remaining,
                                                      expectedRemaining: 0.5,
                                                      resetsAt: now.addingTimeInterval(3600),
                                                      emptiesAt: nil)])],
            hasManyAccounts: false, notice: nil)
    }

    @MainActor
    func testEmptyStateLaysOutForEveryConnection() {
        for connection in [UsageStore.Connection.connecting, .live, .serverDown,
                           .authFailed("bad token"), .incompatible, .failed("gone")] {
            let store = UsageStore(groups: [], connection: connection)
            let controller = PopoverViewController(store: store, prefs: Preferences(),
                                                   openT3: {}, quit: {})
            controller.loadViewIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(controller.preferredContentSize.height, 0)
            assertNoAmbiguousLayout(controller.view)
        }
    }

    @MainActor
    func testPopoverStartsAndStopsItsFeeds() {
        let store = UsageStore(groups: [makeGroup(now: Date())], connection: .live)
        let prefs = Preferences()
        let storeObservers = store.observerCount
        let prefsObservers = prefs.observerCount

        let controller = PopoverViewController(store: store, prefs: prefs, openT3: {}, quit: {})
        controller.loadViewIfNeeded()
        XCTAssertFalse(controller.isUpdating, "nothing runs until the popover opens")

        controller.startUpdates()
        XCTAssertTrue(controller.isUpdating)
        XCTAssertTrue(controller.hasUpdateTimer)
        XCTAssertTrue(controller.isObservingHighContrast)
        XCTAssertEqual(controller.observerCount, 2)
        XCTAssertEqual(store.observerCount, storeObservers + 1)
        XCTAssertEqual(prefs.observerCount, prefsObservers + 1)

        controller.stopUpdates()
        XCTAssertFalse(controller.isUpdating)
        XCTAssertFalse(controller.hasUpdateTimer)
        XCTAssertFalse(controller.isObservingHighContrast)
        XCTAssertEqual(controller.observerCount, 0)
        XCTAssertEqual(store.observerCount, storeObservers)
        XCTAssertEqual(prefs.observerCount, prefsObservers)

        // Idempotent, because the delegate and viewDidDisappear both call it.
        controller.stopUpdates()
        XCTAssertEqual(controller.observerCount, 0)
        XCTAssertFalse(controller.isObservingHighContrast)

        // The lifecycle path tears down as well.
        controller.startUpdates()
        controller.viewDidDisappear()
        XCTAssertFalse(controller.isUpdating)
        XCTAssertFalse(controller.hasUpdateTimer)
        XCTAssertEqual(store.observerCount, storeObservers)
    }

    @MainActor
    func testSettingsMenuReflectsAndUpdatesPreferences() throws {
        try withSavedPreferences { prefs in
            prefs.colorsWhenLow = true
            prefs.colorsOnForecast = true
            let store = UsageStore(groups: [makeGroup(now: Date())], connection: .live)
            let controller = PopoverViewController(store: store, prefs: prefs, openT3: {}, quit: {})
            controller.loadViewIfNeeded()

            var menu = controller.buildSettingsMenu()
            let low = try XCTUnwrap(menu.items.first { $0.title == "少ないとき色を付ける" })
            XCTAssertEqual(low.state, .on)
            XCTAssertEqual(menu.items.first { $0.title == "アイコン" }?.state,
                           prefs.showsProviderIcon ? .on : .off)
            XCTAssertEqual(menu.items.first { $0.title == "グラフ" }?.state,
                           prefs.showsGauge ? .on : .off)
            XCTAssertEqual(menu.items.first { $0.title == "残り %" }?.state,
                           prefs.showsPercent ? .on : .off)
            let forecast = try XCTUnwrap(menu.items.first { $0.title == "枯渇しそうでも色を付ける" })
            XCTAssertEqual(forecast.state, .on)
            XCTAssertTrue(forecast.isEnabled)

            // Entries whose effects are off are disabled.
            prefs.colorsWhenLow = false
            menu = controller.buildSettingsMenu()
            let disabledForecast = try XCTUnwrap(menu.items.first { $0.title == "枯渇しそうでも色を付ける" })
            XCTAssertFalse(disabledForecast.isEnabled,
                           "the forecast switch is meaningless while low-limit colors are off")

            // The check mark follows the selected level preset.
            let levelsItem = try XCTUnwrap(menu.items.first { $0.title == "色を付ける目安" })
            let levels = try XCTUnwrap(levelsItem.submenu)
            XCTAssertEqual(levels.items.count, Preferences.Levels.presets.count)
            for (index, item) in levels.items.enumerated() {
                XCTAssertEqual(item.state,
                               Preferences.Levels.presets[index] == prefs.levels ? .on : .off)
            }

            // Selecting an item writes through to Preferences.
            let targetPreset = try XCTUnwrap(Preferences.Levels.presets.first { $0 != prefs.levels })
            let targetIndex = try XCTUnwrap(Preferences.Levels.presets.firstIndex(of: targetPreset))
            levels.performActionForItem(at: targetIndex)
            XCTAssertEqual(prefs.levels, targetPreset)
            XCTAssertEqual(Theme.levels, targetPreset)

            // Provider choices use the shown provider list.
            let providerItem = try XCTUnwrap(menu.items.first { $0.title == "表示するプロバイダー" })
            let providers = try XCTUnwrap(providerItem.submenu)
            let auto = try XCTUnwrap(providers.items.first { $0.title.contains("自動") })
            XCTAssertEqual(auto.state, prefs.menuBarProvider == Preferences.automatic ? .on : .off)
            let codex = try XCTUnwrap(providers.items.first { $0.title == "Codex" })
            providers.performActionForItem(at: providers.index(of: codex))
            XCTAssertEqual(prefs.menuBarProvider, "codex")

            // Toggles run through the menu's target/action wiring.
            let gaugeItem = try XCTUnwrap(menu.items.first { $0.title == "グラフ" })
            let before = prefs.showsGauge
            menu.performActionForItem(at: menu.index(of: gaugeItem))
            XCTAssertEqual(prefs.showsGauge, !before)
        }
    }

    // MARK: Popover list canvas

    @MainActor
    private func makeCanvasGroup(now: Date) -> DriverGroup {
        let hana = AccountBadge(key: "hana", name: "hana@example", initials: "HE", hue: 0.2)
        let taro = AccountBadge(key: "taro", name: "taro@example", initials: "TE", hue: 0.6)
        let member = { (badge: AccountBadge, remaining: Int) -> MemberBar in
            MemberBar(account: badge, remainingPercent: remaining, expectedRemaining: 0.7,
                      resetsAt: now.addingTimeInterval(3600), emptiesAt: now.addingTimeInterval(1800))
        }
        return DriverGroup(
            driver: "codex", name: "Codex", plan: "Plus", accentHex: nil,
            windows: [
                WindowGroup(id: "primary", kind: .session, label: "Session", remainingPercent: 94,
                            pace: .ahead, members: [member(hana, 94)]),
                WindowGroup(id: "weekly", kind: .weekly, label: "Weekly", remainingPercent: 84,
                            pace: .onTrack, members: [member(hana, 99), member(taro, 69)]),
            ],
            hasManyAccounts: true,
            notice: nil,
            credits: [AccountCredits(account: taro, count: 1, expiresAt: now.addingTimeInterval(86_400))],
            checkedAt: now.addingTimeInterval(-1_200))
    }

    @MainActor
    func testListCanvasMeasuresAndDrawsAProvider() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let group = makeCanvasGroup(now: now)

        let prefs = Preferences()
        let canvas = PopoverListCanvasView(frame: NSRect(x: 0, y: 0, width: 340, height: 1))
        canvas.configure(groups: [group], prefs: prefs, now: now)
        XCTAssertGreaterThan(canvas.requiredHeight, 120)
        XCTAssertEqual(canvas.requiredHeight, canvas.frame.height, accuracy: 0.01)

        // The drawing path itself must not throw or return an empty image.
        let size = NSSize(width: 340, height: canvas.requiredHeight)
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        canvas.frame = NSRect(origin: .zero, size: size)
        canvas.draw(canvas.bounds)
        image.unlockFocus()
        let tiff = image.tiffRepresentation
        XCTAssertNotNil(tiff)
        XCTAssertGreaterThan(tiff?.count ?? 0, 1000)

        // Tooltip hotspots are hit-tested over the canvas.
        let tips = tooltips(in: canvas)
        XCTAssertTrue(tips.contains("Session"))
        XCTAssertTrue(tips.contains { $0.contains("残り") })
        XCTAssertTrue(tips.contains { $0.contains("上限を今すぐリセットできる券") })
        // M7: the depletion countdown must come from the configured `now`, not Date().
        XCTAssertTrue(tips.contains { $0.contains("30m で枯渇") },
                      "projected depletion is rendered from the passed-in now")
    }

    @MainActor
    func testListCanvasEmptyGroupsAndZeroPercent() {
        let prefs = Preferences()
        let canvas = PopoverListCanvasView(frame: NSRect(x: 0, y: 0, width: 340, height: 1))
        canvas.configure(groups: [], prefs: prefs, now: Date())
        XCTAssertEqual(canvas.requiredHeight, 1, accuracy: 0.001)
        XCTAssertEqual(canvas.accessibilityChildren()?.count, 0,
                       "without a window there are no screen frames to report")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hana = AccountBadge(key: "hana", name: "hana@example", initials: "HE", hue: 0.2)
        let solo = DriverGroup(
            driver: "claudeAgent", name: "Claude", plan: "Pro", accentHex: nil,
            windows: [
                WindowGroup(id: "spent", kind: .session, label: "Session", remainingPercent: 0,
                            pace: .ahead,
                            members: [MemberBar(account: hana, remainingPercent: 0,
                                                expectedRemaining: nil,
                                                resetsAt: now.addingTimeInterval(3600),
                                                emptiesAt: nil)]),
                WindowGroup(id: "draining", kind: .weekly, label: "Weekly", remainingPercent: 0,
                            pace: .ahead,
                            members: [MemberBar(account: hana, remainingPercent: 0,
                                                expectedRemaining: 0.2,
                                                resetsAt: now.addingTimeInterval(3600),
                                                emptiesAt: now.addingTimeInterval(1800))]),
            ],
            hasManyAccounts: false, notice: nil)

        canvas.configure(groups: [solo], prefs: prefs, now: now)
        XCTAssertGreaterThan(canvas.requiredHeight, 20)

        // Zero percent still draws (no fill bar) and keeps its help text.
        let size = NSSize(width: 340, height: canvas.requiredHeight)
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        canvas.frame = NSRect(origin: .zero, size: size)
        canvas.draw(canvas.bounds)
        image.unlockFocus()
        XCTAssertNotNil(image.tiffRepresentation)

        let tips = tooltips(in: canvas)
        XCTAssertTrue(tips.contains { $0.contains("残り 0%") })
        XCTAssertTrue(tips.contains { $0.contains("にリセット（あと 1h 0m）") },
                      "a spent window shows when it comes back")
        XCTAssertTrue(tips.contains { $0.contains("上限に到達") })
        XCTAssertFalse(tips.contains { $0.contains("速め") },
                       "a rounded 0% must never read as a pace")
        XCTAssertFalse(tips.contains { $0.contains("30m で枯渇") },
                       "the reset takes priority over a stale forecast")
    }

    @MainActor
    func testListCanvasAccessibilityReadsTheImportantBits() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hana = AccountBadge(key: "hana", name: "hana@example", initials: "HE", hue: 0.2)

        let noticeGroup = DriverGroup(driver: "muse", name: "Muse Code", plan: nil, accentHex: nil,
                                      windows: [], hasManyAccounts: false,
                                      notice: "使用量を取得できませんでした")
        let solo = DriverGroup(
            driver: "claudeAgent", name: "Claude", plan: "Pro", accentHex: nil,
            windows: [WindowGroup(id: "spent", kind: .session, label: "Session", remainingPercent: 0,
                                  pace: .ahead,
                                  members: [MemberBar(account: hana, remainingPercent: 0,
                                                      expectedRemaining: nil,
                                                      resetsAt: now.addingTimeInterval(3600),
                                                      emptiesAt: nil)])],
            hasManyAccounts: false, notice: nil)

        let prefs = Preferences()
        let canvas = PopoverListCanvasView(frame: NSRect(x: 0, y: 0, width: 340, height: 1))
        canvas.configure(groups: [makeCanvasGroup(now: now), solo, noticeGroup],
                         prefs: prefs, now: now)

        // With no window, the rects cannot be converted to screen coordinates.
        XCTAssertEqual(canvas.accessibilityChildren()?.count, 0)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340,
                                             height: max(200, canvas.requiredHeight)))
        canvas.frame = NSRect(x: 0, y: 0, width: 340, height: canvas.requiredHeight)
        container.addSubview(canvas)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        defer { window.contentView = nil }
        window.contentView?.layoutSubtreeIfNeeded()

        let elements = try XCTUnwrap(canvas.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertFalse(elements.isEmpty)
        let labels = elements.compactMap { $0.accessibilityLabel() }
        XCTAssertTrue(labels.contains { $0.contains("リセット券 1") }, "banked resets are announced")
        XCTAssertTrue(labels.contains { $0.contains("分前") }, "staleness is announced")
        XCTAssertTrue(labels.contains { $0.contains("平均") }, "pooled averages are announced")
        XCTAssertTrue(labels.contains { $0.contains("1h 0m") }, "reset countdown is announced")
        XCTAssertTrue(labels.contains { $0.contains("で枯渇") }, "depletion forecasts are announced")
        XCTAssertTrue(labels.contains { $0.contains("1h 0mでリセット") },
                      "zero percent announces its reset instead of a pace")
        XCTAssertTrue(labels.contains { $0.contains("残り 0%") }, "zero percent is announced")
        XCTAssertTrue(labels.contains { $0.contains("使用量を取得できませんでした") },
                      "notices are announced")
        XCTAssertTrue(labels.contains { $0.contains("上限に到達") },
                      "spent-limit help is available to VoiceOver")

        // Frames are real screen coordinates, not view-local rects.
        let screenFrames = elements.map { $0.accessibilityFrame() }
        XCTAssertFalse(screenFrames.contains { $0.origin == .zero && $0.size == .zero })
    }

    @MainActor
    private func tooltips(in canvas: PopoverListCanvasView) -> [String] {
        var tips: [String] = []
        for x in stride(from: 20.0, through: 330, by: 6) {
            for y in stride(from: 20.0, through: canvas.requiredHeight - 5, by: 4) {
                let tip = canvas.view(canvas, stringForToolTip: 0,
                                      point: NSPoint(x: x, y: y), userData: nil)
                if !tip.isEmpty { tips.append(tip) }
            }
        }
        return tips
    }

    // MARK: Zero remaining

    @MainActor
    func testDepletionNoteCoversEveryResetCase() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let future = try XCTUnwrap(Depletion.note(remaining: 0,
                                                  reset: now.addingTimeInterval(20 * 60), now: now))
        XCTAssertEqual(future.text, "20mでリセット")
        XCTAssertEqual(future.short, "上限到達・20mでリセット")
        XCTAssertTrue(future.help.contains("にリセット"))
        XCTAssertTrue(future.help.contains("あと 20m"))

        let long = try XCTUnwrap(Depletion.note(remaining: 0,
                                                reset: now.addingTimeInterval(75 * 60), now: now))
        XCTAssertEqual(long.text, "1h 15mでリセット")

        let soon = try XCTUnwrap(Depletion.note(remaining: 0,
                                                reset: now.addingTimeInterval(30), now: now))
        XCTAssertEqual(soon.text, "まもなくリセット")
        XCTAssertEqual(soon.short, "上限到達・まもなくリセット")
        XCTAssertTrue(soon.help.contains("まもなく"))

        let past = try XCTUnwrap(Depletion.note(remaining: 0,
                                                reset: now.addingTimeInterval(-60), now: now))
        XCTAssertEqual(past.text, "上限到達・更新待ち")
        XCTAssertEqual(past.short, "上限到達・更新待ち")
        XCTAssertTrue(past.help.contains("新しい使用量の取得を待っています"))

        let unknown = try XCTUnwrap(Depletion.note(remaining: 0, reset: nil, now: now))
        XCTAssertEqual(unknown.text, "上限到達")
        XCTAssertEqual(unknown.short, "上限到達")
        XCTAssertTrue(unknown.help.contains("報告されていません"))

        // A rounded negative remainder is still a spent window and reads
        // exactly like an exact zero.
        XCTAssertEqual(Depletion.note(remaining: -1, reset: now.addingTimeInterval(20 * 60), now: now),
                       future)
        XCTAssertEqual(Depletion.note(remaining: -1, reset: now.addingTimeInterval(-60), now: now),
                       past)
        XCTAssertEqual(Depletion.note(remaining: -1, reset: nil, now: now), unknown)

        // 1% and up keeps the existing notes.
        XCTAssertNil(Depletion.note(remaining: 1, reset: now.addingTimeInterval(600), now: now))
        XCTAssertNil(Depletion.note(remaining: 80, reset: nil, now: now))
    }

    @MainActor
    func testListCanvasZeroPercentShowsResetInsteadOfPace() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hana = AccountBadge(key: "hana", name: "hana@example", initials: "HE", hue: 0.2)

        func group(remaining: Int) -> DriverGroup {
            DriverGroup(
                driver: "claudeAgent", name: "Claude", plan: "Pro", accentHex: nil,
                windows: [WindowGroup(
                    id: "session", kind: .session, label: "Session",
                    remainingPercent: remaining,
                    pace: remaining == 0 ? .ahead : nil,
                    members: [MemberBar(account: hana, remainingPercent: remaining,
                                        expectedRemaining: nil,
                                        resetsAt: now.addingTimeInterval(20 * 60),
                                        emptiesAt: remaining == 0
                                            ? now.addingTimeInterval(5 * 60) : nil)])],
                hasManyAccounts: false, notice: nil)
        }

        let prefs = Preferences()
        let spent = PopoverListCanvasView(frame: NSRect(x: 0, y: 0, width: 340, height: 1))
        spent.configure(groups: [group(remaining: 0)], prefs: prefs, now: now)

        let size = NSSize(width: 340, height: spent.requiredHeight)
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        spent.frame = NSRect(origin: .zero, size: size)
        spent.draw(spent.bounds)
        image.unlockFocus()
        XCTAssertNotNil(image.tiffRepresentation)

        let tips = tooltips(in: spent)
        XCTAssertTrue(tips.contains { $0.contains("にリセット（あと 20m）") },
                      "0% shows the reset countdown")
        XCTAssertTrue(tips.contains { $0.contains("上限に到達") },
                      "0% explains the spent limit")
        XCTAssertFalse(tips.contains { $0.contains("速め") },
                       "a rounded 0% must never read as a pace")
        XCTAssertFalse(tips.contains { $0.contains("枯渇") },
                       "the reset takes priority over an outdated forecast")

        // 1% keeps the old inline treatment instead of a 0% note, and the note
        // shares the label line so it does not make the row taller.
        let healthy = PopoverListCanvasView(frame: NSRect(x: 0, y: 0, width: 340, height: 1))
        healthy.configure(groups: [group(remaining: 1)], prefs: prefs, now: now)
        XCTAssertFalse(tooltips(in: healthy).contains { $0.contains("上限に到達") })
        XCTAssertEqual(spent.requiredHeight, healthy.requiredHeight, accuracy: 0.01)
    }

    @MainActor
    func testListCanvasZeroPercentForEachAccount() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hana = AccountBadge(key: "hana", name: "hana@example", initials: "HE", hue: 0.2)
        let taro = AccountBadge(key: "taro", name: "taro@example", initials: "TE", hue: 0.6)

        let spentHana = MemberBar(account: hana, remainingPercent: 0, expectedRemaining: 0.4,
                                  resetsAt: now.addingTimeInterval(75 * 60), emptiesAt: nil)
        let spentTaro = MemberBar(account: taro, remainingPercent: 0, expectedRemaining: 0.4,
                                  resetsAt: now.addingTimeInterval(2 * 3600), emptiesAt: nil)
        let window = WindowGroup(id: "weekly", kind: .weekly, label: "Weekly",
                                 remainingPercent: 0, pace: .ahead,
                                 members: [spentHana, spentTaro])
        let group = DriverGroup(driver: "codex", name: "Codex", plan: "Plus", accentHex: nil,
                                windows: [window], hasManyAccounts: true, notice: nil)

        let prefs = Preferences()
        let canvas = PopoverListCanvasView(frame: NSRect(x: 0, y: 0, width: 340, height: 1))
        canvas.configure(groups: [group], prefs: prefs, now: now)

        let tips = tooltips(in: canvas)
        XCTAssertTrue(tips.contains { $0.contains("hana@example: 残り 0%") },
                      "each spent account keeps its name")
        XCTAssertTrue(tips.contains { $0.contains("にリセット（あと 1h 15m）") })
        XCTAssertTrue(tips.contains { $0.contains("にリセット（あと 2h 0m）") })
        XCTAssertFalse(tips.contains { $0.contains("速め") })
        XCTAssertFalse(tips.contains { $0.contains("枯渇") })

        let size = NSSize(width: 340, height: canvas.requiredHeight)
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        canvas.frame = NSRect(origin: .zero, size: size)
        canvas.draw(canvas.bounds)
        image.unlockFocus()
        XCTAssertNotNil(image.tiffRepresentation)

        // Every spent account owns a note line of its own.
        let healthyWindow = WindowGroup(
            id: "weekly", kind: .weekly, label: "Weekly", remainingPercent: 1,
            pace: .onTrack,
            members: [
                MemberBar(account: hana, remainingPercent: 1, expectedRemaining: 0.4,
                          resetsAt: now.addingTimeInterval(75 * 60), emptiesAt: nil),
                MemberBar(account: taro, remainingPercent: 1, expectedRemaining: 0.4,
                          resetsAt: now.addingTimeInterval(2 * 3600), emptiesAt: nil),
            ])
        let healthyGroup = DriverGroup(driver: "codex", name: "Codex", plan: "Plus", accentHex: nil,
                                       windows: [healthyWindow], hasManyAccounts: true, notice: nil)
        let healthy = PopoverListCanvasView(frame: NSRect(x: 0, y: 0, width: 340, height: 1))
        healthy.configure(groups: [healthyGroup], prefs: prefs, now: now)
        XCTAssertEqual(canvas.requiredHeight - healthy.requiredHeight,
                       2 * (CanvasTextMetrics.lineHeight(PopoverStyle.font(size: 10.5,
                                                                          weight: .medium)) + 2),
                       accuracy: 0.01, "both zero notes are measured")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340,
                                             height: max(200, canvas.requiredHeight)))
        canvas.frame = NSRect(x: 0, y: 0, width: 340, height: canvas.requiredHeight)
        container.addSubview(canvas)
        let hostWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        hostWindow.contentView = container
        defer { hostWindow.contentView = nil }
        hostWindow.contentView?.layoutSubtreeIfNeeded()

        let elements = try XCTUnwrap(canvas.accessibilityChildren() as? [NSAccessibilityElement])
        let labels = elements.compactMap { $0.accessibilityLabel() }
        XCTAssertTrue(labels.contains { $0.contains("hana@example 残り 0%") },
                      "the account name is announced with 0%")
        XCTAssertTrue(labels.contains { $0.contains("1h 15mでリセット") },
                      "each account's own reset is announced")
        XCTAssertTrue(labels.contains { $0.contains("taro@example 残り 0%") })
        XCTAssertTrue(labels.contains { $0.contains("2h 0mでリセット") })
    }

    @MainActor
    func testMenuBarTooltipShowsZeroPercentReset() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hana = AccountBadge(key: "hana", name: "hana@example", initials: "HE", hue: 0.2)
        let taro = AccountBadge(key: "taro", name: "taro@example", initials: "TE", hue: 0.6)

        let soloWindow = WindowGroup(
            id: "session", kind: .session, label: "Session", remainingPercent: 0, pace: .ahead,
            members: [MemberBar(account: hana, remainingPercent: 0, expectedRemaining: nil,
                                resetsAt: now.addingTimeInterval(20 * 60),
                                emptiesAt: now.addingTimeInterval(5 * 60))])
        let solo = DriverGroup(driver: "claudeAgent", name: "Claude", plan: "Pro", accentHex: nil,
                               windows: [soloWindow], hasManyAccounts: false, notice: nil)
        let soloLines = StatusController.usageTooltipLines(group: solo, shown: soloWindow, now: now)
        XCTAssertEqual(soloLines.first, "Claude")
        XCTAssertEqual(soloLines.count, 2)
        XCTAssertTrue(soloLines[1].hasPrefix("Session 0%"))
        XCTAssertTrue(soloLines[1].contains("上限到達・20mでリセット"),
                      "the menu bar tooltip says when the spent window returns")
        XCTAssertFalse(soloLines[1].contains("枯渇"))

        let pooledWindow = WindowGroup(
            id: "weekly", kind: .weekly, label: "Weekly", remainingPercent: 0, pace: .ahead,
            members: [
                MemberBar(account: hana, remainingPercent: 0, expectedRemaining: nil,
                          resetsAt: now.addingTimeInterval(20 * 60), emptiesAt: nil),
                MemberBar(account: taro, remainingPercent: 0, expectedRemaining: nil,
                          resetsAt: now.addingTimeInterval(3600), emptiesAt: nil),
            ])
        let pooled = DriverGroup(driver: "codex", name: "Codex", plan: "Plus", accentHex: nil,
                                 windows: [pooledWindow], hasManyAccounts: true, notice: nil)
        let pooledLines = StatusController.usageTooltipLines(group: pooled, shown: pooledWindow, now: now)
        XCTAssertTrue(pooledLines[1].contains("HE 上限到達・20mでリセット"),
                      "a pooled account is prefixed with its initials")
        XCTAssertTrue(pooledLines[1].contains("TE 上限到達・1h 0mでリセット"))
    }

    // MARK: Metrics and appearance

    @MainActor
    func testCanvasLineHeightMatchesTheLayoutManagerInsteadOfCeiledMetrics() {
        let fonts: [(String, NSFont)] = [
            ("9.5", PopoverStyle.font(size: 9.5, weight: .medium)),
            ("10", PopoverStyle.font(size: 10)),
            ("10.5", PopoverStyle.font(size: 10.5, weight: .medium)),
            ("11", PopoverStyle.font(size: 11)),
            ("11.5", PopoverStyle.font(size: 11.5)),
            ("12", PopoverStyle.font(size: 12, weight: .semibold)),
            ("13", PopoverStyle.font(size: 13, weight: .semibold)),
            ("13.5", PopoverStyle.font(size: 13.5, weight: .semibold, rounded: true, monoDigits: true)),
        ]

        for (label, font) in fonts {
            let old = ceil(font.ascender) + ceil(-font.descender) + ceil(font.leading)
            let new = CanvasTextMetrics.lineHeight(font)
            XCTAssertLessThanOrEqual(new, old, "\(label) pt is not inflated")
            XCTAssertGreaterThanOrEqual(new, ceil(font.ascender - font.descender + font.leading) - 1,
                                        "\(label) pt still fits ascent and descent")
            let baseline = CanvasTextMetrics.baselineOffset(font)
            XCTAssertGreaterThan(baseline, 0, "\(label) pt has a baseline")
            XCTAssertLessThanOrEqual(baseline, new, "\(label) pt baseline stays in the line")
            XCTAssertGreaterThanOrEqual(new - baseline, ceil(-font.descender) - 1,
                                        "\(label) pt leaves room for descenders")
        }

        // The separately ceiled metrics were 2 pt too tall at 10.5/11.5 and
        // 1 pt at 13.5; the layout manager's height is what the canvas uses.
        for (size, expectedGain) in [(10.5 as CGFloat, 2 as CGFloat), (11.5, 2), (13.5, 1)] {
            let font = PopoverStyle.font(size: size, weight: .semibold)
            let old = ceil(font.ascender) + ceil(-font.descender) + ceil(font.leading)
            XCTAssertEqual(old - CanvasTextMetrics.lineHeight(font), expectedGain,
                           "\(size) pt lost \(expectedGain) pt")
        }
    }

    @MainActor
    func testCanvasTextColorsFollowAppearanceWithReadableContrast() throws {
        func resolve(_ color: NSColor, _ name: NSAppearance.Name) throws -> NSColor {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.sRGB)
            }
            return try XCTUnwrap(resolved)
        }
        func ink(_ kind: Theme.CanvasInk, dark: Bool, highContrast: Bool) throws -> NSColor {
            try XCTUnwrap(Theme.canvasColor(kind, dark: dark, highContrast: highContrast)
                .usingColorSpace(.sRGB))
        }

        // The dynamic colours resolve in both appearances (contrast is off on
        // this test machine, so these are the normal variants).
        let secondaryLight = try resolve(Theme.canvasSecondaryText, .aqua)
        let secondaryDark = try resolve(Theme.canvasSecondaryText, .darkAqua)
        let tertiaryLight = try resolve(Theme.canvasTertiaryText, .aqua)
        let tertiaryDark = try resolve(Theme.canvasTertiaryText, .darkAqua)

        // High-contrast values are checked through the explicit resolver,
        // because macOS 27 folds the accessibility appearance names into the
        // base ones and cannot be simulated by `NSAppearance(named:)`.
        let secondaryLightHigh = try ink(.secondary, dark: false, highContrast: true)
        let secondaryDarkHigh = try ink(.secondary, dark: true, highContrast: true)
        let tertiaryLightHigh = try ink(.tertiary, dark: false, highContrast: true)
        let tertiaryDarkHigh = try ink(.tertiary, dark: true, highContrast: true)

        // White popover background vs the dark card (a 4.5% white wash on ~#1E1E1E).
        let lightBackground = try XCTUnwrap(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            .usingColorSpace(.sRGB))
        let darkBackground = try XCTUnwrap(NSColor(srgbRed: 0.16, green: 0.16, blue: 0.16, alpha: 1)
            .usingColorSpace(.sRGB))

        XCTAssertGreaterThanOrEqual(contrastRatio(secondaryLight, lightBackground), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(tertiaryLight, lightBackground), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(secondaryDark, darkBackground), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(tertiaryDark, darkBackground), 4.5)

        // Primary > secondary > tertiary in both appearances, so the
        // hierarchy stays readable instead of collapsing into one grey.
        XCTAssertLessThan(relativeLuminance(secondaryLight), relativeLuminance(tertiaryLight))
        XCTAssertGreaterThan(relativeLuminance(secondaryDark), relativeLuminance(tertiaryDark))
        let black = try XCTUnwrap(NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
            .usingColorSpace(.sRGB))
        let white = try XCTUnwrap(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            .usingColorSpace(.sRGB))
        XCTAssertGreaterThan(relativeLuminance(secondaryLight), relativeLuminance(black))
        XCTAssertLessThan(relativeLuminance(secondaryDark), relativeLuminance(white))

        // High contrast pushes text further from its background.
        XCTAssertLessThan(relativeLuminance(secondaryLightHigh), relativeLuminance(secondaryLight))
        XCTAssertLessThan(relativeLuminance(tertiaryLightHigh), relativeLuminance(tertiaryLight))
        XCTAssertGreaterThan(relativeLuminance(secondaryDarkHigh), relativeLuminance(secondaryDark))
        XCTAssertGreaterThan(relativeLuminance(tertiaryDarkHigh), relativeLuminance(tertiaryDark))
        XCTAssertGreaterThanOrEqual(contrastRatio(secondaryLightHigh, lightBackground),
                                    contrastRatio(secondaryLight, lightBackground))
        XCTAssertGreaterThanOrEqual(contrastRatio(tertiaryDarkHigh, darkBackground),
                                    contrastRatio(tertiaryDark, darkBackground))

        // The 0% note keeps a clearly red, readable warning colour.
        let redLight = try resolve(Theme.canvasCriticalText, .aqua)
        let redDark = try resolve(Theme.canvasCriticalText, .darkAqua)
        XCTAssertGreaterThan(redLight.redComponent, redLight.greenComponent)
        XCTAssertGreaterThan(redDark.redComponent, redDark.greenComponent)
        XCTAssertGreaterThanOrEqual(contrastRatio(redLight, lightBackground), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(redDark, darkBackground), 4.5)
        // The warning red does not depend on the configurable warning levels.
        let saved = Theme.levels
        defer { Theme.levels = saved }
        Theme.levels = Preferences.Levels(warn: 0, critical: 0)
        let criticalAgain = try resolve(Theme.canvasCriticalText, .aqua)
        XCTAssertNotEqual(criticalAgain.redComponent,
                          try resolve(Theme.canvasSecondaryText, .aqua).redComponent,
                          accuracy: 0.05)
    }

    @MainActor
    func testCanvasTextColorsUseTheInjectedHighContrastCache() throws {
        let saved = Theme.highContrastEnabled
        defer { Theme.highContrastEnabled = saved }

        func resolve(_ color: NSColor, _ name: NSAppearance.Name) throws -> NSColor {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.sRGB)
            }
            return try XCTUnwrap(resolved)
        }

        // Resolve normally first, so the comparison at the end proves the cache
        // alone changes the result rather than the appearance.
        let normal = try resolve(Theme.canvasSecondaryText, .aqua)
        Theme.highContrastEnabled = true

        let cases: [(ink: Theme.CanvasInk, color: NSColor, name: NSAppearance.Name)] = [
            (.secondary, Theme.canvasSecondaryText, .aqua),
            (.secondary, Theme.canvasSecondaryText, .darkAqua),
            (.tertiary, Theme.canvasTertiaryText, .aqua),
            (.tertiary, Theme.canvasTertiaryText, .darkAqua),
            (.critical, Theme.canvasCriticalText, .aqua),
            (.critical, Theme.canvasCriticalText, .darkAqua),
        ]
        for (ink, color, name) in cases {
            let expected = try XCTUnwrap(Theme.canvasColor(ink, dark: name == .darkAqua, highContrast: true)
                .usingColorSpace(.sRGB))
            let actual = try resolve(color, name)
            let label = "\(ink) in \(name.rawValue)"
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001, label)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001, label)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001, label)
        }

        XCTAssertNotEqual(try resolve(Theme.canvasSecondaryText, .aqua).redComponent,
                          normal.redComponent, accuracy: 0.001,
                          "the cache alone switches to the high-contrast ink")
    }

    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }

    private func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let first = relativeLuminance(a), second = relativeLuminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    @MainActor
    private func assertNoAmbiguousLayout(_ view: NSView, file: StaticString = #filePath,
                                         line: UInt = #line) {
        XCTAssertFalse(view.hasAmbiguousLayout, "ambiguous layout in \(type(of: view))",
                       file: file, line: line)
        for subview in view.subviews {
            assertNoAmbiguousLayout(subview, file: file, line: line)
        }
    }
}
