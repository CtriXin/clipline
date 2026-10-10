import AppKit
import SwiftUI

/// Bridges each photo to AppKit's drag and drop, so it can be dragged into
/// any app as a real file. Each destination means one thing:
///
/// - An app gets a copy, and the photo stays on the line.
/// - A folder or the Desktop keeps the file, and the photo leaves the line.
/// - The Trash discards it.
/// - Nowhere that accepts it: the photo flies back to the line.
///
/// Click copies, press and hold opens Markup, the corner cross discards.
struct GrabArea: NSViewRepresentable {
    let item: Pegged
    let line: Line

    func makeNSView(context: Context) -> GrabView {
        let view = GrabView()
        configure(view)
        return view
    }

    func updateNSView(_ view: GrabView, context: Context) {
        configure(view)
    }

    private func configure(_ view: GrabView) {
        let id = item.id
        let line = line
        view.url = item.url
        view.dragImage = item.thumb
        view.onClick = { line.copy(id) }
        view.onScroll = { line.scroll(by: $0) }
        view.onDoubleClick = { line.open(id) }
        view.onDragStart = { line.draggingID = id }
        view.onDragEnd = {
            line.draggingID = nil
            // Moved into a folder: it is saved where you wanted it.
            line.prune()
        }
        view.onTrash = { line.trash(id) }
        view.onDiscard = { line.discard(id) }
        view.onLongPress = { line.markup(id) }
        view.onPressChange = { pressed in line.pressedID = pressed ? id : nil }
        let url = item.url
        view.menuProvider = {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(L("Copy")) { line.copy(id) })
            // A card on one of your own lines.
            if let pin = line.pin(for: id) {
                menu.addItem(ClosureMenuItem(L("Rename…")) {
                    if let t = askForText(L("Rename"), value: pin.title) { Bag.shared.rename(pin.id, to: t) }
                })
                let move = NSMenuItem(title: L("Move to"), action: nil, keyEquivalent: "")
                let groups = NSMenu()
                for g in Bag.shared.groups where g != pin.group {
                    groups.addItem(ClosureMenuItem(g) { Bag.shared.move(pin.id, to: g) })
                }
                move.submenu = groups
                menu.addItem(move)
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(L("Take off this line")) { line.takeOff(id) })
                return menu
            }
            // Text lives only in memory: there is no file to open or show.
            if Clips.isText(url) {
                if Clips.link(of: url) != nil {
                    menu.addItem(ClosureMenuItem(L("Open link")) { line.open(id) })
                }
                // Keep it: into one of the bag's groups.
                let bagItem = NSMenuItem(title: L("Hang on"), action: nil, keyEquivalent: "")
                let groups = NSMenu()
                let text = Clips.text(of: url) ?? ""
                for g in Bag.shared.groups {
                    groups.addItem(ClosureMenuItem(g) { Bag.shared.pin(text, to: g, source: Clips.source(of: url)) })
                }
                groups.addItem(.separator())
                groups.addItem(ClosureMenuItem(L("New group…")) {
                    if let name = askForText(L("New group")) {
                        Bag.shared.addGroup(name)
                        Bag.shared.pin(text, to: name, source: Clips.source(of: url))
                    }
                })
                bagItem.submenu = groups
                menu.addItem(bagItem)
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem(L("Take down")) { line.discard(id) })
                return menu
            }
            menu.addItem(ClosureMenuItem(L("Open")) { line.open(id) })
            menu.addItem(ClosureMenuItem(L("Markup")) { line.markup(id) })
            menu.addItem(ClosureMenuItem(L("Show in Finder")) { line.reveal(id) })
            let inInbox = line.isInInbox(id)
            if inInbox {
                menu.addItem(ClosureMenuItem(L("Save to Desktop")) { line.saveToDesktop(id) })
            }
            menu.addItem(.separator())
            if inInbox {
                menu.addItem(ClosureMenuItem(L("Discard")) { line.discard(id) })
            } else {
                menu.addItem(ClosureMenuItem(L("Take down")) { line.discard(id) })
                menu.addItem(ClosureMenuItem(L("Move to Trash")) { line.trash(id) })
            }
            return menu
        }
    }
}

