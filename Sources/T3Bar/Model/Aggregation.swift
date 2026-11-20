import Foundation

// Turns provider statuses and hub accounts into what the popover draws.
// Follows the rules of T3 Code's Limits page (packages/web usageLimits) so the
// numbers match: one entry per account, accounts merged by email or credential,
// windows grouped per provider and averaged by plan weight.

enum Pace: Equatable {
    case ahead, onTrack, under
}

/// What to say about a window whose displayed remainder has reached zero.
/// A rounded 0% is a spent limit, not a pace: it must never fall through to
/// the "速め" note, so the reset countdown takes priority over `emptiesAt`.
enum Depletion {
    struct Note: Equatable {
        /// Card text: "20mでリセット", "まもなくリセット", "上限到達・更新待ち".
        var text: String
        /// One-line menu bar form: "上限到達・20mでリセット".
        var short: String
        /// Hover help, with the absolute reset moment when one is known.
        var help: String
    }

    /// Nil while any remainder is left, so 1% and up keep their existing notes.
    static func note(remaining: Int, reset: Date?, now: Date) -> Note? {
        guard remaining <= 0 else { return nil }
        guard let reset else {
            return Note(text: "上限到達", short: "上限到達",
                        help: "上限に到達。リセット時刻は報告されていません")
        }
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else {
            return Note(text: "上限到達・更新待ち", short: "上限到達・更新待ち",
                        help: "報告されたリセット時刻を過ぎています。新しい使用量の取得を待っています")
        }
        if seconds < 60 {
            return Note(text: "まもなくリセット", short: "上限到達・まもなくリセット",
                        help: "上限に到達。まもなくリセットされます（\(Format.moment(reset))）")
        }
        let countdown = Format.countdown(to: reset, now: now)
        return Note(text: "\(countdown)でリセット", short: "上限到達・\(countdown)でリセット",
                    help: "上限に到達。\(Format.moment(reset)) にリセット（あと \(countdown)）")
    }
}

struct AccountBadge: Equatable {
    var key: String
    var name: String
    var initials: String
    var hue: Double
}

struct MemberBar: Identifiable, Equatable {
    var id: String { account.key }
    var account: AccountBadge
    var remainingPercent: Int
    /// Remaining share a linear pace would leave right now, 0...1.
    var expectedRemaining: Double?
    var resetsAt: Date?
    /// When this limit runs out at the current pace, if that comes before the reset.
    var emptiesAt: Date?
}

struct AccountCredits: Identifiable, Equatable {
    var id: String { account.key }
    var account: AccountBadge
    var count: Int
    var expiresAt: Date?
}

struct WindowGroup: Identifiable, Equatable {
    var id: String
    var kind: WindowKind
    var label: String
    var remainingPercent: Int
    var pace: Pace?
    var members: [MemberBar]

    var nextReset: Date? { members.compactMap(\.resetsAt).min() }
    /// The soonest projected run-out among the accounts in this row.
    var emptiesAt: Date? { members.compactMap(\.emptiesAt).min() }
}

struct DriverGroup: Identifiable, Equatable {
    var id: String { driver }
    var driver: String
    var name: String
    var plan: String?
    var accentHex: String?
    var windows: [WindowGroup]
    var hasManyAccounts: Bool
    var notice: String?
    /// Banked resets, per account that has any.
    var credits: [AccountCredits] = []
    /// The oldest reading among the accounts shown, to flag stale numbers.
    var checkedAt: Date?

    var tightest: WindowGroup? { windows.min { $0.remainingPercent < $1.remainingPercent } }
}

enum Aggregator {
    private struct Entry {
        var key: String
        var driver: String
        var name: String?
        var email: String?
        var plan: String?
        var limits: UsageLimits
    }

    static let defaultNames: [String: String] = [
        "claudeAgent": "Claude", "codex": "Codex", "opencode": "OpenCode", "cursor": "Cursor",
        "grok": "Grok", "antigravity": "Antigravity", "pi": "Pi", "muse": "Muse Code",
    ]

