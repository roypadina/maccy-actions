package com.royp.maccysync.notify

import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import com.royp.maccysync.MaccyApp
import com.royp.maccysync.clipboard.ClipboardCapture
import com.royp.maccysync.net.SyncForegroundService

// Launched by tapping the ongoing notification. The clipboard can only be read
// once we actually hold WINDOW FOCUS — onResume fires too early and the OS denies
// the read (returns null), which is why "send from notification" used to silently
// re-send a stale clip. So we read in onWindowFocusChanged. If the read still
// comes back empty, SyncController falls back to the latest stored clip.
class SendLatestActivity : ComponentActivity() {
  private var done = false

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    overridePendingTransition(0, 0)
  }

  override fun onWindowFocusChanged(hasFocus: Boolean) {
    super.onWindowFocusChanged(hasFocus)
    if (!hasFocus || done) return
    done = true
    val app = MaccyApp.from(this)
    if (!app.prefs.isPaired) {
      Toast.makeText(this, "Pair with a Mac first", Toast.LENGTH_SHORT).show()
      finish(); return
    }
    SyncForegroundService.start(this)
    val live = ClipboardCapture.currentText(this)
    app.controller.sendLatestToMac(live) { ok ->
      Toast.makeText(this, if (ok) "Sent latest to Mac" else "Not connected to Mac", Toast.LENGTH_SHORT).show()
      finish()
    }
  }
}
