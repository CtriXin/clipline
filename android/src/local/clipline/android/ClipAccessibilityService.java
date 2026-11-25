package local.clipline.android;

import android.accessibilityservice.AccessibilityService;
import android.view.accessibility.AccessibilityEvent;
import java.util.List;

/**
 * Watches lightweight click & toast accessibility events (e.g. tapping "复制"/"Copy"
 * or Samsung/WeChat "已复制"/"Copied" toast) and invokes the 1x1-pixel invisible
 * overlay reader to sync the copied text immediately without leaving WeChat.
 */
public final class ClipAccessibilityService extends AccessibilityService {
    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        if (event == null || !SyncPrefs.isEnabled(this)) return;
        int type = event.getEventType();
        if (type != AccessibilityEvent.TYPE_VIEW_CLICKED
                && type != AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED) {
            return;
        }
        StringBuilder sb = new StringBuilder();
        if (event.getContentDescription() != null) sb.append(event.getContentDescription()).append(' ');
        List<CharSequence> texts = event.getText();
        if (texts != null) {
            for (CharSequence cs : texts) {
                if (cs != null) sb.append(cs).append(' ');
            }
        }
        String lower = sb.toString().toLowerCase();
        if (lower.contains("复制") || lower.contains("拷贝") || lower.contains("剪切")
                || lower.contains("copy") || lower.contains("copied") || lower.contains("cut")) {
            OverlayClipboardReader.triggerReadAndPush(this);
        }
    }

    @Override
    public void onInterrupt() {}
}
