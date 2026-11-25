package local.clipline.android;

import android.Manifest;
import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.text.InputType;
import android.view.Gravity;
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
    private static final int REQ_QR_SCAN = 301;

    private Switch enableSwitch;
    private TextView statusView;
    private TextView devicesView;
    private LinearLayout onboardCard;
    private LinearLayout permBody;
    private TextView permSummaryView;
    private TextView permOverlayView;
    private TextView permAccessView;
    private LinearLayout cfgBody;
    private TextView cfgToggle;
    private EditText hubInput;
    private EditText tokenInput;
    private EditText deviceInput;
    private LinearLayout historyBox;
    private boolean updatingUi = false;
    private boolean cfgExpanded = false;
    private boolean isDark = false;

    private final SyncEngine.Listener syncListener = this::refreshUi;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        int night = getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK;
        isDark = (night == Configuration.UI_MODE_NIGHT_YES);
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

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQ_QR_SCAN && resultCode == RESULT_OK && data != null) {
            String qr = data.getStringExtra(QrScanActivity.EXTRA_QR_TEXT);
            if (SyncPrefs.importPairing(this, qr)) {
                ClipSyncService.startOrStop(this);
                Toast.makeText(this, "扫码配对成功，正在连接…", Toast.LENGTH_SHORT).show();
                refreshUi();
            } else {
                Toast.makeText(this, "未识别到有效的 Clipline 配对二维码", Toast.LENGTH_LONG).show();
            }
        }
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

    private int colorBg() { return isDark ? Color.parseColor("#0F1115") : Color.parseColor("#F4F6F9"); }
    private int colorCard() { return isDark ? Color.parseColor("#181C24") : Color.WHITE; }
    private int colorBorder() { return isDark ? Color.parseColor("#2A303C") : Color.parseColor("#E2E7EE"); }
    private int colorText() { return isDark ? Color.parseColor("#E8ECF2") : Color.parseColor("#1B1F24"); }
    private int colorMuted() { return isDark ? Color.parseColor("#8E98A8") : Color.parseColor("#5E6876"); }
    private int colorAccent() { return Color.parseColor("#3B82F6"); }

    private LinearLayout makeCard() {
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        int p = dp(14);
        card.setPadding(p, p, p, p);
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(colorCard());
        gd.setCornerRadius(dp(14));
        gd.setStroke(dp(1), colorBorder());
        card.setBackground(gd);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.bottomMargin = dp(12);
        card.setLayoutParams(lp);
        return card;
    }

    private Button makeButton(String text, boolean primary) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setTextSize(14);
        b.setTypeface(null, primary ? Typeface.BOLD : Typeface.NORMAL);
        b.setTextColor(primary ? Color.WHITE : colorText());
        b.setPadding(dp(14), dp(10), dp(14), dp(10));
        b.setMinHeight(0);
        b.setMinimumHeight(dp(40));
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(primary ? colorAccent() : (isDark ? Color.parseColor("#232935") : Color.parseColor("#EEF2F7")));
        gd.setCornerRadius(dp(10));
        if (!primary) gd.setStroke(dp(1), colorBorder());
        b.setBackground(gd);
        return b;
    }

    private void buildUi() {
        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(colorBg());
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(16);
        root.setPadding(pad, dp(20), pad, dp(28));
        scroll.addView(root);

        // Header
        TextView title = new TextView(this);
        title.setText("Clipline");
        title.setTextSize(24);
        title.setTextColor(colorText());
        title.setTypeface(null, Typeface.BOLD);
        LinearLayout.LayoutParams titleLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        titleLp.bottomMargin = dp(12);
        root.addView(title, titleLp);

        // 1. First-time pairing guide card (auto-hides once paired)
        onboardCard = makeCard();
        TextView obTitle = new TextView(this);
        obTitle.setText("2 步配对电脑");
        obTitle.setTextSize(16);
        obTitle.setTextColor(colorText());
        obTitle.setTypeface(null, Typeface.BOLD);
        onboardCard.addView(obTitle);

        TextView obSteps = new TextView(this);
        obSteps.setText("1. 在 Mac / Windows 打开 Clipline → 设置 → 跨设备同步 → 扫码配对\n2. 点下方「扫码配对」对准电脑二维码一扫即连");
        obSteps.setTextSize(13);
        obSteps.setTextColor(colorMuted());
        obSteps.setLineSpacing(dp(3), 1f);
        obSteps.setPadding(0, dp(6), 0, dp(12));
        onboardCard.addView(obSteps);

        Button obScanBtn = makeButton("📷 扫码配对", true);
        obScanBtn.setOnClickListener(v -> startActivityForResult(new Intent(this, QrScanActivity.class), REQ_QR_SCAN));
        onboardCard.addView(obScanBtn);
        root.addView(onboardCard);

        // 2. Status & primary actions card
        LinearLayout statusCard = makeCard();
        enableSwitch = new Switch(this);
        enableSwitch.setText("后台无感同步");
        enableSwitch.setTextSize(16);
        enableSwitch.setTextColor(colorText());
        enableSwitch.setOnCheckedChangeListener((b, checked) -> {
            if (updatingUi) return;
            SyncPrefs.setEnabled(this, checked);
            ClipSyncService.startOrStop(this);
            refreshUi();
        });
        statusCard.addView(enableSwitch);

        statusView = new TextView(this);
        statusView.setTextSize(13.5f);
        statusView.setPadding(0, dp(6), 0, dp(2));
        statusCard.addView(statusView);

        devicesView = new TextView(this);
        devicesView.setTextSize(12.5f);
        devicesView.setTextColor(colorMuted());
        devicesView.setPadding(0, dp(2), 0, dp(12));
        statusCard.addView(devicesView);

        // Well-spaced action buttons row 1: QR Scan + Paste Pair Code
        LinearLayout row1 = new LinearLayout(this);
        row1.setOrientation(LinearLayout.HORIZONTAL);
        Button btnScan = makeButton("📷 扫码配对", true);
        btnScan.setOnClickListener(v -> startActivityForResult(new Intent(this, QrScanActivity.class), REQ_QR_SCAN));
        LinearLayout.LayoutParams r1Left = new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        r1Left.rightMargin = dp(10);
        row1.addView(btnScan, r1Left);

        Button btnPaste = makeButton("粘贴配对码", false);
        btnPaste.setOnClickListener(v -> pastePairingCode());
        LinearLayout.LayoutParams r1Right = new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        row1.addView(btnPaste, r1Right);
        statusCard.addView(row1);

        // Full-width manual push button with top margin
        Button btnPushNow = makeButton("⬆️ 立即发送当前剪贴板", false);
        btnPushNow.setOnClickListener(v -> {
            OverlayClipboardReader.triggerReadAndPush(this);
            Toast.makeText(this, "已发送当前剪贴板", Toast.LENGTH_SHORT).show();
        });
        LinearLayout.LayoutParams pushLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        pushLp.topMargin = dp(10);
        statusCard.addView(btnPushNow, pushLp);
        root.addView(statusCard);

        // 3. Auto-sync permissions card (auto-collapses when both granted)
        LinearLayout permCard = makeCard();
        permSummaryView = new TextView(this);
        permSummaryView.setTextSize(14);
        permSummaryView.setTypeface(null, Typeface.BOLD);
        permCard.addView(permSummaryView);

        permBody = new LinearLayout(this);
        permBody.setOrientation(LinearLayout.VERTICAL);
        permBody.setPadding(0, dp(8), 0, 0);

        permOverlayView = new TextView(this);
        permOverlayView.setTextSize(12.5f);
        permOverlayView.setTextColor(colorMuted());
        permBody.addView(permOverlayView);

        Button btnOverlay = makeButton("1. 开启悬浮窗（1像素隐形读剪贴板）", false);
        btnOverlay.setOnClickListener(v -> {
            Intent i = new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:" + getPackageName()));
            startActivity(i);
        });
        LinearLayout.LayoutParams btnLp1 = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        btnLp1.topMargin = dp(6);
        btnLp1.bottomMargin = dp(10);
        permBody.addView(btnOverlay, btnLp1);

        permAccessView = new TextView(this);
        permAccessView.setTextSize(12.5f);
        permAccessView.setTextColor(colorMuted());
        permBody.addView(permAccessView);

        Button btnAccess = makeButton("2. 开启无障碍（微信复制自动感应）", false);
        btnAccess.setOnClickListener(v -> startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)));
        LinearLayout.LayoutParams btnLp2 = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        btnLp2.topMargin = dp(6);
        permBody.addView(btnAccess, btnLp2);

        permCard.addView(permBody);
        root.addView(permCard);

        // 4. Collapsible connection details card
        LinearLayout cfgCard = makeCard();
        cfgToggle = new TextView(this);
        cfgToggle.setText("连接设置 ▸");
        cfgToggle.setTextSize(14);
        cfgToggle.setTextColor(colorText());
        cfgToggle.setTypeface(null, Typeface.BOLD);
        cfgToggle.setOnClickListener(v -> {
            cfgExpanded = !cfgExpanded;
            cfgBody.setVisibility(cfgExpanded ? View.VISIBLE : View.GONE);
            cfgToggle.setText(cfgExpanded ? "连接设置 ▾" : "连接设置 ▸");
        });
        cfgCard.addView(cfgToggle);

        cfgBody = new LinearLayout(this);
        cfgBody.setOrientation(LinearLayout.VERTICAL);
        cfgBody.setVisibility(View.GONE);
        cfgBody.setPadding(0, dp(10), 0, 0);

        hubInput = new EditText(this);
        hubInput.setHint("Hub 地址，如 http://100.x.y.z:8765");
        hubInput.setTextColor(colorText());
        hubInput.setHintTextColor(colorMuted());
        cfgBody.addView(hubInput);

        tokenInput = new EditText(this);
        tokenInput.setHint("访问 Token");
        tokenInput.setTextColor(colorText());
        tokenInput.setHintTextColor(colorMuted());
        tokenInput.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        cfgBody.addView(tokenInput);

        deviceInput = new EditText(this);
        deviceInput.setHint("设备名，如 z-fold8");
        deviceInput.setTextColor(colorText());
        deviceInput.setHintTextColor(colorMuted());
        cfgBody.addView(deviceInput);

        Button btnSave = makeButton("保存并重连", true);
        btnSave.setOnClickListener(v -> {
            SyncPrefs.setHubUrl(this, hubInput.getText().toString());
            SyncPrefs.setToken(this, tokenInput.getText().toString());
            SyncPrefs.setDeviceName(this, deviceInput.getText().toString());
            SyncPrefs.setEnabled(this, true);
            ClipSyncService.startOrStop(this);
            Toast.makeText(this, "已保存并重连", Toast.LENGTH_SHORT).show();
            refreshUi();
        });
        LinearLayout.LayoutParams saveLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        saveLp.topMargin = dp(8);
        cfgBody.addView(btnSave, saveLp);
        cfgCard.addView(cfgBody);
        root.addView(cfgCard);

        // 5. Recent synced history
        TextView histTitle = new TextView(this);
        histTitle.setText("最近同步（点击复制）");
        histTitle.setTextSize(14);
        histTitle.setTextColor(colorMuted());
        histTitle.setTypeface(null, Typeface.BOLD);
        histTitle.setPadding(dp(4), dp(4), 0, dp(8));
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
            Toast.makeText(this, "配对成功，正在连接…", Toast.LENGTH_SHORT).show();
            refreshUi();
        } else {
            Toast.makeText(this, "剪贴板中无有效配对码，建议直接点「扫码配对」", Toast.LENGTH_SHORT).show();
        }
    }

    private void refreshUi() {
        boolean configured = !SyncPrefs.getHubUrl(this).isEmpty() && !SyncPrefs.getToken(this).isEmpty();
        onboardCard.setVisibility(configured ? View.GONE : View.VISIBLE);

        updatingUi = true;
        enableSwitch.setChecked(SyncPrefs.isEnabled(this));
        if (!hubInput.hasFocus()) hubInput.setText(SyncPrefs.getHubUrl(this));
        if (!tokenInput.hasFocus()) tokenInput.setText(SyncPrefs.getToken(this));
        if (!deviceInput.hasFocus()) deviceInput.setText(SyncPrefs.getDeviceName(this));
        updatingUi = false;

        statusView.setText("状态：" + SyncEngine.get().getStatus());
        statusView.setTextColor(SyncEngine.get().isConnected() ? Color.parseColor("#2EA043") : colorMuted());

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
        boolean accOk = isAccessibilityEnabled();
        if (overlayOk && accOk) {
            permSummaryView.setText("✅ 微信内复制自动上传已就绪");
            permSummaryView.setTextColor(Color.parseColor("#2EA043"));
            permBody.setVisibility(View.GONE);
        } else {
            permSummaryView.setText("开启微信内复制自动上传（还差 " + ((!overlayOk && !accOk) ? "2" : "1") + " 项）");
            permSummaryView.setTextColor(colorText());
            permBody.setVisibility(View.VISIBLE);
            permOverlayView.setText(overlayOk ? "✅ 悬浮窗权限已开启" : "⚪ 悬浮窗权限未开启");
            permAccessView.setText(accOk ? "✅ 无障碍感应已开启" : "⚪ 无障碍感应未开启");
        }

        historyBox.removeAllViews();
        List<SyncEngine.ClipRecord> items = SyncEngine.get().getHistory();
        if (items.isEmpty()) {
            LinearLayout emptyCard = makeCard();
            TextView empty = new TextView(this);
            empty.setText("暂无记录，在电脑按 Cmd+C 即可实时出现");
            empty.setTextColor(colorMuted());
            empty.setTextSize(13);
            emptyCard.addView(empty);
            historyBox.addView(emptyCard);
        } else {
            for (SyncEngine.ClipRecord rec : items) {
                LinearLayout card = makeCard();
                TextView meta = new TextView(this);
                meta.setText(rec.device + " · " + rec.time);
                meta.setTextSize(11.5f);
                meta.setTextColor(colorMuted());
                card.addView(meta);

                TextView body = new TextView(this);
                String preview = rec.text.length() > 160 ? rec.text.substring(0, 160) + "…" : rec.text;
                body.setText(preview);
                body.setTextSize(14);
                body.setTextColor(colorText());
                body.setPadding(0, dp(4), 0, 0);
                card.addView(body);

                card.setOnClickListener(v -> {
                    SyncEngine.get().writeClipboardText(rec.text);
                    Toast.makeText(this, "已复制", Toast.LENGTH_SHORT).show();
                });
                historyBox.addView(card);
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
