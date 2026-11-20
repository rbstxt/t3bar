import Foundation
import ServiceManagement

/// The handful of choices T3Bar offers, stored in UserDefaults.
@MainActor
final class Preferences {
    static let automatic = "auto"

    /// Remaining-percent levels that turn numbers orange (warn) and red (critical).
    struct Levels: Hashable {
        let warn: Int
        let critical: Int

        static let presets = [Levels(warn: 50, critical: 20), Levels(warn: 25, critical: 10), Levels(warn: 15, critical: 5)]
        static let standard = presets[1]

        var label: String { "残り \(warn)%・\(critical)%" }
    }

    private let observers = Observers()
    private let defaults = UserDefaults.standard

    /// `auto` follows whichever limit is closest to running out; otherwise a provider driver.
    var menuBarProvider: String {
        didSet {
            defaults.set(menuBarProvider, forKey: "menuBarProvider")
            if oldValue != menuBarProvider { observers.notify() }
        }
    }

    /// Show the provider's logo in the menu bar, so "auto" says which provider it follows.
    var showsProviderIcon: Bool {
        didSet {
            defaults.set(showsProviderIcon, forKey: "showsProviderIcon")
            if oldValue != showsProviderIcon { observers.notify() }
        }
    }

    /// Show the two small gauges (first two windows) in the menu bar.
    var showsGauge: Bool {
        didSet {
            defaults.set(showsGauge, forKey: "showsGauge")
            if oldValue != showsGauge { observers.notify() }
        }
    }

    var showsPercent: Bool {
        didSet {
            defaults.set(showsPercent, forKey: "showsPercent")
            if oldValue != showsPercent { observers.notify() }
        }
    }

    /// Tint the menu bar number when a limit runs low.
    var colorsWhenLow: Bool {
        didSet {
            defaults.set(colorsWhenLow, forKey: "colorsWhenLow")
            if oldValue != colorsWhenLow { observers.notify() }
        }
    }

    /// Also tint it when the shown provider is on course to run out before a reset.
    var colorsOnForecast: Bool {
        didSet {
            defaults.set(colorsOnForecast, forKey: "colorsOnForecast")
            if oldValue != colorsOnForecast { observers.notify() }
        }
    }

    /// Where orange and red begin, in the menu bar and the popover alike.
    var levels: Levels {
        didSet {
            defaults.set(levels.warn, forKey: "warnLevel")
            Theme.levels = levels
            if oldValue != levels { observers.notify() }
        }
    }

    private(set) var launchesAtLogin: Bool {
        didSet { if oldValue != launchesAtLogin { observers.notify() } }
    }

    init() {
        menuBarProvider = defaults.string(forKey: "menuBarProvider") ?? Self.automatic
        showsProviderIcon = defaults.object(forKey: "showsProviderIcon") as? Bool ?? true
        showsGauge = defaults.object(forKey: "showsGauge") as? Bool ?? true
        showsPercent = defaults.object(forKey: "showsPercent") as? Bool ?? true
        colorsWhenLow = defaults.object(forKey: "colorsWhenLow") as? Bool ?? true
        colorsOnForecast = defaults.object(forKey: "colorsOnForecast") as? Bool ?? false
        let warn = defaults.object(forKey: "warnLevel") as? Int
        levels = Levels.presets.first { $0.warn == warn } ?? .standard
        launchesAtLogin = SMAppService.mainApp.status == .enabled
        Theme.levels = levels
    }

    func observe(_ handler: @escaping () -> Void) -> ObserverToken {
        observers.add(handler)
    }

    /// Test seam: how many observers are currently attached.
    var observerCount: Int { observers.count }

    func setLaunchesAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("T3Bar: login item change failed: \(error.localizedDescription)")
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }
}
