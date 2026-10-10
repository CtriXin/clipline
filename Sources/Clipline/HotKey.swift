import Carbon

/// Global shortcuts through the Carbon hot key API. Unlike a global key
/// monitor, they need no Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// One entry per live shortcut, so the line's own shortcut and the Space
    /// preview can be registered at the same time.
    private static var actions: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        Self.actions[id] = action
        Self.installHandler()
        let hotKeyID = EventHotKeyID(signature: OSType(0x5445_4E44), id: id) // "TEND"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.actions[id] = nil
    }

    /// A single handler for every shortcut: the event carries which hot key
    /// was pressed, and each one runs its own action.
    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            DispatchQueue.main.async { HotKey.actions[pressed.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
