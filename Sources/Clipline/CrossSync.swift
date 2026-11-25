import AppKit
import CoreImage
import CryptoKit
import Darwin
import Foundation
import Network

/// Cross-device clipboard sync engine (SSE + REST, zero external dependencies).
/// Supports two modes:
/// - Client mode: connects to any Clipline Host or self-hosted clip-hub (LAN, Tailscale, or HTTPS).
/// - Host mode: runs a lightweight embedded HTTP+SSE hub inside Clipline (zero VPS/CLI needed).
@MainActor
final class CrossSync: ObservableObject {
    static let shared = CrossSync()

    enum ConnectionState: Equatable {
        case disabled
        case connecting
        case connected
        case error(String)

        var label: String {
            switch self {
            case .disabled: return "未开启"
            case .connecting: return "连接中…"
            case .connected: return "已连接"
            case .error(let msg): return msg
            }
        }
    }

    struct RemoteDevice: Codable, Equatable, Identifiable {
        let name: String
        let platform: String
        let connected_at: String?
        var id: String { name }

        var icon: String { Self.icon(for: platform) }

        static func icon(for platform: String?) -> String {
            switch platform?.lowercased() {
            case "macos": return "💻"
            case "windows": return "🖥"
            case "ios": return "📱"
            case "android": return "🤖"
            case "web": return "🌐"
            default: return "⚡"
            }
        }
    }

    private struct ClipEvent: Codable {
        let id: Int64
        let kind: String
        let text: String?
        let mime: String?
        let data_base64: String?
        let hash: String
        let device: String
        let platform: String?
    }

    private struct ReadyPayload: Codable {
        let clients: Int?
        let devices: [RemoteDevice]?
    }

    private struct PushPayload: Codable {
        let kind: String
        let text: String?
        let mime: String?
        let data_base64: String?
        let device: String
        let platform: String
    }

    private struct PairPayload: Codable {
        let hub: String
        let token: String
    }

    // MARK: - Persisted settings

