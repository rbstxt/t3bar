import Foundation

/// A read-only (`orchestration:read`) bearer token for the local T3 Code server.
/// Issued with the `t3` CLI and kept in a file only the user can read.
enum TokenStore {
    enum IssueError: LocalizedError {
        case cliMissing
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cliMissing: "t3 コマンドが見つかりません（~/.t3/bin/t3）"
            case .failed(let detail): "トークンを発行できませんでした: \(detail)"
            }
        }
    }

    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("T3Bar", isDirectory: true)
        return dir.appendingPathComponent("token")
    }

    static func load() -> String? {
        guard let s = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let token = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func clear() {
        try? FileManager.default.removeItem(at: file)
    }

    static func issue() async throws -> String {
        guard let cli = ServerLocator.cli() else { throw IssueError.cliMissing }
        let output = try await Task.detached(priority: .utility) { () throws -> String in
            let process = Process()
            process.executableURL = cli
            process.arguments = [
                "auth", "session", "issue",
                "--scope", "orchestration:read",
                "--ttl", "365d",
                "--label", "T3Bar",
                "--token-only",
            ]
            var env = ProcessInfo.processInfo.environment
            env["NO_COLOR"] = "1"
            process.environment = env
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw IssueError.failed(message?.isEmpty == false ? message! : "exit \(process.terminationStatus)")
            }
            return String(data: data, encoding: .utf8) ?? ""
        }.value

        // The token is the last non-empty line; anything before it is CLI chatter.
        guard let token = output.split(whereSeparator: \.isNewline).last.map({ $0.trimmingCharacters(in: .whitespaces) }),
              !token.isEmpty, !token.contains(" ") else {
            throw IssueError.failed("空の応答")
        }
        try save(token)
        return token
    }

    private static func save(_ token: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        fm.createFile(atPath: file.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
    }
}
