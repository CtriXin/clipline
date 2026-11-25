# Clipline CrossSync Protocol (v2)

This document specifies the HTTP + SSE synchronization protocol shared by:
- Go standalone hub (`clip-hub`)
- macOS embedded host hub (`Sources/Clipline/CrossSync.swift` → `LocalSyncHub`)
- Windows embedded host hub (`windows/src/CrossSync.cs` → `LocalWindowsHub`)
- macOS, Windows, Android, and Web clients

Protocol v2 is **strictly backward-compatible with v1 clients** for at least one full release cycle.

---

## 1. Authentication

Every endpoint except `GET /api/health` and `GET /` requires the shared bearer token via one of:
1. `Authorization: Bearer <token>` (preferred for all native clients & REST requests)
2. `X-Token: <token>`
3. `?token=<token>` (legacy fallback for browser `EventSource` which cannot set headers)

### Security Invariants
- Authorization MUST be evaluated **before** reading or buffering any request body on protected routes.
- `Content-Length` MUST be validated as `0 <= len <= 16 MiB` (`400 Bad Request` on negative/invalid, `413 Payload Too Large` above limit).
- Pairing URLs use the `#pair=<token>` URL fragment (never sent to HTTP servers or access logs). Clients also accept legacy `?pair=<token>` during migration and `clipsync://<base64-json({"hub","token"})>`.

---

## 2. Device Identity (`device_id`)

- Every v2 client generates and persists a stable UUIDv4 (`device_id`).
- Display name (`device`) is strictly for UI presentation; deduplication in `/api/devices` and self-echo suppression use `device_id` when present (falling back to `device` for v1 clients).

---

## 3. Endpoints

### `GET /api/health` (unauthenticated)
Returns `200 OK` with `{"ok":true}`.

### `GET /api/devices`
Returns JSON array of online devices deduplicated by `id` (or `name` for v1):
```json
[
  {"id": "uuid-...", "name": "Xin MacBook Pro 16", "platform": "macos", "connected_at": "2026-11-25T02:00:00Z"}
]
```

### `POST /api/clip`
Accepts:
- `application/json`: `{"kind":"text"|"image","text":"...","mime":"image/png","data_base64":"...","device":"...","device_id":"...","platform":"macos|windows|android|ios|web"}`
- `image/*`: raw image bytes with optional `X-Device`, `X-Device-Id`, `X-Platform` headers
- `text/plain` (or raw text): UTF-8 body with optional headers

Deduplication: SHA-256 over `kind + "\0" + rawBytes`. Identical consecutive clip returns `{"duplicate":true,...}`.

### `GET /api/history`
Returns JSON array of clip metadata summaries (newest first). **Never** includes `data_base64`.

### `GET /api/history/{id}/raw`
Returns the raw bytes of clip `{id}` with its original `Content-Type` (`image/png`, `text/plain; charset=utf-8`, etc.), plus `X-Clip-Kind` and `X-Clip-Hash`.

### `GET /api/clip[?raw=1]`
Returns the latest clip (`204 No Content` if empty). With `?raw=1`, returns raw bytes; otherwise returns JSON (with `data_base64` populated for legacy v1 callers).

### `GET /api/events` (SSE)
Query parameters:
- `device`: display name
- `device_id`: stable client UUID (v2)
- `platform`: `macos | windows | android | ios | web`
- `meta=1`: v2 lightweight mode — `image` clip events **omit `data_base64`**; clients that want the image fetch `GET /api/history/{id}/raw` on demand. Subscribers without `meta=1` (v1) continue receiving inline `data_base64`.
- `since=<lastClipId>`: optional reconnect catch-up. If the latest clip on the hub has `id > since`, originated from another device, and is ≤10 minutes old, the hub replays that clip immediately after `ready`.

SSE Events:
- `event: ready` → `{"clients": N, "devices": [...], "latest_id": 42}`
- `event: devices` → `[...]`
- `event: clip` → `ClipItem` JSON (`data_base64` omitted when `meta=1`)
- `: ping` comment every 20s

---

## 4. Memory Budget

Hubs store raw payload bytes once (never retaining duplicate base64 strings in memory) and evict oldest entries whenever either limit is exceeded (while keeping at least the newest 1 item):
- Go `clip-hub`: max `50` items, max `64 MiB` total bytes
- Embedded macOS / Windows hubs: max `30` items, max `48 MiB` total bytes
