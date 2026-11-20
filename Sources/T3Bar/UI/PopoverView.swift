import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var prefs: Preferences
    var openT3: () -> Void
    var quit: () -> Void

    /// Remembered across openings so the popover opens at its last size.
    @MainActor private static var lastHeight: CGFloat = 240
    @State private var contentHeight: CGFloat = PopoverView.lastHeight

    private var maxHeight: CGFloat {
        ((NSScreen.main?.visibleFrame.height ?? 900) - 120).clamped(to: 300...680)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            if store.hasData {
                list
                if store.connection != .live { staleBanner }
            } else {
                EmptyStateView(store: store, openT3: openT3)
            }
        }
        .frame(width: 340)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("使用量の残り")
                    .font(.system(size: 13, weight: .semibold))
                ConnectionLine(store: store)
            }
            Spacer()
            Button(action: store.refresh) {
                ZStack {
                    if store.isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 16, height: 16)
            }
            .buttonStyle(IconButtonStyle())
            .help("プロバイダーに今すぐ問い合わせる")
            .disabled(store.isRefreshing)

            SettingsMenu(store: store, prefs: prefs, openT3: openT3, quit: quit)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
    }

    // MARK: List

    private var list: some View {
        ScrollView(.vertical) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(store.groups) { group in
                        ProviderSection(group: group, now: context.date,
                                        pinned: prefs.menuBarProvider == group.driver) {
                            prefs.menuBarProvider = prefs.menuBarProvider == group.driver ? Preferences.automatic : group.driver
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
            .background(GeometryReader { proxy in
                Color.clear.preference(key: HeightKey.self, value: proxy.size.height)
            })
        }
        .scrollIndicators(.automatic)
        .defaultScrollAnchor(.top)
        .frame(height: min(contentHeight, maxHeight))
        .onPreferenceChange(HeightKey.self) { height in
            guard height > 0, abs(height - contentHeight) > 0.5 else { return }
            contentHeight = height
            PopoverView.lastHeight = height
        }
    }

    private var staleBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(store.connection.bannerText)
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Provider

private struct ProviderSection: View {
    let group: DriverGroup
    let now: Date
    let pinned: Bool
    let togglePin: () -> Void

    var body: some View {
        let color = Theme.color(for: group)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if ProviderIcons.has(group.driver) {
                    ProviderLogo(driver: group.driver, size: 14)
                } else {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color)
                        .frame(width: 8, height: 8)
                        .frame(width: 14, height: 14)
                }
                Text(group.name)
                    .font(.system(size: 12, weight: .semibold))
                if let plan = group.plan {
                    Text(plan)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let checked = group.checkedAt, now.timeIntervalSince(checked) >= 15 * 60 {
                    Text(Format.ago(checked, now: now))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help("最後に取得: \(Format.time(checked))。T3 Code が新しい値を取得できていません")
                }
                ForEach(group.credits) { credit in
                    // With several accounts, the badge says whose credit it is.
                    HStack(spacing: 4) {
                        if group.hasManyAccounts { AccountBadgeView(badge: credit.account, compact: true) }
                        Text("リセット券 \(credit.count)")
                    }
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, group.hasManyAccounts ? 2 : 5)
                    .padding(.trailing, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .help(creditsHelp(credit))
                }
                if pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .help("メニューバーに表示中")
                }
            }
            .padding(.horizontal, 2)

            if let notice = group.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(card)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(group.windows.enumerated()), id: \.element.id) { index, window in
                        if index > 0 { Divider().opacity(0.5) }
                        WindowRow(window: window, color: color, showsBadges: group.hasManyAccounts, now: now)
                    }
                }
                .padding(.horizontal, 10)
                .background(card)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(pinned ? "メニューバーの固定を解除" : "メニューバーに \(group.name) を表示", action: togglePin)
        }
    }

    private func creditsHelp(_ credit: AccountCredits) -> String {
        var text = "\(credit.account.name): 上限を今すぐリセットできる券が \(credit.count) 枚（T3 Code の Limits 画面で使えます）"
        if let expiry = credit.expiresAt { text += "\n次の期限: \(Format.moment(expiry))" }
        return text
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.primary.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }
}

