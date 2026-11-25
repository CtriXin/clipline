package local.clipline.android;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.graphics.PixelFormat;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;

/**
 * 1x1-pixel invisible overlay window that briefly acquires window focus (~60ms)
 * to read the system clipboard on Android 10+ when a copy event is detected in
 * WeChat or any other app, then releases focus immediately with zero visual flash.
 */
public final class OverlayClipboardReader {
    private static final Handler main = new Handler(Looper.getMainLooper());
    private static long lastTriggerAt = 0;

    public static void triggerReadAndPush(Context ctx) {
        Context app = ctx.getApplicationContext();
        if (!SyncPrefs.isEnabled(app)) return;
        long now = System.currentTimeMillis();
        if (now - lastTriggerAt < 350) return;
        lastTriggerAt = now;

        main.postDelayed(() -> {
            // Fast path: if app currently has focus or permission allows direct read
            if (tryReadDirectly(app)) return;

            // Android 10+ background path: 1x1 invisible focusable overlay for ~60ms
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(app)) {
                return;
            }
            WindowManager wm = (WindowManager) app.getSystemService(Context.WINDOW_SERVICE);
            if (wm == null) return;

            final View tiny = new View(app);
            tiny.setAlpha(0f);
            int type = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                    ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                    : WindowManager.LayoutParams.TYPE_PHONE;
            WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                    1, 1, type,
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                            | WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH
                            | WindowManager.LayoutParams.FLAG_ALT_FOCUSABLE_IM,
                    PixelFormat.TRANSLUCENT);
            lp.gravity = Gravity.TOP | Gravity.START;
            lp.x = 0;
            lp.y = 0;

            try {
                wm.addView(tiny, lp);
            } catch (Exception ignored) {
                return;
            }

            tiny.postDelayed(() -> {
                try {
                    tryReadDirectly(app);
                } finally {
                    try { wm.removeViewImmediate(tiny); } catch (Exception ignored) {}
                }
            }, 65);
        }, 120);
    }

    private static boolean tryReadDirectly(Context ctx) {
        try {
            ClipboardManager cm = (ClipboardManager) ctx.getSystemService(Context.CLIPBOARD_SERVICE);
            if (cm == null || !cm.hasPrimaryClip()) return false;
            ClipData clip = cm.getPrimaryClip();
            if (clip == null || clip.getItemCount() == 0) return false;
            CharSequence cs = clip.getItemAt(0).coerceToText(ctx);
            if (cs == null) return false;
            String text = cs.toString();
            if (text.trim().isEmpty()) return false;
            SyncEngine.get().pushText(ctx, text);
            return true;
        } catch (Exception ignored) {
            return false;
        }
    }
}