    private enum Keys {
        static let enabled = "crossSync.enabled"
        static let hostMode = "crossSync.hostMode"
        static let hostPort = "crossSync.hostPort"
        static let hubURL = "crossSync.hubURL"
        static let token = "crossSync.token"
        static let deviceName = "crossSync.deviceName"
        static let syncImages = "crossSync.syncImages"
        static let initialized = "crossSync.initialized"
    }

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            if isEnabled { restart() } else { stop() }
        }
    }

    @Published var hostMode: Bool {
        didSet {
            UserDefaults.standard.set(hostMode, forKey: Keys.hostMode)
            if hostMode && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                token = Self.randomToken()
            }
            if isEnabled { restart() }
        }
    }

    @Published var hostPort: Int {
        didSet { UserDefaults.standard.set(hostPort, forKey: Keys.hostPort) }
    }

    /// Supports comma-separated fallback URLs, e.g. "http://100.x.y.z:8765,https://example.com/clipsync"
    @Published var hubURL: String {
        didSet { UserDefaults.standard.set(hubURL, forKey: Keys.hubURL) }
    }

    @Published var token: String {
        didSet { UserDefaults.standard.set(token, forKey: Keys.token) }
    }

    @Published var deviceName: String {
        didSet { UserDefaults.standard.set(deviceName, forKey: Keys.deviceName) }
    }

    @Published var syncImages: Bool {
        didSet { UserDefaults.standard.set(syncImages, forKey: Keys.syncImages) }
    }

    @Published private(set) var state: ConnectionState = .disabled
    @Published private(set) var onlineDevices: [RemoteDevice] = []
    @Published private(set) var activeHubURL: String = ""

    /// Called when a clip arrives from another device and has been placed into `Clips`.
    var onRemoteClip: ((URL, Bool) -> Void)?

    private var sseTask: Task<Void, Never>?
    private var localHub: LocalSyncHub?
    private var wakeObserver: Any?
    private let maxBytes = 10 * 1024 * 1024
    private var recentHashes: [String: Date] = [:]

    private init() {
        let ud = UserDefaults.standard
        let defaultName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        var initialToken = ud.string(forKey: Keys.token) ?? ""
        var initialHub = ud.string(forKey: Keys.hubURL) ?? ""
        let savedDevice = ud.string(forKey: Keys.deviceName) ?? ""
        var initialEnabled = ud.bool(forKey: Keys.enabled)
        let savedHostMode = ud.bool(forKey: Keys.hostMode)
        let savedPort = ud.integer(forKey: Keys.hostPort)

        if !ud.bool(forKey: Keys.initialized) {
            ud.set(true, forKey: Keys.initialized)
            if initialToken.isEmpty,
               let fileToken = try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".config/clip-sync/token"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
               !fileToken.isEmpty {
                initialToken = fileToken
                ud.set(fileToken, forKey: Keys.token)
            }
            if initialHub.isEmpty, !initialToken.isEmpty {
                let tailIP = Self.detectTailscaleIP()
                initialHub = tailIP.map { "http://\($0):8765" } ?? ""
                ud.set(initialHub, forKey: Keys.hubURL)
            }
            if !initialToken.isEmpty && !initialHub.isEmpty {
                initialEnabled = true
                ud.set(true, forKey: Keys.enabled)
            }
            ud.set(true, forKey: Keys.syncImages)
        }

        self.isEnabled = initialEnabled
        self.hostMode = savedHostMode
        self.hostPort = savedPort > 0 ? savedPort : 8765
        self.hubURL = initialHub
        self.token = initialToken
        self.deviceName = savedDevice.isEmpty ? defaultName : savedDevice
        self.syncImages = ud.object(forKey: Keys.syncImages) == nil ? true : ud.bool(forKey: Keys.syncImages)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled else { return }
                self.restart()
            }
        }
    }

    // MARK: - Lifecycle

    func startIfEnabled() {
        guard isEnabled else {
            state = .disabled
            return
        }
        restart()
    }

    func restart() {
        stop()
        guard isEnabled else {
            state = .disabled
            return
        }

        var tok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if hostMode {
            if tok.isEmpty {
                tok = Self.randomToken()
                token = tok
            }
            let hub = LocalSyncHub(port: UInt16(clamping: hostPort), token: tok)
            if hub.start() {
                localHub = hub
            } else {
                state = .error("端口 \(hostPort) 启动失败")
                return
            }
        }

        let candidates = hostMode ? ["http://127.0.0.1:\(hostPort)"] : candidateURLs()
        guard !candidates.isEmpty, !tok.isEmpty else {
            state = .error("请粘贴配对码或开启主机")
            return
        }
        state = .connecting
        let dev = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalDev = dev.isEmpty ? "mac" : dev

        sseTask = Task { [weak self] in
            if self?.hostMode == true {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            await self?.runSSELoop(candidates: candidates, token: tok, device: finalDev)
        }
    }

    func stop() {
        sseTask?.cancel()
        sseTask = nil
        localHub?.stop()
        localHub = nil
        onlineDevices = []
        activeHubURL = ""
        if !isEnabled { state = .disabled }
    }

    private func candidateURLs() -> [String] {
        hubURL
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Pairing

    var hasTailscale: Bool { Self.detectTailscaleIP() != nil }

    /// Reachable Hub URL for phones/other machines:
    /// - In host mode: uses Tailscale IP (preferred) or LAN IP on hostPort.
    /// - In client mode: prefers HTTPS public entry when configured (so phones work without Tailscale).
    var shareableHubURL: String {
        if hostMode {
            let ip = Self.detectTailscaleIP() ?? Self.detectLANIP() ?? "127.0.0.1"
            return "http://\(ip):\(hostPort)"
        }
        if let https = candidateURLs().first(where: { $0.lowercased().hasPrefix("https://") }) {
            return https
        }
        let base = (activeHubURL.isEmpty ? candidateURLs().first : activeHubURL) ?? "http://127.0.0.1:\(hostPort)"
        guard var comps = URLComponents(string: base),
              let host = comps.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" else {
            return base
        }
        if let ip = Self.detectTailscaleIP() ?? Self.detectLANIP() {
            comps.host = ip
            return comps.string ?? base
        }
        return base
    }

    var pairingCode: String {
        let payload = PairPayload(hub: shareableHubURL, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let data = try? JSONEncoder().encode(payload) else { return "" }
        return "clipsync://" + data.base64EncodedString()
    }

    var pairingWebURL: String {
        let tok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tok.isEmpty else { return shareableHubURL }
        let encoded = tok.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tok
        return "\(shareableHubURL)/?pair=\(encoded)"
    }

    @discardableResult
    func importPairing(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("clipsync://") {
            let b64 = String(s.dropFirst("clipsync://".count))
            guard let data = Data(base64Encoded: b64),
                  let pair = try? JSONDecoder().decode(PairPayload.self, from: data),
                  !pair.hub.isEmpty, !pair.token.isEmpty else {
                return false
            }
            hostMode = false
            hubURL = pair.hub
            token = pair.token
            isEnabled = true
            restart()
            return true
        }
        if let comps = URLComponents(string: s),
           let pairToken = comps.queryItems?.first(where: { $0.name == "pair" })?.value,
           !pairToken.isEmpty,
           let scheme = comps.scheme, let host = comps.host {
            let portPart = comps.port.map { ":\($0)" } ?? ""
            let pathPart = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            hostMode = false
            hubURL = pathPart.isEmpty ? "\(scheme)://\(host)\(portPart)" : "\(scheme)://\(host)\(portPart)/\(pathPart)"
            token = pairToken
            isEnabled = true
            restart()
            return true
        }
        return false
    }

    static func makeQRCode(for string: String, size: CGFloat = 180) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage else { return nil }
        let scale = size / max(ci.extent.width, 1)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Outbound push

    func pushText(_ text: String) {
        guard isEnabled, !text.isEmpty else { return }
        let data = Data(text.utf8)
        guard data.count <= maxBytes else { return }
        let hash = Self.computeHash(kind: "text", raw: data)
        guard !seenRecently(hash) else { return }
        markHash(hash)
        sendAsync(kind: "text", raw: data)
    }

    func pushImage(_ pngData: Data) {
        guard isEnabled, syncImages, !pngData.isEmpty, pngData.count <= maxBytes else { return }
        let hash = Self.computeHash(kind: "image", raw: pngData)
        guard !seenRecently(hash) else { return }
        markHash(hash)
        sendAsync(kind: "image", raw: pngData)
    }

    private func sendAsync(kind: String, raw: Data) {
        let base = hostMode
            ? "http://127.0.0.1:\(hostPort)"
            : (activeHubURL.isEmpty ? (candidateURLs().first ?? "") : activeHubURL)
        let tok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let dev = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !tok.isEmpty, let url = URL(string: "\(base)/api/clip") else { return }

        let payload = PushPayload(
            kind: kind,
            text: kind == "text" ? String(data: raw, encoding: .utf8) : nil,
            mime: kind == "image" ? "image/png" : nil,
            data_base64: kind == "image" ? raw.base64EncodedString() : nil,
            device: dev.isEmpty ? "mac" : dev,
            platform: "macos"
        )
        guard let body = try? JSONEncoder().encode(payload) else { return }

        Task.detached {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.assumesHTTP3Capable = false
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(payload.device, forHTTPHeaderField: "X-Device")
            req.setValue("macos", forHTTPHeaderField: "X-Platform")
            req.httpBody = body
            let session = Self.makeSession(for: base, sse: false)
            _ = try? await session.data(for: req)
        }
    }

    // MARK: - Inbound SSE loop

    private func runSSELoop(candidates: [String], token: String, device: String) async {
        var idx = 0
        while !Task.isCancelled {
            let base = candidates[idx % candidates.count]
            idx += 1

            var comps = URLComponents(string: "\(base)/api/events")
            comps?.queryItems = [
                URLQueryItem(name: "device", value: device),
                URLQueryItem(name: "platform", value: "macos"),
            ]
            guard let url = comps?.url else {
                state = .error("地址格式有误")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }

            let session = Self.makeSession(for: base, sse: true)
            do {
                var req = URLRequest(url: url)
                req.assumesHTTP3Capable = false
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (bytes, resp) = try await session.bytes(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    state = .error(http.statusCode == 401 ? "Token 无效" : "HTTP \(http.statusCode)")
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    continue
                }

                activeHubURL = base
                state = .connected
                var eventType = ""
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    if line.hasPrefix("event:") {
                        eventType = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        let jsonStr = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        handleSSEEvent(type: eventType, jsonString: jsonStr, localDevice: device)
                    } else if line.isEmpty {
                        eventType = ""
                    }
                }
            } catch {
                if !Task.isCancelled {
                    state = .connecting
                }
            }
            if !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
    }

    private func handleSSEEvent(type: String, jsonString: String, localDevice: String) {
        guard let data = jsonString.data(using: .utf8) else { return }
        switch type {
        case "ready":
            if let ready = try? JSONDecoder().decode(ReadyPayload.self, from: data),
               let devs = ready.devices {
                onlineDevices = devs
            }
        case "devices":
            if let devs = try? JSONDecoder().decode([RemoteDevice].self, from: data) {
                onlineDevices = devs
            }
        case "clip":
            guard let ev = try? JSONDecoder().decode(ClipEvent.self, from: data) else { return }
            guard ev.device != localDevice, !seenRecently(ev.hash) else { return }
            markHash(ev.hash)

            let badge = "\(RemoteDevice.icon(for: ev.platform)) \(ev.device)"
            if ev.kind == "text", let text = ev.text, !text.isEmpty {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                Clips.ownChangeCount = pb.changeCount
                let url = Clips.storeText(text, source: badge)
                Clips.setDevice(badge, for: url)
                onRemoteClip?(url, false)
            } else if ev.kind == "image", syncImages,
                      let b64 = ev.data_base64,
                      let imgData = Data(base64Encoded: b64), !imgData.isEmpty {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setData(imgData, forType: .png)
                Clips.ownChangeCount = pb.changeCount
                if let url = Clips.save(imgData, ext: "png") {
                    Clips.setDevice(badge, for: url)
                    onRemoteClip?(url, true)
                }
            }
        default:
            break
        }
    }

    // MARK: - Dedup & Network helpers

    private func markHash(_ hash: String) {
        let now = Date()
        recentHashes[hash] = now
        recentHashes = recentHashes.filter { now.timeIntervalSince($0.value) <= 20.0 }
    }

    private func seenRecently(_ hash: String) -> Bool {
        guard let ts = recentHashes[hash] else { return false }
        return Date().timeIntervalSince(ts) <= 15.0
    }

    nonisolated static func computeHash(kind: String, raw: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: raw)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func isDirectLANOrTailscale(_ urlStr: String) -> Bool {
        guard let host = URL(string: urlStr)?.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1"
            || host.hasSuffix(".local") || host.hasSuffix(".ts.net") {
            return true
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            if parts[0] == 10 || parts[0] == 127 { return true }
            if parts[0] == 192 && parts[1] == 168 { return true }
            if parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31 { return true }
            if parts[0] == 100 && parts[1] >= 64 && parts[1] <= 127 { return true }
        }
        return false
    }

    nonisolated private static func makeSession(for hubURL: String, sse: Bool) -> URLSession {
        let cfg = URLSessionConfiguration.default
        if isDirectLANOrTailscale(hubURL) {
            cfg.connectionProxyDictionary = [:]
        }
        if sse {
            cfg.timeoutIntervalForRequest = 45
            cfg.timeoutIntervalForResource = 0
        } else {
            cfg.timeoutIntervalForRequest = 15
        }
        return URLSession(configuration: cfg)
    }

    static func detectTailscaleIP() -> String? {
        localIPv4Addresses().first { ip in
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            return parts.count == 4 && parts[0] == 100 && parts[1] >= 64 && parts[1] <= 127
        }
    }

    static func detectLANIP() -> String? {
        localIPv4Addresses().first { ip in
            ip.hasPrefix("192.168.") || ip.hasPrefix("10.")
        }
    }

    private static func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return result }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            if let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if ip != "127.0.0.1" { result.append(ip) }
                }
            }
            ptr = cur.pointee.ifa_next
        }
        return result
    }
}

