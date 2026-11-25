package local.clipline.android;

import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;
import android.widget.Toast;

public final class SyncTileService extends TileService {
    @Override
    public void onStartListening() {
        super.onStartListening();
        Tile t = getQsTile();
        if (t != null) {
            t.setState(SyncPrefs.isEnabled(this) ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
            t.setLabel("发剪贴板");
            t.updateTile();
        }
    }

    @Override
    public void onClick() {
        super.onClick();
        OverlayClipboardReader.triggerReadAndPush(this);
        Toast.makeText(this, "正在同步剪贴板到电脑", Toast.LENGTH_SHORT).show();
    }
}
