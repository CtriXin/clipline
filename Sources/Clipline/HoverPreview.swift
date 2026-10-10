import AppKit
import SwiftUI

/// Resting the pointer on a card shows it large, just below the line: the
/// full text of a clip at a readable size, or a bigger picture. It lives in
/// its own window so it is not clipped by the line's thin strip.
@MainActor
final class HoverPreview {
    private let panel: NSPanel
    private var shownURL: URL?
    private var host: NSHostingView<AnyView>?
    private var model: PreviewModel?

    fileprivate static let maxBody = CGSize(width: 432, height: 290)

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
    }

    /// Shows the preview for a card, below `card` (screen coordinates), with
    /// its pointer at `cardX`.
    func show(_ url: URL, below card: CGRect, pointingAt cardX: CGFloat, on screen: NSScreen) {
        if shownURL != url {
            guard let model = Self.model(for: url) else { return hide() }
            self.model = model
            let host = NSHostingView(rootView: AnyView(PreviewView(model: model, caretX: nil)))
            host.sizingOptions = [.intrinsicContentSize]
            panel.contentView = host
            panel.setContentSize(host.fittingSize)
            self.host = host
            shownURL = url
        }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        var x = cardX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = max(card.minY - 4 - size.height, visible.minY + 8)
        // The pointer stays over the card even when the screen edge pushes
        // the preview aside.
        if let model, let host {
            host.rootView = AnyView(PreviewView(model: model, caretX: cardX - x))
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        shownURL = nil
        model = nil
        panel.orderOut(nil)
    }

    private static func model(for url: URL) -> PreviewModel? {
        let pinned = url.scheme == "clipline-pin"
        if Clips.isText(url) || pinned {
            let pin = pinned ? url.host.flatMap(UUID.init(uuidString:)).flatMap { id in Bag.shared.pins.first { $0.id == id } } : nil
            guard let raw = pinned ? pin?.text : Clips.text(of: url) else { return nil }
            // Keys show in full only while Option is held.
            let (text, hidden) = NSEvent.modifierFlags.contains(.option) ? (raw, false) : Secrets.mask(raw)
            let limit = 1500
            return PreviewModel(
                kind: Clips.link(of: url) != nil ? .link : .text,
                title: pin?.title,
                source: pin?.source ?? Clips.source(of: url),
                text: text.count > limit ? String(text.prefix(limit)) : text,
                more: max(0, text.count - limit),
                masked: hidden,
                image: nil,
                pixels: nil)
        }
        guard let image = makeThumbnail(url, maxPixels: 1000) else { return nil }
        var pixels: CGSize?
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            pixels = CGSize(width: w, height: h)
        }
        return PreviewModel(kind: .picture, title: nil, source: nil, text: "", more: 0,
                            masked: false, image: image, pixels: pixels)
    }
}

private struct PreviewModel {
    enum Kind { case text, link, picture }
    let kind: Kind
    /// The label of a card on one of your own lines.
    let title: String?
    let source: String?
    let text: String
    /// Characters left out of a very long clip.
    let more: Int
    let masked: Bool
    let image: NSImage?
    let pixels: CGSize?
}

/// A solid card with a visible edge, a header saying what it is and where it
/// came from, and a notch pointing at the card it belongs to.
private struct PreviewView: View {
    let model: PreviewModel
    /// Where the card is, from the window's left edge.
    let caretX: CGFloat?

    private static let radius: CGFloat = 12
    private static let margin: CGFloat = 18
    private static let surface = Color(nsColor: .controlBackgroundColor)
    private static let edge = Color.primary.opacity(0.3)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            footer
        }
        .frame(minWidth: 240, alignment: .leading)
        .fixedSize()
        .background(Self.surface, in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        // A real edge: on a dark desktop a shadow alone disappears.
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .strokeBorder(Self.edge, lineWidth: 1))
        .overlay(alignment: .topLeading) { caret }
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        .padding(.horizontal, Self.margin)
        .padding(.top, 10)
        .padding(.bottom, Self.margin + 6)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.masked ? Color.orange : .secondary)
            Text(heading)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if let source = model.source {
                Text("· " + source)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(detail)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder private var content: some View {
        let limit = HoverPreview.maxBody
        if let image = model.image {
            let s = image.size
            let scale = min(limit.width / s.width, limit.height / s.height, 1)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: s.width * scale, height: s.height * scale)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .padding(10)
        } else {
            Text(model.text)
                .font(.system(size: 14))
                .foregroundStyle(model.kind == .link ? Color.accentColor : .primary)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: limit.width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: limit.height, alignment: .top)
                .clipped()
                // A long clip fades out at the bottom instead of a hard cut.
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0.8),
                                           .init(color: .black.opacity(isLong ? 0 : 1), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(L("Click to copy"))
            if model.kind == .link { Text(L("Double-click to open")) }
            if model.kind == .picture { Text(L("Space: Quick Look")) }
            if model.masked { Text(L("Hold ⌥ to show the key")) }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 12)
        .padding(.bottom, 7)
    }

    /// A small notch pointing up at the card.
    @ViewBuilder private var caret: some View {
        if let caretX {
            Caret()
                .fill(Self.surface)
                .overlay(Caret().stroke(Self.edge, lineWidth: 1))
                // Hides the box's edge under the notch, so the two join.
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Self.surface).frame(height: 2).padding(.horizontal, 1.2).offset(y: 1.5)
                }
                .frame(width: 18, height: 9)
                .offset(x: max(caretX - Self.margin, Self.radius + 9) - 9, y: -8)
        }
    }

    /// Taller than the preview, or cut short: some of it is not shown.
    private var isLong: Bool { model.more > 0 || model.text.count > 600 || model.text.split(separator: "\n").count > 14 }

    private var icon: String {
        if model.masked { return "lock.fill" }
        switch model.kind {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .picture: return "photo"
        }
    }

    private var heading: String {
        if let title = model.title { return title }
        switch model.kind {
        case .text: return model.masked ? L("Key, partly hidden") : L("Text")
        case .link: return L("Link")
        case .picture: return L("Picture")
        }
    }

    private var detail: String {
        if let p = model.pixels { return "\(Int(p.width)) × \(Int(p.height))" }
        if model.kind == .picture { return "" }
        return String(format: L("%d characters"), model.text.count + model.more)
    }
}

private struct Caret: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        }
    }
}
