import AppKit

/// Title, connection line, refresh and settings buttons.
final class PopoverHeaderView: NSStackView {
    var onRefresh: (() -> Void)?
    var onSettings: ((NSButton) -> Void)?

    private let connectionDot = DotView()
    private let connectionLabel = PopoverStyle.label("", size: 10.5, color: .secondaryLabelColor)
    private let refreshContainer = NSView()
    private let refreshButton = HighlightButton()
    private let spinner = NSProgressIndicator()
    private let settingsButton = HighlightButton()

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 10
        edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 8)
        translatesAutoresizingMaskIntoConstraints = false

        let left = NSStackView()
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 2

        let title = PopoverStyle.label("使用量の残り", size: 13, weight: .semibold)
        left.addArrangedSubview(title)

        let connection = NSStackView(views: [connectionDot, connectionLabel])
        connection.orientation = .horizontal
        connection.alignment = .centerY
        connection.spacing = 5
        left.addArrangedSubview(connection)

        addArrangedSubview(left)
        addArrangedSubview(SpacerView())

        configureRefresh()
        addArrangedSubview(refreshContainer)
        configureSettings()
        addArrangedSubview(settingsButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureRefresh() {
        refreshContainer.translatesAutoresizingMaskIntoConstraints = false
        refreshContainer.widthAnchor.constraint(equalToConstant: 26).isActive = true
        refreshContainer.heightAnchor.constraint(equalToConstant: 26).isActive = true

        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.isBordered = false
        refreshButton.imagePosition = .imageOnly
        refreshButton.focusRingType = .none
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        refreshButton.contentTintColor = .secondaryLabelColor
        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed)
        refreshButton.toolTip = "プロバイダーに今すぐ問い合わせる"
        refreshButton.setAccessibilityLabel("プロバイダーに今すぐ問い合わせる")
        refreshContainer.addSubview(refreshButton)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isHidden = true
        refreshContainer.addSubview(spinner)

        NSLayoutConstraint.activate([
            refreshButton.centerXAnchor.constraint(equalTo: refreshContainer.centerXAnchor),
            refreshButton.centerYAnchor.constraint(equalTo: refreshContainer.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 26),
            refreshButton.heightAnchor.constraint(equalToConstant: 26),
            spinner.centerXAnchor.constraint(equalTo: refreshContainer.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: refreshContainer.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    private func configureSettings() {
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.isBordered = false
        settingsButton.imagePosition = .imageOnly
        settingsButton.focusRingType = .none
        settingsButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.target = self
        settingsButton.action = #selector(settingsPressed)
        settingsButton.toolTip = "設定"
        settingsButton.setAccessibilityLabel("設定")
        NSLayoutConstraint.activate([
            settingsButton.widthAnchor.constraint(equalToConstant: 24),
            settingsButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    func update(store: UsageStore) {
        switch store.connection {
        case .live:
            if let at = store.updatedAt {
                connectionLabel.stringValue = "T3 Code · \(Format.time(at)) 更新"
            } else {
                connectionLabel.stringValue = "T3 Code に接続済み"
            }
            connectionDot.color = .systemGreen
        case .connecting:
            connectionLabel.stringValue = "接続中…"
            connectionDot.color = .systemYellow
        case .serverDown:
            connectionLabel.stringValue = "T3 Code が起動していません"
            connectionDot.color = .systemOrange
        case .authFailed:
            connectionLabel.stringValue = "認証に失敗しました"
            connectionDot.color = .systemOrange
        case .incompatible:
            connectionLabel.stringValue = "未対応の T3 Code バージョン"
            connectionDot.color = .systemOrange
        case .failed:
            connectionLabel.stringValue = "再接続を待っています"
            connectionDot.color = .systemOrange
        }

        refreshButton.isHidden = store.isRefreshing
        refreshButton.isEnabled = !store.isRefreshing
        spinner.isHidden = !store.isRefreshing
        if store.isRefreshing {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    @objc private func refreshPressed() { onRefresh?() }
    @objc private func settingsPressed() { onSettings?(settingsButton) }
}

/// A borderless icon button that shows the same faint pressed background as the
/// SwiftUI icon button style did.
final class HighlightButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}
