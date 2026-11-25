import Foundation
import Network

// Minimal stub for Clips referenced by CrossSync.swift
@MainActor
enum Clips {
    static var ownChangeCount: Int = 0
    static func storeText(_ text: String, source: String?) -> URL { URL(fileURLWithPath: "/tmp/stub.txt") }
    static func save(_ data: Data, ext: String = "png") -> URL? { URL(fileURLWithPath: "/tmp/stub.png") }
    static func setDevice(_ badge: String, for url: URL) {}
}

func assertTrue(_ cond: Bool, _ msg: String) {
    if !cond {
        fputs("FAIL: \(msg)\n", stderr)
        exit(1)
    }
}

func sendRawHTTP(port: UInt16, raw: String) -> String {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    assertTrue(sock >= 0, "socket() failed")
    defer { close(sock) }

    var tv = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let res = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    assertTrue(res == 0, "connect() failed on port \(port)")

    let bytes = Array(raw.utf8)
    _ = bytes.withUnsafeBytes { send(sock, $0.baseAddress, $0.count, 0) }

    var buf = [UInt8](repeating: 0, count: 4096)
    let n = recv(sock, &buf, buf.count, 0)
    guard n > 0 else { return "" }
    return String(decoding: buf[0..<n], as: UTF8.self)
}

@main
struct CrossSyncRegressionTests {
    static func main() {
        // 1. Pairing URL parser regression: #pair=, ?pair=, clipsync://
        let pHash = CrossSync.parsePairing("https://example.com/clipsync/#pair=secretHash123")
        assertTrue(pHash?.hub == "https://example.com/clipsync" && pHash?.token == "secretHash123",
                   "fragment #pair= parse failed: \(String(describing: pHash))")

        let pQuery = CrossSync.parsePairing("https://example.com/clipsync/?pair=legacyQuery456")
        assertTrue(pQuery?.hub == "https://example.com/clipsync" && pQuery?.token == "legacyQuery456",
                   "legacy ?pair= parse failed: \(String(describing: pQuery))")

        let b64 = Data(#"{"hub":"http://10.0.0.2:8765","token":"tok789"}"#.utf8).base64EncodedString()
        let pScheme = CrossSync.parsePairing("clipsync://" + b64)
        assertTrue(pScheme?.hub == "http://10.0.0.2:8765" && pScheme?.token == "tok789",
                   "clipsync:// parse failed: \(String(describing: pScheme))")

        assertTrue(CrossSync.parsePairing("https://example.com/") == nil, "missing pair token should fail")
        print("PASS: pairing URL parser (#pair=, ?pair=, clipsync://)")

        // 2. LocalSyncHub regression: auth before body + negative Content-Length
        let port: UInt16 = 18769
        let hub = LocalSyncHub(port: port, token: "valid-secret")
        assertTrue(hub.start(), "LocalSyncHub failed to start")
        Thread.sleep(forTimeInterval: 0.25)

        // 2a. Unauthenticated request with Content-Length: -1 -> 401 (auth checked BEFORE length/body, no crash!)
        let respUnauthNeg = sendRawHTTP(
            port: port,
            raw: "POST /api/clip HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: -1\r\n\r\n"
        )
        assertTrue(respUnauthNeg.contains("401 Unauthorized"),
                   "expected 401 before body/length on unauth request, got: \(respUnauthNeg)")

        // 2b. Unauthenticated request claiming 10MB body without sending body -> immediate 401 (no hang/buffer!)
        let respUnauthBig = sendRawHTTP(
            port: port,
            raw: "POST /api/clip HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 10000000\r\n\r\n"
        )
        assertTrue(respUnauthBig.contains("401 Unauthorized"),
                   "expected immediate 401 on unauth 10MB claim, got: \(respUnauthBig)")

        // 2c. Authenticated request with Content-Length: -1 -> 400 Bad Request (no SIGTRAP crash!)
        let respAuthNeg = sendRawHTTP(
            port: port,
            raw: "POST /api/clip HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer valid-secret\r\nContent-Length: -1\r\n\r\n"
        )
        assertTrue(respAuthNeg.contains("400 Bad Request"),
                   "expected 400 on negative Content-Length, got: \(respAuthNeg)")

        // 2d. Health endpoint still alive after attacks
        let respHealth = sendRawHTTP(
            port: port,
            raw: "GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        )
        assertTrue(respHealth.contains("200 OK") && respHealth.contains("\"ok\":true"),
                   "health check failed after negative Content-Length: \(respHealth)")

        hub.stop()
        print("PASS: LocalSyncHub negative Content-Length + auth-before-body regression tests")
    }
}
