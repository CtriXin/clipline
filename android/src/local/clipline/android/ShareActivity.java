package local.clipline.android;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.widget.Toast;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;

public final class ShareActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Intent intent = getIntent();
        if (intent != null && Intent.ACTION_SEND.equals(intent.getAction())) {
            String type = intent.getType();
            if (type != null && type.startsWith("text/")) {
                String text = intent.getStringExtra(Intent.EXTRA_TEXT);
                if (text != null && !text.trim().isEmpty()) {
                    SyncEngine.get().pushText(this, text);
                    Toast.makeText(this, "已发送到 Clipline", Toast.LENGTH_SHORT).show();
                }
            } else if (type != null && type.startsWith("image/")) {
                Uri uri = intent.getParcelableExtra(Intent.EXTRA_STREAM);
                if (uri != null) {
                    try (InputStream is = getContentResolver().openInputStream(uri)) {
                        if (is != null) {
                            ByteArrayOutputStream baos = new ByteArrayOutputStream();
                            byte[] buf = new byte[8192];
                            int n;
                            while ((n = is.read(buf)) > 0) baos.write(buf, 0, n);
                            SyncEngine.get().pushImage(this, baos.toByteArray(), type);
                            Toast.makeText(this, "图片已发送到 Clipline", Toast.LENGTH_SHORT).show();
                        }
                    } catch (Exception ignored) {}
                }
            }
        }
        finish();
    }
}
