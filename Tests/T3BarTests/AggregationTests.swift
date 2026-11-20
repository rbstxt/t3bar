import XCTest
@testable import T3Bar

final class AggregationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(_ id: String, _ kind: WindowKind, _ label: String, used: Double,
                        resetIn hours: Double? = nil, minutes: Int? = nil) -> LimitWindow {
        LimitWindow(id: id, kind: kind, label: label, usedPercent: used,
                    resetsAt: hours.map { now.addingTimeInterval($0 * 3600) }, durationMins: minutes)
    }

    private func limits(_ windows: [LimitWindow], unavailable: String? = nil) -> UsageLimits {
        UsageLimits(checkedAt: now, windows: windows, unavailableReason: unavailable,
                    unavailableMessage: nil, credentialFingerprint: nil)
    }

    private func provider(_ driver: String, name: String, email: String? = nil, plan: String? = nil,
                          limits: UsageLimits?) -> ProviderStatus {
        ProviderStatus(instanceId: driver, driver: driver, displayName: name, enabled: true, installed: true,
                       status: "ready", email: email, plan: plan, workspaceId: nil, accentColor: nil, limits: limits)
    }

    func testHubAccountsAverageIntoOneCodexSection() {
        // Codex itself reports "unsupported"; its numbers come from two hub accounts.
        let codex = provider("codex", name: "Codex", limits: limits([], unavailable: "unsupported"))
        let hub = HubSource(id: "hub", label: "hub", accounts: [
            HubAccount(id: "a", driver: "codex", email: "hana@giga.example", plan: "ChatGPT Plus Subscription",
                       workspaceId: "w1", limits: limits([
                        window("primary", .session, "Session", used: 6, resetIn: 3, minutes: 300),
                        window("secondary", .weekly, "Weekly", used: 1, resetIn: 160, minutes: 10080),
                       ])),
            HubAccount(id: "b", driver: "codex", email: "taro@corp.example", plan: "ChatGPT Plus Subscription",
                       workspaceId: "w2", limits: limits([
                        window("primary", .weekly, "Weekly", used: 23, resetIn: 150, minutes: 10080),
                       ])),
        ], error: nil)

        let groups = Aggregator.groups(providers: [codex], sources: [hub], now: now)
        XCTAssertEqual(groups.map(\.name), ["Codex"])
        let codexGroup = groups[0]
        XCTAssertTrue(codexGroup.hasManyAccounts)
        XCTAssertEqual(codexGroup.plan, "Plus")
        XCTAssertEqual(codexGroup.windows.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(codexGroup.windows[0].remainingPercent, 94)
        // Codex groups by kind, so the two weekly windows share one row: (99 + 77) / 2.
        XCTAssertEqual(codexGroup.windows[1].remainingPercent, 88)
        XCTAssertEqual(codexGroup.windows[1].members.map(\.account.initials), ["HG", "TC"])
        XCTAssertEqual(codexGroup.tightest?.remainingPercent, 88)
    }

    func testSameLoginFromProviderAndHubIsOneAccount() {
        let direct = provider("codex", name: "Codex", email: "Me@Mail.example",
                              limits: limits([window("primary", .session, "Session", used: 10)]))
        var newer = limits([window("primary", .session, "Session", used: 40)])
        newer.checkedAt = now.addingTimeInterval(60)
        let hub = HubSource(id: "hub", label: "hub", accounts: [
            HubAccount(id: "x", driver: "codex", email: "me@mail.example", plan: nil, workspaceId: nil, limits: newer),
        ], error: nil)

        let group = Aggregator.groups(providers: [direct], sources: [hub], now: now)[0]
        XCTAssertFalse(group.hasManyAccounts)
        XCTAssertEqual(group.windows[0].remainingPercent, 60, "the newer reading wins")
    }

    func testPaceAndExpectedMarker() {
        // 2 of 5 hours gone (40%) but 70% used: well ahead of a steady pace.
        let claude = provider("claudeAgent", name: "Claude", limits: limits([
            window("five_hour", .session, "Session", used: 70, resetIn: 3, minutes: 300),
            window("seven_day", .weekly, "Weekly", used: 10, resetIn: 84, minutes: 10080),
        ]))
        let group = Aggregator.groups(providers: [claude], sources: [], now: now)[0]
        XCTAssertEqual(group.windows[0].pace, .ahead)
        XCTAssertEqual(group.windows[0].members[0].expectedRemaining ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(group.windows[1].pace, .under)
    }

    func testSpentWeeklyEmptiesSession() {
        let claude = provider("claudeAgent", name: "Claude", limits: limits([
            window("five_hour", .session, "Session", used: 20, resetIn: 2, minutes: 300),
            window("seven_day", .weekly, "Weekly", used: 100, resetIn: 30, minutes: 10080),
        ]))
        let group = Aggregator.groups(providers: [claude], sources: [], now: now)[0]
        XCTAssertEqual(group.windows[0].remainingPercent, 0)
        XCTAssertEqual(group.windows[0].nextReset, now.addingTimeInterval(30 * 3600))
        XCTAssertNil(group.windows[0].pace)
    }

    func testHidesUnsupportedAndDisabledButExplainsFailures() {
        var disabled = provider("kiro", name: "Kiro", limits: limits([window("w", .weekly, "Weekly", used: 5)]))
        disabled.enabled = false
        let unsupported = provider("pi", name: "Pi", limits: limits([], unavailable: "unsupported"))
        let failed = provider("grok", name: "Grok", limits: limits([], unavailable: "probeFailed"))
        let groups = Aggregator.groups(providers: [disabled, unsupported, failed], sources: [], now: now)
        XCTAssertEqual(groups.map(\.name), ["Grok"])
        XCTAssertNotNil(groups[0].notice)
        XCTAssertTrue(groups[0].windows.isEmpty)
    }

    func testCursorDropsDuplicateOverall() {
        let cursor = provider("cursor", name: "Cursor", limits: limits([
            window("autoPercentUsed", .monthly, "Cursor Models", used: 46.7, resetIn: 100),
            window("totalPercentUsed", .monthly, "Overall", used: 46.7, resetIn: 100),
        ]))
        let group = Aggregator.groups(providers: [cursor], sources: [], now: now)[0]
        XCTAssertEqual(group.windows.map(\.label), ["Overall"])
        XCTAssertEqual(group.windows[0].remainingPercent, 53)
    }

    func testProjectsRunOutOnlyWhenItBeatsTheReset() {
        // 2h of 5h gone, 70% used: 30% left at 35%/h runs out in ~51 minutes, before the 3h reset.
        let fast = window("five_hour", .session, "Session", used: 70, resetIn: 3, minutes: 300)
        let empties = Aggregator.projectedEmpty(fast, now: now)
        XCTAssertEqual(empties?.timeIntervalSince(now) ?? 0, 30 / 35 * 3600, accuracy: 1)

        // 10% used over 3.5 days of a week lasts well past the reset.
        let slow = window("seven_day", .weekly, "Weekly", used: 10, resetIn: 84, minutes: 10080)
        XCTAssertNil(Aggregator.projectedEmpty(slow, now: now))

        // Five minutes in, the rate means nothing yet.
        let early = window("five_hour", .session, "Session", used: 20, resetIn: 4.92, minutes: 300)
        XCTAssertNil(Aggregator.projectedEmpty(early, now: now))

        // Spent already: the reset time is what matters, not a forecast.
        let spent = window("five_hour", .session, "Session", used: 100, resetIn: 1, minutes: 300)
        XCTAssertNil(Aggregator.projectedEmpty(spent, now: now))

        let claude = provider("claudeAgent", name: "Claude", limits: limits([fast, slow]))
        let group = Aggregator.groups(providers: [claude], sources: [], now: now)[0]
        XCTAssertNotNil(group.windows[0].emptiesAt)
        XCTAssertNil(group.windows[1].emptiesAt)
    }

    func testSumsResetCreditsAndKeepsOldestReading() throws {
        let json = """
        {"checkedAt":"2026-11-20T07:15:42.231Z","windows":[{"id":"primary","kind":"weekly","label":"Weekly","usedPercent":23}],
         "resetCredits":{"availableCount":1,"nextExpiresAt":"2026-12-12T20:45:21.790Z"}}
        """
        var a = try XCTUnwrap(LimitsDecoder.limits(JSONSerialization.jsonObject(with: Data(json.utf8))))
        XCTAssertEqual(a.resetCredits, 1)
        XCTAssertNotNil(a.resetCreditsExpireAt)
        var b = a
        b.checkedAt = a.checkedAt.addingTimeInterval(600)
        b.resetCredits = 2
        let hub = HubSource(id: "hub", label: "hub", accounts: [
            HubAccount(id: "a", driver: "codex", email: "a@x.example", plan: nil, workspaceId: nil, limits: a),
            HubAccount(id: "b", driver: "codex", email: "b@x.example", plan: nil, workspaceId: nil, limits: b),
        ], error: nil)
        let group = Aggregator.groups(providers: [], sources: [hub], now: now)[0]
        XCTAssertEqual(group.credits.map(\.count), [1, 2])
        XCTAssertEqual(group.credits.map(\.account.initials), ["AX", "BX"])
        XCTAssertEqual(group.checkedAt, a.checkedAt)
    }

    func testPlanLabels() {
        XCTAssertEqual(Aggregator.shortPlan("ChatGPT Pro 200 Subscription", provider: "Codex"), "Pro 200")
        XCTAssertEqual(Aggregator.shortPlan("Claude Pro", provider: "Claude"), "Pro")
        XCTAssertNil(Aggregator.shortPlan("Cursor account", provider: "Cursor"))
        XCTAssertNil(Aggregator.shortPlan("Google account", provider: "Antigravity"))
    }

    func testDecodesServerJSON() throws {
        let json = """
        {"instanceId":"claudeAgent","driver":"claudeAgent","displayName":"Claude","enabled":true,"installed":true,
         "status":"ready","auth":{"status":"authenticated","label":"Max"},
         "usageLimits":{"checkedAt":"2026-11-20T07:15:28.863Z","windows":[
           {"id":"five_hour","kind":"session","label":"Session","usedPercent":28,"resetsAt":"2026-11-20T10:30:00.134Z","windowDurationMins":300},
           {"id":"x","kind":"future-kind","label":"New","usedPercent":140}]}}
        """
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let p = try XCTUnwrap(LimitsDecoder.provider(raw))
        XCTAssertEqual(p.plan, "Max")
        XCTAssertEqual(p.limits?.windows.count, 2)
        XCTAssertEqual(p.limits?.windows[1].kind, .other)
        XCTAssertEqual(p.limits?.windows[1].usedPercent, 100)
        XCTAssertNotNil(p.limits?.windows[0].resetsAt)
    }
}
