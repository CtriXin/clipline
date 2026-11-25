package local.clipline.android;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

public final class ClipSyncService extends Service {
    public static final String ACTION_PUSH_NOW = "local.clipline.android.PUSH_NOW";
    private static final String CHANNEL_ID = "clipline_sync";
    private static final int NOTIF_ID = 1001;

    private ClipboardManager clipboard;
    private final ClipboardManager.OnPrimaryClipChangedListener clipListener =
            () -> OverlayClipboardReader.triggerReadAndPush(this);
    private final SyncEngine.Listener syncListener = this::updateNotification;

    public static void startOrStop(Context ctx) {
        Intent i = new Intent(ctx, ClipSyncService.class);
        if (SyncPrefs.isEnabled(ctx)) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ctx.startForegroundService(i);
            } else {
                ctx.startService(i);
            }
        } else {
            ctx.stopService(i);
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        createChannel();
        Notification n = buildNotification("连接中…");
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        } else {
            startForeground(NOTIF_ID, n);
        }
        clipboard = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
        if (clipboard != null) {
            try { clipboard.addPrimaryClipChangedListener(clipListener); } catch (Exception ignored) {}
        }
        SyncEngine.get().addListener(syncListener);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_PUSH_NOW.equals(intent.getAction())) {
            OverlayClipboardReader.triggerReadAndPush(this);
            return START_STICKY;
        }
        if (!SyncPrefs.isEnabled(this)) {
            stopSelf();
            return START_NOT_STICKY;
        }
        SyncEngine.get().start(this);
        updateNotification();
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        SyncEngine.get().removeListener(syncListener);
        SyncEngine.get().stop();
        if (clipboard != null) {
            try { clipboard.removePrimaryClipChangedListener(clipListener); } catch (Exception ignored) {}
        }
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }

    private void updateNotification() {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (nm != null) nm.notify(NOTIF_ID, buildNotification(SyncEngine.get().getStatus()));
    }

    private Notification buildNotification(String text) {
        int piFlags = PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE;
        PendingIntent openPi = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), piFlags);
        Intent pushIntent = new Intent(this, ClipSyncService.class).setAction(ACTION_PUSH_NOW);
        PendingIntent pushPi = PendingIntent.getService(this, 1, pushIntent, piFlags);

        Notification.Builder b = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        return b.setContentTitle("Clipline 跨设备同步")
                .setContentText(text)
                .setSmallIcon(android.R.drawable.ic_menu_share)
                .setOngoing(true)
                .setContentIntent(openPi)
                .addAction(new Notification.Action.Builder(null, "发送剪贴板", pushPi).build())
                .build();
    }

    private void createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel ch = new NotificationChannel(CHANNEL_ID, "跨设备剪贴板同步", NotificationManager.IMPORTANCE_MIN);
            ch.setShowBadge(false);
            NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
            if (nm != null) nm.createNotificationChannel(ch);
        }
    }
}
