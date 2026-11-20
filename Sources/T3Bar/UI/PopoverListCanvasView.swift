import AppKit

/// Line heights and baseline offsets for the canvas text. Ceiling each font
/// metric separately (ascender, descender, leading) overstated a 10.5–11.5 pt
/// line by 2 pt and a 13.5 pt line by 1 pt; the layout manager's default line
/// height already covers the same glyphs, so it is rounded once instead.
@MainActor
enum CanvasTextMetrics {
    private static var heights: [String: CGFloat] = [:]
    private static var baselines: [String: CGFloat] = [:]

    private static func key(_ font: NSFont) -> String {
        // `fontName` and size alone collide once a family gains a rounded or
        // monospaced-digit variant, so the descriptor's traits (weight, width,
        // design, proportion, slant) and feature settings (number spacing,
        // ligatures) are part of the key too. Values are sorted so the key is
        // stable across descriptors built in different orders.
        let descriptor = font.fontDescriptor
        let traits = (descriptor.object(forKey: .traits)
            as? [NSFontDescriptor.TraitKey: Any])?
            .map { "\($0.key.rawValue)=\($0.value)" }
            .sorted()
            .joined(separator: ",") ?? ""
        let features = (descriptor.object(forKey: .featureSettings)
            as? [[NSFontDescriptor.FeatureKey: Any]])?
            .map { feature in
                let type = (feature[.typeIdentifier] as? NSNumber)?.intValue ?? 0
                let selector = (feature[.selectorIdentifier] as? NSNumber)?.intValue ?? 0
                return "\(type):\(selector)"
            }
            .sorted()
            .joined(separator: ",") ?? ""
        return "\(font.fontName)|\(font.pointSize)|\(traits)|\(features)"
    }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        let key = key(font)
        if let cached = heights[key] { return cached }
        let height = ceil(NSLayoutManager().defaultLineHeight(for: font))
        heights[key] = height
        return height
    }

    /// Distance from the top of a `lineHeight` rect to the text baseline.
    static func baselineOffset(_ font: NSFont) -> CGFloat {
        let key = key(font)
        if let cached = baselines[key] { return cached }
        let offset = ceil(NSLayoutManager().defaultBaselineOffset(for: font))
        baselines[key] = offset
        return offset
    }
}

/// Draws the whole provider list into one view. Text, bars, badges and logos
/// are rendered directly instead of one AppKit view per label, which keeps the
/// popover's memory close to the empty state. Tooltips hang off hotspot rects
/// and the section-wide right-click menu is resolved by hit test.
@MainActor
final class PopoverListCanvasView: NSView, NSViewToolTipOwner {
    private enum Font {
        static let sectionName = PopoverStyle.font(size: 12, weight: .semibold)
        static let plan = PopoverStyle.font(size: 10.5)
        static let ago = PopoverStyle.font(size: 10)
        static let credit = PopoverStyle.font(size: 9.5, weight: .medium)
        static let rowLabel = PopoverStyle.font(size: 11.5)
        static let average = PopoverStyle.font(size: 10)
        static let percent = PopoverStyle.font(size: 13.5, weight: .semibold, rounded: true, monoDigits: true)
        static let memberPercent = PopoverStyle.font(size: 10.5, weight: .medium, monoDigits: true)
        static let note = PopoverStyle.font(size: 10.5, weight: .medium, monoDigits: true)
        static let reset = PopoverStyle.font(size: 10.5, monoDigits: true)
        static let notice = PopoverStyle.font(size: 11)
    }

    private struct TextRun {
        var text: NSAttributedString
        var rect: NSRect
        var maxLines: Int
        var truncation: NSLineBreakMode
    }

    private struct BarRun {
        var rect: NSRect
        var percent: Int
        var expected: Double?
        var base: NSColor
    }

    private struct BadgeRun {
        var rect: NSRect
        var badge: AccountBadge
        var compact: Bool
    }

    private struct LogoRun {
        var rect: NSRect
        var driver: String
    }

    private struct MarkRun {
        var rect: NSRect
        var color: NSColor
    }

    private struct SymbolRun {
        var rect: NSRect
        var name: String
        var color: NSColor
        var pointSize: CGFloat
        var weight: NSFont.Weight
    }

    private struct CardRun {
        var rect: NSRect
    }

