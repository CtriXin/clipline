import AppKit
import Security

/// One thing kept in the bag: a piece of text you reach for again and again.
struct Pin: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var text: String
    var group: String
}

/// The bag at the end of the line. Unlike everything on the line, what goes
/// in here is kept: it is what you chose to keep. It lives in the Keychain,
/// encrypted, never in a plain file.
@MainActor
final class Bag: ObservableObject {
    static let shared = Bag()
    static let secretGroup = "密钥"
    static let defaultGroups = ["常用", secretGroup]

    @Published private(set) var pins: [Pin] = []
    @Published private(set) var groups: [String] = Bag.defaultGroups

    private init() { load() }

    func pins(in group: String) -> [Pin] { pins.filter { $0.group == group } }

    // MARK: Changing what is in the bag

    func add(_ text: String, to group: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if !groups.contains(group) { groups.append(group) }
        // Already in that group: nothing new to keep.
        guard !pins.contains(where: { $0.text == t && $0.group == group }) else { return }
        pins.append(Pin(title: Self.defaultTitle(for: t), text: t, group: group))
        save()
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = pins.firstIndex(where: { $0.id == id }) else { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        pins[i].title = t.isEmpty ? Self.defaultTitle(for: pins[i].text) : t
        save()
    }

    func move(_ id: UUID, to group: String) {
        guard let i = pins.firstIndex(where: { $0.id == id }) else { return }
        if !groups.contains(group) { groups.append(group) }
        pins[i].group = group
        save()
    }

    func remove(_ id: UUID) {
        pins.removeAll { $0.id == id }
        save()
    }

    func addGroup(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !groups.contains(n) else { return }
        groups.append(n)
        save()
    }

    /// Only an empty group can go; the default ones always stay.
    func removeGroup(_ name: String) {
        guard !Self.defaultGroups.contains(name), pins(in: name).isEmpty else { return }
        groups.removeAll { $0 == name }
        save()
    }

    // MARK: Using it

    func copy(_ id: UUID) {
        guard let pin = pins.first(where: { $0.id == id }) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(pin.text, forType: .string)
        // Keys are marked concealed, so clipboard managers do not record them.
        if isSecret(pin) { item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
        pb.writeObjects([item])
        Clips.ownChangeCount = pb.changeCount
    }

    /// The text behind a card on one of your own lines.
    func text(forCard url: URL) -> String? {
        guard let id = url.host.flatMap(UUID.init(uuidString:)) else { return nil }
        return pins.first { $0.id == id }?.text
    }

    func isSecret(_ pin: Pin) -> Bool { pin.group == Self.secretGroup || Secrets.mask(pin.text).1 }

    /// What the bag shows for a pin: keys keep only their ends.
    func shown(_ pin: Pin) -> String {
        if pin.group == Self.secretGroup { return Secrets.conceal(pin.text) }
        return Secrets.mask(pin.text).0
    }

    static func defaultTitle(for text: String) -> String {
        let first = Secrets.mask(text).0.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.count > 24 ? String(first.prefix(24)) + "…" : first
    }

    // MARK: Keychain

    private struct Stored: Codable {
        var groups: [String]
        var pins: [Pin]
    }

    private static let service = "local.clipline.Clipline.bag"
    private static let account = "bag"

    private func load() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        pins = stored.pins
        groups = Self.defaultGroups + stored.groups.filter { !Self.defaultGroups.contains($0) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Stored(groups: groups, pins: pins)) else { return }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Clipline bag"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            log.error("Could not save the bag to the Keychain: \(status, privacy: .public)")
        }
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
