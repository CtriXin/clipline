package local.clipline.android;

import android.content.Context;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Build;
import android.util.Base64;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;

public final class SyncPrefs {
    private static final String NAME = "clipline_sync";

    private static SharedPreferences prefs(Context ctx) {
        return ctx.getApplicationContext().getSharedPreferences(NAME, Context.MODE_PRIVATE);
    }

    public static boolean isEnabled(Context ctx) {
        return prefs(ctx).getBoolean("enabled", false);
    }

    public static void setEnabled(Context ctx, boolean v) {
        prefs(ctx).edit().putBoolean("enabled", v).apply();
    }

    public static String getHubUrl(Context ctx) {
        return prefs(ctx).getString("hub_url", "").trim();
    }

    public static void setHubUrl(Context ctx, String v) {
        prefs(ctx).edit().putString("hub_url", v == null ? "" : v.trim()).apply();
    }

    public static String getToken(Context ctx) {
        return prefs(ctx).getString("token", "").trim();
    }

    public static void setToken(Context ctx, String v) {
        prefs(ctx).edit().putString("token", v == null ? "" : v.trim()).apply();
    }

    public static String getDeviceName(Context ctx) {
        String def = Build.MODEL == null ? "android" : Build.MODEL.toLowerCase().replace(" ", "-");
        String v = prefs(ctx).getString("device_name", def);
        return (v == null || v.trim().isEmpty()) ? def : v.trim();
    }

    public static void setDeviceName(Context ctx, String v) {
        prefs(ctx).edit().putString("device_name", v == null ? "" : v.trim()).apply();
    }

    public static String[] parsePairing(String raw) {
        if (raw == null) return null;
        String s = raw.trim();
        if (s.startsWith("clipsync://")) {
            try {
                String b64 = s.substring("clipsync://".length());
                byte[] decoded = Base64.decode(b64, Base64.DEFAULT);
                JSONObject obj = new JSONObject(new String(decoded, StandardCharsets.UTF_8));
                String hub = obj.optString("hub", "").trim();
                String tok = obj.optString("token", "").trim();
                if (hub.isEmpty() || tok.isEmpty()) return null;
                return new String[]{hub, tok};
            } catch (Exception ignored) {
                return null;
            }
        }
        try {
            Uri uri = Uri.parse(s);
            String pairTok = null;
            String frag = uri.getFragment();
            if (frag != null && !frag.isEmpty()) {
                pairTok = Uri.parse("http://local/?" + frag).getQueryParameter("pair");
            }
            if (pairTok == null || pairTok.trim().isEmpty()) {
                pairTok = uri.getQueryParameter("pair");
            }
            if (pairTok != null && !pairTok.trim().isEmpty() && uri.getScheme() != null && uri.getHost() != null) {
                String portPart = uri.getPort() > 0 ? (":" + uri.getPort()) : "";
                String path = uri.getPath() == null ? "" : uri.getPath().replaceAll("/+$", "");
                String hub = uri.getScheme() + "://" + uri.getHost() + portPart + path;
                return new String[]{hub, pairTok.trim()};
            }
        } catch (Exception ignored) {}
        return null;
    }

    public static boolean importPairing(Context ctx, String raw) {
        String[] parsed = parsePairing(raw);
        if (parsed == null) return false;
        setHubUrl(ctx, parsed[0]);
        setToken(ctx, parsed[1]);
        setEnabled(ctx, true);
        return true;
    }
}
