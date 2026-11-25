package local.clipline.android;

import android.Manifest;
import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.text.InputType;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;
import java.util.List;

public final class MainActivity extends Activity {
    private Switch enableSwitch;
    private TextView statusView;
    private TextView devicesView;
    private TextView permOverlayView;
    private TextView permAccessView;
    private EditText hubInput;
    private EditText tokenInput;
    private EditText deviceInput;
    private LinearLayout historyBox;
    private boolean updatingUi = false;

    private final SyncEngine.Listener syncListener = this::refreshUi;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        handleDeepLink(getIntent());
        buildUi();
        requestNotifIfNeeded();
        if (SyncPrefs.isEnabled(this)) ClipSyncService.startOrStop(this);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        handleDeepLink(intent);
        refreshUi();
    }

    @Override
    protected void onResume() {
        super.onResume();
        SyncEngine.get().addListener(syncListener);
        refreshUi();
    }

    @Override
    protected void onPause() {
        SyncEngine.get().removeListener(syncListener);
        super.onPause();
    }

    private void handleDeepLink(Intent intent) {
        if (intent == null || intent.getData() == null) return;
        if (SyncPrefs.importPairing(this, intent.getData().toString())) {
            ClipSyncService.startOrStop(this);
            Toast.makeText(this, "已通过链接完成配对", Toast.LENGTH_SHORT).show();
        }
    }

    private void requestNotifIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 100);
        }
    }

    private void buildUi() {
        ScrollView scroll = new ScrollView(this);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(18);
        root.setPadding(pad, pad, pad, pad);
        scroll.addView(root);

        TextView title = new TextView(this);
        title.setText("Clipline 跨设备剪贴板");
        title.setTextSize(22);
        title.setTypeface(null, Typeface.BOLD);
        root.addView(title);

        enableSwitch = new Switch(this);
        enableSwitch.setText("开启后台无感同步");
        enableSwitch.setTextSize(16);
        enableSwitch.setPadding(0, dp(12), 0, dp(6));
        enableSwitch.setOnCheckedChangeListener((b, checked) -> {
            if (updatingUi) return;
            SyncPrefs.setEnabled(this, checked);
            ClipSyncService.startOrStop(this);
            refreshUi();
        });
        root.addView(enableSwitch);

        statusView = new TextView(this);
        statusView.setTextSize(14);
        root.addView(statusView);

        devicesView = new TextView(this);
        devicesView.setTextSize(13);
        devicesView.setPadding(0, dp(4), 0, dp(10));
        root.addView(devicesView);

        // Primary action buttons
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        Button btnPastePair = new Button(this);
        btnPastePair.setText("粘贴配对码");
        btnPastePair.setOnClickListener(v -> pastePairingCode());
        Button btnPushNow = new Button(this);
        btnPushNow.setText("立即发剪贴板");
        btnPushNow.setOnClickListener(v -> {
            OverlayClipboardReader.triggerReadAndPush(this);
            Toast.makeText(this, "已同步当前剪贴板", Toast.LENGTH_SHORT).show();
        });
        row.addView(btnPastePair);
        row.addView(btnPushNow);
        root.addView(row);

        // 1-pixel invisible auto-sync permissions card
        TextView permTitle = new TextView(this);
        permTitle.setText("微信内复制自动上传（1像素隐形浮窗）");
        permTitle.setTypeface(null, Typeface.BOLD);
        permTitle.setPadding(0, dp(14), 0, dp(4));
        root.addView(permTitle);

        permOverlayView = new TextView(this);
        permOverlayView.setTextSize(13);
        root.addView(permOverlayView);

        Button btnOverlay = new Button(this);
        btnOverlay.setText("1. 开启悬浮窗权限（1像素隐形读取）");
        btnOverlay.setOnClickListener(v -> {
            Intent i = new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:" + getPackageName()));
            startActivity(i);
        });
        root.addView(btnOverlay);

        permAccessView = new TextView(this);
        permAccessView.setTextSize(13);
        permAccessView.setPadding(0, dp(4), 0, 0);
        root.addView(permAccessView);

        Button btnAccess = new Button(this);
        btnAccess.setText("2. 开启无障碍感应（监听复制事件）");
        btnAccess.setOnClickListener(v -> startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)));
        root.addView(btnAccess);

        // Connection details
        TextView cfgTitle = new TextView(this);
        cfgTitle.setText("连接设置");
        cfgTitle.setTypeface(null, Typeface.BOLD);
        cfgTitle.setPadding(0, dp(14), 0, dp(4));
        root.addView(cfgTitle);

        hubInput = new EditText(this);
        hubInput.setHint("Hub 地址，如 http://100.x.y.z:8765");
        root.addView(hubInput);

        tokenInput = new EditText(this);
        tokenInput.setHint("访问 Token");
        tokenInput.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        root.addView(tokenInput);

        deviceInput = new EditText(this);
        deviceInput.setHint("设备名，如 z-fold8");
        root.addView(deviceInput);

        Button btnSave = new Button(this);
        btnSave.setText("保存并重连");
        btnSave.setOnClickListener(v -> {
            SyncPrefs.setHubUrl(this, hubInput.getText().toString());
            SyncPrefs.setToken(this, tokenInput.getText().toString());
            SyncPrefs.setDeviceName(this, deviceInput.getText().toString());
            SyncPrefs.setEnabled(this, true);
            ClipSyncService.startOrStop(this);
            Toast.makeText(this, "已保存并重连", Toast.LENGTH_SHORT).show();
            refreshUi();
        });
        root.addView(btnSave);

        TextView histTitle = new TextView(this);
        histTitle.setText("最近同步（点击复制）");
        histTitle.setTypeface(null, Typeface.BOLD);
        histTitle.setPadding(0, dp(16), 0, dp(6));
        root.addView(histTitle);

        historyBox = new LinearLayout(this);
        historyBox.setOrientation(LinearLayout.VERTICAL);
        root.addView(historyBox);

        setContentView(scroll);
    }

    private void pastePairingCode() {
        ClipboardManager cm = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
        if (cm == null || !cm.hasPrimaryClip()) {
            Toast.makeText(this, "剪贴板为空", Toast.LENGTH_SHORT).show();
            return;
        }
        ClipData clip = cm.getPrimaryClip();
        CharSequence cs = (clip != null && clip.getItemCount() > 0) ? clip.getItemAt(0).coerceToText(this) : null;
        if (cs != null && SyncPrefs.importPairing(this, cs.toString())) {
            ClipSyncService.startOrStop(this);
            Toast.makeText(this, "配对成功，正在连接", Toast.LENGTH_SHORT).show();
            refreshUi();
        } else {
            Toast.makeText(this, "剪贴板中无有效 clipsync:// 配对码", Toast.LENGTH_SHORT).show();
        }
    }

    private void refreshUi() {
        updatingUi = true;
        enableSwitch.setChecked(SyncPrefs.isEnabled(this));
        if (!hubInput.hasFocus()) hubInput.setText(SyncPrefs.getHubUrl(this));
        if (!tokenInput.hasFocus()) tokenInput.setText(SyncPrefs.getToken(this));
        if (!deviceInput.hasFocus()) deviceInput.setText(SyncPrefs.getDeviceName(this));
        updatingUi = false;

        statusView.setText("状态：" + SyncEngine.get().getStatus());
        statusView.setTextColor(SyncEngine.get().isConnected() ? Color.parseColor("#2EA043") : Color.GRAY);

        List<SyncEngine.DeviceInfo> devs = SyncEngine.get().getOnlineDevices();
        if (devs.isEmpty()) {
            devicesView.setText("在线设备：暂无");
        } else {
            StringBuilder sb = new StringBuilder("在线设备：");
            for (int i = 0; i < devs.size(); i++) {
                if (i > 0) sb.append(" · ");
                sb.append(devs.get(i).name);
            }
            devicesView.setText(sb.toString());
        }

        boolean overlayOk = Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(this);
        permOverlayView.setText(overlayOk ? "✅ 悬浮窗权限已开启" : "⚪ 悬浮窗权限未开启（开启后可后台读取剪贴板）");
        boolean accOk = isAccessibilityEnabled();
        permAccessView.setText(accOk ? "✅ 无障碍复制感应已开启" : "⚪ 无障碍感应未开启（开启后微信复制自动上传）");

        historyBox.removeAllViews();
        List<SyncEngine.ClipRecord> items = SyncEngine.get().getHistory();
        if (items.isEmpty()) {
            TextView empty = new TextView(this);
            empty.setText("暂无记录，在电脑按 Cmd+C 即可实时出现");
            empty.setTextColor(Color.GRAY);
            historyBox.addView(empty);
        } else {
            for (SyncEngine.ClipRecord rec : items) {
                TextView tv = new TextView(this);
                String preview = rec.text.length() > 140 ? rec.text.substring(0, 140) + "…" : rec.text;
                tv.setText("[" + rec.device + "] " + preview);
                tv.setPadding(dp(10), dp(8), dp(10), dp(8));
                tv.setTextSize(13);
                tv.setOnClickListener(v -> {
                    SyncEngine.get().writeClipboardText(rec.text);
                    Toast.makeText(this, "已复制", Toast.LENGTH_SHORT).show();
                });
                historyBox.addView(tv);
            }
        }
    }

    private boolean isAccessibilityEnabled() {
        String enabled = Settings.Secure.getString(getContentResolver(), Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
        return enabled != null && enabled.contains(getPackageName() + "/" + ClipAccessibilityService.class.getName());
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }
}
