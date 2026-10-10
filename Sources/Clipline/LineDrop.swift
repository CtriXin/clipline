import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The line as a drop target, for two things:
///
/// - A card dragged along the rope takes the place under the pointer and the
///   others make room; letting go there keeps the new order.
/// - Pictures, links and text dragged from any app hang on Recent. A picture
///   hangs as a scratch copy, so taking it down never touches the original.
struct LineDrop: DropDelegate {
    let line: Line
    let width: CGFloat

    /// Anything at all, so an app that drags in an odd way (a file promise,
    /// say) still gets a try, and what it offered is logged when nothing fits.
    static let types: [UTType] = [.fileURL, .image, .url, .plainText, .item]

    private var movingCard: UUID? { line.draggingID }

    func validateDrop(info: DropInfo) -> Bool {
        movingCard != nil || info.hasItemsConforming(to: Self.types)
    }

    func dropEntered(info: DropInfo) {
        guard movingCard == nil else { return }
        line.dropTargeted = true
        let offered = info.itemProviders(for: [.item]).flatMap(\.registeredTypeIdentifiers)
        log.notice("Drag over the line offers: \(offered.joined(separator: ", "), privacy: .public)")
    }

    func dropExited(info: DropInfo) {
        line.dropTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let id = movingCard else { return DropProposal(operation: .copy) }
        let x = info.location.x
        // Held near either end, the line slides on to make room further along.
        if x < Layout.tabsReserve + 30 { line.scroll(by: -Layout.spacing / 3) }
        if x > width - Layout.tabsReserve - 30 { line.scroll(by: Layout.spacing / 3) }
        let index = Layout.index(atX: x, count: line.visible.count, width: width, scroll: line.scroll)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { line.moveCard(id, to: index) }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        line.dropTargeted = false
        if movingCard != nil {
            line.finishMove()
            return true
        }
        // Pictures straight off the drag pasteboard first: what the app put
        // there itself, with no file copied on the way. WeChat's file sits in
        // its own container, and the system's copy of it is refused.
        switch Self.pictureFromDragPasteboard() {
        case .picture(let url):
            line.hang(url)
            return true
        case .locked:
            return false
        case .none:
            break
        }
        let providers = info.itemProviders(for: Self.types)
        for provider in providers {
            Self.load(provider) { url in line.hang(url) }
        }
        return !providers.isEmpty
    }

    /// Turns one dropped thing into something the line can hang.
    private static func load(_ provider: NSItemProvider, then hang: @escaping @MainActor (URL) -> Void) {
        let deliver: @Sendable (URL?) -> Void = { url in
            guard let url else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { hang(url) } }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { file, _ in
                guard let file, file.isFileURL,
                      UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true else { return }
                deliver(Clips.save(copyOf: file))
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            // WeChat hands over a file inside its own container, which the
            // system will not copy for us ("Operation not permitted"). Taking
            // it in place and reading it ourselves works; the data is the
            // fallback for apps that only have it in memory.
            let type = provider.registeredTypeIdentifiers
                .first { UTType($0)?.conforms(to: .image) == true } ?? UTType.image.identifier
            _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: type) { file, _, error in
                if let file {
                    let reading = file.startAccessingSecurityScopedResource()
                    defer { if reading { file.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: file) {
                        let ext = file.pathExtension.isEmpty ? "png" : file.pathExtension.lowercased()
                        return deliver(Clips.save(data, ext: ext))
                    }
                }
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, dataError in
                    guard let data, let png = pngData(data) else {
                        log.error("Dropped picture could not be read: \(String(describing: error ?? dataError), privacy: .public)")
                        return
                    }
                    deliver(Clips.save(png))
                }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { link, _ in
                guard let link, !link.isFileURL else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { hang(Clips.storeText(link.absoluteString)) } }
            }
        } else if provider.canLoadObject(ofClass: String.self) {
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { hang(Clips.storeText(text)) } }
            }
        } else {
            log.notice("Dropped item not taken: \(provider.registeredTypeIdentifiers.joined(separator: ", "), privacy: .public)")
        }
    }

    private enum Found { case picture(URL), locked, none }

    private static func pictureFromDragPasteboard() -> Found {
        let pb = NSPasteboard(name: .drag)
        let types = pb.types ?? []
        log.notice("Drag pasteboard types: \(types.map(\.rawValue).joined(separator: ", "), privacy: .public)")
        for type in types {
            guard let ut = UTType(type.rawValue), ut.conforms(to: .image),
                  let data = pb.data(forType: type), !data.isEmpty else { continue }
            if let url = Clips.save(data, ext: ut.preferredFilenameExtension ?? "png") { return .picture(url) }
        }
        // A file anywhere we can read: the original stays untouched.
        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for file in files where UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) == true {
                if let data = try? Data(contentsOf: file),
                   let url = Clips.save(data, ext: file.pathExtension.lowercased()) {
                    return .picture(url)
                }
                log.error("Dropped file not readable: \(file.path, privacy: .public)")
                // Another app's container: macOS only lets us in with Full Disk Access.
                if file.path.contains("/Library/Containers/") {
                    DispatchQueue.main.async { MainActor.assumeIsolated { askForDiskAccess() } }
                    return .locked
                }
            }
        }
        return .none
    }

    @MainActor
    private static func askForDiskAccess() {
        let alert = NSAlert()
        alert.messageText = L("Clipline cannot read this picture")
        alert.informativeText = L("The app it came from keeps it in its own protected folder. Give Clipline Full Disk Access to drop pictures from apps like WeChat, or copy the picture (⌘C) instead: copied pictures hang without it.")
        alert.addButton(withTitle: L("Open Settings"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func pngData(_ data: Data) -> Data? {
        if let rep = NSBitmapImageRep(data: data) { return rep.representation(using: .png, properties: [:]) }
        guard let tiff = NSImage(data: data)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
