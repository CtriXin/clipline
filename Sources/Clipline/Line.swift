import AppKit
import Combine
import os

let log = Logger(subsystem: "local.clipline.Clipline", category: "line")

/// One screenshot hanging on the line.
struct Pegged: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var thumb: NSImage
    /// Every photo hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false

    /// Text, from the clipboard or one of your lines: sized to its content.
    var isNote: Bool { url.scheme == "clipline-text" || url.scheme == "clipline-pin" }

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb
    }
}

/// The line itself: what hangs on it and what you can do with each item.
/// The files never move. The line is only a view onto them.
@MainActor
final class Line: ObservableObject {
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    /// The card under the pointer, for the large preview.
    @Published var hoveredID: UUID?
    /// Which line is up: the recent one (screenshots and the clipboard) or
    /// one of your own groups. Switching swaps the whole line.
    @Published var shelf: Shelf = .recent {
        didSet {
            guard shelf != oldValue else { return }
            rebuildPins()
            // Recent opens on its newest end; your own lines on their first card.
            if shelf == .recent { scrollToNewest() } else { scroll = 0 }
        }
    }
    /// The current group's pins, hung as cards.
    @Published private(set) var pinCards: [Pegged] = []
    /// Option held: keys on the cards show in full.
    @Published var revealSecrets = false { didSet { if revealSecrets != oldValue { rebuildPins() } } }
    /// Brought up from the keyboard: ⌘1–9 copy, Tab switches lines, Esc leaves.
    @Published var keyboardMode = false
    /// ⌘ held over the lowered line: the cards show their ⌘ numbers.
    @Published var showShortcuts = false
    /// The pointer is at the lowered line.
    @Published var pointerInside = false
    static let tabsID = UUID()
    static let moreLeftID = UUID()
    /// The pointer sweeping along the line, like a hand: where it is (in the
    /// line's coordinates) and how fast it moves, + to the right. Cards ahead
    /// of it lean with it; when it stops they swing back and settle.
    struct Wind: Equatable {
        var x: CGFloat
        var speed: CGFloat
        static let calm = Wind(x: 0, speed: 0)
    }
    @Published var wind = Wind.calm

    /// How far a card leans in this wind, in degrees.
    static func lean(cardX: CGFloat, in wind: Wind) -> Double {
        guard abs(wind.speed) > 60 else { return 0 }
        let dir: CGFloat = wind.speed > 0 ? 1 : -1
        // Only the cards ahead of the hand, and the one under it.
        let ahead = (cardX - wind.x) * dir
        guard ahead > -Layout.cardWidth / 2 else { return 0 }
        let strength = min(13, abs(wind.speed) / 55)
        let falloff = exp(-max(0, ahead) / 420)
        // Pushed right, the bottom swings right: a negative angle.
        return -Double(dir * strength * falloff)
    }
    static let moreRightID = UUID()
    /// How far a line too long for the screen has slid.
    @Published private(set) var scroll: CGFloat = 0
    /// The panel's width, for the scrolling limits.
    var width: CGFloat = 0

    /// What hangs on the line right now.
    var visible: [Pegged] { shelf == .recent ? items : pinCards }
    private var pinPegs: [UUID: Pegged] = [:]
    private var bagWatch: AnyCancellable?
    /// Whether the line has slid down into view.
    @Published var revealed = false

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var hitRects: [UUID: CGRect] = [:]

    /// How many cards fit on screen at once (set from the screen width).
    var maxItems = 8
    /// How many Recent keeps. More than fit on screen: the line slides.
    static let recentLimit = 24


