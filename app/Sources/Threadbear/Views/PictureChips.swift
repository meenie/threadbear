import AppKit
import ThreadbearCore

/// A picture's chip among the words (docs/protocol.md, "Pictures in a
/// message"): a small rounded tag with the picture and "Picture N", the
/// marker the agent gets, so Mike can point at two or more pictures in one
/// message (1 Nov 2026, after T3 Code's). The composer's has the picture's
/// thumbnail; his bubble's has the photo symbol, as the pictures show over
/// the words there.
enum PictureChip {
    static func label(_ number: Int) -> String { "Picture \(number)" }

    /// Sizes from the font of the words around the chip, so it follows the
    /// zoom.
    struct Metrics {
        let font: NSFont
        let labelFont: NSFont
        let height: CGFloat
        let icon: CGFloat
        let gap: CGFloat
        let trailing: CGFloat
        let radius: CGFloat

        init(font: NSFont) {
            self.font = font
            labelFont = .systemFont(ofSize: (font.pointSize * 0.87).rounded())
            height = (labelFont.ascender - labelFont.descender).rounded(.up) + (font.pointSize * 0.27).rounded()
            icon = height - (font.pointSize * 0.4).rounded()
            gap = (height * 0.25).rounded()
            trailing = (height * 0.35).rounded()
            radius = (height * 0.28).rounded()
        }

        /// The thumbnail's inset from the chip's edges, the same on three sides.
        var inset: CGFloat { ((height - icon) / 2).rounded() }

        func labelText(_ number: Int, dimmed: Bool = false) -> NSAttributedString {
            NSAttributedString(string: PictureChip.label(number), attributes: [
                .font: labelFont,
                .foregroundColor: dimmed ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor,
            ])
        }

        func size(_ number: Int) -> NSSize {
            NSSize(width: (inset + icon + gap + labelText(number).size().width + trailing).rounded(.up), height: height)
        }

        /// Where the chip's bottom sits under the baseline: centred on the
        /// capitals beside it, as the transcript's symbols are.
        var baselineOffset: CGFloat { ((font.capHeight - height) / 2).rounded() }
    }

    static let fill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.06)
    }

    /// Draws a chip filling `rect`, in a flipped context or not. With no
    /// thumbnail it shows the photo symbol (the transcript, or while the
    /// thumbnail is still being read).
    static func draw(in rect: NSRect, number: Int, thumbnail: CGImage?, metrics: Metrics, dimmed: Bool = false) {
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: metrics.radius, yRadius: metrics.radius)
        fill.setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 0.5
        shape.stroke()

        let icon = NSRect(x: rect.minX + metrics.inset, y: rect.midY - metrics.icon / 2, width: metrics.icon, height: metrics.icon)
        if let thumbnail {
            NSGraphicsContext.saveGraphicsState()
            let corner = max(2, (metrics.icon * 0.18).rounded())
            NSBezierPath(roundedRect: icon, xRadius: corner, yRadius: corner).addClip()
            // Filled into the square from the picture's middle.
            let width = CGFloat(thumbnail.width), height = CGFloat(thumbnail.height)
            let side = min(width, height)
            let crop = NSRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side)
            NSImage(cgImage: thumbnail, size: NSSize(width: width, height: height))
                .draw(in: icon, from: crop, operation: .sourceOver, fraction: dimmed ? 0.5 : 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        } else if let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: label(number))?
            .withSymbolConfiguration(.init(pointSize: metrics.icon * 0.78, weight: .regular)) {
            let size = symbol.size
            let tinted = NSImage(size: size, flipped: false) { box in
                // The colour cut to the symbol's shape, as RowRenderer's symbols are.
                NSColor.secondaryLabelColor.set()
                box.fill(using: .copy)
                symbol.draw(in: box, from: .zero, operation: .destinationIn, fraction: 1)
                return true
            }
            let box = NSRect(x: icon.midX - size.width / 2, y: icon.midY - size.height / 2, width: size.width, height: size.height)
            tinted.draw(in: box.integral, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.5 : 1, respectFlipped: true, hints: nil)
        }

        let label = metrics.labelText(number, dimmed: dimmed)
        // The point is the line box's top-left in a flipped context and its
        // bottom-left otherwise, so midY less half the height centres it
        // either way.
        let y = rect.midY - label.size().height / 2
        label.draw(at: NSPoint(x: icon.maxX + metrics.gap, y: y.rounded()))
    }

    /// Mike's bubble: the chip as an attachment that draws itself, with
    /// the photo symbol (main thread or not; it draws when shown).
    static func attachment(number: Int, font: NSFont) -> NSTextAttachment {
        let metrics = Metrics(font: font)
        let size = metrics.size(number)
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, number: number, thumbnail: nil, metrics: metrics)
            return true
        }
        attachment.bounds = NSRect(x: 0, y: metrics.baselineOffset, width: size.width, height: size.height)
        return attachment
    }
}

/// A picture in the composer's words, the attachment behind a U+FFFC mark
/// (InlinePictures). It carries its picture, so the draft can be read
/// straight off the text: the k-th chip is the k-th picture.
final class PictureAttachment: NSTextAttachment {
    /// Nil while the runner is still copying it in (`media.import`).
    var picture: ImageRef?
    /// The file it came from, for the thumbnail meanwhile.
    let source: String
    /// Its place among the box's pictures, set as the words change.
    var number = 1
    private(set) var thumbnail: CGImage?
    /// The text view to redraw once the thumbnail is in.
    weak var owner: NSTextView?

    static let thumbnailPixels = 96

    init(picture: ImageRef?, source: String) {
        self.picture = picture
        self.source = source
        super.init(data: nil, ofType: nil)
        let cell = PictureChipCell()
        attachmentCell = cell
        cell.attachment = self
        // The file pasted here while it's copied in; after, the runner's
        // copy, which is fetched when the runner is on another Mac.
        let path = picture?.path ?? source
        thumbnail = ThumbnailLoader.shared.cached(path: path, maxPixels: Self.thumbnailPixels)
        if thumbnail == nil {
            let done: @MainActor (CGImage?) -> Void = { [weak self] image in
                guard let self, let image else { return }
                self.thumbnail = image
                self.owner?.needsDisplay = true
            }
            if picture != nil {
                MainActor.assumeIsolated { AppModel.shared.loadRunnerThumbnail(path, maxPixels: Self.thumbnailPixels, completion: done) }
            } else {
                ThumbnailLoader.shared.load(path: path, maxPixels: Self.thumbnailPixels, completion: done)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not coded") }
}

/// Draws a `PictureAttachment` in the composer (TextKit 1).
final class PictureChipCell: NSTextAttachmentCell {
    private var picture: PictureAttachment? { attachment as? PictureAttachment }
    private var metrics: PictureChip.Metrics { PictureChip.Metrics(font: ComposerTextField.font) }

    override func cellSize() -> NSSize { metrics.size(picture?.number ?? 1) }

    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: metrics.baselineOffset) }

    // A click puts the cursor beside it, as on a word, rather than
    // dragging the attachment off.
    override func wantsToTrackMouse() -> Bool { false }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        PictureChip.draw(in: cellFrame, number: picture?.number ?? 1, thumbnail: picture?.thumbnail,
                         metrics: metrics, dimmed: picture?.picture == nil)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }
}
