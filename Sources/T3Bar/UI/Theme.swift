import AppKit
import os

/// Thread-safe mirror of the system's increase-contrast setting. `NSColor`
/// may resolve a dynamic provider on any thread, so that path reads this lock
/// instead of touching `NSWorkspace` off the main thread.
private enum HighContrastSetting {
    static let cache = OSAllocatedUnfairLock(initialState: false)
}

@MainActor
enum Theme {
    /// Set from Preferences; where orange and red begin.
    static var levels = Preferences.Levels.standard

    // MARK: - Increase contrast

    /// The cached `NSWorkspace.accessibilityDisplayShouldIncreaseContrast`.
    /// Internal so tests can inject a value and restore it afterwards.
    static var highContrastEnabled: Bool {
        get { HighContrastSetting.cache.withLock { $0 } }
        set { HighContrastSetting.cache.withLock { $0 = newValue } }
    }

    private static var highContrastObserver: NSObjectProtocol?

    /// Reads the system setting on the main thread and keeps the cache current.
    /// Safe to call more than once; the observer lives for the process.
    static func startTrackingHighContrast() {
        guard highContrastObserver == nil else { return }
        refreshHighContrast()
        highContrastObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                Theme.refreshHighContrast()
            }
        }
    }

    /// Re-reads the system setting synchronously, so a redraw requested from
    /// the same notification already sees the new value.
    static func refreshHighContrast() {
        highContrastEnabled = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// The colors T3 Code uses for each provider on its Limits page.
    private static let driverHex: [String: String] = [
        "claudeAgent": "#D97757",
        "cursor": "#8B8B8B",
        "opencode": "#5B9BBD",
        "antigravity": "#8C7BD1",
        "pi": "#4D9F8A",
        "muse": "#0866FF",
    ]

    /// A grey that follows light and dark mode, resolved when it is drawn.
    private static func ink(_ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            (appearance.isDark ? NSColor.white : NSColor.black).withAlphaComponent(alpha)
        }
    }

    static func color(for group: DriverGroup) -> NSColor {
        // Codex is black and white; follow the appearance instead of a fixed grey.
        if group.accentHex == nil {
            if group.driver == "codex" { return ink(0.62) }
            if group.driver == "grok" { return ink(0.45) }
        }
        if let hex = group.accentHex ?? driverHex[group.driver], let c = NSColor(hex: hex) { return c }
        var hash: Int32 = 0
        for unit in group.driver.utf16 { hash = hash &* 31 &+ Int32(unit) }
        return NSColor(hue: Double(abs(Int(hash)) % 360) / 360, saturation: 0.5, brightness: 0.75, alpha: 1)
    }

    /// Secondary text the canvas draws itself. `secondaryLabelColor` goes muddy
    /// on the translucent card once `NSLayoutManager` draws it, so the canvas
    /// uses these brighter, contrast-checked greys instead.
    static let canvasSecondaryText = dynamic(.secondary)

    /// Faint captions and icons the canvas draws: `平均`, reset countdowns and
    /// their ↻, staleness, and the zero-percent help.
    static let canvasTertiaryText = dynamic(.tertiary)

    /// The red for a spent window's note, independent of the warning levels.
    static let canvasCriticalText = dynamic(.critical)

    /// The inks the canvas may draw, with their light/dark and high-contrast
    /// variants. Exposed so the high-contrast pair can be checked without
    /// changing the system setting: recent macOS folds those appearance names
    /// into the base ones.
    enum CanvasInk { case secondary, tertiary, critical }

    nonisolated static func canvasColor(_ ink: CanvasInk, dark: Bool, highContrast: Bool) -> NSColor {
        let palette: (light: String, lightHigh: String, dark: String, darkHigh: String) = switch ink {
        case .secondary: ("#454545", "#262626", "#D0D0D0", "#E6E6E6")
        case .tertiary: ("#595959", "#383838", "#AEAEAE", "#CCCCCC")
        case .critical: ("#C62828", "#8E1B1B", "#FF7B72", "#FF9A93")
        }
        let hex = dark
            ? (highContrast ? palette.darkHigh : palette.dark)
            : (highContrast ? palette.lightHigh : palette.light)
        return NSColor(hex: hex) ?? .labelColor
    }

    /// A colour that follows light/dark and increase-contrast. The appearance's
    /// own high-contrast name collapses into `.aqua`/`.darkAqua` on macOS 27,
    /// so the cached system setting is consulted as well. The provider runs on
    /// whatever thread resolves the colour, so it reads only the appearance and
    /// the lock — never `NSWorkspace`.
    private static func dynamic(_ ink: CanvasInk) -> NSColor {
        NSColor(name: nil) { appearance in
            canvasColor(ink, dark: appearance.isDark,
                        highContrast: appearance.isHighContrast
                            || HighContrastSetting.cache.withLock { $0 })
        }
    }

    /// Bars and numbers turn warm as a limit runs low.
    static func level(_ remaining: Int, base: NSColor) -> NSColor {
        alert(remaining) ?? base
    }

    static func levelText(_ remaining: Int) -> NSColor {
        alert(remaining) ?? .labelColor
    }

    /// Red at the critical level, orange at the warning level, nothing above.
    static func alert(_ remaining: Int) -> NSColor? {
        if remaining <= levels.critical { return .systemRed }
        if remaining <= levels.warn { return .systemOrange }
        return nil
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }
}

extension NSAppearance {
    /// True for dark mode, including the high-contrast variants.
    var isDark: Bool {
        switch bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua: true
        default: false
        }
    }

    /// True when the appearance itself is one of the accessibility variants.
    /// macOS 27 folds those names into the base ones, so `Theme` also consults
    /// the cached system setting.
    var isHighContrast: Bool {
        let name = name.rawValue.lowercased()
        return name.contains("accessibility") || name.contains("highcontrast")
    }
}

enum Format {
    /// "2d 4h", "3h 10m", "12m" — the same shape T3 Code uses.
    static func countdown(to date: Date, now: Date) -> String {
        let s = max(0, date.timeIntervalSince(now))
        if s < 60 { return "まもなく" }
        let d = Int(s) / 86_400, h = Int(s) % 86_400 / 3_600, m = Int(s) % 3_600 / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private static let todayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "今日 H:mm"
        return f
    }()

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d (E) H:mm"
        return f
    }()

    /// "今日 19:30" or "11/24 (火) 9:00".
    static func moment(_ date: Date) -> String {
        (Calendar.current.isDateInToday(date) ? todayFormat : dayFormat).string(from: date)
    }

    static func resetMoment(_ date: Date) -> String { "\(moment(date)) にリセット" }

    /// "32分前", "3時間前", "2日前".
    static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 3_600 { return "\(Int(s / 60))分前" }
        if s < 86_400 { return "\(Int(s / 3_600))時間前" }
        return "\(Int(s / 86_400))日前"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
