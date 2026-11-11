import AppKit

/// A patch's picture icon (`iconFile`): an image file, or a .app's own icon
/// from the Finder. Kept once read, since the rail and every chip ask on
/// each redraw; a file that can't be read is nil and the symbol shows.
@MainActor
enum PatchImage {
    private static var cache: [String: NSImage?] = [:]

    static func image(_ path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        // With the runner on another Mac the file is there: fetched through
        // it (RunnerPictures). A .app there has no icon to ask the Finder
        // for here, so the symbol shows.
        if RunnerPictures.shared.fetch != nil {
            return path.hasSuffix(".app") ? nil : RunnerPictures.shared.image(at: path)
        }
        if let hit = cache[path] { return hit }
        let image: NSImage? = path.hasSuffix(".app") ? NSWorkspace.shared.icon(forFile: path) : NSImage(contentsOfFile: path)
        cache[path] = image
        return image
    }
}
