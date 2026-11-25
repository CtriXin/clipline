import AppKit
import Combine
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
        Task { @MainActor in
            PermissionDragGuide.shared.show()
        }
    }
}

/// Floating always-on-top helper card that lets the user drag Clipline's own
/// .app icon directly into System Settings → Full Disk Access without hunting
/// through folders.
@MainActor
final class PermissionDragGuide {
    static let shared = PermissionDragGuide()
    private var panel: NSPanel?
    private var timer: Timer?

    func show() {
        if panel == nil {
            let host = NSHostingController(rootView: PermissionDragGuideView(onClose: { [weak self] in self?.close() }))
            let p = NSPanel(contentViewController: host)
            p.title = "拖入完全磁盘访问权限"
            p.styleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel]
            p.level = .floating
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                let vf = screen.visibleFrame
                let size = p.frame.size
                p.setFrameOrigin(NSPoint(x: vf.minX + 60, y: vf.midY - size.height / 2))
            }
            panel = p
        }
        panel?.orderFrontRegardless()
        startPolling()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if DiskAccess.isGranted {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self?.close()
                    }
                }
            }
        }
    }
}

private struct PermissionDragGuideView: View {
    let onClose: () -> Void
    @State private var granted = DiskAccess.isGranted
    private let poll = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.green)
                Text("完全磁盘访问权限已开启")
                    .font(.headline)
            } else {
                Text("直接把下面图标拖进「完全磁盘访问权限」列表")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                HStack(spacing: 16) {
                    VStack(spacing: 6) {
                        DraggableAppIconView(size: 64)
                            .frame(width: 64, height: 64)
                        Text("按住拖动我")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(10)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                    Image(systemName: "arrow.right")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. 拖到右侧系统设置列表松手")
                        Text("2. 输入密码或指纹确认")
                        Text("3. 勾选开启 Clipline 开关")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                HStack {
                    Button("在访达中显示 App") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                    Spacer()
                    Button("关闭") { onClose() }
                }
            }
        }
        .padding(18)
        .frame(width: 380)
        .onReceive(poll) { _ in
            granted = DiskAccess.isGranted
        }
    }
}

/// Native AppKit drag source that drags `Bundle.main.bundleURL` as a real `.app`
/// file URL so macOS System Settings accepts the drop directly.
private struct DraggableAppIconView: NSViewRepresentable {
    let size: CGFloat

    func makeNSView(context: Context) -> DragIconNSView {
        let v = DragIconNSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        v.iconSize = size
        return v
    }

    func updateNSView(_ nsView: DragIconNSView, context: Context) {
        nsView.iconSize = size
    }

    final class DragIconNSView: NSView, NSDraggingSource {
        var iconSize: CGFloat = 56
        private var mouseDownPoint: NSPoint?

