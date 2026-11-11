import AppKit
import SwiftUI
import ThreadbearCore

/// A project's icon (docs/protocol.md, "Icons"): the picture the librarian
/// found in its folders, else its SF Symbol, else the title's first letter
/// in a quiet tile. `size` is in points before zoom.
struct ProjectIconView: View {
    let project: Project?
    /// The title to take a letter from when there's no project to hand
    /// (a chip from a summary the list hasn't caught up with).
    var title: String = ""
    let size: CGFloat

    var body: some View {
        let side = zoomed(size)
        Group {
            if let path = project?.icon?.image?.path, let image = ProjectIconImages.image(at: path) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
            } else if let symbol = project?.icon?.symbol, ProjectIconImages.symbolExists(symbol) {
                Image(systemName: symbol)
                    .font(.system(size: side * 0.78, weight: .regular))
                    .foregroundStyle(.secondary)
            } else {
                Text(letter)
                    .font(.system(size: side * 0.62, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: side, height: side)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: side * 0.26, style: .continuous))
            }
        }
        .frame(width: side, height: side)
    }

    private var letter: String { ProjectMark.letter(project?.title ?? title) }
}

/// Pictures read once per path. Each copy the runner makes has its own
/// name (the file's hash is in it), so a changed icon is a new path and
/// nothing here goes stale. With the runner on another Mac the path is
/// there, so it comes through RunnerPictures.
@MainActor
enum ProjectIconImages {
    private static var symbols: [String: Bool] = [:]

    static func image(at path: String) -> NSImage? {
        RunnerPictures.shared.image(at: path)
    }

    /// A symbol from a newer macOS (or a typo an agent made) draws nothing,
    /// so check first.
    static func symbolExists(_ name: String) -> Bool {
        if let known = symbols[name] { return known }
        let exists = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        symbols[name] = exists
        return exists
    }
}

/// Pictures the app's own runner names outside a thread's transcript:
/// project icons and patch icons (`iconFile`). Read once per path from
/// this Mac's disk, or, while that runner is on another Mac (runner.json's
/// `host`, AppModel.runnerAwayChanged), fetched once through it
/// (`files.read`, kept in RemoteFileCache) and drawn when it comes.
/// Observable, so a view that asked before the copy came draws it then.
@MainActor
@Observable
final class RunnerPictures {
    static let shared = RunnerPictures()

    private var images: [String: NSImage] = [:]
    @ObservationIgnored private var missing: Set<String> = []
    @ObservationIgnored private var fetching: Set<String> = []

    /// This Mac's copy of a path on the runner's Mac; nil while the runner
    /// is here and paths are read as they are. Changing it forgets what
    /// was read, which was from the other place.
    @ObservationIgnored var fetch: (@MainActor (String) async throws -> URL)? {
        didSet {
            images = [:]
            missing = []
            fetching = []
        }
    }

    /// The picture at `path`, or nil when there's none (or it's still on
    /// its way: then the view is drawn again once it's here).
    func image(at path: String) -> NSImage? {
        if let image = images[path] { return image }
        if missing.contains(path) { return nil }
        guard let fetch else {
            guard let image = Self.read(URL(fileURLWithPath: path)) else {
                missing.insert(path)
                return nil
            }
            images[path] = image
            return image
        }
        guard fetching.insert(path).inserted else { return nil }
        Task { [weak self] in
            let image = (try? await fetch(path)).flatMap(Self.read)
            guard let self, self.fetching.remove(path) != nil else { return }
            if let image { self.images[path] = image } else { self.missing.insert(path) }
        }
        return nil
    }

    private static func read(_ url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        return image
    }
}