    private struct PillRun {
        var rect: NSRect
    }

    private struct DividerRun {
        var rect: NSRect
    }

    private struct Section {
        var rect: NSRect
        var driver: String
        var name: String
    }

    private struct TooltipSpot {
        var rect: NSRect
        var text: String
    }

    private struct AccessibilitySpot {
        var rect: NSRect
        var text: String
    }

    private var texts: [TextRun] = []
    private var bars: [BarRun] = []
    private var badges: [BadgeRun] = []
    private var logos: [LogoRun] = []
    private var marks: [MarkRun] = []
    private var symbols: [SymbolRun] = []
    private var cards: [CardRun] = []
    private var pills: [PillRun] = []
    private var dividers: [DividerRun] = []
    private var sections: [Section] = []
    private var tooltips: [TooltipSpot] = []
    private var accessibilitySpots: [AccessibilitySpot] = []

    /// The height the list wants, set by `configure`.
    private(set) var requiredHeight: CGFloat = 1
    /// Called with a driver when its section's context menu asks for a pin toggle.
    var onTogglePin: ((String) -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Build

    func configure(groups: [DriverGroup], prefs: Preferences, now: Date) {
        texts.removeAll()
        bars.removeAll()
        badges.removeAll()
        logos.removeAll()
        marks.removeAll()
        symbols.removeAll()
        cards.removeAll()
        pills.removeAll()
        dividers.removeAll()
        sections.removeAll()
        tooltips.removeAll()
        accessibilitySpots.removeAll()
        removeAllToolTips()

        let left: CGFloat = 12
        let width: CGFloat = 316
        var cursor: CGFloat = 8

        for (index, group) in groups.enumerated() {
            if index > 0 { cursor += 10 }
            let top = cursor
            cursor = layoutSection(group, prefs: prefs, now: now, left: left, width: width, top: top)
            sections.append(Section(rect: NSRect(x: left, y: top, width: width, height: cursor - top),
                                    driver: group.driver, name: group.name))
        }

        requiredHeight = max(1, groups.isEmpty ? 1 : cursor + 10)
        frame.size.height = requiredHeight
        registerTooltips()
        needsDisplay = true
    }

    private func layoutSection(_ group: DriverGroup, prefs: Preferences, now: Date,
                               left: CGFloat, width: CGFloat, top: CGFloat) -> CGFloat {
        let color = Theme.color(for: group)
        var y = top

        // Header: logo, name, plan, then the right-aligned extras.
        let pinned = prefs.menuBarProvider == group.driver
        let pillHeight = lineHeight(Font.credit) + 3
        let headerHeight = max(14, lineHeight(Font.sectionName), pillHeight)

        var trailing: [(width: CGFloat, draw: (CGFloat) -> Void)] = []

        if pinned, let pin = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)) {
            let size = pin.size
            trailing.append((size.width, { [weak self] x in
                guard let self else { return }
                let rect = NSRect(x: x, y: y + (headerHeight - size.height) / 2,
                                  width: size.width, height: size.height)
                self.symbols.append(SymbolRun(rect: rect, name: "pin.fill", color: Theme.canvasTertiaryText,
                                              pointSize: 9, weight: .regular))
                self.addTooltip(rect, "メニューバーに表示中")
            }))
        }

        for credit in group.credits.reversed() {
            let leading: CGFloat = group.hasManyAccounts ? 2 : 5
            let badgeWidth: CGFloat = group.hasManyAccounts ? 15 + 4 : 0
            let label = creditsText(credit)
            let labelWidth = measure(label, width: .greatestFiniteMagnitude, maxLines: 1)
            let creditLine = lineHeight(Font.credit)
            let pillWidth = leading + badgeWidth + labelWidth + 5
            trailing.append((pillWidth, { [weak self] x in
                guard let self else { return }
                let rect = NSRect(x: x, y: y + (headerHeight - pillHeight) / 2, width: pillWidth, height: pillHeight)
                self.pills.append(PillRun(rect: rect))
                if group.hasManyAccounts {
                    let badgeRect = NSRect(x: rect.minX + leading, y: rect.midY - 11 / 2, width: 15, height: 11)
                    self.badges.append(BadgeRun(rect: badgeRect, badge: credit.account, compact: true))
                }
                let textRect = NSRect(x: rect.minX + leading + badgeWidth, y: rect.midY - creditLine / 2,
                                      width: labelWidth, height: creditLine)
                self.texts.append(TextRun(text: label, rect: textRect, maxLines: 1, truncation: .byTruncatingTail))
                self.addTooltip(rect, self.creditsHelp(credit))
                self.addAccessibility(rect, "\(credit.account.name) \(label.string)")
            }))
        }

