import AppKit
import SwiftUI

@MainActor
enum Theme {
    /// Set from Preferences; where orange and red begin.
    static var levels = Preferences.Levels.standard

    /// The colors T3 Code uses for each provider on its Limits page.
    private static let driverHex: [String: String] = [
        "claudeAgent": "#D97757",
        "cursor": "#8B8B8B",
        "opencode": "#5B9BBD",
        "antigravity": "#8C7BD1",
        "pi": "#4D9F8A",
        "muse": "#0866FF",
    ]

    static func color(for group: DriverGroup) -> Color {
        // Codex is black and white; follow the appearance instead of a fixed grey.
        if group.accentHex == nil {
            if group.driver == "codex" { return Color.primary.opacity(0.62) }
            if group.driver == "grok" { return Color.primary.opacity(0.45) }
        }
        if let hex = group.accentHex ?? driverHex[group.driver], let c = Color(hex: hex) { return c }
        var hash: Int32 = 0
        for unit in group.driver.utf16 { hash = hash &* 31 &+ Int32(unit) }
        return Color(hue: Double(abs(Int(hash)) % 360) / 360, saturation: 0.5, brightness: 0.75)
    }

    /// Bars and numbers turn warm as a limit runs low.
    static func level(_ remaining: Int, base: Color) -> Color {
        alert(remaining).map { Color(nsColor: $0) } ?? base
    }

    static func levelText(_ remaining: Int) -> Color {
        alert(remaining).map { Color(nsColor: $0) } ?? .primary
    }

    /// Red at the critical level, orange at the warning level, nothing above.
    static func alert(_ remaining: Int) -> NSColor? {
        if remaining <= levels.critical { return .systemRed }
        if remaining <= levels.warn { return .systemOrange }
        return nil
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
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
