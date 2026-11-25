package local.clipline.android;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.ImageFormat;
import android.graphics.drawable.GradientDrawable;
import android.hardware.Camera;
import android.os.Build;
import android.os.Bundle;
import android.view.Gravity;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.TextView;
import android.widget.Toast;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.BinaryBitmap;
import com.google.zxing.DecodeHintType;
import com.google.zxing.PlanarYUVLuminanceSource;
import com.google.zxing.Result;
import com.google.zxing.common.HybridBinarizer;
import com.google.zxing.qrcode.QRCodeReader;
import java.util.Collections;
import java.util.EnumMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Lightweight native QR code scanner using Android Camera + ZXing QRCodeReader.
 * Zero Google Play Services dependency; scans Clipline's pairing QR directly.
 */
@SuppressWarnings("deprecation")
public final class QrScanActivity extends Activity implements SurfaceHolder.Callback, Camera.PreviewCallback {
    public static final String EXTRA_QR_TEXT = "qr_text";
    private static final int REQ_CAMERA = 201;

    private SurfaceView previewView;
    private Camera camera;
    private final QRCodeReader reader = new QRCodeReader();
    private final Map<DecodeHintType, Object> hints = new EnumMap<>(DecodeHintType.class);
    private final AtomicBoolean decoding = new AtomicBoolean(false);
    private volatile boolean found = false;
    private long lastDecodeAt = 0;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        hints.put(DecodeHintType.POSSIBLE_FORMATS, Collections.singletonList(BarcodeFormat.QR_CODE));
        hints.put(DecodeHintType.CHARACTER_SET, "UTF-8");