        if let checked = group.checkedAt, now.timeIntervalSince(checked) >= 15 * 60 {
            let ago = attributed(Format.ago(checked, now: now), font: Font.ago, color: Theme.canvasTertiaryText)
            let agoWidth = measure(ago, width: .greatestFiniteMagnitude, maxLines: 1)
            let agoLine = lineHeight(Font.ago)
            trailing.append((agoWidth, { [weak self] x in
                guard let self else { return }
                let rect = NSRect(x: x, y: y + (headerHeight - agoLine) / 2,
                                  width: agoWidth, height: agoLine)
                self.texts.append(TextRun(text: ago, rect: rect, maxLines: 1, truncation: .byTruncatingTail))
                self.addTooltip(rect, "最後に取得: \(Format.time(checked))。T3 Code が新しい値を取得できていません")
                self.addAccessibility(rect, "最後に取得: \(Format.ago(checked, now: now)) \(Format.time(checked))")
            }))
        }

        var right = left + width - 2
        for item in trailing {
            right -= item.width
            item.draw(right)
            right -= 7
        }

        let markX = left + 2
        if ProviderIcons.has(group.driver) {
            logos.append(LogoRun(rect: NSRect(x: markX, y: y + (headerHeight - 14) / 2, width: 14, height: 14),
                                 driver: group.driver))
        } else {
            marks.append(MarkRun(rect: NSRect(x: markX, y: y + (headerHeight - 14) / 2, width: 14, height: 14),
                                 color: color))
        }

        let nameX = markX + 14 + 7
        let available = max(0, right - nameX)
        let name = attributed(group.name, font: Font.sectionName, color: .labelColor, truncation: .byTruncatingTail)
        let plan = group.plan.map {
            attributed($0, font: Font.plan, color: Theme.canvasSecondaryText, truncation: .byTruncatingTail)
        }
        var planWidth = plan.map { measure($0, width: .greatestFiniteMagnitude, maxLines: 1) } ?? 0
        var nameWidth = measure(name, width: .greatestFiniteMagnitude, maxLines: 1)
        if plan != nil {
            let total = nameWidth + 7 + planWidth
            if total > available {
                planWidth = max(0, available - nameWidth - 7)
                if planWidth < 10 { planWidth = 0 }
            }
            if planWidth == 0 { nameWidth = min(nameWidth, available) }
        } else {
            nameWidth = min(nameWidth, available)
        }
        let nameRect = NSRect(x: nameX, y: y + (headerHeight - lineHeight(Font.sectionName)) / 2,
                              width: nameWidth, height: lineHeight(Font.sectionName))
        texts.append(TextRun(text: name, rect: nameRect, maxLines: 1, truncation: .byTruncatingTail))
        if let plan, planWidth > 0 {
            let planRect = NSRect(x: nameRect.maxX + 7, y: y + (headerHeight - lineHeight(Font.plan)) / 2,
                                  width: planWidth, height: lineHeight(Font.plan))
            texts.append(TextRun(text: plan, rect: planRect, maxLines: 1, truncation: .byTruncatingTail))
        }
        accessibilitySpots.append(AccessibilitySpot(
            rect: NSRect(x: left, y: y, width: width, height: headerHeight),
            text: [group.name, group.plan].compactMap { $0 }.joined(separator: " ")))

        y += headerHeight + 4

