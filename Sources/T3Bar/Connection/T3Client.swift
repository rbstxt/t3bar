import AppKit
import Foundation

/// Subscribes to the local T3 Code server's config stream and reports the
/// events that carry usage limits. Speaks the server's Effect RPC protocol
/// over its WebSocket: JSON frames tagged Request / Chunk / Ack / Exit / Ping.
@MainActor
final class T3Client {
    enum State: Equatable {
        case connecting
        case connected
        case serverDown
        case authFailed(String)
        case incompatible
        case failed(String)
    }

    var onState: (State) -> Void = { _ in }
    var onEvent: ([String: Any]) -> Void = { _ in }
    var onRefreshFinished: () -> Void = {}

    private static let protocolVersion = "2"

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var nextRequestId = 1
    private var subscriptionId: String?
    private var refreshId: String?
    private var retryDelay: TimeInterval = 1
    private var retryTask: Task<Void, Never>?
    private var pingTimer: Timer?
    private var isConnected = false
    private var wakeObserver: NSObjectProtocol?

    init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnect() }
        }
    }

    func start() { connect() }

    func reconnect() {
        retryDelay = 1
        connect()
    }

    /// Asks the server to probe providers again; the new limits arrive on the stream.
    func refresh() {
        guard let task, subscriptionId != nil else {
            reconnect()
            return
        }
        let id = makeRequestId()
        refreshId = id
        send(task, ["_tag": "Request", "id": id, "tag": "server.refreshProviders",
                    "payload": ["omitProviders": true], "headers": [Any]()])
    }

    // MARK: - Connection lifecycle

    private func connect() {
        generation += 1
        let gen = generation
        teardown()
        onState(.connecting)
        Task { await run(gen) }
    }

    private func teardown() {
        retryTask?.cancel()
        retryTask = nil
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        subscriptionId = nil
        isConnected = false
        if refreshId != nil {
            refreshId = nil
            onRefreshFinished()
        }
    }

    private enum Failure: Error {
        case serverDown
        case auth(String)
        case incompatible
        case other(String)
    }

    private func run(_ gen: Int) async {
        do {
            guard let origin = ServerLocator.origin() else { throw Failure.serverDown }
            let ticket = try await webSocketTicket(origin: origin, mayReissue: true)
            guard gen == generation else { return }

            var parts = URLComponents(url: origin.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
            parts.scheme = origin.scheme == "https" ? "wss" : "ws"
            parts.queryItems = [
                URLQueryItem(name: "wsTicket", value: ticket),
                URLQueryItem(name: "orchestrationProtocol", value: Self.protocolVersion),
            ]
            let socket = session.webSocketTask(with: parts.url!)
            socket.maximumMessageSize = 32 * 1024 * 1024
            task = socket
            socket.resume()

            let id = makeRequestId()
            subscriptionId = id
            send(socket, [
                "_tag": "Request", "id": id, "tag": "subscribeServerConfig",
                "payload": [
                    "usageLimitSources": true,
                    // Leave out per-workspace catalogs; T3Bar only needs provider status.
                    "workspaceSnapshotsOnDemand": true,
                    "providerCatalogsOnDemand": true,
                    "providerCatalogDigests": true,
                ],
                "headers": [Any](),
            ])

            while gen == generation {
                let message = try await socket.receive()
                guard gen == generation else { return }
                try handle(message, on: socket)
            }
        } catch {
            guard gen == generation else { return }
            await fail(error, origin: ServerLocator.origin())
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, on socket: URLSessionWebSocketTask) throws {
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: return
        }
        guard let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = frame["_tag"] as? String else { return }

        switch tag {
        case "Chunk":
            guard let requestId = frame["requestId"] as? String else { return }
            send(socket, ["_tag": "Ack", "requestId": requestId])
            if requestId == subscriptionId {
                if !isConnected { markConnected(socket) }
                for case let event as [String: Any] in frame["values"] as? [Any] ?? [] {
                    onEvent(event)
                }
            }
        case "Exit":
            let requestId = frame["requestId"] as? String
            if requestId == refreshId {
                refreshId = nil
                onRefreshFinished()
            } else if requestId == subscriptionId {
                throw Failure.other(exitReason(frame) ?? "サーバーが購読を終了しました")
            }
        case "Ping":
            send(socket, ["_tag": "Pong"])
        case "Defect":
            throw Failure.other("サーバーエラー")
        default:
            break
        }
    }

    private func markConnected(_ socket: URLSessionWebSocketTask) {
        isConnected = true
        retryDelay = 1
        onState(.connected)
        pingTimer?.invalidate()
        let gen = generation
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self, weak socket] _ in
            MainActor.assumeIsolated { self?.ping(socket, generation: gen) }
        }
    }

    private func ping(_ socket: URLSessionWebSocketTask?, generation gen: Int) {
        socket?.sendPing { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == gen else { return }
                    self.connect()
                }
            }
        }
    }

    private func fail(_ error: Error, origin: URL?) async {
        var failure = error as? Failure ?? Self.classify(error)
        // A rejected upgrade may mean T3 Code moved to a newer protocol.
        if case .other = failure, let origin, await isProtocolIncompatible(origin) {
            failure = .incompatible
        }
        teardown()
        switch failure {
        case .serverDown:
            onState(.serverDown)
            scheduleRetry(after: 3, maxDelay: 3)
        case .auth(let message):
            onState(.authFailed(message))
            scheduleRetry(after: retryDelay, maxDelay: 120)
        case .incompatible:
            onState(.incompatible)
            scheduleRetry(after: 300, maxDelay: 300)
        case .other(let message):
            onState(ServerLocator.origin() == nil ? .serverDown : .failed(message))
            scheduleRetry(after: retryDelay, maxDelay: 30)
        }
    }

    private func scheduleRetry(after delay: TimeInterval, maxDelay: TimeInterval) {
        let wait = min(delay, maxDelay)
        retryDelay = min(max(retryDelay, 1) * 2, maxDelay)
        let gen = generation
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == gen else { return }
            self.connect()
        }
    }

    private static func classify(_ error: Error) -> Failure {
        if let url = error as? URLError {
            switch url.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .timedOut:
                return .serverDown
            default:
                return .other(url.localizedDescription)
            }
        }
        if let issue = error as? TokenStore.IssueError {
            return .auth(issue.localizedDescription)
        }
        let posix = (error as NSError).domain == NSPOSIXErrorDomain
        return posix ? .serverDown : .other(error.localizedDescription)
    }

    // MARK: - HTTP

    private func webSocketTicket(origin: URL, mayReissue: Bool) async throws -> String {
        let token: String
        if let stored = TokenStore.load() {
            token = stored
        } else {
            token = try await TokenStore.issue()
        }

        var request = URLRequest(url: origin.appendingPathComponent("api/auth/websocket-ticket"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "x-t3-orchestration-protocol")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            guard mayReissue else { throw Failure.auth("T3 Code がトークンを受け付けません（HTTP \(status)）") }
            TokenStore.clear()
            return try await webSocketTicket(origin: origin, mayReissue: false)
        }
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ticket = json["ticket"] as? String else {
            throw Failure.other("WebSocket チケットを取得できません（HTTP \(status)）")
        }
        return ticket
    }

    private func isProtocolIncompatible(_ origin: URL) async -> Bool {
        var parts = URLComponents(url: origin.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "orchestrationProtocol", value: Self.protocolVersion)]
        guard let url = parts.url, let (data, _) = try? await session.data(from: url) else { return false }
        return String(decoding: data, as: UTF8.self).contains("orchestration_protocol_incompatible")
    }

    // MARK: - Framing

    private func makeRequestId() -> String {
        defer { nextRequestId += 1 }
        return String(nextRequestId)
    }

    private func send(_ socket: URLSessionWebSocketTask, _ frame: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func exitReason(_ frame: [String: Any]) -> String? {
        guard let exit = frame["exit"] as? [String: Any], exit["_tag"] as? String == "Failure" else { return nil }
        let cause = exit["cause"]
        if let data = try? JSONSerialization.data(withJSONObject: cause ?? [:]),
           let text = String(data: data, encoding: .utf8) {
            return String(text.prefix(160))
        }
        return nil
    }
}