        buildUi();
        if (Build.VERSION.SDK_INT >= 23
                && checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.CAMERA}, REQ_CAMERA);
        }
    }

    private void buildUi() {
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);

        previewView = new SurfaceView(this);
        previewView.getHolder().addCallback(this);
        root.addView(previewView, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        // Center viewfinder frame
        int boxSize = dp(240);
        View frame = new View(this);
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(Color.TRANSPARENT);
        gd.setCornerRadius(dp(18));
        gd.setStroke(dp(3), Color.parseColor("#4C8DFF"));
        frame.setBackground(gd);
        FrameLayout.LayoutParams fp = new FrameLayout.LayoutParams(boxSize, boxSize, Gravity.CENTER);
        root.addView(frame, fp);

        // Top instruction pill
        TextView tip = new TextView(this);
        tip.setText("对准电脑 Clipline 的配对二维码");
        tip.setTextColor(Color.WHITE);
        tip.setTextSize(15);
        tip.setPadding(dp(16), dp(10), dp(16), dp(10));
        GradientDrawable tipBg = new GradientDrawable();
        tipBg.setColor(Color.parseColor("#99000000"));
        tipBg.setCornerRadius(dp(20));
        tip.setBackground(tipBg);
        FrameLayout.LayoutParams tp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP | Gravity.CENTER_HORIZONTAL);
        tp.topMargin = dp(56);
        root.addView(tip, tp);

        // Bottom cancel button
        Button btnCancel = new Button(this);
        btnCancel.setText("取消");
        btnCancel.setTextColor(Color.WHITE);
        btnCancel.setPadding(dp(28), dp(10), dp(28), dp(10));
        GradientDrawable cancelBg = new GradientDrawable();
        cancelBg.setColor(Color.parseColor("#AA22262E"));
        cancelBg.setCornerRadius(dp(22));
        btnCancel.setBackground(cancelBg);
        btnCancel.setOnClickListener(v -> finish());
        FrameLayout.LayoutParams cp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        cp.bottomMargin = dp(48);
        root.addView(btnCancel, cp);

        setContentView(root);
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQ_CAMERA) {
            if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                startCamera(previewView.getHolder());
            } else {
                Toast.makeText(this, "需要相机权限才能扫码配对", Toast.LENGTH_SHORT).show();
                finish();
            }
        }
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        if (Build.VERSION.SDK_INT < 23 || checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            startCamera(holder);
        }
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {}

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        stopCamera();
    }

    @Override
    protected void onPause() {
        super.onPause();
        stopCamera();
    }

    private void startCamera(SurfaceHolder holder) {
        if (camera != null) return;
        try {
            camera = Camera.open(Camera.CameraInfo.CAMERA_FACING_BACK);
            if (camera == null) camera = Camera.open();
            if (camera == null) {
                Toast.makeText(this, "无法打开相机", Toast.LENGTH_SHORT).show();
                finish();
                return;
            }
            Camera.Parameters params = camera.getParameters();
            params.setPreviewFormat(ImageFormat.NV21);
            List<String> focusModes = params.getSupportedFocusModes();
            if (focusModes != null && focusModes.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE)) {
                params.setFocusMode(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE);
            } else if (focusModes != null && focusModes.contains(Camera.Parameters.FOCUS_MODE_AUTO)) {
                params.setFocusMode(Camera.Parameters.FOCUS_MODE_AUTO);
            }
            Camera.Size best = chooseSize(params.getSupportedPreviewSizes());
            if (best != null) params.setPreviewSize(best.width, best.height);
            camera.setParameters(params);
            camera.setDisplayOrientation(90);
            camera.setPreviewDisplay(holder);
            camera.setPreviewCallback(this);
            camera.startPreview();
        } catch (Exception e) {
            Toast.makeText(this, "相机启动失败", Toast.LENGTH_SHORT).show();
            finish();
        }
    }

    private void stopCamera() {
        if (camera != null) {
            try { camera.setPreviewCallback(null); } catch (Exception ignored) {}
            try { camera.stopPreview(); } catch (Exception ignored) {}
            try { camera.release(); } catch (Exception ignored) {}
            camera = null;
        }
    }

    private Camera.Size chooseSize(List<Camera.Size> sizes) {
        if (sizes == null || sizes.isEmpty()) return null;
        Camera.Size best = sizes.get(0);
        int bestDiff = Integer.MAX_VALUE;
        for (Camera.Size s : sizes) {
            int diff = Math.abs(s.width - 1280) + Math.abs(s.height - 720);
            if (diff < bestDiff) {
                bestDiff = diff;
                best = s;
            }
        }
        return best;
    }

    @Override
    public void onPreviewFrame(byte[] data, Camera cam) {
        if (found || data == null || cam == null) return;
        long now = System.currentTimeMillis();
        if (now - lastDecodeAt < 180) return;
        if (!decoding.compareAndSet(false, true)) return;
        lastDecodeAt = now;

        final Camera.Size size;
        try {
            size = cam.getParameters().getPreviewSize();
        } catch (Exception e) {
            decoding.set(false);
            return;
        }
        final byte[] copy = data.clone();
        new Thread(() -> {
            try {
                // Scan both normal and 90-degree rotated center crop for fast detection
                String text = decodeNV21(copy, size.width, size.height);
                if (text == null) {
                    byte[] rot = rotate90(copy, size.width, size.height);
                    text = decodeNV21(rot, size.height, size.width);
                }
                if (text != null && !found) {
                    found = true;
                    final String matched = text;
                    runOnUiThread(() -> {
                        Intent res = new Intent();
                        res.putExtra(EXTRA_QR_TEXT, matched);
                        setResult(RESULT_OK, res);
                        finish();
                    });
                }
            } catch (Exception ignored) {
            } finally {
                reader.reset();
                decoding.set(false);
            }
        }, "QrDecode").start();
    }

    private String decodeNV21(byte[] yuv, int w, int h) {
        try {
            PlanarYUVLuminanceSource src = new PlanarYUVLuminanceSource(yuv, w, h, 0, 0, w, h, false);
            BinaryBitmap bmp = new BinaryBitmap(new HybridBinarizer(src));
            Result r = reader.decode(bmp, hints);
            return r == null ? null : r.getText();
        } catch (Exception ignored) {
            return null;
        }
    }

    private static byte[] rotate90(byte[] yuv, int w, int h) {
        byte[] out = new byte[w * h];
        int k = 0;
        for (int x = 0; x < w; x++) {
            for (int y = h - 1; y >= 0; y--) {
                out[k++] = yuv[y * w + x];
            }
        }
        return out;
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }
}
