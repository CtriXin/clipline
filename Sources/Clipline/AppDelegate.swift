import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let line = Line()
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var watcher: ScreenshotWatcher!
    /// In inbox mode, a second watcher on the Desktop. If a macOS version
    /// ignores the screenshot settings (macOS 27 renamed one), captures keep
    /// landing on the Desktop, and they still hang on the line.
    private var safetyWatcher: ScreenshotWatcher?
    private var clipWatcher: ClipboardWatcher?
    /// QQ keeps a copy of every screenshot it copies to the clipboard inside
    /// its own container; watching it hangs QQ captures with their flight.
    /// From y0un922/tendedero (MIT).
    private var qqWatcher: ScreenshotWatcher?
    /// Space on the picture under the pointer. Registered only while the
    /// pointer rests on one, so Space keeps being Space everywhere else.
    private var previewHotKey: HotKey?
    /// ⌘1–9, Tab, Esc: registered only while the line is up from the
    /// keyboard, so they are never taken from other apps otherwise.
    private var keyboardKeys: [HotKey] = []
    /// ⌘1–9 alone, while ⌘ is held over the line brought down by the mouse.
    private var digitKeys: [HotKey] = []
    /// The pointer a tick ago, to tell how fast it sweeps across the line.
    private var lastPointer: (x: CGFloat, at: Date)?
    private var windSpeed: CGFloat = 0
    private let preview = HoverPreview()
    private var previewWork: DispatchWorkItem?
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?

    /// Whether the panel is ordered in. It can be in and still tucked away
    /// above the top edge, like an auto-hiding Dock.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private var isRevealed = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A new screenshot shows itself for a moment, then tucks away.
    private var peekUntil = Date.distantPast
    private var hotZoneSince: Date?
    /// After a click in the menu bar the line stays up there hidden until the
    /// pointer leaves the menu bar, so it does not come back over a menu.
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []
    private var awaySince: Date?
    /// Whether the line should be up, if nothing prevents it. A full screen
    /// app on that screen does: the line waits until you leave full screen.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false
    private var lastLiveCount = 0
    /// The screen a new capture was taken on: the line goes there.
    private var pendingScreen: NSScreen?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Clips.wipe()
        let host = NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        panel.placeOnScreen()
        updateCapacity()

        if Inbox.isEnabled { Inbox.apply() }
        restoreSettingsOnTermination()
        startWatcher()
        // Images on the clipboard are mostly screenshots taken with a tool
        // that copies instead of saving: they hang like screenshots and bring
        // the line down. Text is copied all day long, so it hangs quietly.
        clipWatcher = ClipboardWatcher { [weak self] url in
            if Clips.isText(url) {
                self?.line.hang(url, quietly: true, peek: false)
            } else {
                self?.hangCapture(url)
            }
        }
        if Clips.isEnabled { clipWatcher?.start() }

        registerSummon(Shortcut.saved)

        setUpStatusItem()
        watchMenuBarClicks()

        // Something in the bag is reason enough for the line to answer the top edge.
        if !Bag.shared.pins.isEmpty {
            wanted = true
            refresh()
        }

        Previewer.shared.onClosed = { [weak self] in
            self?.updatePreviewHotKey(hovered: self?.line.hoveredID)
        }
        Markup.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        line.onFall = { [weak self] item in self?.fall(item) }

        Publishers.CombineLatest3(line.$hoveredID, line.$draggingID, line.$pressedID)
            .receive(on: RunLoop.main)
            .sink { [weak self] hovered, dragging, pressed in
                self?.updatePreview(hovered: dragging == nil && pressed == nil ? hovered : nil)
                self?.updatePreviewHotKey(hovered: hovered)
            }
            .store(in: &cancellables)

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
                self?.updateCapacity()
            }
        }

        if !Inbox.wasOffered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.offerInbox() }
        }

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            keepOpen = true
            wanted = true
            refresh()
            reveal(pinned: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.line.liveCount == 0 else { return }
                self.keepOpen = false
                self.wanted = false
                self.refresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Inbox.isEnabled { Inbox.restore() }
        Clips.wipe()
    }

    // MARK: Inbox mode

    private func startWatcher() {
        watcher?.stop()
        safetyWatcher?.stop()
        safetyWatcher = nil
        watcher = ScreenshotWatcher(
            onNew: { [weak self] url in self?.hangCapture(url) ?? false },
            onChange: { [weak self] in self?.line.prune() })
        watcher.start()
        if Inbox.isEnabled, watcher.folder.standardizedFileURL != ScreenshotWatcher.desktop.standardizedFileURL {
            let safety = ScreenshotWatcher(
                folder: ScreenshotWatcher.desktop,
                onNew: { [weak self] url in
                    log.notice("Screenshot landed on the Desktop despite inbox mode: \(url.lastPathComponent, privacy: .public)")
                    return self?.hangCapture(url) ?? false
                },
                onChange: { [weak self] in self?.line.prune() })
            safety.start()
            safetyWatcher = safety
        }

        qqWatcher?.stop()
        let qq = ScreenshotWatcher(
            folder: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/com.tencent.qq/Data/tmp", isDirectory: true),
            onNew: { [weak self] url in
                // QQ_<epoch ms>.png is the capture; QQ_<epoch ms>_thumb.png is
                // the little preview it keeps next to it.
                let name = url.lastPathComponent
                guard name.hasPrefix("QQ_"), !name.hasSuffix("_thumb.png") else { return true }
                return self?.hangCapture(url) ?? false
            },
            onChange: { [weak self] in self?.line.prune() })
        qq.start()
        qqWatcher = qq
    }

    private func setInbox(_ on: Bool) {
        Inbox.isEnabled = on
        if on { Inbox.apply() } else { Inbox.restore() }
        startWatcher()
    }

    /// Asked once. Changing system settings is the user's call, never ours.
    private func offerInbox() {
        Inbox.wasOffered = true
        let alert = NSAlert()
        alert.messageText = L("Let Clipline handle your screenshots?")
        alert.informativeText = L(
            "Screenshots will hang on the line the instant you take them, without the floating thumbnail, and will not pile up on your Desktop. Drag one to a folder to keep it, or discard it with the cross. You can turn this off from the menu bar, and your settings come back when Clipline quits.")
        alert.addButton(withTitle: L("Turn on"))
        alert.addButton(withTitle: L("Not now"))
        if let icon = NSImage(named: "Clipline") ?? NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
    }

    /// Quitting from the menu or logging out runs applicationWillTerminate.
    /// A plain kill does not, so settings are also restored on those signals.
    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                if Inbox.isEnabled { Inbox.restore() }
                Clips.wipe()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Showing and hiding

    private func itemsChanged() {
        let live = line.liveCount
        if live > lastLiveCount && !line.lastHangPeeks {
            // Copied text hangs quietly: the line does not come down, but it
            // must be ready to, or the top edge would never bring it down.
            updateCapacity()
            if !wanted {
                wanted = true
                refresh()
            }
        } else if live > lastLiveCount {
            // Something new arrived: show the line it is on.
            line.shelf = .recent
            panel.placeOnScreen(pendingScreen)
            pendingScreen = nil
            updateCapacity()
            wanted = true
            refresh()
            reveal(peekFor: 2.5)
        } else if live == 0 && !keepOpen && Bag.shared.pins.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.line.liveCount == 0, !self.keepOpen, Bag.shared.pins.isEmpty else { return }
                self.wanted = false
                self.refresh()
            }
        }
        lastLiveCount = live
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    @discardableResult
    private func hangCapture(_ url: URL) -> Bool {
        // A second watcher can report a capture that is already on the line.
        if line.items.contains(where: { $0.url == url && !$0.falling }) { return true }
        let from = captureRect(of: url)
        if let from {
            let center = CGPoint(x: from.midX, y: from.midY)
            pendingScreen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
        }
        guard let id = line.hang(url, flying: from != nil) else {
            pendingScreen = nil
            return false
        }
        guard let from else { return true }
        // Let the line come down and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: from)
        }
        return true
    }

    private func fly(_ id: UUID, from: CGRect) {
        guard isPresent, isRevealed, let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = line.visible.first(where: { $0.id == id }) else {
            line.land(id)
            return
        }
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(3000, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), on: screen) { [weak self] in
            self?.line.land(id)
        }
    }

    /// Resting on a card for a moment shows it large below the line.
    private func updatePreview(hovered id: UUID?) {
        previewWork?.cancel()
        guard let id else { preview.hide(); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRevealed, let screen = self.panel.screen,
                  self.line.hoveredID == id, self.line.draggingID == nil,
                  let item = self.line.visible.first(where: { $0.id == id && !$0.falling }),
                  let card = self.cardFrame(for: id) else { return }
            // Below the lowest card on the line, not just this one: the line
            // sags, and a preview under a high card would cover its neighbours.
            let lowest = self.line.visible.filter { !$0.falling }
                .compactMap { self.cardFrame(for: $0.id)?.minY }.min() ?? card.minY
            let below = CGRect(x: card.minX, y: lowest - 8, width: card.width, height: card.maxY - lowest + 8)
            self.preview.show(item.url, below: below, on: screen)
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    // MARK: The pointer's wind

    /// Sweeping the pointer along the lowered line pushes the cards ahead of
    /// it, like a hand brushing hanging clothes: they lean with the sweep,
    /// and swing back and settle once it stops or leaves.
    private func blowWind(_ mouse: NSPoint, now: Date) {
        let x = mouse.x - panel.frame.minX
        let fromTop = panel.frame.maxY - mouse.y
        defer { lastPointer = (x, now) }
        let near = fromTop > -20 && fromTop < Layout.panelHeight
        guard near, let last = lastPointer, !GrabView.isDragging, line.pressedID == nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            calmWind()
            return
        }
        let dt = now.timeIntervalSince(last.at)
        guard dt > 0, dt < 0.2 else { return }
        // Smoothed, so a steady sweep holds the lean and a stop lets it go.
        let instant = (x - last.x) / CGFloat(dt)
        windSpeed = windSpeed * 0.55 + instant * 0.45
        if abs(windSpeed) < 60 {
            calmWind()
        } else {
            line.wind = Line.Wind(x: x, speed: windSpeed)
        }
    }

    private func calmWind() {
        windSpeed = 0
        if line.wind != .calm { line.wind = .calm }
    }

    // MARK: Keyboard

    /// ⌃⌥T brings the line down ready for the keyboard; pressed again it
    /// walks to the next line, like Tab.
    private func startKeyboardMode() {
        line.keyboardMode = true
        guard keyboardKeys.isEmpty else { return }
        keyboardKeys.append(contentsOf: makeDigitKeys())
        keyboardKeys.append(HotKey(keyCode: kVK_Tab, modifiers: 0) { [weak self] in self?.line.nextShelf() })
        keyboardKeys.append(HotKey(keyCode: kVK_Tab, modifiers: shiftKey) { [weak self] in self?.line.nextShelf(-1) })
        keyboardKeys.append(HotKey(keyCode: kVK_Escape, modifiers: 0) { [weak self] in self?.tuckAway() })
        keyboardKeys.append(HotKey(keyCode: kVK_RightArrow, modifiers: 0) { [weak self] in self?.line.page(1) })
        keyboardKeys.append(HotKey(keyCode: kVK_LeftArrow, modifiers: 0) { [weak self] in self?.line.page(-1) })
    }

    /// ⌘1–9: copy the card shown in that place, then get out of the way so
    /// it can be pasted at once.
    private func makeDigitKeys() -> [HotKey] {
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                      kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        return digits.enumerated().map { n, key in
            HotKey(keyCode: key, modifiers: cmdKey) { [weak self] in
                guard let self, self.line.copy(at: n) else { NSSound.beep(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.tuckAway() }
            }
        }
    }

    /// Holding ⌘ with the pointer at the lowered line shows each card's
    /// number and lets ⌘1–9 copy it, without bringing it down from the
    /// keyboard first. Elsewhere, ⌘1–9 stay with the other apps.
    private func updateCommandHold(inside: Bool) {
        let flags = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
        let holding = flags == .command && inside && !line.keyboardMode
        if holding != line.showShortcuts { line.showShortcuts = holding }
        if holding && digitKeys.isEmpty {
            digitKeys = makeDigitKeys()
        } else if !holding && !digitKeys.isEmpty {
            digitKeys.removeAll()
        }
    }

    private func stopKeyboardMode() {
        keyboardKeys.removeAll()
        line.keyboardMode = false
        line.revealSecrets = false
    }

    private func tuckAway() {
        pinned = false
        setRevealed(false)
        if line.liveCount == 0 && Bag.shared.pins.isEmpty {
            keepOpen = false
            wanted = false
            refresh()
        }
    }

    // MARK: Quick Look

    /// Space previews the picture under the pointer in Quick Look, like the
    /// Finder. Text clips have no file and keep the hover preview instead.
    private func updatePreviewHotKey(hovered id: UUID?) {
        let url = id.flatMap { id in line.visible.first { $0.id == id }?.url }
        if url?.isFileURL == true || Previewer.shared.isVisible {
            guard previewHotKey == nil else { return }
            previewHotKey = HotKey(keyCode: kVK_Space, modifiers: 0) { [weak self] in
                self?.togglePreview()
            }
        } else {
            previewHotKey = nil
        }
    }

    private func togglePreview() {
        let url = line.hoveredID.flatMap { id in line.visible.first { $0.id == id }?.url }
        preview.hide()
        Previewer.shared.toggle(url?.isFileURL == true ? url : nil)
        updatePreviewHotKey(hovered: line.hoveredID)
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    private func fall(_ item: Pegged) {
        guard isPresent, isRevealed, !item.flying, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), on: screen)
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        let shown = line.visible
        guard let index = shown.firstIndex(where: { $0.id == id }) else { return nil }
        let width = panel.frame.width
        let x = Layout.x(index: index, count: shown.count, width: width, scroll: line.scroll)
        let viewTop = Layout.ropeY(x: x, width: width) - Layout.pinAbove
        let cardTop = viewTop + PeggedView.cardOffsetBelowTop
        let size = PeggedView.cardSize(for: shown[index].thumb.size, note: shown[index].isNote)
        return CGRect(x: panel.frame.minX + x - size.width / 2,
                      y: panel.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    /// Decides whether the panel is ordered in at all: something to show,
    /// and no full screen app on that screen.
    private func refresh() {
        let blocked = panel.screen.map(FullScreen.isActive(on:))
            ?? LinePanel.screenUnderPointer().map(FullScreen.isActive(on:)) ?? false
        if wanted && !blocked {
            present()
            keepOnActiveSpace()
        } else {
            dismiss()
        }
        // The cursor is watched while there is a line, even tucked away,
        // to notice it pushing against the top edge.
        if wanted { startMouseTracking() } else { stopMouseTracking() }
    }

    /// macOS sometimes parks the window on another Space and the app never
    /// hears about it: the line is up everywhere except the desktop you are
    /// on. Ordering it front again brings it back. From y0un922/tendedero.
    private func keepOnActiveSpace() {
        guard isPresent, isRevealed, !panel.isOnActiveSpace else { return }
        log.notice("The line was parked on another Space: ordering it front again")
        panel.orderFrontRegardless()
    }

    private func present() {
        guard !isPresent else { return }
        isPresent = true
        panel.alphaValue = 1
        // The window itself only comes in while the line is down; see setRevealed.
        if isRevealed { panel.orderFrontRegardless() }
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel.orderOut(nil)
        }
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        isRevealed = on
        line.revealed = on
        if !on {
            calmWind()
            updateCommandHold(inside: false)
            stopKeyboardMode()
            // Next time it comes down on its own, it shows what is new.
            line.shelf = .recent
        }
        // Tucked away, the line leaves no window behind: an invisible strip
        // over the top of the screen would still sit above other apps for
        // anything that checks what is on top, like screen automation.
        if on {
            if isPresent { panel.orderFrontRegardless() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.isRevealed else { return }
                self.panel.orderOut(nil)
            }
        }
        if !on {
            pinned = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
        }
    }

    /// Registers the shortcut that brings the line down. Returns false when
    /// the system refuses it, usually because another app already has it.
    @discardableResult
    private func registerSummon(_ shortcut: Shortcut) -> Bool {
        hotKey = nil
        let key = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
            self?.summon()
        }
        hotKey = key
        return key.isRegistered
    }

    private func changeSummon() {
        let old = Shortcut.saved
        // Off while recording, so pressing the current one does not fire it.
        hotKey = nil
        guard let new = recordShortcut(current: old), new != old else {
            registerSummon(old)
            return
        }
        if registerSummon(new) {
            Shortcut.saved = new
        } else {
            registerSummon(old)
            let alert = NSAlert()
            alert.messageText = String(format: L("%@ is already used by another app"), new.display)
            alert.informativeText = String(format: L("Keeping %@. Try a different combination."), old.display)
            alert.runModal()
        }
    }

    /// ⌃⌥T: down and ready for the keyboard; again, the next line.
    private func summon() {
        if isRevealed && line.keyboardMode {
            line.nextShelf()
            return
        }
        if !isRevealed { toggle() }
        startKeyboardMode()
    }

    @objc private func toggle() {
        if isRevealed {
            setRevealed(false)
            if line.liveCount == 0 {
                keepOpen = false
                wanted = false
                refresh()
            }
        } else {
            keepOpen = true
            wanted = true
            panel.placeOnScreen()
            updateCapacity()
            refresh()
            reveal(pinned: true)
        }
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel.ignoresMouseEvents = true
    }

    /// How long the cursor rests against the top edge before the line comes
    /// down. Short enough to feel instant, long enough that a quick trip to
    /// the menu bar does not trigger it.
    private static let revealDelay: TimeInterval = 0.25

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    /// A click anywhere in the top bar of any screen, a menu or an icon, puts the line away.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { NSMouseInRect(p, Self.menuBarBand(of: $0), false) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                if self.isRevealed {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = Date()

        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { NSMouseInRect(mouse, Self.menuBarBand(of: $0), false) } ?? false
        if !inMenuBar { menuBarSuppressed = false }

        guard isRevealed else {
            // Resting in the menu bar brings the line down on that screen.
            // Pushing against the top edge is part of it, and it also works
            // when another display sits above and the pointer never stops.
            if let screen = screenUnderPointer, inMenuBar, !menuBarSuppressed,
               !FullScreen.isActive(on: screen) {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    if panel.screen != screen {
                        panel.placeOnScreen()
                        updateCapacity()
                    }
                    refresh()
                    reveal()
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        updateMousePassThrough(mouse)
        keepOnActiveSpace()
        blowWind(mouse, now: now)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        updateCommandHold(inside: inside)
        // Option held shows keys in full, on the cards and in the preview.
        let option = NSEvent.modifierFlags.contains(.option)
        if line.revealSecrets != option && (line.keyboardMode || inside) { line.revealSecrets = option }
        if inside && pinned { pinned = false }

        let busy = pinned || line.keyboardMode || GrabView.isDragging || line.pressedID != nil || now < peekUntil
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a photo. Everywhere else, clicks go to
    /// whatever is underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        let overPhoto = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        if panel.ignoresMouseEvents == overPhoto {
            panel.ignoresMouseEvents = !overPhoto
        }
    }

    private func updateCapacity() {
        let usable = Layout.usable(width: panel.frame.width)
        line.width = panel.frame.width
        line.maxItems = max(3, min(12, Int(usable / Layout.spacing)))
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "tshirt", accessibilityDescription: "Clipline")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggleItem = ClosureMenuItem(isRevealed ? L("Hide line") : L("Show line")) { [weak self] in
            self?.toggle()
        }
        let shortcut = Shortcut.saved
        toggleItem.keyEquivalent = shortcut.key.count == 1 ? shortcut.key.lowercased() : ""
        toggleItem.keyEquivalentModifierMask = shortcut.menuModifiers
        menu.addItem(toggleItem)

        let clearItem = ClosureMenuItem(L("Take everything down")) { [weak self] in
            self?.line.clear()
        }
        clearItem.isEnabled = line.liveCount > 0
        menu.addItem(clearItem)

        let inbox = ClosureMenuItem(L("Handle screenshots")) { [weak self] in
            self?.setInbox(!Inbox.isEnabled)
        }
        inbox.state = Inbox.isEnabled ? .on : .off
        inbox.toolTip = L("Screenshots hang instantly and skip the Desktop")
        menu.addItem(inbox)

        let clip = ClosureMenuItem(L("Hang clipboard")) { [weak self] in
            Clips.isEnabled.toggle()
            if Clips.isEnabled { self?.clipWatcher?.start() } else { self?.clipWatcher?.stop() }
        }
        clip.state = Clips.isEnabled ? .on : .off
        menu.addItem(clip)

        menu.addItem(ClosureMenuItem(L("Open screenshots folder")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.watcher.folder)
        })

        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(String(format: L("Shortcut: %@…"), Shortcut.saved.display)) { [weak self] in
            self?.changeSummon()
        })

        let sound = ClosureMenuItem(L("Sounds")) { [weak self] in
            guard let self else { return }
            self.line.soundOn.toggle()
        }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)

        let login = ClosureMenuItem(L("Open at login")) {
            AppDelegate.toggleLaunchAtLogin()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Quit Clipline"), key: "q") {
            NSApp.terminate(nil)
        })
    }

    private static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting")
            alert.informativeText = L("Move Clipline to the Applications folder and try again.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