// MARK: - Window

private struct WindowRow: View {
    let window: WindowGroup
    let color: Color
    let showsBadges: Bool
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(window.label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(window.label)
                if !showsBadges { PaceNote(window: window, now: now) }
                Spacer(minLength: 8)
                if window.members.count > 1 {
                    Text("平均")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help("\(window.members.count) アカウントの平均（プランの大きさで重み付け）")
                }
                Text("\(window.remainingPercent)%")
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.levelText(window.remainingPercent))
            }

            if showsBadges {
                ForEach(window.members) { member in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            AccountBadgeView(badge: member.account)
                            UsageBar(member: member, color: color)
                            Text("\(member.remainingPercent)%")
                                .font(.system(size: 10.5, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 32, alignment: .trailing)
                            ResetLabel(date: member.resetsAt, now: now)
                        }
                        if let empties = member.emptiesAt {
                            EmptiesNote(empties: empties, reset: member.resetsAt, now: now)
                                .padding(.leading, 25)
                        }
                    }
                }
            } else if let member = window.members.first {
                HStack(spacing: 8) {
                    UsageBar(member: member, color: color)
                    ResetLabel(date: member.resetsAt, now: now)
                }
            }
        }
        .padding(.vertical, 7)
    }
}

private struct UsageBar: View {
    let member: MemberBar
    let color: Color

    var body: some View {
        let remaining = Double(member.remainingPercent) / 100
        let fill = Theme.level(member.remainingPercent, base: color)
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.09))
                    .frame(height: 6)
                if remaining > 0 {
                    Capsule()
                        .fill(fill)
                        .frame(width: max(6, width * remaining), height: 6)
                }
                if let expected = member.expectedRemaining {
                    // Where a steady pace would leave you now. Fill past it means headroom.
                    RoundedRectangle(cornerRadius: 0.75)
                        .fill(Color.primary.opacity(0.7))
                        .frame(width: 1.5, height: 11)
                        .offset(x: min(width - 1.5, max(0, width * expected - 0.75)))
                }
            }
            .frame(height: proxy.size.height)
        }
        .frame(height: 11)
        .help(barHelp)
    }

    private var barHelp: String {
        var text = "\(member.account.name): 残り \(member.remainingPercent)%"
        if let expected = member.expectedRemaining {
            text += "（均等ペースなら \(Int((expected * 100).rounded()))%）"
        }
        if let empties = member.emptiesAt {
            text += "\nこのペースだと \(Format.countdown(to: empties, now: Date())) で枯渇"
        }
        return text
    }
}

private struct ResetLabel: View {
    let date: Date?
    let now: Date

    var body: some View {
        HStack(spacing: 2) {
            if let date {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 8, weight: .semibold))
                Text(Format.countdown(to: date, now: now))
            }
        }
        .font(.system(size: 10.5))
        .monospacedDigit()
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .frame(width: 52, alignment: .trailing)
        .help(date.map(Format.resetMoment) ?? "リセット時刻は報告されていません")
    }
}

/// Says when a single-account limit runs out at the current pace, only if that beats
/// the reset. A limit that lasts gets no text: silence means it is fine.
private struct PaceNote: View {
    let window: WindowGroup
    let now: Date

    var body: some View {
        if let member = window.members.first, let empties = member.emptiesAt {
            EmptiesNote(empties: empties, reset: member.resetsAt, now: now)
        } else if window.pace == .ahead {
            Text("速め")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.orange)
                .help("均等なペースより速く使っています")
        }
    }
}

private struct EmptiesNote: View {
    let empties: Date
    let reset: Date?
    let now: Date

    var body: some View {
        Text("\(Format.countdown(to: empties, now: now))で枯渇")
            .font(.system(size: 10.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.orange)
            .lineLimit(1)
            .layoutPriority(1)
            .help(help)
    }

    private var help: String {
        var text = "このペースだと \(Format.countdown(to: empties, now: now)) で使い切ります"
        if let reset { text += "（リセットは \(Format.countdown(to: reset, now: now)) 後）" }
        return text
    }
}

private struct AccountBadgeView: View {
    let badge: AccountBadge
    var compact = false