final class GrabView: NSView, NSDraggingSource {
    static var isDragging = false

    var url: URL?
    var dragImage: NSImage?
    var onClick: () -> Void = {}
    var onScroll: (CGFloat) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onTrash: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onPressChange: (Bool) -> Void = { _ in }
    var menuProvider: () -> NSMenu = { NSMenu() }

    private var downPoint: NSPoint?
    private var startedDrag = false
    private var holdTimer: Timer?
    private var didLongPress = false

    /// How long you hold before Markup opens. Long enough not to fire on a
    /// slow click, short enough to feel deliberate.
    private static let holdDuration: TimeInterval = 0.45

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The discard cross drawn in the top left corner of the card. It is
    /// handled here because this view sits on top of the SwiftUI card.
    static let crossHitSize: CGFloat = 26

    private func isInCross(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        let corner = NSRect(x: 0, y: isFlipped ? 0 : bounds.height - Self.crossHitSize,
                            width: Self.crossHitSize, height: Self.crossHitSize)
        return corner.contains(p)
    }

    /// Sideways on a trackpad, or an ordinary wheel, slides the line.
    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        var delta = abs(dx) > abs(dy) ? -dx : -dy
        if !event.hasPreciseScrollingDeltas { delta *= 12 }
        onScroll(delta)
    }

    override func mouseDown(with event: NSEvent) {
        if isInCross(event) {
            downPoint = nil
            onDiscard()
            return
        }
        if event.clickCount == 2 {
            downPoint = nil
            onDoubleClick()
            return
        }
        downPoint = event.locationInWindow
        startedDrag = false
        didLongPress = false
        onPressChange(true)
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.downPoint != nil, !self.startedDrag else { return }
                self.didLongPress = true
                self.onPressChange(false)
                self.onLongPress()
            }
        }
    }

    private func endPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        onPressChange(false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !startedDrag, let url else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4, !didLongPress else { return }
        startedDrag = true
        endPress()

        // A text clip drags as its text, so it drops into any text field.
        let writer: NSPasteboardWriting = url.scheme == "clipline-pin"
            ? (Bag.shared.text(forCard: url) ?? "") as NSString
            : Clips.isText(url) ? (Clips.text(of: url) ?? "") as NSString : url as NSURL
        let item = NSDraggingItem(pasteboardWriter: writer)
        item.setDraggingFrame(imageFrame(), contents: dragImage)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        // Released where nothing accepts it: it flies back to the line.
        session.animatesToStartingPositionsOnCancelOrFail = true
        GrabView.isDragging = true
        onDragStart()
    }

    override func mouseUp(with event: NSEvent) {
        endPress()
        if downPoint != nil && !startedDrag && !didLongPress && event.clickCount == 1 { onClick() }
        downPoint = nil
        didLongPress = false
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Apps pick copy. Finder picks move, so a folder or the Desktop keeps
        // the file. Delete is what lets the Dock's Trash accept it.
        // On the line itself, a card moves along it or onto one of your tabs.
        context == .outsideApplication ? [.copy, .move, .delete] : [.copy, .move]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        GrabView.isDragging = false
        startedDrag = false
        downPoint = nil
        log.notice("Drag ended with operation \(operation.rawValue, privacy: .public)")
        // Dropped on the Trash: macOS only tells us, we move the file.
        if operation.contains(.delete) {
            onDragEnd()
            onTrash()
            return
        }
        onDragEnd()
        // Finder finishes a move a moment later. Check again then, so a photo
        // saved into a folder leaves the line.
        if operation.contains(.move) {
            let done = onDragEnd
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done() }
        }
    }

    /// The drag preview keeps the photo's aspect ratio inside the card.
    private func imageFrame() -> NSRect {
        guard let size = dragImage?.size, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