        override func draw(_ dirtyRect: NSRect) {
            let img = NSImage(named: "Clipline") ?? NSApp.applicationIconImage
            img?.draw(in: bounds)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = convert(event.locationInWindow, from: nil)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownPoint else { return }
            let cur = convert(event.locationInWindow, from: nil)
            if hypot(cur.x - start.x, cur.y - start.y) < 3 { return }
            mouseDownPoint = nil

            let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
            let img = NSImage(named: "Clipline") ?? NSApp.applicationIconImage
            item.setDraggingFrame(bounds, contents: img)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var line: Line
    @ObservedObject private var sync = CrossSync.shared
    let actions: SettingsActions

    @State private var shortcut = Shortcut.saved.display
    @State private var zone = HotZone.saved
    @State private var delay = HotZone.Delay.saved
    @State private var inbox = Inbox.isEnabled
    @State private var clipboard = Clips.isEnabled
    @State private var sound = true
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var diskAccess = DiskAccess.isGranted
    @State private var showPairSheet = false
    @State private var showSyncDetails = false
    @State private var pairFeedback: String?

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
                Picker(L("Bring it down by resting the pointer on"), selection: $zone) {
                    ForEach(HotZone.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: zone) { _, z in HotZone.saved = z }
                if zone != .off {
                    Picker(L("How long it rests there"), selection: $delay) {
                        ForEach(HotZone.Delay.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: delay) { _, d in HotZone.Delay.saved = d }
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
                Toggle(isOn: $sync.isEnabled) {
                    HStack(spacing: 6) {
                        Text("跨设备同步")
                        Circle()
                            .fill(syncDotColor)
                            .frame(width: 8, height: 8)
                        Text(syncStatusSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if sync.isEnabled {
                    Picker("角色", selection: $sync.hostMode) {
                        Text("连接主机").tag(false)
                        Text("本机作主机").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if !sync.onlineDevices.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(sync.onlineDevices) { dev in
                                    Text("\(dev.icon) \(dev.name)")
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                                }
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Button("扫码配对") { showPairSheet = true }
                            .disabled(sync.token.isEmpty)
                        Button("粘贴配对码") {
                            let text = NSPasteboard.general.string(forType: .string) ?? ""
                            pairFeedback = sync.importPairing(text) ? "已配对并连接" : "剪贴板中无有效配对码"
                        }
                        if !sync.token.isEmpty {
                            Button("复制配对码") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(sync.pairingCode, forType: .string)
                                Clips.ownChangeCount = NSPasteboard.general.changeCount
                                pairFeedback = "已复制，去另一台设备点「粘贴配对码」"
                            }
                        }
                        Spacer()
                    }

                    HStack(spacing: 6) {
                        Text(syncGuideText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !sync.hasTailscale {
                            Link("安装 Tailscale ↗", destination: URL(string: "https://tailscale.com/download")!)
                                .font(.caption)
                        }
                    }

                    if let pairFeedback {
                        Text(pairFeedback).font(.caption).foregroundStyle(.secondary)
                    }

                    DisclosureGroup("连接设置", isExpanded: $showSyncDetails) {
                        if !sync.hostMode {
                            TextField("Hub 地址", text: $sync.hubURL)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            LabeledContent("监听地址", value: sync.shareableHubURL)
                        }
                        SecureField("Token", text: $sync.token)
                            .textFieldStyle(.roundedBorder)
                        TextField("设备名", text: $sync.deviceName)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Toggle("同步图片（≤10MB）", isOn: $sync.syncImages)
                            Spacer()
                            Button("重连") { sync.restart() }
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        Text("支持 Mac / Windows / 手机互通：一台开「本机作主机」，其余粘贴配对码或扫码。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Link("Tailscale ↗", destination: URL(string: "https://tailscale.com/download")!)
                            .font(.caption)
                    }
                }
            } header: {
                Text("跨设备同步")
            }

            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("Full Disk Access"))
                    Spacer()
                    Label(diskAccess ? L("On") : L("Off"),
                          systemImage: diskAccess ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(diskAccess ? Color.green : Color.secondary)
                }
                Text("仅用于拖拽微信等受保护目录内的图片（直接 ⌘C 复制无需此权限）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if !diskAccess {
                        DraggableAppIconView(size: 36)
                            .frame(width: 36, height: 36)
                            .help("拖进系统设置的完全磁盘访问列表")
                    }
                    Button(L("Open Privacy Settings…")) { DiskAccess.openSettings() }
                    Spacer()
                    if !diskAccess {
                        Text("把图标拖进系统设置列表即可")
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
        .frame(width: 540, height: 640)
        .sheet(isPresented: $showPairSheet) {
            PairDeviceSheet(sync: sync, dismiss: { showPairSheet = false })
        }
        .onAppear(perform: reload)
        // Back from System Settings: show what changed there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
    }

    private var syncDotColor: Color {
        switch sync.state {
        case .connected: return .green
        case .connecting: return .orange
        case .error: return .red
        case .disabled: return .secondary
        }
    }

    private var syncStatusSummary: String {
        if case .connected = sync.state {
            return "已连接 · \(max(1, sync.onlineDevices.count)) 台在线"
        }
        return sync.state.label
    }

    private var syncGuideText: String {
        if sync.hostMode {
            return sync.hasTailscale
                ? "已检测到 Tailscale：点「扫码配对」或「复制配对码」连其他设备。"
                : "同 Wi-Fi 可直连；跨网建议装免费 Tailscale 组网。"
        }
        if sync.token.isEmpty || sync.hubURL.isEmpty {
            return "在另一台设备复制配对码后点「粘贴配对码」，或展开连接设置。"
        }
        return "跨网直连可用免费 Tailscale 或自建 HTTPS Hub。"
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

private struct PairDeviceSheet: View {
    @ObservedObject var sync: CrossSync
    let dismiss: () -> Void
    @State private var copiedHint: String?

    var body: some View {
        VStack(spacing: 14) {
            Text("配对新设备（iPhone / Android / Mac / Windows）")
                .font(.headline)

            if let qr = CrossSync.makeQRCode(for: sync.pairingWebURL, size: 180) {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            }

            Text("用 iPhone / Android 相机扫码即可自动登录 ClipSync 网页端，并可一键导入手机快捷指令。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(sync.shareableHubURL)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("复制配对码（给其他电脑）") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sync.pairingCode, forType: .string)
                    Clips.ownChangeCount = NSPasteboard.general.changeCount
                    copiedHint = "已复制配对码，去另一台 Mac 的 Clipline 点「粘贴配对码」即可"
                }
                Button("打开 Web 端") {
                    if let url = URL(string: sync.pairingWebURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if let copiedHint {
                Text(copiedHint).font(.caption).foregroundStyle(.green)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
