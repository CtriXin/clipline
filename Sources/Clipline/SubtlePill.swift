import AppKit

/// Minimal, click-through, privacy-safe floating capsule notice.
/// Never shows thumbnails, clipboard text, or sensitive content — only a short
/// status label (e.g. sender device) that fades out cleanly without stealing focus.
@MainActor
final class SubtlePill {
    static let shared = SubtlePill()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, duration: TimeInterval = 1.6) {
        hideWork?.cancel()
        let p = ensurePanel()
        guard let label else { return }
        label.stringValue = text
        label.sizeToFit()

        let w = min(280, max(120, ceil(label.frame.width) + 28))
        let h: CGFloat = 28
        label.frame = NSRect(x: 14, y: (h - label.frame.height) / 2, width: w - 28, height: label.frame.height)

        let screen = LinePanel.screenUnderPointer() ?? NSScreen.main ?? NSScreen.screens.first
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let x = vis.maxX - w - 16
        let y = vis.maxY - h - 12

        p.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        p.contentView?.frame = NSRect(x: 0, y: 0, width: w, height: h)
        p.alphaValue = 0
        p.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            p.animator().alphaValue = 0.92
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    if panel.alphaValue < 0.05 { panel.orderOut(nil) }
                }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 28),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let vev = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
        vev.material = .hudWindow
        vev.blendingMode = .behindWindow
        vev.state = .active
        vev.wantsLayer = true
        vev.layer?.cornerRadius = 14
        vev.layer?.masksToBounds = true
        vev.layer?.borderWidth = 0.5
        vev.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: 11.5, weight: .medium)
        tf.textColor = .labelColor
        tf.lineBreakMode = .byTruncatingTail
        tf.alignment = .center
        vev.addSubview(tf)

        p.contentView = vev
        self.panel = p
        self.label = tf
        return p
    }
}
