import AppKit
import SwiftUI

/// Resting the pointer on a card shows it large, just below the line: the
/// full text of a clip at a readable size, or a bigger picture. It lives in
/// its own window so it is not clipped by the line's thin strip.
@MainActor
final class HoverPreview {
    private let panel: NSPanel
    private var shownURL: URL?

    private static let maxSize = CGSize(width: 440, height: 340)

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

    /// Shows the preview for a file, hanging below `card` (screen coordinates).
    func show(_ url: URL, below card: CGRect, on screen: NSScreen) {
        if shownURL != url {
            guard let content = Self.content(for: url) else { return hide() }
            let host = NSHostingView(rootView: content)
            host.sizingOptions = [.intrinsicContentSize]
            panel.contentView = host
            panel.setContentSize(host.fittingSize)
            shownURL = url
        }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        var x = card.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let y = max(card.minY - 10 - size.height, visible.minY + 8)
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
        panel.orderOut(nil)
    }

    private static func content(for url: URL) -> AnyView? {
        let pinned = url.scheme == "clipline-pin"
        if Clips.isText(url) || pinned {
            guard let raw = pinned ? Bag.shared.text(forCard: url) : Clips.text(of: url) else { return nil }
            // Keys show in full only while Option is held.
            let (text, hidden) = NSEvent.modifierFlags.contains(.option) ? (raw, false) : Secrets.mask(raw)
            let body = (hidden ? "🔒 " : "") + (text.count > 1500 ? String(text.prefix(1500)) + "…" : text)
            return AnyView(
                Text(body)
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: maxSize.width - 32, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: maxSize.height - 28, alignment: .top)
                    .clipped()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .modifier(PreviewChrome()))
        }
        guard let image = makeThumbnail(url, maxPixels: 1000) else { return nil }
        let s = image.size
        let scale = min(maxSize.width / s.width, maxSize.height / s.height, 1)
        return AnyView(
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: s.width * scale, height: s.height * scale)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(6)
                .modifier(PreviewChrome()))
    }
}

private struct PreviewChrome: ViewModifier {
    func body(content: Content) -> some View {
        // Solid, not glass: whatever is behind would show through the text.
        content
            .background(Color(nsColor: .windowBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
            .padding(16)   // room for the shadow inside the window
    }
}
