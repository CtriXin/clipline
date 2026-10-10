import AppKit
import SwiftUI

/// What hangs from the bag when you open it: the groups as small tabs, and
/// under them the pins of that group. Click one to copy it.
@MainActor
final class BagPanel {
    private let panel: NSPanel
    private(set) var isOpen = false

    var frame: CGRect { panel.frame }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: BagView(bag: .shared))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
    }

    /// Opens hanging from the bag, `icon` in screen coordinates.
    func open(below icon: CGRect, on screen: NSScreen) {
        if let host = panel.contentView { panel.setContentSize(host.fittingSize) }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        var x = icon.midX - size.width + 40
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 4)
        let y = max(icon.minY - size.height + 6, visible.minY + 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        guard !isOpen else { return }
        isOpen = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        panel.orderOut(nil)
    }

    /// Keeps the window fitted to its content as pins come and go.
    func refit() {
        guard isOpen, let host = panel.contentView else { return }
        let top = panel.frame.maxY
        let size = host.fittingSize
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height),
                       display: true)
    }
}

/// Asks for one line of text. The app is brought to the front for it, since
/// typing is an explicit request.
@MainActor
func askForText(_ title: String, value: String = "") -> String? {
    let alert = NSAlert()
    alert.messageText = title
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = value
    alert.accessoryView = field
    alert.addButton(withTitle: L("OK"))
    alert.addButton(withTitle: L("Cancel"))
    NSApp.activate(ignoringOtherApps: true)
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

struct BagView: View {
    @ObservedObject var bag: Bag
    /// Holding Option shows keys in full.
    @State private var reveal = false
    private let optionWatch = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            tabs
            let pins = bag.pins(in: bag.selectedGroup)
            if pins.isEmpty {
                Text(L("Right-click a card on the line › Put in the bag"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(pins) { pin in row(pin) }
                    }
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: pins.count <= 7)
            }
            Text(reveal ? L("Showing keys in full") : L("Click to copy · hold ⌥ to show keys"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
        .padding(16)
        .onReceive(optionWatch) { _ in
            let on = NSEvent.modifierFlags.contains(.option)
            if on != reveal { reveal = on }
        }
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(bag.groups, id: \.self) { group in
                    let selected = group == bag.selectedGroup
                    Button {
                        bag.selectedGroup = group
                    } label: {
                        HStack(spacing: 3) {
                            if group == Bag.secretGroup { Image(systemName: "lock.fill").font(.system(size: 9)) }
                            Text(group)
                            Text("\(bag.pins(in: group).count)").foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !Bag.defaultGroups.contains(group) && bag.pins(in: group).isEmpty {
                            Button(L("Delete group")) { bag.removeGroup(group) }
                        }
                    }
                }
                Button {
                    if let name = askForText(L("New group")) { bag.addGroup(name) }
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        .padding(5)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func row(_ pin: Pin) -> some View {
        let copied = bag.copiedID == pin.id
        return Button {
            bag.copy(pin.id)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(pin.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(reveal ? pin.text : bag.shown(pin))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? Color.green : Color.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(BagRowStyle())
        .contextMenu {
            Button(L("Rename…")) {
                if let t = askForText(L("Rename"), value: pin.title) { bag.rename(pin.id, to: t) }
            }
            Menu(L("Move to")) {
                ForEach(bag.groups.filter { $0 != pin.group }, id: \.self) { g in
                    Button(g) { bag.move(pin.id, to: g) }
                }
            }
            Divider()
            Button(L("Remove from the bag"), role: .destructive) { bag.remove(pin.id) }
        }
    }
}

private struct BagRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.06 : 0)),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onHover { hovering = $0 }
    }
}
