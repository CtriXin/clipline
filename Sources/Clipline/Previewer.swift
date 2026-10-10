// Adapted from y0un922/tendedero (MIT), "Preview a photo with Space, like the Finder".
import AppKit
import QuickLookUI

/// Space on the photo under the pointer opens the Quick Look window, the
/// same one the Finder shows: same look, same zoom, same arrow keys.
///
/// QLPreviewPanel is a shared system panel that hands control to whichever
/// responder asks for it, so the data source is set here directly.
@MainActor
final class Previewer: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = Previewer()

    private var url: URL?
    /// The app that was in front before the preview, so the front can be
    /// handed back when it closes. The line never keeps the focus.
    private var previousApp: NSRunningApplication?
    private var watch: Timer?

    /// Told when the preview goes away, however it was closed, so the Space
    /// shortcut can be let go of again.
    var onClosed: (() -> Void)?

    var isVisible: Bool { QLPreviewPanel.shared()?.isVisible ?? false }

    /// Space again closes what Space opened.
    func toggle(_ url: URL?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard let url else { return }
        self.url = url
        panel.dataSource = self
        panel.delegate = self
        // The panel only comes up in an active app, and the line never
        // activates it on its own. Space is an explicit request, so asking
        // for the front is fair; it is handed straight back below.
        previousApp = NSWorkspace.shared.frontmostApplication
        // activate() alone is refused for an app that never comes to the
        // front on its own; this is the call the Markup editor uses too.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startWatching()
    }

    // MARK: Handing the front back

    /// Quick Look can be closed by its own close button, by Esc once it has
    /// the keyboard, or by Space. Its closing is watched rather than assumed.
    private func startWatching() {
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
            MainActor.assumeIsolated { self.panelWentAway() }
        }
    }

    private func panelWentAway() {
        guard !isVisible else { return }
        watch?.invalidate()
        watch = nil
        onClosed?()
        // Only if the preview closing is what left the app in front: if the
        // pointer went somewhere else meanwhile, that choice is respected.
        guard NSApp.isActive,
              let previous = previousApp,
              previous.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        previousApp = nil
        previous.activate(from: .current, options: [])
    }

    // MARK: QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}
