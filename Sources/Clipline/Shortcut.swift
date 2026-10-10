import AppKit
import Carbon

/// The shortcut that brings the line down, ⌃⌥T unless you set another.
/// Only this one can change: the keys used while the line is up (⌘1–9, Tab,
/// arrows, Esc) follow what clipboard tools everywhere use.
struct Shortcut: Equatable {
    var keyCode: Int
    /// Carbon modifier flags (cmdKey, optionKey, controlKey, shiftKey).
    var modifiers: Int
    var key: String

    static let standard = Shortcut(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey, key: "T")

    static var saved: Shortcut {
        get {
            let d = UserDefaults.standard
            guard let key = d.string(forKey: "summonKey") else { return .standard }
            return Shortcut(keyCode: d.integer(forKey: "summonKeyCode"), modifiers: d.integer(forKey: "summonModifiers"), key: key)
        }
        set {
            let d = UserDefaults.standard
            d.set(newValue.keyCode, forKey: "summonKeyCode")
            d.set(newValue.modifiers, forKey: "summonModifiers")
            d.set(newValue.key, forKey: "summonKey")
        }
    }

    /// As macOS writes it: ⌃⌥⇧⌘ then the key.
    var display: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s + key
    }

    var menuModifiers: NSEvent.ModifierFlags {
        var m: NSEvent.ModifierFlags = []
        if modifiers & controlKey != 0 { m.insert(.control) }
        if modifiers & optionKey != 0 { m.insert(.option) }
        if modifiers & shiftKey != 0 { m.insert(.shift) }
        if modifiers & cmdKey != 0 { m.insert(.command) }
        return m
    }

    /// A key press usable as a global shortcut: at least ⌃, ⌥ or ⌘ held,
    /// so plain typing is never taken.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
        var m = 0
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.shift) { m |= shiftKey }
        if flags.contains(.command) { m |= cmdKey }
        let special: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
                                      kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓"]
        let code = Int(event.keyCode)
        let name = special[code] ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !name.isEmpty, code != kVK_Escape else { return nil }
        self.init(keyCode: code, modifiers: m, key: name)
    }

    init(keyCode: Int, modifiers: Int, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }
}

/// Asks for a new shortcut by having you press it. Returns nil when
/// cancelled, `.standard` when reset.
@MainActor
func recordShortcut(current: Shortcut) -> Shortcut? {
    let alert = NSAlert()
    alert.messageText = L("Press the new shortcut")
    alert.informativeText = L("Hold ⌃, ⌥ or ⌘ with a key. It brings the line down ready for the keyboard.")
    let label = NSTextField(labelWithString: current.display)
    label.font = .monospacedSystemFont(ofSize: 22, weight: .semibold)
    label.alignment = .center
    label.frame = NSRect(x: 0, y: 0, width: 260, height: 34)
    alert.accessoryView = label
    alert.addButton(withTitle: L("Save"))
    alert.addButton(withTitle: L("Cancel"))
    alert.addButton(withTitle: L("Reset to ⌃⌥T"))

    var picked: Shortcut?
    let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        guard let s = Shortcut(event: event) else { return event }
        picked = s
        label.stringValue = s.display
        return nil
    }
    NSApp.activate(ignoringOtherApps: true)
    let answer = alert.runModal()
    if let monitor { NSEvent.removeMonitor(monitor) }
    switch answer {
    case .alertFirstButtonReturn: return picked
    case .alertThirdButtonReturn: return .standard
    default: return nil
    }
}