    static func groups(providers: [ProviderStatus], sources: [HubSource], now: Date) -> [DriverGroup] {
        let shown = providers.filter { $0.enabled && $0.installed && $0.status != "disabled" && $0.limits != nil }

        // Identity: the same login reached directly and through a hub is one account.
        var workspaces: [String: Set<String>] = [:]
        func base(_ driver: String, _ email: String?, _ limits: UsageLimits?) -> String? {
            if let email { return "\(driver):\(email.lowercased())" }
            if let fp = limits?.credentialFingerprint { return "\(driver):credential:\(fp)" }
            return nil
        }
        for p in providers where p.enabled {
            if let b = base(p.driver, p.email, p.limits), let ws = p.workspaceId { workspaces[b, default: []].insert(ws) }
        }
        for s in sources {
            for a in s.accounts {
                if let b = base(a.driver, a.email, a.limits), let ws = a.workspaceId { workspaces[b, default: []].insert(ws) }
            }
        }
        func identity(_ driver: String, _ email: String?, _ workspaceId: String?, _ limits: UsageLimits) -> String? {
            guard let b = base(driver, email, limits) else { return nil }
            if let workspaceId { return "\(b):\(workspaceId)" }
            guard let known = workspaces[b] else { return b }
            return known.count == 1 ? "\(b):\(known.first!)" : nil
        }

        var merged: [String: Entry] = [:]
        var order: [String] = []
        func add(_ id: String, _ entry: Entry) {
            guard let current = merged[id] else {
                merged[id] = entry
                order.append(id)
                return
            }
            var next = entry.limits.checkedAt > current.limits.checkedAt ? entry : current
            next.key = current.key
            next.plan = next.plan ?? current.plan ?? entry.plan
            next.name = current.name ?? entry.name
            merged[id] = next
        }

        for p in shown {
            guard let limits = p.limits, limits.isUsable else { continue }
            let key = identity(p.driver, p.email, p.workspaceId, limits) ?? "instance:\(p.instanceId)"
            add(key, Entry(key: key, driver: p.driver, name: p.displayName, email: p.email, plan: p.plan, limits: limits))
        }
        for s in sources {
            for a in s.accounts where a.limits.isUsable {
                let fallback = "\(s.id):\(a.id)\(a.workspaceId.map { ":\($0)" } ?? "")"
                let key = identity(a.driver, a.email, a.workspaceId, a.limits) ?? fallback
                let name = a.email == nil ? a.id.replacingOccurrences(of: ".json", with: "", options: [.caseInsensitive]) : nil
                add(key, Entry(key: key, driver: a.driver, name: name, email: a.email, plan: a.plan, limits: a.limits))
            }
        }

        // Providers keep T3 Code's order; drivers seen only through a hub follow.
        var driverOrder: [String] = []
        for d in providers.map(\.driver) + sources.flatMap({ $0.accounts.map(\.driver) }) where !driverOrder.contains(d) {
            driverOrder.append(d)
        }

        let entries = order.compactMap { merged[$0] }
        var result: [DriverGroup] = []
        for driver in driverOrder {
            let accounts = entries.filter { $0.driver == driver }
                .sorted { sortName($0).localizedStandardCompare(sortName($1)) == .orderedAscending }
            let provider = providers.first { $0.driver == driver && $0.enabled } ?? providers.first { $0.driver == driver }
            let name = provider?.displayName ?? defaultNames[driver] ?? driver.capitalized

            if accounts.isEmpty {
                // Say why a provider the user turned on shows nothing, unless it simply has no limits.
                guard let p = provider, p.enabled, p.installed, let l = p.limits,
                      l.unavailableReason == "probeFailed" else { continue }
                result.append(DriverGroup(driver: driver, name: name, plan: p.plan.flatMap { shortPlan($0, provider: name) }, accentHex: p.accentColor,
                                          windows: [], hasManyAccounts: false,
                                          notice: l.unavailableMessage ?? "使用量を取得できませんでした"))
                continue
            }

            let plans = Set(accounts.compactMap(\.plan))
            result.append(DriverGroup(
                driver: driver,
                name: name,
                plan: plans.count == 1 ? shortPlan(plans.first!, provider: name) : nil,
                accentHex: provider?.accentColor,
                windows: windows(driver: driver, accounts: accounts, now: now),
                hasManyAccounts: accounts.count > 1,
                notice: nil,
                credits: accounts.filter { $0.limits.resetCredits > 0 }.map {
                    AccountCredits(account: badge($0), count: $0.limits.resetCredits,
                                   expiresAt: $0.limits.resetCreditsExpireAt)
                },
                checkedAt: accounts.map(\.limits.checkedAt).min()))
        }
        return result
    }

