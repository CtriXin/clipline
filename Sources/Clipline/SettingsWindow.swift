import AppKit
import ServiceManagement
import SwiftUI

/// What the settings window can change that lives in the app delegate.
struct SettingsActions {
    var setInbox: (Bool) -> Void
    var setClipboard: (Bool) -> Void
    var changeShortcut: () -> Void
}

/// One small window for everything that is not used every day, and the
/// place that explains the one permission Clipline can ask for.
@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    private let line: Line
    private let actions: SettingsActions

    init(line: Line, actions: SettingsActions) {
        self.line = line
        self.actions = actions
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(line: line, actions: actions))
            let w = NSWindow(contentViewController: host)
            w.title = L("Clipline Settings")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Full Disk Access is the only way into another app's own folder, which is
/// where WeChat keeps the pictures it drags out.
enum DiskAccess {
    /// A file only readable with Full Disk Access: opening it is the test.
    static var isGranted: Bool {
        let probe = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")
        guard let handle = try? FileHandle(forReadingFrom: probe) else { return false }
        try? handle.close()
        return true
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct SettingsView: View {
    @ObservedObject var line: Line
    let actions: SettingsActions

    @State private var shortcut = Shortcut.saved.display
    @State private var inbox = Inbox.isEnabled
    @State private var clipboard = Clips.isEnabled
    @State private var sound = true
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var diskAccess = DiskAccess.isGranted

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        Form {
            Section(L("General")) {
                LabeledContent(L("Shortcut to bring the line down")) {
                    HStack {
                        Text(shortcut).font(.system(.body, design: .rounded).weight(.semibold))
                        Button(L("Change…")) {
                            actions.changeShortcut()
                            shortcut = Shortcut.saved.display
                        }
                    }
                }
                Picker(L("Line speed"), selection: $line.pace) {
                    ForEach(Line.Pace.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(L("Sounds"), isOn: $sound)
                    .onChange(of: sound) { _, on in line.soundOn = on }
                Toggle(L("Open at login"), isOn: $login)
                    .onChange(of: login) { _, on in
                        // reload() sets these too: only act on a real change.
                        guard on != (SMAppService.mainApp.status == .enabled) else { return }
                        AppDelegate.toggleLaunchAtLogin()
                        login = SMAppService.mainApp.status == .enabled
                    }
            }

            Section(L("What hangs on the line")) {
                Toggle(isOn: $inbox) {
                    Text(L("Handle screenshots"))
                    Text(L("Screenshots hang instantly and skip the Desktop"))
                }
                .onChange(of: inbox) { _, on in if on != Inbox.isEnabled { actions.setInbox(on) } }
                Toggle(isOn: $clipboard) {
                    Text(L("Hang clipboard"))
                    Text(L("Copied text hangs quietly; copied pictures bring the line down. Nothing is kept after Clipline quits."))
                }
                .onChange(of: clipboard) { _, on in if on != Clips.isEnabled { actions.setClipboard(on) } }
            }

            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("Full Disk Access"))
                    Spacer()
                    Label(diskAccess ? L("On") : L("Off"),
                          systemImage: diskAccess ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(diskAccess ? Color.green : Color.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Optional. Some apps, like WeChat, keep the pictures you drag out of them in their own protected folder, which macOS only lets other apps read with this permission. Without it, copy the picture (⌘C) instead: copied pictures hang either way."))
                    Text(L("Clipline only reads a picture when you drop it on the line, keeps a copy that is deleted when it leaves the line or Clipline quits, and never connects to the internet."))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                HStack {
                    Button(L("Open Privacy Settings…")) { DiskAccess.openSettings() }
                    Spacer()
                    if !diskAccess {
                        Text(L("Turn on Clipline in the list, then come back here."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L("Permissions"))
            }

            Section {
                LabeledContent(L("Version"), value: version)
                Link(L("Clipline on GitHub"), destination: URL(string: "https://github.com/CtriXin/clipline")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: reload)
        // Back from System Settings: show what changed there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
    }

    private func reload() {
        shortcut = Shortcut.saved.display
        inbox = Inbox.isEnabled
        clipboard = Clips.isEnabled
        sound = line.soundOn
        login = SMAppService.mainApp.status == .enabled
        diskAccess = DiskAccess.isGranted
    }
}
