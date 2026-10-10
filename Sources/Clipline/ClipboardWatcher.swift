import AppKit
import CryptoKit

/// What was copied, while it hangs on the line. Nothing outlives the app:
/// text lives only in memory, behind a `clipline-text://` address so the line
/// can treat it like any other item, and copied images are scratch files that
/// are wiped on launch and on quit.
enum Clips {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clipline/Clips", isDirectory: true)
    }()

    private static let enabledKey = "clipboardOff"
    private static let textScheme = "clipline-text"

    /// The user's choice, kept across launches. On unless turned off.
    static var isEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(!newValue, forKey: enabledKey) }
    }

    nonisolated(unsafe) private static var texts: [String: String] = [:]
    /// Where each text was copied from: a site, or the app.
    nonisolated(unsafe) private static var sources: [String: String] = [:]

    static func storeText(_ text: String, source: String? = nil) -> URL {
        let key = UUID().uuidString
        texts[key] = text
        sources[key] = source
        return URL(string: "\(textScheme)://\(key)")!
    }

    static func source(of url: URL) -> String? { isText(url) ? sources[url.host ?? ""] : nil }

    static func forget(_ url: URL) {
        if isText(url) {
            texts[url.host ?? ""] = nil
            sources[url.host ?? ""] = nil
        } else if contains(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Anything that came from the clipboard rather than a screenshot.
    static func contains(_ url: URL) -> Bool {
        isText(url) || url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    static func isText(_ url: URL) -> Bool { url.scheme == textScheme }

    static func text(of url: URL) -> String? { isText(url) ? texts[url.host ?? ""] : nil }

    /// A text clip that is just one web address.
    static func link(of url: URL) -> URL? {
        guard let t = text(of: url)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.contains(where: \.isWhitespace),
              let link = URL(string: t), ["http", "https"].contains(link.scheme?.lowercased() ?? ""),
              link.host != nil else { return nil }
        return link
    }

    /// Clears the scratch folder: on launch, nothing from last time comes back.
    static func wipe() {
        texts.removeAll()
        sources.removeAll()
        try? FileManager.default.removeItem(at: folder)
    }

    /// Set after the app writes to the pasteboard itself, so copying a card
    /// back does not hang it a second time.
    @MainActor static var ownChangeCount = -1

    /// Keeps image data as a scratch file, gone again when it leaves the line.
    static func save(_ data: Data, ext: String = "png") -> URL? {
        let url = newURL(ext: ext)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            log.error("Could not save clip: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// An image dropped on the line from anywhere: it hangs as a copy, so
    /// taking it down never touches the original.
    static func save(copyOf file: URL) -> URL? {
        let url = newURL(ext: file.pathExtension.isEmpty ? "png" : file.pathExtension.lowercased())
        do {
            try FileManager.default.copyItem(at: file, to: url)
            return url
        } catch {
            log.error("Could not copy dropped file: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func newURL(ext: String) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = stampFormatter.string(from: Date())
        return folder.appendingPathComponent("Clip \(stamp)-\(UUID().uuidString.prefix(4))")
            .appendingPathExtension(ext)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()
}

/// Polls the general pasteboard. macOS has no notification for clipboard
/// changes, so every clipboard manager does this; checking changeCount is cheap.
@MainActor
final class ClipboardWatcher {
    private let onNew: (URL) -> Void
    private var timer: Timer?
    private var lastCount = NSPasteboard.general.changeCount
    private var lastImageHash: String?

    private static let maxTextLength = 100_000
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]

    /// Password managers and the like mark what should not be kept.
    /// See nspasteboard.org.
    private static let skipTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
    ]

    init(onNew: @escaping (URL) -> Void) {
        self.onNew = onNew
    }

    func start() {
        stop()
        lastCount = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        guard pb.changeCount != Clips.ownChangeCount else { return }
        let types = Set((pb.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: Self.skipTypes) else { return }

        // Copying an image file in Finder: hang the file itself.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            for url in urls where Self.imageExtensions.contains(url.pathExtension.lowercased()) {
                onNew(url)
            }
            return
        }

        // Image data: a screenshot sent to the clipboard, or "Copy Image".
        if let png = imagePNG(pb) {
            let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            guard hash != lastImageHash else { return }
            lastImageHash = hash
            if let url = Clips.save(png) { onNew(url) }
            return
        }

        if var text = pb.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if text.count > Self.maxTextLength { text = String(text.prefix(Self.maxTextLength)) }
            onNew(Clips.storeText(text, source: source(of: pb)))
        }
    }

    /// Where a copy came from: Chromium browsers attach the page's address,
    /// otherwise the app in front is the best guess.
    private func source(of pb: NSPasteboard) -> String? {
        let pageType = NSPasteboard.PasteboardType("org.chromium.source-url")
        if let page = pb.string(forType: pageType), let host = URL(string: page)?.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return app.localizedName
    }

    private func imagePNG(_ pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        guard let tiff = pb.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Hides the middle of anything that looks like a key, token or password,
/// for what is shown on the line. Copying a card still gives the real text.
enum Secrets {
    private static func rx(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    /// Whole private key blocks.
    private static let pem = rx(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"#)
    /// password=…, "token": "…", Authorization: Bearer …; the value is group 1.
    private static let keyed = rx(
        #"(?:pass(?:word|wd)?|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|auth(?:orization)?|credential|bearer|cookie|session)[\w-]*["']?\s*[:=]\s*["']?(?:bearer\s+)?([^\s"',;]{4,})"#)
    private static let bearer = rx(#"\bbearer\s+([^\s"',;]{8,})"#)
    /// Well-known token shapes.
    private static let known = rx(
        #"\b(sk-[\w-]{16,}|sk_(?:live|test)_\w{16,}|gh[pousr]_\w{20,}|github_pat_\w{20,}|glpat-[\w-]{20,}|xox[abpr]-[\w-]{10,}|AKIA[0-9A-Z]{16}|AIza[\w-]{30,}|ya29\.[\w-]{20,}|eyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]{8,})"#)
    /// Long random-looking strings, judged by entropy below.
    private static let generic = rx(#"(?<![\w/.-])[A-Za-z0-9+_=-]{24,}(?![\w/.-])"#)

    /// Returns the text with secrets masked, and whether anything was masked.
    static func mask(_ text: String) -> (String, Bool) {
        var ranges: [NSRange] = []
        let all = NSRange(text.startIndex..., in: text)
        for m in pem.matches(in: text, range: all) { ranges.append(m.range) }
        for re in [keyed, bearer] {
            for m in re.matches(in: text, range: all) where m.range(at: 1).location != NSNotFound {
                ranges.append(m.range(at: 1))
            }
        }
        for m in known.matches(in: text, range: all) { ranges.append(m.range) }
        let ns = text as NSString
        for m in generic.matches(in: text, range: all) where looksRandom(ns.substring(with: m.range)) {
            ranges.append(m.range)
        }
        guard !ranges.isEmpty else { return (text, false) }

        // Replace from the end so earlier ranges stay valid; skip overlaps.
        let out = NSMutableString(string: text)
        var lastStart = Int.max
        for r in ranges.sorted(by: { $0.location > $1.location }) where NSMaxRange(r) <= lastStart {
            out.replaceCharacters(in: r, with: hideMiddle(ns.substring(with: r)))
            lastStart = r.location
        }
        return (out as String, true)
    }

    /// Hides the middle of the whole string, whatever it looks like.
    static func conceal(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.contains("\n") ? hideMiddle(String(t.prefix(while: { $0 != "\n" }))) + " …" : hideMiddle(t)
    }

    private static func hideMiddle(_ s: String) -> String {
        if s.hasPrefix("-----BEGIN") { return "-----BEGIN PRIVATE KEY----- •••••• -----END PRIVATE KEY-----" }
        let c = Array(s)
        if c.count >= 12 { return String(c.prefix(4)) + "••••••" + String(c.suffix(4)) }
        return String(c.prefix(2)) + "••••"
    }

    /// Mixed letters and digits with high entropy. Git hashes and UUIDs are
    /// copied all the time and are not secret, so pure hex is left alone.
    private static func looksRandom(_ s: String) -> Bool {
        if s.allSatisfy(\.isHexDigit) || s.allSatisfy({ $0.isHexDigit || $0 == "-" }) { return false }
        guard s.contains(where: \.isNumber), s.contains(where: \.isLetter) else { return false }
        var counts: [Character: Int] = [:]
        for ch in s { counts[ch, default: 0] += 1 }
        let n = Double(s.count)
        let entropy = counts.values.reduce(0.0) { e, k in
            let p = Double(k) / n
            return e - p * log2(p)
        }
        return entropy >= 3.6
    }
}

/// Text cards are sized to what they hold, within these bounds (points, as
/// shown on the line): a code is a small tag, a paragraph a long note.
enum Note {
    static let minWidth: CGFloat = 96, maxWidth: CGFloat = Layout.cardWidth - 14
    static let minHeight: CGFloat = 56, maxHeight: CGFloat = 170
    static let pad: CGFloat = 6

    static var isDark: Bool { NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// Draws `body` on a note just big enough for it, at the size it is shown.
    static func draw(_ body: NSAttributedString, paper: NSColor) -> NSImage {
        let inner = maxWidth - pad * 2
        let oneLine = body.size().width
        let width = oneLine < inner ? max(minWidth, ceil(oneLine) + pad * 2 + 2) : maxWidth
        let needed = body.boundingRect(with: NSSize(width: width - pad * 2, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin]).height
        let height = min(maxHeight, max(minHeight, ceil(needed) + pad * 2))
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        paper.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        // Short text sits in the middle of the smallest note, not at its top.
        let used = min(ceil(needed), height - pad * 2)
        let top = (height - pad * 2 - used) / 2
        body.draw(with: NSRect(x: pad, y: pad + top, width: width - pad * 2, height: used),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        image.unlockFocus()
        return image
    }

    static func paragraph() -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.lineSpacing = 1.5
        return p
    }
}

/// A text clip drawn as a small note, so it can hang next to the photos.
/// A single link shows its site big; secrets are masked.
func makeTextCard(_ text: String, link: URL?, maxPixels: Int = 480) -> NSImage {
    let dark = Note.isDark
    let paper = dark ? NSColor(calibratedRed: 0.20, green: 0.20, blue: 0.22, alpha: 1)
                     : NSColor(calibratedRed: 1.0, green: 0.98, blue: 0.9, alpha: 1)
    let ink = dark ? NSColor(calibratedWhite: 0.92, alpha: 1) : NSColor(calibratedWhite: 0.15, alpha: 1)
    let para = Note.paragraph()
    let body = NSMutableAttributedString()
    if let link, let host = link.host {
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        body.append(NSAttributedString(string: "🔗 " + site, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: ink, .paragraphStyle: para]))
        let rest = Secrets.mask(String(link.absoluteString.dropFirst((link.scheme?.count ?? 0) + 3 + host.count))).0
        if rest.count > 1 {
            body.append(NSAttributedString(string: "\n" + rest, attributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: ink.withAlphaComponent(0.6), .paragraphStyle: para]))
        }
    } else {
        let (masked, hidden) = Secrets.mask(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let shown = masked.count > 400 ? String(masked.prefix(400)) + "…" : masked
        body.append(NSAttributedString(string: (hidden ? "🔒 " : "") + shown, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: ink, .paragraphStyle: para]))
    }
    return Note.draw(body, paper: paper)
}

/// A pin drawn as a card for one of your own lines: its name on top, the
/// value below, keys with only their ends showing.
func makePinCard(title: String, value: String, locked: Bool, maxPixels: Int = 480) -> NSImage {
    let dark = Note.isDark
    let paper = dark ? NSColor(calibratedRed: 0.17, green: 0.20, blue: 0.24, alpha: 1)
                     : NSColor(calibratedRed: 0.92, green: 0.96, blue: 1.0, alpha: 1)
    let ink = dark ? NSColor(calibratedWhite: 0.94, alpha: 1) : NSColor(calibratedWhite: 0.12, alpha: 1)
    let para = Note.paragraph()
    let body = NSMutableAttributedString(string: (locked ? "🔒 " : "") + title + "\n", attributes: [
        .font: NSFont.systemFont(ofSize: 12.5, weight: .bold), .foregroundColor: ink, .paragraphStyle: para])
    let v = value.count > 300 ? String(value.prefix(300)) + "…" : value
    body.append(NSAttributedString(string: v, attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular),
        .foregroundColor: ink.withAlphaComponent(0.7), .paragraphStyle: para]))
    return Note.draw(body, paper: paper)
}
