import AppKit
import ThreadbearCore

/// Pictures, long tool output and file links in another runner's thread
/// are paths on that Mac (docs/protocol.md, "Other runners' threads"). The
/// app gets each with `files.read` on that runner's connection, keeps a
/// copy (RemoteFileCache), and then uses the copy exactly as it would a
/// file of its own. The app's own runner's threads come here too when
/// that runner is on another Mac (runner.json's `host`, `fileSource(of:)`);
/// with the usual runner on this Mac their paths are local and never do.
@MainActor
final class RemoteFileStore {
    let cache: RemoteFileCache
    /// One fetch per file at a time, however many views ask.
    private var inFlight: [String: Task<RemoteFileCache.Copy, Error>] = [:]

    init(root: URL) {
        cache = RemoteFileCache(root: root)
    }

    /// The copy, if it can be used without asking that runner (fetched or
    /// checked since launch).
    func ready(_ path: String, runnerId: String) -> RemoteFileCache.Copy? {
        cache.ready(runnerId: runnerId, path: path)
    }

    /// The copy, fetching or checking it first as the cache says.
    func copy(_ path: String, runnerId: String, client: @escaping () async throws -> RPCClient) async throws -> RemoteFileCache.Copy {
        let key = runnerId + "\u{0}" + path
        if let pending = inFlight[key] { return try await pending.value }
        let cache = cache
        let task = Task { () throws -> RemoteFileCache.Copy in
            try await cache.copy(runnerId: runnerId, path: path) { known in
                try await client().readFile(path: path, known: known)
            }
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// Where the copies go: the app's cache folder for Mike's own app, and
    /// inside the data folder for a dev or scripted app on a dev runner or
    /// the mock, so those never mix with his (and go when it's deleted).
    static func root(dataDir: URL) -> URL {
        if dataDir.standardizedFileURL.path == RunnerConfig.defaultDataDir.standardizedFileURL.path {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
            return caches.appendingPathComponent("Threadbear/remote", isDirectory: true)
        }
        return dataDir.appendingPathComponent("app-remote-files", isDirectory: true)
    }
}

/// The transcript's picture grids get their pictures through this: the
/// copy straight away when there is one, else a fetch that calls back.
struct RemoteImages {
    /// "bruce", for the tile's words.
    let name: String
    let ready: (String) -> RemoteFileCache.Copy?
    let fetch: (String, @escaping (Result<RemoteFileCache.Copy, Error>) -> Void) -> Void
}

extension AppModel {
    /// The app's own runner is on another Mac (runner.json's `host` isn't
    /// this Mac's loopback): its threads' folders and files are there.
    var runnerAway: Bool { runnerEndpoint?.isRemote == true }

    /// Where a file `thread` names is read from: another runner's from it,
    /// the own runner's from disk, or from that runner when it's away. Nil
    /// is the own runner with no thread (a project's icon, a patch's).
    func fileSource(of thread: ThreadSummary?) -> FileSource {
        FileSource.of(threadRunnerId: thread?.runnerId, ownRunner: runnerEndpoint)
    }

    /// Whether `thread`'s files are on another Mac, so they're fetched
    /// rather than read here, and nothing here opens its folder.
    func filesAway(_ thread: ThreadSummary) -> Bool { !fileSource(of: thread).isDisk }

    /// The same by id; a thread the app doesn't list is the own runner's.
    func filesAway(_ threadId: String) -> Bool { threads[threadId].map(filesAway) ?? runnerAway }

    /// The own runner's name ("mac-studio"): what the runner list calls
    /// it, else the first part of runner.json's host. For "This Mac" in
    /// the pickers, which isn't true of a runner on another Mac.
    var selfRunnerName: String {
        if let name = runners.first(where: \.isSelf)?.name, !name.isEmpty { return name }
        let host = runnerEndpoint?.host ?? ""
        return host.split(separator: ".").first.map(String.init) ?? "This Mac"
    }

    /// "This Mac" for the runner picker's own entry, or its name while
    /// it's on another Mac.
    var selfRunnerTitle: String { runnerAway ? selfRunnerName : "This Mac" }

    /// The Mac `thread`'s files are on, by name, when it isn't this one.
    func awayName(of thread: ThreadSummary) -> String? {
        if thread.isRemote { return runnerName(of: thread) }
        return runnerAway ? selfRunnerName : nil
    }

    /// The runner went from this Mac to another or back: copies of its
    /// files replace reads from disk, and pictures read already go.
    func runnerAwayChanged() {
        guard runnerAway else {
            RunnerPictures.shared.fetch = nil
            return
        }
        RunnerPictures.shared.fetch = { @MainActor [weak self] (path: String) async throws -> URL in
            guard let self else { throw RPCError.disconnected(nil) }
            return try await self.ownRunnerCopy(path)
        }
    }

    /// This Mac's copy of a file on the own runner's Mac, for what has no
    /// thread (project and patch icons).
    func ownRunnerCopy(_ path: String) async throws -> URL {
        guard case .runner(let key) = fileSource(of: nil) else { return URL(fileURLWithPath: path) }
        let copy = try await remoteFiles.copy(path, runnerId: key) { [weak self] in
            guard let client = self?.client else { throw RPCError.disconnected(nil) }
            return client
        }
        return copy.url
    }

    /// A folder on the own runner's Mac while it's away, typed in, as a
    /// picker here would only show this Mac's folders. Nil for Cancel.
    func askRunnerFolder(_ message: String, current: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "Its full path on \(selfRunnerName), like \(defaults.cwd.isEmpty ? "/Users/you/dev" : defaults.cwd)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = current
        field.placeholderString = defaults.cwd
        alert.accessoryView = field
        alert.addButton(withTitle: "Use")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let folder = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return folder.isEmpty ? nil : folder
    }

    var remoteFiles: RemoteFileStore {
        if let remoteFileStore { return remoteFileStore }
        let store = RemoteFileStore(root: RemoteFileStore.root(dataDir: dataDir))
        remoteFileStore = store
        return store
    }

    /// This Mac's copy of a file in another runner's thread, fetched
    /// through that runner (connecting to it if need be).
    func remoteCopy(_ path: String, in thread: ThreadSummary) async throws -> RemoteFileCache.Copy {
        guard case .runner(let runnerId) = fileSource(of: thread) else {
            // Never for a thread whose files are here.
            throw RPCError.badResponse("not a thread on another Mac")
        }
        let threadId = thread.id
        // Through Convex the files stay on that machine: this Mac's runner
        // would read its own file at that path, which isn't the one meant.
        if thread.isRemote, viaRelay(threadId) {
            throw RPCError.server(code: -32000, message: "This file is kept on \(runnerName(of: thread) ?? "the other machine"). Turn on Connect to other machines directly in Settings > Runners to open it here.")
        }
        return try await remoteFiles.copy(path, runnerId: runnerId) { [weak self] in
            guard let self else { throw RPCError.disconnected(nil) }
            return try await self.openClient(for: threadId)
        }
    }

    /// The picture source for a remote thread's transcript; nil for this
    /// Mac's own.
    func remoteImages(for thread: ThreadSummary) -> RemoteImages? {
        guard case .runner(let runnerId) = fileSource(of: thread), let name = awayName(of: thread) else { return nil }
        return RemoteImages(
            name: name,
            ready: { [weak self] path in self?.remoteFiles.ready(path, runnerId: runnerId) },
            fetch: { [weak self] path, done in
                guard let self else { return }
                Task {
                    do { done(.success(try await self.remoteCopy(path, in: thread))) } catch { done(.failure(error)) }
                }
            }
        )
    }

    /// Why a fetch failed, in words for a tooltip.
    static func remoteFileReason(_ error: Error) -> String {
        if let unreachable = error as? RemoteUnreachable { return unreachable.headline + " " + unreachable.detail }
        return error.localizedDescription
    }

    /// What `files.read` answers for a folder (runner/src/files.ts).
    static func isFolderError(_ error: Error) -> Bool {
        if case RPCError.server(_, let message) = error { return message.hasPrefix("Not a file") }
        return false
    }

    /// The home folder on that Mac, for a `~/` path in its thread: from the
    /// thread's folder or that runner's default one when either is under
    /// /Users, else this Mac's (the runner expands `~` itself anyway).
    func remoteHome(of thread: ThreadSummary) -> String {
        let candidates = [thread.cwd, thread.runnerId.map { remoteLogins[$0]?.defaults.cwd ?? "" } ?? defaults.cwd]
        for folder in candidates {
            let parts = folder.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0] == "Users" { return "/Users/" + parts[1] }
        }
        return NSHomeDirectory()
    }

    /// A file in another runner's thread, opened as `action` says once
    /// it's here. The pane shows it loading, then the copy; a failure says
    /// so there, or in the banner for the other ways of opening it. A
    /// plain click (`automatic`) previews it in the pane whatever it is:
    /// a copy opened in an editor would look like the real file. `from` is
    /// the section it opens over, when that isn't the one the thread
    /// would pick (the rail's Files panel).
    func openRemoteFile(_ url: URL, _ action: FileLinkAction, in thread: ThreadSummary, title: String? = nil, back: [PanePreview] = [], from: PaneSection? = nil) {
        let path = url.path
        let name = awayName(of: thread) ?? "another Mac"
        let title = title ?? (path as NSString).lastPathComponent
        switch action {
        case .panel, .automatic:
            // The pane belongs to a thread; on a project page there's none.
            guard openProjectId == nil else { return openRemoteFile(url, .app, in: thread, title: title) }
            var preview = PanePreview(target: .remote(path: path, failed: nil), title: title, from: from ?? paneSection(for: thread))
            preview.away = name
            preview.remotePath = path
            preview.back = back
            show(preview, in: thread.id)
            let opened = panePreview[thread.id]?.opened
            Task {
                let result: Result<RemoteFileCache.Copy, Error>
                do { result = .success(try await remoteCopy(path, in: thread)) } catch { result = .failure(error) }
                // Unless Mike has opened something else meanwhile.
                guard var current = panePreview[thread.id], current.opened == opened, case .remote = current.target else { return }
                switch result {
                case .success(let copy):
                    // A page keeps the ?query and #fragment it was linked with.
                    if url.query != nil || url.fragment != nil, PreviewRules.viewer(forPath: path) == .web {
                        current.target = .page(FilePathRefs.withQuery(copy.url, query: url.query, fragment: url.fragment))
                    } else {
                        current.target = .file(copy.path)
                    }
                    current.cut = copy.truncated
                case .failure(let error) where Self.isFolderError(error):
                    // A link to a folder there: `files.read` won't, so browse it.
                    current.target = .folder(path)
                case .failure(let error):
                    AppLog.write("rpc", "files.read \(path) on \(name) failed: \(error.localizedDescription)")
                    current.target = .remote(path: path, failed: Self.remoteFileReason(error))
                }
                panePreview[thread.id] = current
            }
        case .app, .finder:
            // It can take a while over the network, and a menu or a row has
            // nothing to spin. A second click on the same file does nothing.
            whileBusy(BusyKey.fetching(path, runner: thread.runnerId, action: action), note: "Getting \(title) from \(name)…") { [self] in
                do {
                    let copy = try await remoteCopy(path, in: thread)
                    if action == .finder {
                        revealInFinder(copy.path)
                    } else {
                        // Never a program: that Mac chose what the file is.
                        openExternally(url.query != nil || url.fragment != nil ? FilePathRefs.withQuery(copy.url, query: url.query, fragment: url.fragment) : copy.url,
                                       from: copyOrigin(of: thread))
                    }
                } catch where Self.isFolderError(error) && openProjectId == nil {
                    // Nothing here to open it in: the pane can browse it.
                    openRemoteFile(url, .panel, in: thread, title: title)
                } catch {
                    AppLog.write("rpc", "files.read \(path) on \(name) failed: \(error.localizedDescription)")
                    errorMessage = "Couldn't get \(title) from \(name). \(Self.remoteFileReason(error))"
                }
            }
        }
    }
}