    var body: some View {
        Text(badge.initials)
            .font(.system(size: compact ? 6.5 : 7.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: compact ? 15 : 18, height: compact ? 11 : 14)
            .background(
                RoundedRectangle(cornerRadius: compact ? 3 : 4, style: .continuous)
                    .fill(Color(hue: badge.hue, saturation: 0.45, brightness: 0.72))
            )
            .help(badge.name)
    }
}

// MARK: - Header pieces

private struct ConnectionLine: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dot)
                .frame(width: 6, height: 6)
            Text(text)
                .lineLimit(1)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    private var dot: Color {
        switch store.connection {
        case .live: .green
        case .connecting: .yellow
        default: .orange
        }
    }

    private var text: String {
        switch store.connection {
        case .live:
            if let at = store.updatedAt { return "T3 Code · \(Format.time(at)) 更新" }
            return "T3 Code に接続済み"
        case .connecting: return "接続中…"
        case .serverDown: return "T3 Code が起動していません"
        case .authFailed: return "認証に失敗しました"
        case .incompatible: return "未対応の T3 Code バージョン"
        case .failed: return "再接続を待っています"
        }
    }
}

private struct SettingsMenu: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var prefs: Preferences
    var openT3: () -> Void
    var quit: () -> Void

    var body: some View {
        Menu {
            Section("メニューバー") {
                Picker("表示するプロバイダー", selection: $prefs.menuBarProvider) {
                    Text("自動（残りが最も少ない）").tag(Preferences.automatic)
                    Divider()
                    ForEach(store.groups.filter { !$0.windows.isEmpty }) { group in
                        Text(group.name).tag(group.driver)
                    }
                }
                Toggle("アイコン", isOn: $prefs.showsProviderIcon)
                Toggle("グラフ", isOn: $prefs.showsGauge)
                Toggle("残り %", isOn: $prefs.showsPercent)
            }
            Section("色") {
                Toggle("少ないとき色を付ける", isOn: $prefs.colorsWhenLow)
                Picker("色を付ける目安", selection: $prefs.levels) {
                    ForEach(Preferences.Levels.presets, id: \.self) { levels in
                        Text(levels.label).tag(levels)
                    }
                }
                Toggle("枯渇しそうでも色を付ける", isOn: $prefs.colorsOnForecast)
                    .disabled(!prefs.colorsWhenLow)
            }
            Divider()
            Toggle("ログイン時に起動", isOn: Binding(
                get: { prefs.launchesAtLogin },
                set: { prefs.setLaunchesAtLogin($0) }))
            Button("T3 Code を開く", action: openT3)
            Button("再接続") { store.reconnect() }
            Divider()
            Button("T3Bar を終了", action: quit)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 4)
        .help("設定")
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0))
            )
            .contentShape(Rectangle())
    }
}

// MARK: - Empty states

private struct EmptyStateView: View {
    @ObservedObject var store: UsageStore
    var openT3: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            content
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
    }

    @ViewBuilder private var content: some View {
        switch store.connection {
        case .connecting:
            ProgressView().controlSize(.small)
            Text("T3 Code に接続しています…").font(.system(size: 12)).foregroundStyle(.secondary)
        case .live:
            symbol("chart.bar.xaxis")
            title("表示できる使用量がありません")
            detail("T3 Code で使用量の上限を報告するプロバイダーにログインすると、ここに表示されます。")
        case .serverDown:
            symbol("powerplug")
            title("T3 Code が起動していません")
            detail("起動すると自動で接続します。")
            Button("T3 Code を開く", action: openT3).controlSize(.small)
        case .authFailed(let message):
            symbol("key")
            title("T3 Code に接続できません")
            detail(message)
            Button("トークンを再発行") { store.reconnect(resetToken: true) }.controlSize(.small)
        case .incompatible:
            symbol("arrow.triangle.2.circlepath")
            title("この T3 Code には未対応です")
            detail("T3 Code の通信形式が変わりました。T3Bar の更新が必要です。")
        case .failed(let message):
            symbol("exclamationmark.triangle")
            title("接続が切れました")
            detail(message)
            Button("再接続") { store.reconnect() }.controlSize(.small)
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5, weight: .semibold))
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
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

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