    var soundOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }

    private let storeKey = "pegged"

    init() {
        restore()
        scheduleGust()
        // @Published reports before the change lands: read it a beat later.
        bagWatch = Bag.shared.$pins.sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildPins() }
        }
    }

    // MARK: Your own lines

    enum Shelf: Equatable {
        case recent
        case group(String)
    }

    /// Every line, in the order Tab walks them.
    var shelves: [Shelf] { [.recent] + Bag.shared.groups.map(Shelf.group) }

    func nextShelf(_ step: Int = 1) {
        let all = shelves
        let i = all.firstIndex(of: shelf) ?? 0
        shelf = all[(i + step + all.count) % all.count]
    }

    func rebuildPins() {
        guard case .group(let g) = shelf else {
            if !pinCards.isEmpty { pinCards = [] }
            return
        }
        if !Bag.shared.groups.contains(g) { shelf = .recent; return }
        let bag = Bag.shared
        pinCards = bag.pins(in: g).map { pin in
            let value = revealSecrets ? pin.text : bag.shown(pin)
            let thumb = makePinCard(title: pin.title, value: value, locked: bag.isSecret(pin) && !revealSecrets)
            var peg = pinPegs[pin.id] ?? Pegged(url: URL(string: "clipline-pin://\(pin.id.uuidString)")!, thumb: thumb)
            peg.thumb = thumb
            pinPegs[pin.id] = peg
            return peg
        }
    }

    /// The pin behind a card on one of your own lines.
    func pin(for id: UUID) -> Pin? {
        guard let peg = pinCards.first(where: { $0.id == id }),
              let key = peg.url.host.flatMap(UUID.init(uuidString:)) else { return nil }
        return Bag.shared.pins.first { $0.id == key }
    }

    // MARK: Sliding

    /// Trackpad or wheel: slide the line, within its ends.
    func scroll(by delta: CGFloat) {
        let limit = Layout.maxScroll(count: visible.filter { !$0.falling }.count, width: width)
        let next = min(max(scroll + delta, 0), limit)
        if next != scroll { scroll = next }
    }

    func scrollToNewest() {
        scroll = Layout.maxScroll(count: items.filter { !$0.falling }.count, width: width)
    }

    /// ← →: a screenful at a time, landing on a whole card.
    func page(_ direction: Int) {
        let perPage = max(1, Int(Layout.usable(width: width) / Layout.spacing))
        let target = CGFloat(firstShown + direction * perPage) * Layout.spacing
        let limit = Layout.maxScroll(count: visible.filter { !$0.falling }.count, width: width)
        scroll = min(max(target, 0), limit)
    }

    /// The first card fully on the line; ⌘1 copies it.
    var firstShown: Int {
        guard Layout.maxScroll(count: visible.filter { !$0.falling }.count, width: width) > 0 else { return 0 }
        return Int((scroll / Layout.spacing).rounded(.up))
    }

    /// ⌘1–9: copy the card in that place.
    @discardableResult
    func copy(at index: Int) -> Bool {
        let live = visible.filter { !$0.falling }
        let index = firstShown + index
        guard live.indices.contains(index) else { return false }
        copy(live[index].id)
        return true
    }

    // MARK: Hanging and dropping

    /// Whether the last thing hung should bring the line down to show itself.
    /// Screenshots do; clipboard copies hang quietly, there are far too many.
    private(set) var lastHangPeeks = true

    @discardableResult
    func hang(_ url: URL, quietly: Bool = false, flying: Bool = false, peek: Bool = true) -> UUID? {
        guard !items.contains(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else {
            Clips.forget(url)
            return nil
        }
        // The same text copied again moves to the newest end, not a second card.
        if let text = Clips.text(of: url),
           let old = items.first(where: { !$0.falling && Clips.text(of: $0.url) == text }) {
            drop(old.id, quietly: true)
        }
        var item = Pegged(url: url, thumb: thumb)
        item.flying = flying
        lastHangPeeks = peek
        items.append(item)
        // A full line lets the oldest card fall off the far end. Pictures
        // and text each keep half the line, so a burst of copied text cannot
        // push every screenshot off, nor the other way round.
        while liveCount > Self.recentLimit {
            let live = items.filter { !$0.falling }
            let isText = Clips.isText(url)
            let same = live.filter { Clips.isText($0.url) == isText }
            let victim = same.count > Self.recentLimit / 2 ? same.first
                : live.first { Clips.isText($0.url) != isText }
            guard let victim else { break }
            drop(victim.id, quietly: true)
        }
        if !quietly { play("Tink", volume: 0.35) }
        // The newest hangs at the right end: slide there so it is in view.
        if shelf == .recent { scrollToNewest() }
        return item.id
    }

    /// The capture has reached the line: the real card takes over.
    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    /// Called just before a photo starts falling, so the fall can be drawn
    /// over the whole screen.
    var onFall: ((Pegged) -> Void)?

    func drop(_ id: UUID, quietly: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        onFall?(items[i])
        items[i].falling = true
        hitRects[id] = nil
        if !quietly { play("Pop", volume: 0.25) }
        let url = items[i].url
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.items.removeAll { $0.id == id }
            // A clip only lives while it hangs.
            Clips.forget(url)
        }
    }

    func clear() {
        let live = items.filter { !$0.falling }
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.drop(item.id, quietly: n > 0)
            }
        }
    }

    /// Photos whose file was deleted or moved away fall off by themselves.
    func prune() {
        for item in items where !item.falling && item.url.isFileURL
            && !FileManager.default.fileExists(atPath: item.url.path) {
            drop(item.id, quietly: true)
        }
    }

    // MARK: Actions on one photo

    func copy(_ id: UUID) {
        if let pin = pin(for: id) {
            Bag.shared.copy(pin.id)
            flashCopied(id)
            return
        }
        guard let item = items.first(where: { $0.id == id }) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if Clips.isText(item.url) {
            pb.setString(Clips.text(of: item.url) ?? "", forType: .string)
        } else {
            let entry = NSPasteboardItem()
            if let png = pngData(item.url) { entry.setData(png, forType: .png) }
            entry.setString(item.url.absoluteString, forType: .fileURL)
            pb.writeObjects([entry])
        }
        Clips.ownChangeCount = pb.changeCount
        flashCopied(id)
    }

    private func flashCopied(_ id: UUID) {
        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == id { self?.copiedID = nil }
        }
    }

    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if Clips.isText(item.url) {
            if let link = Clips.link(of: item.url) { NSWorkspace.shared.open(link) }
            return
        }
        NSWorkspace.shared.open(item.url)
    }

    /// Moves the file to the Trash and takes the photo off the line. When a
    /// drag ends on the Dock's Trash, macOS only reports it: deleting the file
    /// is the source app's job, as Finder does.
    func trash(_ id: UUID) {
        if pin(for: id) != nil { return takeOff(id) }
        guard let item = items.first(where: { $0.id == id }) else { return }
        // Clips are scratch: taking one down already deletes it.
        if Clips.contains(item.url) { return drop(id) }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            log.notice("Trashed \(item.url.lastPathComponent, privacy: .public)")
            if soundOn { Line.trashSound?.play() }
            drop(id, quietly: true)
        } catch {
            log.error("Could not trash \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Whether the file lives in Clipline's own folder. Those are discarded
    /// to the Trash, or the folder would fill up with forgotten screenshots.
    /// Files anywhere else, like the Desktop, stay where they are.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return item.url.standardizedFileURL.path.hasPrefix(Inbox.folder.standardizedFileURL.path + "/")
    }

    /// The corner cross and "Take down" both end up here.
    func discard(_ id: UUID) {
        if pin(for: id) != nil { return takeOff(id) }
        if isInInbox(id) { trash(id) } else { drop(id) }
    }

    /// The cross on a card of your own line. A pin is something you chose to
    /// keep, so it is asked about before it goes for good.
    func takeOff(_ id: UUID) {
        guard let pin = pin(for: id) else { return }
        let alert = NSAlert()
        alert.messageText = String(format: L("Take “%@” off “%@”?"), pin.title, pin.group)
        alert.informativeText = L("It is deleted from the Keychain and cannot be brought back.")
        alert.addButton(withTitle: L("Take off"))
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Bag.shared.remove(pin.id)
        play("Pop", volume: 0.25)
    }

    /// Inbox mode: keep a screenshot by moving it to the Desktop.
    func saveToDesktop(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let target = uniqueURL(in: desktop, for: item.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            drop(id, quietly: true)
        } catch {
            log.error("Could not save to Desktop: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Long press: open the photo in the system Markup editor.
    func markup(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if Clips.isText(item.url) { return }
        Markup.shared.edit(item.url)
    }

    /// After editing, the photo on the line shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return }
        items[i].thumb = thumb
    }

    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.url.isFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget.
    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self else { return }
            if !self.items.isEmpty && self.draggingID == nil { self.gust += 1 }
            self.scheduleGust()
        }
    }

    // MARK: Persistence

    /// Nothing comes back after a restart: the line is scratch space. Only the
    /// list kept by earlier versions is cleared; the files themselves stay.
    private func restore() {
        UserDefaults.standard.removeObject(forKey: storeKey)
    }

    // MARK: Helpers

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    private func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

func makeThumbnail(_ url: URL, maxPixels: Int = 480) -> NSImage? {
    if Clips.isText(url) {
        guard let text = Clips.text(of: url) else { return nil }
        return makeTextCard(text, link: Clips.link(of: url), maxPixels: maxPixels)
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
