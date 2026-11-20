import Combine
import Foundation
import ServiceManagement

/// The handful of choices T3Bar offers, stored in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    static let automatic = "auto"

    /// Remaining-percent levels that turn numbers orange (warn) and red (critical).
    struct Levels: Hashable {
        let warn: Int
        let critical: Int

        static let presets = [Levels(warn: 50, critical: 20), Levels(warn: 25, critical: 10), Levels(warn: 15, critical: 5)]
        static let standard = presets[1]

        var label: String { "残り \(warn)%・\(critical)%" }
    }

    /// `auto` follows whichever limit is closest to running out; otherwise a provider driver.
    @Published var menuBarProvider: String {
        didSet { defaults.set(menuBarProvider, forKey: "menuBarProvider") }
    }

    /// Show the provider's logo in the menu bar, so "auto" says which provider it follows.
    @Published var showsProviderIcon: Bool {
        didSet { defaults.set(showsProviderIcon, forKey: "showsProviderIcon") }
    }

    /// Show the two small gauges (first two windows) in the menu bar.
    @Published var showsGauge: Bool {
        didSet { defaults.set(showsGauge, forKey: "showsGauge") }
    }

    @Published var showsPercent: Bool {
        didSet { defaults.set(showsPercent, forKey: "showsPercent") }
    }

    /// Tint the menu bar number when a limit runs low.
    @Published var colorsWhenLow: Bool {
        didSet { defaults.set(colorsWhenLow, forKey: "colorsWhenLow") }
    }

    /// Also tint it when the shown provider is on course to run out before a reset.
    @Published var colorsOnForecast: Bool {
        didSet { defaults.set(colorsOnForecast, forKey: "colorsOnForecast") }
    }

    /// Where orange and red begin, in the menu bar and the popover alike.
    @Published var levels: Levels {
        didSet {
            defaults.set(levels.warn, forKey: "warnLevel")
            Theme.levels = levels
        }
    }

    @Published private(set) var launchesAtLogin: Bool

    private let defaults = UserDefaults.standard

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

    func setLaunchesAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("T3Bar: login item change failed: \(error.localizedDescription)")
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }
}
