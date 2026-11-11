import AppKit
import XCTest
@testable import Threadbear
@testable import ThreadbearCore

/// The app pointed at its own runner on another Mac (runner.json's
/// `host`): the paths that runner sends are there, so reads go through
/// `files.read` and the copies cache, pictures go over as bytes, and what
/// needs the folders here says so. With the runner on this Mac, nothing
/// changes.
@MainActor
final class RemoteOwnRunnerAppTests: XCTestCase {
    private let local = RunnerEndpoint(url: URL(string: "ws://127.0.0.1:8797/rpc")!, token: "t")
    private let away = RunnerEndpoint(url: URL(string: "ws://mac-studio.example.ts.net:8797/rpc")!, token: "t")
    private let picture = "/Users/someone/Library/Application Support/Threadbear/threads/t1/media/shot.png"

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    override func tearDown() {
        RunnerPictures.shared.fetch = nil
        super.tearDown()
    }

    private func app(_ endpoint: RunnerEndpoint?) throws -> AppModel {
        let app = AppModel()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("own-runner-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        app.dataDir = dir
        app.runnerEndpoint = endpoint
        app.threads["t1"] = ThreadSummary(id: "t1", title: "Mine", cwd: "/Users/someone/dev/app")
        var other = ThreadSummary(id: "t2", title: "Bruce's", cwd: "/Users/bruce/dev")
        other.runnerId = "r-bruce"
        app.threads["t2"] = other
        return app
    }

    // MARK: The decision

    func testTheUsualRunnerReadsFromDiskAsBefore() throws {
        let app = try app(local)
        let mine = try XCTUnwrap(app.threads["t1"])
        XCTAssertFalse(app.runnerAway)
        XCTAssertEqual(app.fileSource(of: mine), .disk)
        XCTAssertFalse(app.filesAway(mine))
        XCTAssertNil(app.remoteImages(for: mine), "pictures read from disk")
        XCTAssertNil(app.awayName(of: mine))
        XCTAssertEqual(app.selfRunnerTitle, "This Mac")
        let file = URL(fileURLWithPath: picture)
        XCTAssertEqual(app.localCopy(of: file, in: mine), file, "the file itself")
        XCTAssertNil(RunnerPictures.shared.fetch, "icons read from disk")
        // Another runner's thread is still that runner's.
        XCTAssertEqual(app.fileSource(of: app.threads["t2"]), .runner("r-bruce"))
    }

    func testARemoteRunnersThreadsReadThroughIt() throws {
        let app = try app(away)
        app.runners = [RunnerInfo(id: "r-studio", name: "mac-studio", isSelf: true)]
        let mine = try XCTUnwrap(app.threads["t1"])
        XCTAssertTrue(app.runnerAway)
        XCTAssertEqual(app.fileSource(of: mine), .runner(away.filesKey))
        XCTAssertTrue(app.filesAway(mine))
        XCTAssertTrue(app.filesAway("not-listed"), "a thread not listed yet is the own runner's")
        XCTAssertEqual(app.awayName(of: mine), "mac-studio")
        XCTAssertEqual(app.selfRunnerTitle, "mac-studio", "not This Mac in the pickers")
        XCTAssertEqual(app.remoteImages(for: mine)?.name, "mac-studio", "transcript pictures are fetched")
        XCTAssertNil(app.localCopy(of: URL(fileURLWithPath: picture), in: mine), "never the path read as this Mac's")
        XCTAssertNotNil(RunnerPictures.shared.fetch, "project and patch icons are fetched")
        XCTAssertEqual(app.fileSource(of: app.threads["t2"]), .runner("r-bruce"))
    }

    func testTheRunnersNameFromItsHostBeforeTheRunnerListComes() throws {
        let app = try app(away)
        XCTAssertEqual(app.selfRunnerName, "mac-studio")
    }

    // MARK: Reads

    func testAPictureInAnOwnThreadComesThroughFilesRead() async throws {
        let app = try app(away)
        let transport = FilesTransport(png: Self.png())
        let client = RPCClient(transport: transport)
        try await client.start()
        app.useClientForTesting(client)
        let mine = try XCTUnwrap(app.threads["t1"])

        let copy = try await app.remoteCopy(picture, in: mine)
        XCTAssertEqual(transport.calls.map(\.method), ["files.read"])
        XCTAssertEqual(transport.calls.first?.params["path"] as? String, picture)
        XCTAssertNil(transport.calls.first?.params["runnerId"], "the own runner's own file")
        XCTAssertNotNil(NSImage(contentsOf: copy.url))
        XCTAssertTrue(copy.url.path.hasPrefix(app.dataDir.path), "a test app's copies stay in its data folder")
        // Ready now, for the grid and for drags.
        XCTAssertEqual(app.remoteImages(for: mine)?.ready(picture)?.url, copy.url)
        XCTAssertEqual(app.localCopy(of: URL(fileURLWithPath: picture), in: mine), copy.url)
    }

    /// The composer's strip draws a pasted picture from the runner's inbox
    /// copy, which is on the other Mac too.
    func testADraftPicturesThumbnailComesThroughTheRunner() async throws {
        let app = try app(away)
        let transport = FilesTransport(png: Self.png())
        let client = RPCClient(transport: transport)
        try await client.start()
        app.useClientForTesting(client)
        let inbox = "/Users/someone/Library/Application Support/Threadbear/inbox/\(UUID().uuidString).png"
        let image: CGImage? = await withCheckedContinuation { done in
            app.loadRunnerThumbnail(inbox, maxPixels: 64) { done.resume(returning: $0) }
        }
        XCTAssertNotNil(image)
        XCTAssertEqual(transport.calls.map(\.method), ["files.read"])
        XCTAssertEqual(transport.calls.first?.params["path"] as? String, inbox)
    }

    func testRemoteCopyRefusesAThreadWhoseFilesAreHere() async throws {
        let app = try app(local)
        let mine = try XCTUnwrap(app.threads["t1"])
        do {
            _ = try await app.remoteCopy(picture, in: mine)
            XCTFail("a local thread's file isn't fetched")
        } catch {}
    }

    func testProjectIconsComeThroughTheRunnerWhenItsAway() async throws {
        let store = RunnerPictures()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(UUID().uuidString).png")
        try Self.png().write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        var asked: [String] = []
        store.fetch = { path in
            asked.append(path)
            return file
        }
        let there = "/Users/someone/Library/Application Support/Threadbear/project-icons/abc.png"
        XCTAssertNil(store.image(at: there), "on its way")
        XCTAssertNil(store.image(at: there), "asked once")
        for _ in 0..<200 where store.image(at: there) == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(store.image(at: there))
        XCTAssertEqual(asked, [there])
    }

    func testProjectIconsReadFromDiskWithTheRunnerHere() throws {
        let store = RunnerPictures()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(UUID().uuidString).png")
        try Self.png().write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        XCTAssertNotNil(store.image(at: file.path), "straight away, as before")
        XCTAssertNil(store.image(at: "/no/such/icon.png"))
    }

    // MARK: Pictures sent

    func testAPastedPictureGoesAsBytesToARunnerOnAnotherMac() async throws {
        let app = try app(away)
        let transport = FilesTransport(png: Self.png())
        let client = RPCClient(transport: transport)
        try await client.start()
        app.useClientForTesting(client)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Screenshot \(UUID().uuidString).png")
        try Self.png().write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }

        let refs = await app.importImages([file])
        XCTAssertEqual(refs.count, 1)
        let call = try XCTUnwrap(transport.calls.first { $0.method == "media.import" })
        XCTAssertNil(call.params["path"], "a path here means nothing there")
        XCTAssertEqual((call.params["data"] as? String).flatMap { Data(base64Encoded: $0) }, Self.png())
        XCTAssertEqual(call.params["name"] as? String, file.lastPathComponent)
    }

