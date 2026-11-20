import Foundation

/// Cuts an observation loose. Releasing the token also unregisters it, so a
/// view that drops its subscriptions cannot keep listening by accident.
///
/// The token is a main-actor object: it is created, cancelled and released by
/// main-actor code (the stores and views), and both `cancel()` and the stored
/// handler are isolated there. `deinit` is nonisolated by language rule, so it
/// hops back onto the main actor with `assumeIsolated`, which is sound because
/// tokens never leave the main thread.
@MainActor
final class ObserverToken {
    private var cancelHandler: (@MainActor () -> Void)?

    init(_ cancel: @escaping @MainActor () -> Void) {
        cancelHandler = cancel
    }

    /// Removes the registration. Idempotent and safe to call while the
    /// observer is running.
    func cancel() {
        let handler = cancelHandler
        cancelHandler = nil
        handler?()
    }

    deinit {
        // A token still alive at deinit was never cancelled explicitly; release
        // the registration synchronously on the main actor.
        guard cancelHandler != nil else { return }
        MainActor.assumeIsolated { cancel() }
    }
}

/// The little bit of Combine T3Bar actually used: register a closure, get a
/// token, call it back. Handlers run on the main actor in registration order,
/// and may unregister themselves (or add new observers) while being called.
@MainActor
final class Observers {
    /// Array rather than a dictionary: `notify()` promises registration order.
    private var entries: [(id: UUID, handler: () -> Void)] = []

    var count: Int { entries.count }

    @discardableResult
    func add(_ handler: @escaping () -> Void) -> ObserverToken {
        let id = UUID()
        entries.append((id, handler))
        return ObserverToken { [weak self] in
            guard let self else { return }
            self.entries.removeAll { $0.id == id }
        }
    }

    func notify() {
        // Iterate a snapshot so handlers can cancel themselves or register more
        // observers without disturbing this pass.
        let snapshot = entries
        for entry in snapshot { entry.handler() }
    }
}
