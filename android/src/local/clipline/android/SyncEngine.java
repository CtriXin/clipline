package local.clipline.android;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;

public final class SyncEngine {
    public static final class DeviceInfo {
        public final String name;
        public final String platform;
        public DeviceInfo(String name, String platform) {
            this.name = name;
            this.platform = platform;
        }
    }

    public static final class ClipRecord {
        public final String kind;
        public final String text;
        public final String device;
        public final String time;
        public ClipRecord(String kind, String text, String device, String time) {
            this.kind = kind;
            this.text = text;
            this.device = device;
            this.time = time;
        }
    }

    public interface Listener {
        void onStateChanged();
    }

    private static final SyncEngine INSTANCE = new SyncEngine();
    public static SyncEngine get() { return INSTANCE; }

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService io = Executors.newCachedThreadPool();
    private final Map<String, Long> recentHashes = new HashMap<>();
    private final List<Listener> listeners = new ArrayList<>();
    private final List<DeviceInfo> onlineDevices = new ArrayList<>();
    private final List<ClipRecord> history = new ArrayList<>();

    private final AtomicLong generation = new AtomicLong(0);
    private volatile boolean running = false;
    private volatile String status = "未开启";
    private volatile boolean connected = false;
    private volatile String activeHub = "";
    private volatile HttpURLConnection currentConn = null;
    private Context appCtx;

    private SyncEngine() {}

    public void addListener(Listener l) {
        synchronized (listeners) {
            if (!listeners.contains(l)) listeners.add(l);
        }
    }

    public void removeListener(Listener l) {
        synchronized (listeners) { listeners.remove(l); }
    }

    private void notifyListeners() {
        main.post(() -> {
            List<Listener> copy;
            synchronized (listeners) { copy = new ArrayList<>(listeners); }
            for (Listener l : copy) l.onStateChanged();
        });
    }

    public String getStatus() { return status; }
    public boolean isConnected() { return connected; }

    public List<DeviceInfo> getOnlineDevices() {
        synchronized (onlineDevices) { return new ArrayList<>(onlineDevices); }
    }

    public List<ClipRecord> getHistory() {
        synchronized (history) { return new ArrayList<>(history); }
    }

    public synchronized void start(Context ctx) {
        this.appCtx = ctx.getApplicationContext();
        stop();
        if (!SyncPrefs.isEnabled(appCtx)) {
            status = "未开启";
            connected = false;
            notifyListeners();
            return;
        }
        List<String> hubs = candidateHubs(SyncPrefs.getHubUrl(appCtx));
        String tok = SyncPrefs.getToken(appCtx);
        if (hubs.isEmpty() || tok.isEmpty()) {
            status = "请粘贴配对码";
            connected = false;
            notifyListeners();
            return;
        }
        final long myGen = generation.incrementAndGet();
        running = true;
        status = "连接中…";
        connected = false;
        notifyListeners();
        final String dev = SyncPrefs.getDeviceName(appCtx);
        Thread t = new Thread(() -> sseLoop(myGen, hubs, tok, dev), "CliplineSSE-" + myGen);
        t.setDaemon(true);
        t.start();
    }

    public synchronized void stop() {
        generation.incrementAndGet();
        running = false;
        connected = false;
        HttpURLConnection c = currentConn;
        currentConn = null;
        if (c != null) {
            io.execute(() -> { try { c.disconnect(); } catch (Exception ignored) {} });
        }
        synchronized (onlineDevices) { onlineDevices.clear(); }
        status = "未开启";
        notifyListeners();
    }

    public void pushText(Context ctx, String text) {
        if (text == null || text.trim().isEmpty()) return;
        Context c = ctx.getApplicationContext();
        if (!SyncPrefs.isEnabled(c)) return;
        byte[] raw = text.getBytes(StandardCharsets.UTF_8);
        if (raw.length > 10 * 1024 * 1024) return;
        String hash = computeHash("text", raw);
        if (seenRecently(hash)) return;
        markHash(hash);

        io.execute(() -> sendPayload(c, "text", text, null, null));
    }