    func testAPastedPictureGoesAsAPathToTheRunnerHere() async throws {
        let app = try app(local)
        let transport = FilesTransport(png: Self.png())
        let client = RPCClient(transport: transport)
        try await client.start()
        app.useClientForTesting(client)
        _ = await app.importImages([URL(fileURLWithPath: "/tmp/shot.png")])
        let call = try XCTUnwrap(transport.calls.first { $0.method == "media.import" })
        XCTAssertEqual(call.params["path"] as? String, "/tmp/shot.png")
        XCTAssertNil(call.params["data"])
    }

    // MARK: What can't work from here

    func testTheTerminalSaysWhereTheThreadIs() throws {
        // A folder that exists here too (the same user name on both Macs)
        // still isn't the thread's.
        let thread = ThreadSummary(id: "t1", title: "Mine", cwd: FileManager.default.temporaryDirectory.path)
        let target = TerminalTarget.for(thread) { _ in "mac-studio" }
        XCTAssertEqual(target.key, .home)
        XCTAssertEqual(target.note?.contains("on mac-studio"), true)
        XCTAssertEqual(TerminalTarget.for(thread) { _ in nil }.key, .thread("t1"), "with the runner here, as before")
    }

    func testNoStartRunnerForARunnerOnAnotherMac() throws {
        let app = try app(away)
        app.connection = .runnerDown("Could not connect to the server.")
        let banner = try XCTUnwrap(app.banner)
        XCTAssertFalse(banner.showStart, "no LaunchAgent here to start")
        XCTAssertTrue(banner.text.contains("mac-studio"))
        XCTAssertTrue(banner.detail?.contains("tailscale serve") == true)
    }

    static func png() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }
}

/// Answers `files.read` with a picture and `media.import` with an inbox
/// ref, and keeps what was asked.
private final class FilesTransport: RPCTransport, @unchecked Sendable {
    struct Call { var method: String; var params: [String: Any] }
    private let lock = NSLock()
    private let png: Data
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var recorded: [Call] = []

    init(png: Data) { self.png = png }

    var calls: [Call] { lock.withLock { recorded } }

    func open() async throws {}

    func send(_ text: String) async throws {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let id = object["id"] as? Int, let method = object["method"] as? String else { return }
        let params = object["params"] as? [String: Any] ?? [:]
        lock.withLock { recorded.append(Call(method: method, params: params)) }
        let result: [String: Any]
        switch method {
        case "files.read":
            result = ["path": params["path"] ?? "", "size": png.count, "modifiedAt": "2026-11-10T00:00:00.000Z",
                      "mediaType": "image/png", "data": png.base64EncodedString(), "truncated": false]
        case "media.import":
            result = ["image": ["path": "/Users/someone/Library/Application Support/Threadbear/inbox/x.png", "mediaType": "image/png", "width": 4, "height": 3]]
        default:
            result = [:]
        }
        push(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result]))
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !inbox.isEmpty {
                let data = inbox.removeFirst()
                lock.unlock()
                continuation.resume(returning: data)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func close() {}

    private func push(_ data: Data) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: data)
        } else {
            inbox.append(data)
            lock.unlock()
        }
    }
}
