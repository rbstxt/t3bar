import Combine
import Foundation

/// Holds the latest limits from T3 Code and what the menu bar and popover show.
@MainActor
final class UsageStore: ObservableObject {
    enum Connection: Equatable {
        case connecting
        case live
        case serverDown
        case authFailed(String)
        case incompatible
        case failed(String)
    }

    @Published private(set) var groups: [DriverGroup] = []
    @Published private(set) var connection: Connection = .connecting
    @Published private(set) var updatedAt: Date?
    @Published private(set) var isRefreshing = false

    private var providers: [ProviderStatus] = []
    private var sources: [HubSource] = []
    private let client = T3Client()
    private var clock: Timer?

    init() {
        client.onState = { [weak self] state in self?.apply(state) }
        client.onEvent = { [weak self] event in self?.apply(event) }
        client.onRefreshFinished = { [weak self] in self?.isRefreshing = false }
    }

    func start() {
        client.start()
        // Pace and session/weekly interplay depend on the time, so recompute now and then.
        clock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    func refresh() {
        guard connection == .live else {
            client.reconnect()
            return
        }
        isRefreshing = true
        client.refresh()
        // The server answers once every provider was probed; never spin forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in self?.isRefreshing = false }
    }

    func reconnect(resetToken: Bool = false) {
        if resetToken { TokenStore.clear() }
        client.reconnect()
    }

    var hasData: Bool { !groups.isEmpty }

    // MARK: -

    private func apply(_ state: T3Client.State) {
        switch state {
        case .connecting: if connection != .live { connection = .connecting }
        case .connected: connection = .live
        case .serverDown: connection = .serverDown
        case .authFailed(let m): connection = .authFailed(m)
        case .incompatible: connection = .incompatible
        case .failed(let m): connection = .failed(m)
        }
    }

    private func apply(_ event: [String: Any]) {
        let payload = event["payload"] as? [String: Any]
        switch event["type"] as? String {
        case "snapshot":
            let config = event["config"] as? [String: Any]
            providers = LimitsDecoder.providers(config?["providers"])
            if let s = config?["usageLimitSources"] { sources = LimitsDecoder.sources(s) }
        case "providerStatuses":
            providers = LimitsDecoder.providers(payload?["providers"])
        case "providerStatusDeltas":
            // Not requested, but merge if a server sends them anyway.
            for delta in LimitsDecoder.providers(payload?["providers"]) {
                if let i = providers.firstIndex(where: { $0.instanceId == delta.instanceId }) {
                    providers[i] = delta
                } else {
                    providers.append(delta)
                }
            }
        case "usageLimitSourcesUpdated":
            sources = LimitsDecoder.sources(payload?["sources"])
        default:
            return
        }
        updatedAt = Date()
        rebuild()
    }

    private func rebuild() {
        let next = Aggregator.groups(providers: providers, sources: sources, now: Date())
        if next != groups { groups = next }
    }
}