    public void pushImage(Context ctx, byte[] bytes, String mime) {
        if (bytes == null || bytes.length == 0 || bytes.length > 10 * 1024 * 1024) return;
        Context c = ctx.getApplicationContext();
        if (!SyncPrefs.isEnabled(c)) return;
        String hash = computeHash("image", bytes);
        if (seenRecently(hash)) return;
        markHash(hash);
        String finalMime = (mime == null || mime.isEmpty()) ? "image/png" : mime;
        io.execute(() -> sendPayload(c, "image", null, bytes, finalMime));
    }

    private void sendPayload(Context ctx, String kind, String text, byte[] imgBytes, String mime) {
        List<String> targets = new ArrayList<>();
        if (!activeHub.isEmpty()) targets.add(activeHub);
        for (String h : candidateHubs(SyncPrefs.getHubUrl(ctx))) {
            if (!targets.contains(h)) targets.add(h);
        }
        String tok = SyncPrefs.getToken(ctx);
        String dev = SyncPrefs.getDeviceName(ctx);
        if (targets.isEmpty() || tok.isEmpty()) return;

        try {
            JSONObject obj = new JSONObject();
            obj.put("kind", kind);
            obj.put("device", dev);
            obj.put("platform", "android");
            if ("text".equals(kind)) {
                obj.put("text", text);
            } else {
                obj.put("mime", mime);
                obj.put("data_base64", Base64.encodeToString(imgBytes, Base64.NO_WRAP));
            }
            byte[] body = obj.toString().getBytes(StandardCharsets.UTF_8);

            for (String base : targets) {
                HttpURLConnection conn = null;
                try {
                    conn = (HttpURLConnection) new URL(base + "/api/clip").openConnection();
                    conn.setRequestMethod("POST");
                    conn.setConnectTimeout(8000);
                    conn.setReadTimeout(10000);
                    conn.setDoOutput(true);
                    conn.setRequestProperty("Authorization", "Bearer " + tok);
                    conn.setRequestProperty("Content-Type", "application/json");
                    conn.setRequestProperty("X-Device", dev);
                    conn.setRequestProperty("X-Platform", "android");
                    try (OutputStream os = conn.getOutputStream()) {
                        os.write(body);
                    }
                    int code = conn.getResponseCode();
                    if (code >= 200 && code < 300) {
                        activeHub = base;
                        addHistory(new ClipRecord(kind, "text".equals(kind) ? text : "[图片]", dev, "刚刚"));
                        return;
                    }
                } catch (Exception ignored) {
                } finally {
                    if (conn != null) conn.disconnect();
                }
            }
        } catch (Exception ignored) {}
    }

    private boolean isCurrent(long gen) {
        return running && generation.get() == gen;
    }

    private void sseLoop(long gen, List<String> hubs, String tok, String dev) {
        int idx = 0;
        while (isCurrent(gen)) {
            String base = hubs.get(idx % hubs.size());
            idx++;
            HttpURLConnection conn = null;
            try {
                String q = "device=" + URLEncoder.encode(dev, "UTF-8") + "&platform=android";
                conn = (HttpURLConnection) new URL(base + "/api/events?" + q).openConnection();
                conn.setRequestMethod("GET");
                conn.setConnectTimeout(10000);
                conn.setReadTimeout(45000);
                conn.setRequestProperty("Authorization", "Bearer " + tok);
                if (!isCurrent(gen)) break;
                currentConn = conn;

                int code = conn.getResponseCode();
                if (!isCurrent(gen)) break;
                if (code != 200) {
                    connected = false;
                    status = (code == 401) ? "Token 无效" : ("HTTP " + code);
                    notifyListeners();
                    sleepQuiet(4000);
                    continue;
                }

                activeHub = base;
                connected = true;
                status = "已连接";
                notifyListeners();

                try (BufferedReader br = new BufferedReader(new InputStreamReader(conn.getInputStream(), StandardCharsets.UTF_8))) {
                    String evType = "";
                    String line;
                    while (isCurrent(gen) && (line = br.readLine()) != null) {
                        if (line.startsWith("event:")) {
                            evType = line.substring(6).trim();
                        } else if (line.startsWith("data:")) {
                            handleEvent(evType, line.substring(5).trim(), dev);
                        } else if (line.isEmpty()) {
                            evType = "";
                        }
                    }
                }
            } catch (Exception ignored) {
                if (isCurrent(gen)) {
                    connected = false;
                    status = "重连中…";
                    notifyListeners();
                }
            } finally {
                if (conn != null) try { conn.disconnect(); } catch (Exception ignored) {}
                if (currentConn == conn) currentConn = null;
            }
            if (isCurrent(gen)) sleepQuiet(2500);
        }
    }