    private static func sortName(_ e: Entry) -> String { (e.name ?? e.email ?? e.key).lowercased() }

    private static func windows(driver: String, accounts: [Entry], now: Date) -> [WindowGroup] {
        struct Member { var entry: Entry; var window: LimitWindow }
        var buckets: [(key: String, members: [Member])] = []

        for entry in accounts {
            for raw in displayWindows(driver: driver, entry.limits.windows) {
                let window = effective(driver: driver, limits: entry.limits, window: raw, now: now)
                var key = driver == "codex" ? window.kind.rawValue : "\(window.kind.rawValue):\(window.id)"
                if let i = buckets.firstIndex(where: { $0.key == key }), buckets[i].members.contains(where: { $0.entry.key == entry.key }) {
                    key = "\(window.kind.rawValue):\(window.id)"
                }
                if let i = buckets.firstIndex(where: { $0.key == key }) {
                    buckets[i].members.append(Member(entry: entry, window: window))
                } else {
                    buckets.append((key, [Member(entry: entry, window: window)]))
                }
            }
        }

        let groups = buckets.map { key, members -> WindowGroup in
            let first = members[0].window
            let planWeights = members.map { weight(driver: driver, plan: $0.entry.plan, kind: $0.window.kind) }
            let weights = planWeights.allSatisfy { $0 != nil } ? planWeights.map { $0! } : members.map { _ in 1.0 }
            let total = weights.reduce(0, +)
            let used = zip(members, weights).reduce(0) { $0 + $1.0.window.usedPercent * $1.1 } / total

            let paced = zip(members, weights).compactMap { m, w -> (used: Double, elapsed: Double, weight: Double)? in
                guard let e = elapsedFraction(m.window, now: now) else { return nil }
                return (m.window.usedPercent, e, w)
            }
            var pace: Pace?
            if !paced.isEmpty {
                let pw = paced.reduce(0) { $0 + $1.weight }
                let pu = paced.reduce(0) { $0 + $1.used * $1.weight } / pw
                let pe = paced.reduce(0) { $0 + $1.elapsed * $1.weight } / pw
                let diff = pu - pe * 100
                pace = diff > 5 ? .ahead : diff < -5 ? .under : .onTrack
            }

            return WindowGroup(
                id: key,
                kind: first.kind,
                label: first.label,
                remainingPercent: Int((100 - used).rounded()),
                pace: pace,
                members: members.map { m in
                    MemberBar(
                        account: badge(m.entry),
                        remainingPercent: Int((100 - m.window.usedPercent).rounded()),
                        expectedRemaining: elapsedFraction(m.window, now: now).map { 1 - $0 },
                        resetsAt: m.window.resetsAt,
                        emptiesAt: projectedEmpty(m.window, now: now))
                })
        }
        return groups.enumerated().sorted {
            ($0.element.kind.order, $0.offset) < ($1.element.kind.order, $1.offset)
        }.map(\.element)
    }

    /// Cursor and Antigravity report overlapping or many windows; trim and order them as T3 Code does.
    private static func displayWindows(driver: String, _ windows: [LimitWindow]) -> [LimitWindow] {
        switch driver {
        case "cursor":
            let ids = Set(windows.map(\.id))
            let total = windows.first { $0.id == "totalPercentUsed" }
            let auto = windows.first { $0.id == "autoPercentUsed" }
            let order = ["totalPercentUsed", "autoPercentUsed", "apiPercentUsed"]
            var list = windows
            if ids.contains("autoPercentUsed") && ids.contains("apiPercentUsed") {
                list.removeAll { $0.id == "totalPercentUsed" }
            } else if let total, let auto, windows.count == 2,
                      total.usedPercent == auto.usedPercent, total.resetsAt == auto.resetsAt {
                list.removeAll { $0.id == "autoPercentUsed" }
            }
            return list.sorted { (order.firstIndex(of: $0.id) ?? 9) < (order.firstIndex(of: $1.id) ?? 9) }
        case "antigravity":
            func stem(_ id: String) -> String {
                id.replacingOccurrences(of: "-(5h|weekly|quota)$", with: "", options: .regularExpression)
            }
            return windows.sorted { a, b in
                let ga = a.id.hasPrefix("gemini-") ? 0 : 1, gb = b.id.hasPrefix("gemini-") ? 0 : 1
                if ga != gb { return ga < gb }
                if stem(a.id) != stem(b.id) { return stem(a.id) < stem(b.id) }
                return a.kind.order < b.kind.order
            }
        default:
            return windows
        }
    }

