import Foundation

/// Finds the local T3 Code server from the runtime file it writes on start.
enum ServerLocator {
    static var t3Home: URL {
        if let custom = ProcessInfo.processInfo.environment["T3CODE_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3")
    }

    static var runtimeFile: URL { t3Home.appendingPathComponent("userdata/server-runtime.json") }

    /// The server's origin, or nil when T3 Code is not running.
    static func origin() -> URL? {
        guard let data = try? Data(contentsOf: runtimeFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let origin = json["origin"] as? String, let url = URL(string: origin) else { return nil }
        if let pid = (json["pid"] as? NSNumber)?.int32Value, pid > 0, kill(pid, 0) != 0, errno != EPERM {
            return nil
        }
        return url
    }

    /// The `t3` command line tool, which can issue access tokens for the running server.
    static func cli() -> URL? {
        let candidates = [
            t3Home.appendingPathComponent("bin/t3").path,
            "/opt/homebrew/bin/t3",
            "/usr/local/bin/t3",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}