    private void handleEvent(String type, String data, String localDev) {
        try {
            if ("ready".equals(type)) {
                JSONObject obj = new JSONObject(data);
                updateDevices(obj.optJSONArray("devices"));
            } else if ("devices".equals(type)) {
                updateDevices(new JSONArray(data));
            } else if ("clip".equals(type)) {
                JSONObject obj = new JSONObject(data);
                String dev = obj.optString("device", "");
                String hash = obj.optString("hash", "");
                String kind = obj.optString("kind", "");
                if (dev.equalsIgnoreCase(localDev) || seenRecently(hash)) return;
                markHash(hash);

                if ("text".equals(kind)) {
                    String text = obj.optString("text", "");
                    if (!text.isEmpty()) {
                        writeClipboardText(text);
                        addHistory(new ClipRecord("text", text, dev, "刚刚"));
                    }
                } else if ("image".equals(kind)) {
                    addHistory(new ClipRecord("image", "[图片，请在网页端查看]", dev, "刚刚"));
                }
            }
        } catch (Exception ignored) {}
    }

    private void updateDevices(JSONArray arr) {
        if (arr == null) return;
        List<DeviceInfo> list = new ArrayList<>();
        for (int i = 0; i < arr.length(); i++) {
            JSONObject d = arr.optJSONObject(i);
            if (d != null) list.add(new DeviceInfo(d.optString("name"), d.optString("platform")));
        }
        synchronized (onlineDevices) {
            onlineDevices.clear();
            onlineDevices.addAll(list);
        }
        if (connected) status = "已连接 · " + Math.max(1, list.size()) + " 台在线";
        notifyListeners();
    }

    private void addHistory(ClipRecord rec) {
        synchronized (history) {
            history.add(0, rec);
            if (history.size() > 30) history.remove(history.size() - 1);
        }
        notifyListeners();
    }

    public void writeClipboardText(String text) {
        if (appCtx == null || text == null) return;
        main.post(() -> {
            try {
                ClipboardManager cm = (ClipboardManager) appCtx.getSystemService(Context.CLIPBOARD_SERVICE);
                if (cm != null) {
                    cm.setPrimaryClip(ClipData.newPlainText("Clipline", text));
                }
            } catch (Exception ignored) {}
        });
    }

    private synchronized void markHash(String h) {
        if (h == null || h.isEmpty()) return;
        long now = System.currentTimeMillis();
        recentHashes.put(h, now);
        Iterator<Map.Entry<String, Long>> it = recentHashes.entrySet().iterator();
        while (it.hasNext()) {
            if (now - it.next().getValue() > 20000L) it.remove();
        }
    }

    private synchronized boolean seenRecently(String h) {
        if (h == null || h.isEmpty()) return false;
        Long ts = recentHashes.get(h);
        return ts != null && (System.currentTimeMillis() - ts) <= 15000L;
    }

    private static String computeHash(String kind, byte[] raw) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            md.update((kind + "\0").getBytes(StandardCharsets.UTF_8));
            md.update(raw);
            byte[] sum = md.digest();
            StringBuilder sb = new StringBuilder(sum.length * 2);
            for (byte b : sum) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (Exception e) {
            return "";
        }
    }

    private static List<String> candidateHubs(String raw) {
        List<String> out = new ArrayList<>();
        if (raw == null) return out;
        for (String p : raw.split(",")) {
            String s = p.trim().replaceAll("/+$", "");
            if (!s.isEmpty()) out.add(s);
        }
        return out;
    }

    private static void sleepQuiet(long ms) {
        try { Thread.sleep(ms); } catch (InterruptedException ignored) {}
    }
}