    /// A session window is unusable while the weekly window behind it is spent.
    static func effective(driver: String, limits: UsageLimits, window: LimitWindow, now: Date) -> LimitWindow {
        guard window.kind == .session, let blocker = limits.windows.first(where: { w in
            w.usedPercent >= 100 && (driver == "claudeAgent" ? w.id == "seven_day" : driver == "codex" && w.kind == .weekly)
        }) else { return window }
        var out = window
        out.usedPercent = 100
        out.durationMins = nil
        out.resetsAt = nil
        let since = max(now, limits.checkedAt)
        if let weekly = blocker.resetsAt, let session = window.resetsAt, weekly > since, session > since {
            out.resetsAt = session <= weekly ? blocker.resetsAt : (window.usedPercent >= 100 ? window.resetsAt : blocker.resetsAt)
        }
        return out
    }

    /// When the window runs out if use continues at its average rate so far.
    /// Nil when it lasts until the reset, is already spent, or too little of
    /// the window has passed for the rate to mean anything.
    static func projectedEmpty(_ w: LimitWindow, now: Date) -> Date? {
        guard let reset = w.resetsAt, let mins = w.durationMins, mins > 0,
              w.usedPercent > 0, w.usedPercent < 100 else { return nil }
        let length = Double(mins) * 60
        let elapsed = length - reset.timeIntervalSince(now)
        guard elapsed >= max(10 * 60, length * 0.03), elapsed < length else { return nil }
        let secondsLeft = (100 - w.usedPercent) / (w.usedPercent / elapsed)
        let empties = now.addingTimeInterval(secondsLeft)
        return empties < reset ? empties : nil
    }

    static func elapsedFraction(_ w: LimitWindow, now: Date) -> Double? {
        guard let reset = w.resetsAt, let mins = w.durationMins, mins > 0 else { return nil }
        let length = Double(mins) * 60
        return min(1, max(0, (length - reset.timeIntervalSince(now)) / length))
    }

    private static func weight(driver: String, plan: String?, kind: WindowKind) -> Double? {
        guard let plan else { return nil }
        if driver == "codex", kind == .session || kind == .weekly {
            return ["ChatGPT Plus Subscription": 1, "ChatGPT Pro 100 Subscription": 5, "ChatGPT Pro 200 Subscription": 20][plan]
        }
        if driver == "claudeAgent", kind == .session {
            return ["Pro": 1, "Max": 5, "Ultra": 20][plan]
        }
        return nil
    }

    /// "ChatGPT Plus Subscription" → "Plus", "Claude Pro" → "Pro"; generic "… account" labels say nothing.
    static func shortPlan(_ plan: String, provider: String) -> String? {
        if plan.lowercased().hasSuffix(" account") { return nil }
        var s = plan.replacingOccurrences(of: "ChatGPT ", with: "").replacingOccurrences(of: " Subscription", with: "")
        if s.lowercased().hasPrefix(provider.lowercased() + " ") { s = String(s.dropFirst(provider.count + 1)) }
        return s.isEmpty ? nil : s
    }

    static func badge(email: String?, fallback: String, key: String) -> AccountBadge {
        let name = email ?? fallback
        var initials = "?"
        if let email {
            let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
            initials = ((parts.first?.prefix(1) ?? "") + (parts.count > 1 ? parts[1].prefix(1) : "")).uppercased()
        } else if !fallback.isEmpty {
            initials = String(fallback.filter { $0.isLetter || $0.isNumber }.prefix(2)).uppercased()
        }
        var hash: Int32 = 0
        for unit in name.utf16 { hash = hash &* 31 &+ Int32(unit) }
        return AccountBadge(key: key, name: name, initials: initials.isEmpty ? "?" : initials,
                            hue: Double(abs(Int(hash)) % 360) / 360)
    }

    private static func badge(_ e: Entry) -> AccountBadge {
        badge(email: e.email, fallback: e.name ?? e.key, key: e.key)
    }
}
