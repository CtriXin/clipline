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

    static let types: [UTType] = [.fileURL, .image, .url, .plainText]

    private var movingCard: UUID? { line.draggingID }

    func validateDrop(info: DropInfo) -> Bool {
        movingCard != nil || info.hasItemsConforming(to: Self.types)
    }

    func dropEntered(info: DropInfo) {
        if movingCard == nil { line.dropTargeted = true }
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
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data, let png = pngData(data) else { return }
                deliver(Clips.save(png))
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { link, _ in
                guard let link, !link.isFileURL else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { hang(Clips.storeText(link.absoluteString)) } }
            }
        } else {
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { hang(Clips.storeText(text)) } }
            }
        }
    }

    private static func pngData(_ data: Data) -> Data? {
        if let rep = NSBitmapImageRep(data: data) { return rep.representation(using: .png, properties: [:]) }
        guard let tiff = NSImage(data: data)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
