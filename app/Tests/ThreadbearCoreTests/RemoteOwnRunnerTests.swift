import Foundation
import XCTest
@testable import ThreadbearCore

/// The app's own runner on another Mac (runner.json's `host`, reached
/// through `tailscale serve`): whether it's remote, and where a file a
/// thread names is read from then.
final class RemoteOwnRunnerTests: XCTestCase {
    func testOnlyLoopbackIsThisMac() {
        for host in ["127.0.0.1", "localhost", "LOCALHOST", "localhost.", "::1", "[::1]", " 127.0.0.1 "] {
            XCTAssertFalse(RunnerConfig.isRemote(host: host), host)
        }
        for host in ["mac-studio.snowshoe-bebop.ts.net", "mac-studio", "100.101.102.103", "192.168.1.20", "fd7a:115c:a1e0::1", "127.0.0.2"] {
            XCTAssertTrue(RunnerConfig.isRemote(host: host), host)
        }
    }

    func testEndpointFromRunnerJSON() throws {
        let local = try RunnerConfig.endpoint(dataDir: try dataDir(json: nil))
        XCTAssertEqual(local.host, "127.0.0.1")
        XCTAssertFalse(local.isRemote, "no runner.json: the runner on this Mac")

        let away = try RunnerConfig.endpoint(dataDir: try dataDir(json: #"{ "host": "mac-studio.snowshoe-bebop.ts.net", "port": 8797 }"#))
        XCTAssertEqual(away.url.absoluteString, "ws://mac-studio.snowshoe-bebop.ts.net:8797/rpc")
        XCTAssertEqual(away.host, "mac-studio.snowshoe-bebop.ts.net")
        XCTAssertTrue(away.isRemote)
        XCTAssertEqual(away.filesKey, "own-mac-studio.snowshoe-bebop.ts.net-8797")

        let six = try RunnerConfig.endpoint(dataDir: try dataDir(json: #"{ "host": "::1" }"#))
        XCTAssertEqual(six.url.absoluteString, "ws://[::1]:8797/rpc", "an IPv6 host is bracketed rather than crashing")
        XCTAssertFalse(six.isRemote)
    }

    func testWhereFilesAreRead() {
        let local = RunnerEndpoint(url: URL(string: "ws://127.0.0.1:8797/rpc")!, token: "t")
        let away = RunnerEndpoint(url: URL(string: "ws://mac-studio.example.ts.net:8797/rpc")!, token: "t")
        // The usual runner on this Mac: exactly as before.
        XCTAssertEqual(FileSource.of(threadRunnerId: nil, ownRunner: local), .disk)
        XCTAssertEqual(FileSource.of(threadRunnerId: nil, ownRunner: nil), .disk, "before the endpoint is known")
        XCTAssertEqual(FileSource.of(threadRunnerId: "r-bruce", ownRunner: local), .runner("r-bruce"))
        // The own runner on another Mac: its files come through it.
        XCTAssertEqual(FileSource.of(threadRunnerId: nil, ownRunner: away), .runner(away.filesKey))
        XCTAssertEqual(FileSource.of(threadRunnerId: "r-bruce", ownRunner: away), .runner("r-bruce"), "another runner's are still its own")
    }

    private func dataDir(json: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("own-runner-\(UUID().uuidString)", isDirectory: true)
        let tokenDir = dir.appendingPathComponent("secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: tokenDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try "token\n".write(to: tokenDir.appendingPathComponent("runner-token"), atomically: true, encoding: .utf8)
        if let json { try json.write(to: dir.appendingPathComponent("runner.json"), atomically: true, encoding: .utf8) }
        return dir
    }
}
