import Foundation

/// Where the runner listens and the token to use, read from the runner's
/// data folder (`runner.json` and `secrets/runner-token`).
public struct RunnerEndpoint: Sendable, Equatable {
    public var url: URL
    public var token: String

    public init(url: URL, token: String) {
        self.url = url
        self.token = token
    }

    /// The host the app dials: runner.json's `host`, 127.0.0.1 by default.
    public var host: String { url.host.map(RunnerConfig.bareHost) ?? "127.0.0.1" }

    /// The runner is on another Mac (runner.json's `host` is a tailnet name
    /// or an address, reached through `tailscale serve`): the paths it sends
    /// (pictures, blobs, project icons, file links, thread folders) are on
    /// that Mac, not this one. Anything but this Mac's loopback names.
    public var isRemote: Bool { RunnerConfig.isRemote(host: host) }

    /// What the app's copies of that runner's files are kept under in the
    /// cache (RemoteFileCache's `runnerId`), apart from other runners' and
    /// from another runner.json pointing somewhere else.
    public var filesKey: String { "own-\(host)-\(url.port ?? RunnerConfig.defaultPort)" }
}

/// Where the app reads a file a thread or project names: this Mac's disk,
/// or `files.read` on a runner (docs/protocol.md, "Other runners' threads"),
/// keyed for RemoteFileCache.
public enum FileSource: Sendable, Equatable {
    case disk
    case runner(String)

    /// Another runner's thread reads from that runner (`threadRunnerId`).
    /// The app's own runner's threads, and things with no thread (a
    /// project's icon, a patch's), read from disk, unless that runner is
    /// on another Mac (`ownRunner` remote): then from it.
    public static func of(threadRunnerId: String?, ownRunner: RunnerEndpoint?) -> FileSource {
        if let threadRunnerId { return .runner(threadRunnerId) }
        if let ownRunner, ownRunner.isRemote { return .runner(ownRunner.filesKey) }
        return .disk
    }

    public var isDisk: Bool { self == .disk }
}

public enum RunnerConfig {
    public static let defaultPort = 8797
    public static let launchdLabel = "com.mikerosoft.threadbear.runner"

    public static var defaultDataDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Threadbear", isDirectory: true)
    }

    /// The data folder: `--data-dir <path>`, then `THREADBEAR_DATA_DIR`, then
    /// the default. The override is how the mock runner and tests stay away
    /// from the real one.
    public static func dataDir(arguments: [String] = CommandLine.arguments, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let index = arguments.firstIndex(of: "--data-dir"), index + 1 < arguments.count {
            return URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let path = environment["THREADBEAR_DATA_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return defaultDataDir
    }

    /// Whether `host` is another Mac's: anything but 127.0.0.1, localhost
    /// and ::1 (case, a trailing dot and IPv6 brackets aside).
    public static func isRemote(host: String) -> Bool {
        let bare = bareHost(host).lowercased()
        return !["127.0.0.1", "localhost", "::1", ""].contains(bare)
    }

    static func bareHost(_ host: String) -> String {
        var bare = host.trimmingCharacters(in: .whitespaces)
        if bare.hasPrefix("["), bare.hasSuffix("]") { bare = String(bare.dropFirst().dropLast()) }
        if bare.hasSuffix(".") { bare.removeLast() }
        return bare
    }

    public enum LoadError: Error, Equatable, LocalizedError {
        case missingToken(String)
        case badHost(String)

        public var errorDescription: String? {
            switch self {
            case .missingToken(let path): return "There's no runner token at \(path) yet."
            case .badHost(let host): return "runner.json's host \"\(host)\" isn't one the app can reach."
            }
        }
    }

    public static func endpoint(dataDir: URL) throws -> RunnerEndpoint {
        var host = "127.0.0.1"
        var port = defaultPort
        let configURL = dataDir.appendingPathComponent("runner.json")
        if let data = try? Data(contentsOf: configURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let value = object["port"] as? Int { port = value }
            if let value = object["host"] as? String, !value.isEmpty { host = value }
        }
        let tokenURL = dataDir.appendingPathComponent("secrets/runner-token")
        guard let raw = try? String(contentsOf: tokenURL, encoding: .utf8) else {
            throw LoadError.missingToken(tokenURL.path)
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw LoadError.missingToken(tokenURL.path) }
        // An IPv6 address goes in brackets, or the URL can't be made.
        let dialled = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let url = URL(string: "ws://\(dialled):\(port)/rpc") else { throw LoadError.badHost(host) }
        return RunnerEndpoint(url: url, token: token)
    }
}

/// Reconnect delays: 0.25 s doubling to a 10 s ceiling.
public struct Backoff: Sendable {
    public var attempt = 0
    public var base: Double
    public var ceiling: Double

    public init(base: Double = 0.25, ceiling: Double = 10) {
        self.base = base
        self.ceiling = ceiling
    }

    public mutating func next() -> Double {
        defer { attempt += 1 }
        return min(ceiling, base * pow(2, Double(attempt)))
    }

    public mutating func reset() { attempt = 0 }
}
