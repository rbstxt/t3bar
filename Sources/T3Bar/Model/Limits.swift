import Foundation

// Raw data as T3 Code reports it. Only the fields T3Bar shows are kept.

enum WindowKind: String {
    case session, weekly, monthly, other

    var order: Int {
        switch self {
        case .session: 0
        case .weekly: 1
        case .monthly: 2
        case .other: 3
        }
    }
}

struct LimitWindow: Equatable {
    var id: String
    var kind: WindowKind
    var label: String
    var usedPercent: Double
    var resetsAt: Date?
    var durationMins: Int?
}

struct UsageLimits: Equatable {
    var checkedAt: Date
    var windows: [LimitWindow]
    var unavailableReason: String?
    var unavailableMessage: String?
    var credentialFingerprint: String?
    /// Banked resets that clear the windows at once (Codex "reset credits").
    var resetCredits: Int = 0
    var resetCreditsExpireAt: Date?

    /// Mirrors T3 Code: unsupported, failed, or empty limits draw no bars.
    var isUsable: Bool { unavailableReason == nil && !windows.isEmpty }
}

struct ProviderStatus: Equatable {
    var instanceId: String
    var driver: String
    var displayName: String?
    var enabled: Bool
    var installed: Bool
    var status: String
    var email: String?
    var plan: String?
    var workspaceId: String?
    var accentColor: String?
    var limits: UsageLimits?
}

struct HubAccount: Equatable {
    var id: String
    var driver: String
    var email: String?
    var plan: String?
    var workspaceId: String?
    var limits: UsageLimits
}

struct HubSource: Equatable {
    var id: String
    var label: String
    var accounts: [HubAccount]
    var error: String?
}

// MARK: - Decoding from the loosely typed JSON T3 Code sends

enum LimitsDecoder {
    static func providers(_ value: Any?) -> [ProviderStatus] {
        guard let list = value as? [[String: Any]] else { return [] }
        return list.compactMap(provider)
    }

    static func sources(_ value: Any?) -> [HubSource] {
        guard let list = value as? [[String: Any]] else { return [] }
        return list.compactMap { raw in
            guard let id = raw["id"] as? String else { return nil }
            let accounts = (raw["accounts"] as? [[String: Any]] ?? []).compactMap { acc -> HubAccount? in
                guard let id = acc["id"] as? String, let driver = acc["driver"] as? String,
                      let limits = limits(acc["usageLimits"]) else { return nil }
                return HubAccount(
                    id: id, driver: driver,
                    email: nonEmpty(acc["email"]), plan: nonEmpty(acc["plan"]),
                    workspaceId: nonEmpty(acc["workspaceId"]), limits: limits)
            }
            return HubSource(id: id, label: (raw["label"] as? String) ?? id,
                             accounts: accounts, error: nonEmpty(raw["error"]))
        }
    }

    static func provider(_ raw: [String: Any]) -> ProviderStatus? {
        guard let instanceId = raw["instanceId"] as? String,
              let driver = raw["driver"] as? String else { return nil }
        let auth = raw["auth"] as? [String: Any] ?? [:]
        return ProviderStatus(
            instanceId: instanceId,
            driver: driver,
            displayName: nonEmpty(raw["displayName"]),
            enabled: raw["enabled"] as? Bool ?? false,
            installed: raw["installed"] as? Bool ?? false,
            status: raw["status"] as? String ?? "unknown",
            email: nonEmpty(auth["email"]),
            plan: nonEmpty(auth["label"]),
            workspaceId: nonEmpty(auth["workspaceId"]),
            accentColor: nonEmpty(raw["accentColor"]),
            limits: limits(raw["usageLimits"]))
    }

    static func limits(_ value: Any?) -> UsageLimits? {
        guard let raw = value as? [String: Any] else { return nil }
        let windows = (raw["windows"] as? [[String: Any]] ?? []).compactMap { w -> LimitWindow? in
            guard let id = w["id"] as? String, let used = (w["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
            return LimitWindow(
                id: id,
                kind: WindowKind(rawValue: w["kind"] as? String ?? "") ?? .other,
                label: (w["label"] as? String) ?? id,
                usedPercent: min(100, max(0, used)),
                resetsAt: date(w["resetsAt"]),
                durationMins: (w["windowDurationMins"] as? NSNumber)?.intValue)
        }
        let unavailable = raw["unavailable"] as? [String: Any]
        let credits = raw["resetCredits"] as? [String: Any]
        return UsageLimits(
            checkedAt: date(raw["checkedAt"]) ?? .distantPast,
            windows: windows,
            unavailableReason: unavailable?["reason"] as? String,
            unavailableMessage: nonEmpty(unavailable?["message"]),
            credentialFingerprint: nonEmpty(raw["credentialFingerprint"]),
            resetCredits: (credits?["availableCount"] as? NSNumber)?.intValue ?? 0,
            resetCreditsExpireAt: date(credits?["nextExpiresAt"]))
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    static func date(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }
}