// MARK: - Embedded Zero-Server HTTP+SSE Sync Hub (for LAN / Tailscale Host Mode)

private final class LocalSyncHub: @unchecked Sendable {
    private let port: UInt16
    private let token: String
    private let queue = DispatchQueue(label: "local.clipline.sync-hub")
    private var listener: NWListener?
    private var pingTimer: DispatchSourceTimer?

    private struct StoredClip: Codable {
        let id: Int64
        let kind: String
        let text: String?
        let mime: String?
        let data_base64: String?
        let size_bytes: Int
        let hash: String
        let device: String
        let platform: String?
        let created_at: String
    }

    private struct DeviceRecord: Codable {
        let name: String
        let platform: String
        let connected_at: String
    }

    private final class Subscriber {
        let conn: NWConnection
        let device: DeviceRecord
        init(conn: NWConnection, device: DeviceRecord) {
            self.conn = conn
            self.device = device
        }
    }

    private var nextID: Int64 = 0
    private var history: [(clip: StoredClip, raw: Data)] = []
    private var subscribers: [ObjectIdentifier: Subscriber] = [:]

    init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }

    func start() -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        do {
            let l = try NWListener(using: .tcp, on: nwPort)
            l.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            l.start(queue: queue)
            listener = l

            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 20, repeating: 20)
            t.setEventHandler { [weak self] in
                self?.sendPingAll()
            }
            t.resume()
            pingTimer = t
            return true
        } catch {
            return false
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.pingTimer?.cancel()
            self?.pingTimer = nil
            self?.listener?.cancel()
            self?.listener = nil
            for (_, sub) in self?.subscribers ?? [:] { sub.conn.cancel() }
            self?.subscribers.removeAll()
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn: conn, buffer: Data())
    }

    private func receiveRequest(conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { _ = error; conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > 16 * 1024 * 1024 {
                self.writeResponse(conn, status: "413 Payload Too Large", contentType: "text/plain", body: Data("too large".utf8))
                return
            }
            let sep = Data("\r\n\r\n".utf8)
            if let headerRange = buf.range(of: sep) {
                let headerData = buf.subdata(in: 0..<headerRange.lowerBound)
                let bodyStart = headerRange.upperBound
                guard let headerText = String(data: headerData, encoding: .utf8) else {
                    conn.cancel(); return
                }
                let lines = headerText.components(separatedBy: "\r\n")
                guard let reqLine = lines.first else { conn.cancel(); return }
                let parts = reqLine.split(separator: " ")
                guard parts.count >= 2 else { conn.cancel(); return }
                let method = String(parts[0])
                let target = String(parts[1])
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    if let idx = line.firstIndex(of: ":") {
                        let k = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
                        let v = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                        headers[k] = v
                    }
                }
                let contentLength = Int(headers["content-length"] ?? "0") ?? 0
                if buf.count - bodyStart >= contentLength {
                    let body = buf.subdata(in: bodyStart..<(bodyStart + contentLength))
                    self.handle(conn: conn, method: method, target: target, headers: headers, body: body)
                    return
                }
            }
            if isComplete { conn.cancel(); return }
            self.receiveRequest(conn: conn, buffer: buf)
        }
    }

    private func isAuthorized(headers: [String: String], query: [String: String]) -> Bool {
        var got = ""
        if let auth = headers["authorization"], auth.hasPrefix("Bearer ") {
            got = String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        } else if let x = headers["x-token"] {
            got = x.trimmingCharacters(in: .whitespaces)
        } else if let q = query["token"] {
            got = q.trimmingCharacters(in: .whitespaces)
        }
        return !got.isEmpty && got == token
    }

    private func handle(conn: NWConnection, method: String, target: String, headers: [String: String], body: Data) {
        let comps = URLComponents(string: "http://local" + target)
        let path = comps?.path ?? target
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }

        if path == "/api/health" {
            writeResponse(conn, status: "200 OK", contentType: "application/json", body: Data("{\"ok\":true}".utf8))
            return
        }
        if path == "/" {
            writeResponse(conn, status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(Self.miniWebHTML.utf8))
            return
        }
        guard isAuthorized(headers: headers, query: query) else {
            writeResponse(conn, status: "401 Unauthorized", contentType: "text/plain", body: Data("unauthorized".utf8))
            return
        }

        switch (method, path) {
        case ("GET", "/api/devices"):
            let devs = currentDevices()
            let data = (try? JSONEncoder().encode(devs)) ?? Data("[]".utf8)
            writeResponse(conn, status: "200 OK", contentType: "application/json", body: data)

        case ("GET", "/api/history"):
            let clips = history.map { $0.clip }
            let data = (try? JSONEncoder().encode(clips)) ?? Data("[]".utf8)
            writeResponse(conn, status: "200 OK", contentType: "application/json", body: data)

        case ("GET", "/api/clip"):
            guard let first = history.first else {
                writeResponse(conn, status: "204 No Content", contentType: "text/plain", body: Data())
                return
            }
            if query["raw"] == "1" {
                writeResponse(conn, status: "200 OK", contentType: first.clip.mime ?? "text/plain; charset=utf-8", body: first.raw)
            } else {
                let data = (try? JSONEncoder().encode(first.clip)) ?? Data("{}".utf8)
                writeResponse(conn, status: "200 OK", contentType: "application/json", body: data)
            }

        case ("POST", "/api/clip"):
            handlePostClip(conn: conn, headers: headers, body: body)

        case ("GET", "/api/events"):
            handleSSE(conn: conn, headers: headers, query: query)

        default:
            if method == "GET", path.hasPrefix("/api/history/"), path.hasSuffix("/raw") {
                let idStr = path.replacingOccurrences(of: "/api/history/", with: "").replacingOccurrences(of: "/raw", with: "")
                if let id = Int64(idStr), let found = history.first(where: { $0.clip.id == id }) {
                    writeResponse(conn, status: "200 OK", contentType: found.clip.mime ?? "application/octet-stream", body: found.raw)
                    return
                }
            }
            writeResponse(conn, status: "404 Not Found", contentType: "text/plain", body: Data("not found".utf8))
        }
    }

    private func handlePostClip(conn: NWConnection, headers: [String: String], body: Data) {
        let ct = (headers["content-type"] ?? "").lowercased()
        var device = headers["x-device"] ?? "unknown"
        var platform = headers["x-platform"] ?? "other"
        var kind = "text"
        var mime = "text/plain; charset=utf-8"
        var raw = body

        if ct.hasPrefix("application/json"),
           let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let d = obj["device"] as? String, !d.isEmpty { device = d }
            if let p = obj["platform"] as? String, !p.isEmpty { platform = p }
            kind = (obj["kind"] as? String) ?? ((obj["data_base64"] as? String) != nil ? "image" : "text")
            if kind == "image", let b64 = obj["data_base64"] as? String, let d = Data(base64Encoded: b64) {
                raw = d
                mime = (obj["mime"] as? String) ?? "image/png"
            } else {
                kind = "text"
                raw = Data(((obj["text"] as? String) ?? "").utf8)
            }
        } else if ct.hasPrefix("image/") {
            kind = "image"
            mime = ct.components(separatedBy: ";").first ?? "image/png"
        }

        guard !raw.isEmpty else {
            writeResponse(conn, status: "400 Bad Request", contentType: "text/plain", body: Data("empty".utf8))
            return
        }

        let hash = CrossSync.computeHash(kind: kind, raw: raw)
        if let latest = history.first, latest.clip.hash == hash {
            writeResponse(conn, status: "200 OK", contentType: "application/json", body: Data("{\"duplicate\":true}".utf8))
            return
        }

        nextID += 1
        let clip = StoredClip(
            id: nextID,
            kind: kind,
            text: kind == "text" ? String(data: raw, encoding: .utf8) : nil,
            mime: mime,
            data_base64: kind == "image" ? raw.base64EncodedString() : nil,
            size_bytes: raw.count,
            hash: hash,
            device: device,
            platform: platform,
            created_at: ISO8601DateFormatter().string(from: Date())
        )
        history.insert((clip, raw), at: 0)
        if history.count > 30 { history.removeLast(history.count - 30) }

        if let json = try? JSONEncoder().encode(clip) {
            broadcast(event: "clip", data: json)
        }
        writeResponse(conn, status: "200 OK", contentType: "application/json", body: Data("{\"duplicate\":false}".utf8))
    }

    private func handleSSE(conn: NWConnection, headers: [String: String], query: [String: String]) {
        let devName = query["device"] ?? headers["x-device"] ?? "client"
        let plat = query["platform"] ?? headers["x-platform"] ?? "other"
        let sub = Subscriber(conn: conn, device: DeviceRecord(name: devName, platform: plat, connected_at: ISO8601DateFormatter().string(from: Date())))
        let key = ObjectIdentifier(conn)
        subscribers[key] = sub
        conn.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.removeSubscriber(key) }
            if case .failed = state { self?.removeSubscriber(key) }
        }

        let devs = currentDevices()
        let devsJSON = (try? JSONEncoder().encode(devs)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\nevent: ready\ndata: {\"clients\":\(devs.count),\"devices\":\(devsJSON)}\n\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] err in
            if err != nil { self?.removeSubscriber(key) }
        })
        if let data = try? JSONEncoder().encode(devs) {
            broadcast(event: "devices", data: data)
        }
    }

    private func removeSubscriber(_ key: ObjectIdentifier) {
        guard subscribers.removeValue(forKey: key) != nil else { return }
        if let data = try? JSONEncoder().encode(currentDevices()) {
            broadcast(event: "devices", data: data)
        }
    }

    private func currentDevices() -> [DeviceRecord] {
        var map: [String: DeviceRecord] = [:]
        for sub in subscribers.values {
            map[sub.device.name] = sub.device
        }
        return map.values.sorted { $0.name < $1.name }
    }

    private func broadcast(event: String, data: Data) {
        guard let str = String(data: data, encoding: .utf8) else { return }
        let frame = Data("event: \(event)\ndata: \(str)\n\n".utf8)
        for (key, sub) in subscribers {
            sub.conn.send(content: frame, completion: .contentProcessed { [weak self] err in
                if err != nil { self?.removeSubscriber(key) }
            })
        }
    }

    private func sendPingAll() {
        let ping = Data(": ping\n\n".utf8)
        for (key, sub) in subscribers {
            sub.conn.send(content: ping, completion: .contentProcessed { [weak self] err in
                if err != nil { self?.removeSubscriber(key) }
            })
        }
    }

    private func writeResponse(_ conn: NWConnection, status: String, contentType: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static let miniWebHTML = """
    <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Clipline Sync</title><style>body{font-family:-apple-system,sans-serif;max-width:680px;margin:0 auto;padding:16px;background:#111;color:#eee}
    textarea,input{width:100%;padding:10px;border-radius:10px;border:1px solid #333;background:#1c1f26;color:#fff;box-sizing:border-box}
    button{padding:10px 14px;border-radius:10px;border:0;background:#4c8dff;color:#fff;font-weight:600;margin:6px 6px 6px 0}
    .card{background:#1c1f26;border-radius:12px;padding:12px;margin:10px 0;white-space:pre-wrap;word-break:break-word}</style></head>
    <body><h3>Clipline 跨设备剪贴板</h3><textarea id="t" rows="3" placeholder="输入或粘贴文字发送..."></textarea>
    <div><button onclick="send()">发送到电脑</button><button onclick="pull()">复制最新</button></div><div id="h"></div>
    <script>const p=new URLSearchParams(location.search);if(p.get('pair')){localStorage.cs_tok=p.get('pair');history.replaceState(null,'','/');}
    const tok=localStorage.cs_tok||prompt('Token')||'';localStorage.cs_tok=tok;
    const hdr={'Authorization':'Bearer '+tok,'X-Device':'mobile-web','X-Platform':'web'};
    async function load(){const r=await fetch('api/history',{headers:hdr});if(!r.ok)return;const a=await r.json();
    document.getElementById('h').innerHTML=a.map(x=>'<div class="card"><small>'+x.device+'</small><br>'+(x.kind==='text'?x.text.replace(/</g,'&lt;'):'[图片]')+'</div>').join('');}
    async function send(){const v=document.getElementById('t').value;if(!v)return;await fetch('api/clip',{method:'POST',headers:hdr,body:v});document.getElementById('t').value='';load();}
    async function pull(){const r=await fetch('api/clip?raw=1',{headers:hdr});if(r.ok){const s=await r.text();navigator.clipboard&&navigator.clipboard.writeText(s);alert('已获取: '+s.slice(0,60));}}
    load();new EventSource('api/events?token='+encodeURIComponent(tok)+'&device=mobile-web&platform=web').addEventListener('clip',load);
    </script></body></html>
    """
}