        // Card.
        let cardTop = y
        if let notice = group.notice {
            let textWidth = width - 20
            let text = attributed(notice, font: Font.notice, color: Theme.canvasSecondaryText,
                                  truncation: .byTruncatingTail)
            let height = measuredHeight(text, width: textWidth, maxLines: 3, truncation: .byTruncatingTail)
            let rect = NSRect(x: left + 10, y: y + 8, width: textWidth, height: height)
            texts.append(TextRun(text: text, rect: rect, maxLines: 3, truncation: .byTruncatingTail))
            addAccessibility(rect, notice)
            y += 8 + height + 8
        } else {
            for (index, window) in group.windows.enumerated() {
                if index > 0 {
                    dividers.append(DividerRun(rect: NSRect(x: left + 10, y: y, width: width - 20, height: 1)))
                    y += 1
                }
                y = layoutRow(window, group: group, color: color, now: now,
                              left: left, width: width, top: y)
            }
        }
        cards.append(CardRun(rect: NSRect(x: left, y: cardTop, width: width, height: y - cardTop)))

        return y
    }

    private func layoutRow(_ window: WindowGroup, group: DriverGroup, color: NSColor, now: Date,
                           left: CGFloat, width: CGFloat, top: CGFloat) -> CGFloat {
        let contentX = left + 10
        let contentWidth = width - 20
        let rowRight = contentX + contentWidth
        var y = top + 6

        // The top row shares one baseline, like the old SwiftUI row's
        // `.firstTextBaseline`: the label, note, 平均 and the large number.
        let topFonts = [Font.rowLabel, Font.percent, Font.average, Font.note]
        let ascent = topFonts.map { baselineOffset($0) }.max() ?? 0
        let descent = topFonts.map { lineHeight($0) - baselineOffset($0) }.max() ?? 0
        let topLine = ascent + descent
        let baseline = y + ascent
        func topY(for font: NSFont) -> CGFloat { baseline - baselineOffset(font) }

        let percent = attributed("\(window.remainingPercent)%", font: Font.percent,
                                 color: Theme.levelText(window.remainingPercent), alignment: .right)
        let percentWidth = measure(percent, width: 400, maxLines: 1)
        let percentRect = NSRect(x: rowRight - percentWidth, y: topY(for: Font.percent),
                                 width: percentWidth, height: lineHeight(Font.percent))
        texts.append(TextRun(text: percent, rect: percentRect, maxLines: 1, truncation: .byTruncatingTail))
        accessibilitySpots.append(AccessibilitySpot(
            rect: NSRect(x: contentX, y: y, width: contentWidth, height: topLine),
            text: "\(window.label) 残り \(window.remainingPercent)%"))

        var rightEdge = percentRect.minX
        if window.members.count > 1 {
            let average = attributed("平均", font: Font.average, color: Theme.canvasTertiaryText)
            let averageWidth = measure(average, width: .greatestFiniteMagnitude, maxLines: 1)
            let averageHeight = lineHeight(Font.average)
            let averageRect = NSRect(x: rightEdge - 4 - averageWidth, y: topY(for: Font.average),
                                     width: averageWidth, height: averageHeight)
            texts.append(TextRun(text: average, rect: averageRect, maxLines: 1, truncation: .byTruncatingTail))
            addTooltip(averageRect, "\(window.members.count) アカウントの平均（プランの大きさで重み付け）")
            addAccessibility(averageRect, "\(window.members.count) アカウントの平均")
            rightEdge = averageRect.minX
        }

        var note: (text: NSAttributedString, tooltip: String, width: CGFloat)?
        if !group.hasManyAccounts, let member = window.members.first {
            // A spent window says when it comes back, regardless of pace or a
            // stale forecast; 速め must never be shown for 0%.
            if let zero = Depletion.note(remaining: member.remainingPercent,
                                         reset: member.resetsAt, now: now) {
                let text = attributed(zero.text, font: Font.note, color: Theme.canvasCriticalText)
                note = (text, zero.help, measure(text, width: .greatestFiniteMagnitude, maxLines: 1))
            } else if let empties = member.emptiesAt {
                let text = attributed("\(Format.countdown(to: empties, now: now))で枯渇",
                                      font: Font.note, color: .systemOrange)
                note = (text, emptiesHelp(empties: empties, reset: member.resetsAt, now: now),
                        measure(text, width: .greatestFiniteMagnitude, maxLines: 1))
            } else if window.pace == .ahead {
                let text = attributed("速め", font: Font.note, color: .systemOrange)
                note = (text, "均等なペースより速く使っています",
                        measure(text, width: .greatestFiniteMagnitude, maxLines: 1))
            }
        }

        let label = attributed(window.label, font: Font.rowLabel, color: Theme.canvasSecondaryText,
                               truncation: .byTruncatingMiddle)
        let available = max(0, rightEdge - 8 - contentX)
        // Keep the note readable even with a long label; the label truncates
        // first and the note's full text stays in the tooltip and VoiceOver.
        let noteWidth = min(note?.width ?? 0, max(0, available * 0.7))
        var labelWidth = min(measure(label, width: .greatestFiniteMagnitude, maxLines: 1),
                             available - (noteWidth > 0 ? noteWidth + 4 : 0))
        labelWidth = max(0, labelWidth)
        let labelRect = NSRect(x: contentX, y: topY(for: Font.rowLabel),
                               width: labelWidth, height: lineHeight(Font.rowLabel))
        texts.append(TextRun(text: label, rect: labelRect, maxLines: 1, truncation: .byTruncatingMiddle))
        addTooltip(labelRect, window.label)

        if let note, noteWidth > 0 {
            let noteRect = NSRect(x: contentX + labelWidth + 4, y: topY(for: Font.note),
                                  width: noteWidth, height: lineHeight(Font.note))
            texts.append(TextRun(text: note.text, rect: noteRect, maxLines: 1, truncation: .byTruncatingTail))
            addTooltip(noteRect, note.tooltip)
            addAccessibility(noteRect, "\(note.text.string)。\(note.tooltip)")
        }

        y += topLine

        if group.hasManyAccounts {
            y += 3.5
            for (index, member) in window.members.enumerated() {
                if index > 0 { y += 4 }
                y = layoutMember(member, color: color, now: now, contentX: contentX,
                                 contentWidth: contentWidth, rowRight: rowRight, top: y)
            }
        } else if let member = window.members.first {
            y += 3.5
            let lineH = max(11, lineHeight(Font.reset))
            let resetRect = NSRect(x: rowRight - 52, y: y + (lineH - lineHeight(Font.reset)) / 2,
                                   width: 52, height: lineHeight(Font.reset))
            addReset(date: member.resetsAt, now: now, rect: resetRect)
            let barX = contentX
            let barWidth = max(0, resetRect.minX - 8 - barX)
            addBar(percent: member.remainingPercent, expected: member.expectedRemaining, base: color,
                   rect: NSRect(x: barX, y: y + (lineH - 11) / 2, width: barWidth, height: 11),
                   tooltip: barHelp(member, now: now))
            y += lineH
        }

        return y + 6
    }

    private func layoutMember(_ member: MemberBar, color: NSColor, now: Date,
                              contentX: CGFloat, contentWidth: CGFloat, rowRight: CGFloat, top: CGFloat) -> CGFloat {
        var y = top
        let lineH = max(14, lineHeight(Font.memberPercent), lineHeight(Font.reset), 11)

        let badgeRect = NSRect(x: contentX, y: y + (lineH - 14) / 2, width: 18, height: 14)
        badges.append(BadgeRun(rect: badgeRect, badge: member.account, compact: false))
        addTooltip(badgeRect, member.account.name)

        let resetRect = NSRect(x: rowRight - 52, y: y + (lineH - lineHeight(Font.reset)) / 2,
                               width: 52, height: lineHeight(Font.reset))
        addReset(date: member.resetsAt, now: now, rect: resetRect)

        let percentWidth: CGFloat = 32
        let percent = attributed("\(member.remainingPercent)%", font: Font.memberPercent,
                                 color: Theme.canvasSecondaryText, alignment: .right)
        let percentRect = NSRect(x: resetRect.minX - 7 - percentWidth,
                                 y: y + (lineH - lineHeight(Font.memberPercent)) / 2,
                                 width: percentWidth, height: lineHeight(Font.memberPercent))
        texts.append(TextRun(text: percent, rect: percentRect, maxLines: 1, truncation: .byTruncatingTail))

        let barX = badgeRect.maxX + 7
        let barWidth = max(0, percentRect.minX - 7 - barX)
        addBar(percent: member.remainingPercent, expected: member.expectedRemaining, base: color,
               rect: NSRect(x: barX, y: y + (lineH - 11) / 2, width: barWidth, height: 11),
               tooltip: barHelp(member, now: now))
        accessibilitySpots.append(AccessibilitySpot(
            rect: NSRect(x: contentX, y: y, width: contentWidth, height: lineH),
            text: "\(member.account.name) 残り \(member.remainingPercent)%"))

        y += lineH

        if let zero = Depletion.note(remaining: member.remainingPercent,
                                     reset: member.resetsAt, now: now) {
            y += 2
            let text = attributed(zero.text, font: Font.note, color: Theme.canvasCriticalText)
            let noteRect = NSRect(x: contentX + 25, y: y,
                                  width: max(0, rowRight - (contentX + 25)), height: lineHeight(Font.note))
            texts.append(TextRun(text: text, rect: noteRect, maxLines: 1, truncation: .byTruncatingTail))
            let help = "\(member.account.name): 残り \(member.remainingPercent)%。\(zero.help)"
            addTooltip(noteRect, help)
            addAccessibility(noteRect, "\(member.account.name) 残り \(member.remainingPercent)%。\(zero.text)。\(zero.help)")
            y += lineHeight(Font.note)
        } else if let empties = member.emptiesAt {
            y += 2
            let text = attributed("\(Format.countdown(to: empties, now: now))で枯渇",
                                  font: Font.note, color: .systemOrange)
            let noteRect = NSRect(x: contentX + 25, y: y,
                                  width: max(0, rowRight - (contentX + 25)), height: lineHeight(Font.note))
            texts.append(TextRun(text: text, rect: noteRect, maxLines: 1, truncation: .byTruncatingTail))
            let help = emptiesHelp(empties: empties, reset: member.resetsAt, now: now)
            addTooltip(noteRect, help)
            addAccessibility(noteRect, "\(text.string)。\(help)")
            y += lineHeight(Font.note)
        }
        return y
    }

    private func addReset(date: Date?, now: Date, rect: NSRect) {
        let text = attributed(date.map { Format.countdown(to: $0, now: now) } ?? "",
                              font: Font.reset, color: Theme.canvasTertiaryText, alignment: .right)
        let textWidth = measure(text, width: 400, maxLines: 1)
        let textRect = NSRect(x: max(rect.minX, rect.maxX - textWidth), y: rect.minY,
                              width: min(textWidth, rect.width), height: rect.height)
        texts.append(TextRun(text: text, rect: textRect, maxLines: 1, truncation: .byTruncatingTail))
        if date != nil, let image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)) {
            let size = image.size
            let iconRect = NSRect(x: max(rect.minX, textRect.minX - 2 - size.width),
                                  y: rect.midY - size.height / 2,
                                  width: size.width, height: size.height)
            symbols.append(SymbolRun(rect: iconRect, name: "arrow.clockwise",
                                     color: Theme.canvasTertiaryText, pointSize: 8, weight: .semibold))
        }
        let help = date.map(Format.resetMoment) ?? "リセット時刻は報告されていません"
        addTooltip(rect, help)
        addAccessibility(rect, date.map { "リセットまで \(Format.countdown(to: $0, now: now))" }
            ?? "リセット時刻は報告されていません")
    }

    private func addBar(percent: Int, expected: Double?, base: NSColor, rect: NSRect, tooltip: String) {
        bars.append(BarRun(rect: rect, percent: percent, expected: expected, base: base))
        addTooltip(rect, tooltip)
        addAccessibility(rect, tooltip)
    }

    private func creditsText(_ credit: AccountCredits) -> NSAttributedString {
        attributed("リセット券 \(credit.count)", font: Font.credit, color: Theme.canvasSecondaryText)
    }

    private func creditsHelp(_ credit: AccountCredits) -> String {
        var text = "\(credit.account.name): 上限を今すぐリセットできる券が \(credit.count) 枚（T3 Code の Limits 画面で使えます）"
        if let expiry = credit.expiresAt { text += "\n次の期限: \(Format.moment(expiry))" }
        return text
    }

    private func barHelp(_ member: MemberBar, now: Date) -> String {
        var text = "\(member.account.name): 残り \(member.remainingPercent)%"
        // A spent window says when it returns instead of forecasting a pace.
        if let zero = Depletion.note(remaining: member.remainingPercent,
                                     reset: member.resetsAt, now: now) {
            return text + "\n" + zero.help
        }
        if let expected = member.expectedRemaining {
            text += "（均等ペースなら \(Int((expected * 100).rounded()))%）"
        }
        if let empties = member.emptiesAt {
            text += "\nこのペースだと \(Format.countdown(to: empties, now: now)) で枯渇"
        }
        return text
    }

    private func emptiesHelp(empties: Date, reset: Date?, now: Date) -> String {
        var text = "このペースだと \(Format.countdown(to: empties, now: now)) で使い切ります"
        if let reset { text += "（リセットは \(Format.countdown(to: reset, now: now)) 後）" }
        return text
    }

    private func addTooltip(_ rect: NSRect, _ text: String) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        // Appended in drawing order; `stringForToolTip` resolves overlaps with
        // `last(where:)` so the topmost, later-drawn element wins.
        tooltips.append(TooltipSpot(rect: rect, text: text))
    }

    private func addAccessibility(_ rect: NSRect, _ text: String) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        accessibilitySpots.append(AccessibilitySpot(rect: rect, text: text))
    }

    private func registerTooltips() {
        for spot in tooltips { addToolTip(spot.rect, owner: self, userData: nil) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Tooltips registered before the popover had a window are re-armed here.
        guard window != nil else { return }
        removeAllToolTips()
        registerTooltips()
    }

    // MARK: - Text helpers

    private func attributed(_ string: String, font: NSFont, color: NSColor,
                            alignment: NSTextAlignment = .left,
                            truncation: NSLineBreakMode = .byTruncatingTail) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = truncation
        return NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
    }

    private func lineHeight(_ font: NSFont) -> CGFloat {
        CanvasTextMetrics.lineHeight(font)
    }

    private func baselineOffset(_ font: NSFont) -> CGFloat {
        CanvasTextMetrics.baselineOffset(font)
    }

    private func measure(_ text: NSAttributedString, width: CGFloat, maxLines: Int) -> CGFloat {
        guard !text.string.isEmpty else { return 0 }
        if maxLines == 1, width >= .greatestFiniteMagnitude / 2 {
            return ceil(text.size().width)
        }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: max(1, min(width, 10_000)), height: 10_000))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = maxLines
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return maxLines == 1 ? ceil(used.width) : ceil(used.height)
    }

    private func measuredHeight(_ text: NSAttributedString, width: CGFloat,
                                maxLines: Int, truncation: NSLineBreakMode) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: max(1, width), height: 10_000))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = maxLines
        container.lineBreakMode = truncation
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Scrolling asks for a thin strip; skip runs outside it (with a little
        // slack for antialiasing and half-pixel strokes).
        let visible = dirtyRect.insetBy(dx: -2, dy: -2)
        for card in cards where visible.intersects(card.rect) { drawCard(card.rect) }
        for divider in dividers where visible.intersects(divider.rect) {
            // A hairline instead of a full 1 pt band: it separates the rows
            // without cutting the card in two. Snap it to the backing store's
            // pixel grid, otherwise the 0.5 pt band straddles two pixels and
            // smears on both Retina and 1x displays.
            let scale = window?.backingScaleFactor ?? 2
            let y = ((divider.rect.midY - 0.25) * scale).rounded() / scale
            NSColor.separatorColor.withAlphaComponent(0.45).setFill()
            NSRect(x: divider.rect.minX, y: y,
                   width: divider.rect.width, height: 0.5).fill()
        }
        for pill in pills where visible.intersects(pill.rect) { drawPill(pill.rect) }
        for bar in bars where visible.intersects(bar.rect) { drawBar(bar) }
        for badge in badges where visible.intersects(badge.rect) { drawBadge(badge) }
        for logo in logos where visible.intersects(logo.rect) { drawLogo(logo) }
        for mark in marks where visible.intersects(mark.rect) { drawMark(mark) }
        for symbol in symbols where visible.intersects(symbol.rect) { drawSymbol(symbol) }
        for text in texts where visible.intersects(text.rect) { drawText(text) }
    }

    private func drawCard(_ rect: NSRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 9, yRadius: 9)
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.06).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private func drawPill(_ rect: NSRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    }

    private func drawBar(_ run: BarRun) {
        let rect = run.rect
        guard rect.width > 0 else { return }
        let height: CGFloat = 6
        let y = rect.midY - height / 2
        let track = NSRect(x: rect.minX, y: y, width: rect.width, height: height)

        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2).fill()

        let remaining = Double(run.percent) / 100
        if remaining > 0 {
            let fill = NSRect(x: rect.minX, y: y, width: min(rect.width, max(6, rect.width * remaining)), height: height)
            Theme.level(run.percent, base: run.base).setFill()
            NSBezierPath(roundedRect: fill, xRadius: height / 2, yRadius: height / 2).fill()
        }

        if let expected = run.expected {
            // Where a steady pace would leave you now. Fill past it means headroom.
            let x = min(rect.width - 1.5, max(0, rect.width * expected - 0.75))
            let marker = NSRect(x: rect.minX + x, y: rect.midY - 5.5, width: 1.5, height: 11)
            NSColor.labelColor.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: marker, xRadius: 0.75, yRadius: 0.75).fill()
        }
    }

    private func drawBadge(_ run: BadgeRun) {
        let radius: CGFloat = run.compact ? 3 : 4
        NSColor(hue: run.badge.hue, saturation: 0.45, brightness: 0.72, alpha: 1).setFill()
        NSBezierPath(roundedRect: run.rect, xRadius: radius, yRadius: radius).fill()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let text = NSAttributedString(string: run.badge.initials, attributes: [
            .font: PopoverStyle.font(size: run.compact ? 6.5 : 7.5, weight: .bold, rounded: true),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ])
        drawText(TextRun(text: text, rect: run.rect, maxLines: 1, truncation: .byClipping),
                 verticalCenter: true)
    }

    private func drawLogo(_ run: LogoRun) {
        guard let image = ProviderIcons.image(run.driver, effectiveAppearance.isDark ? .dark : .light) else { return }
        image.draw(in: ProviderIcons.fit(image, in: run.rect))
    }

    private func drawMark(_ run: MarkRun) {
        let square = NSRect(x: run.rect.midX - 4, y: run.rect.midY - 4, width: 8, height: 8)
        run.color.setFill()
        NSBezierPath(roundedRect: square, xRadius: 3, yRadius: 3).fill()
    }

    private func drawSymbol(_ run: SymbolRun) {
        guard !run.name.isEmpty else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: run.pointSize, weight: run.weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [run.color]))
        guard let image = NSImage(systemSymbolName: run.name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        image.draw(in: run.rect)
    }

    private func drawText(_ run: TextRun, verticalCenter: Bool = false) {
        guard run.rect.width > 0.5, run.rect.height > 0.5, !run.text.string.isEmpty else { return }
        let storage = NSTextStorage(attributedString: run.text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: run.rect.width, height: run.rect.height))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = run.maxLines
        container.lineBreakMode = run.truncation
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        var origin = run.rect.origin
        if verticalCenter {
            let used = manager.usedRect(for: container)
            origin.y += (run.rect.height - used.height) / 2
        }
        let range = manager.glyphRange(for: container)
        manager.drawGlyphs(forGlyphRange: range, at: origin)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Tooltips and menu

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        // Later runs are drawn on top, so the last match is what the user sees.
        tooltips.last(where: { $0.rect.contains(point) })?.text ?? ""
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let section = sections.last(where: { $0.rect.contains(point) }) else { return nil }
        let pinned = onTogglePin != nil && isPinned(driver: section.driver)
        let item = NSMenuItem(title: pinned ? "メニューバーの固定を解除" : "メニューバーに \(section.name) を表示",
                              action: #selector(togglePinItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = section.driver
        let menu = NSMenu()
        menu.addItem(item)
        return menu
    }

    /// Set by the controller; asks whether a driver is currently pinned.
    var pinnedDriver: ((String) -> Bool)?

    private func isPinned(driver: String) -> Bool { pinnedDriver?(driver) ?? false }

    @objc private func togglePinItem(_ sender: NSMenuItem) {
        guard let driver = sender.representedObject as? String else { return }
        onTogglePin?(driver)
    }

    // MARK: - Accessibility

    override func accessibilityChildren() -> [Any]? {
        // Without a window the rects are in view coordinates and cannot be
        // turned into screen frames; VoiceOver would read the wrong place, so
        // report nothing until the canvas is in a window.
        guard let window else { return [] }
        guard !accessibilitySpots.isEmpty else { return super.accessibilityChildren() }
        return accessibilitySpots.map { spot in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(spot.text)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrame(window.convertToScreen(convert(spot.rect, to: nil)))
            return element
        }
    }
}
