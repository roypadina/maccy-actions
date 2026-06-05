package com.royp.maccysync.tile

import android.service.quicksettings.TileService
import android.widget.Toast
import com.royp.maccysync.MaccyApp
import com.royp.maccysync.clipboard.ClipboardCapture

// Manual "capture current clip" fallback for when auto-capture is unavailable.
class CaptureTileService : TileService() {
  override fun onClick() {
    super.onClick()
    val text = ClipboardCapture.currentText(this)
    if (text == null) {
      Toast.makeText(this, "Clipboard empty or unreadable", Toast.LENGTH_SHORT).show()
      return
    }
    MaccyApp.from(this).controller.captureLocal(ClipboardCapture.metaFor(text))
    Toast.makeText(this, "Captured to Maccy Sync", Toast.LENGTH_SHORT).show()
  }
}
