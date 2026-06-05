package com.royp.maccysync.clipboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context

// Writes text to the phone clipboard and remembers it briefly so the
// accessibility capture doesn't echo our own write back to the Mac.
object ClipboardWriter {
  @Volatile private var lastText: String? = null
  @Volatile private var lastAt: Long = 0

  fun setText(context: Context, text: String) {
    lastText = text
    lastAt = System.currentTimeMillis()
    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    cm.setPrimaryClip(ClipData.newPlainText("Maccy Sync", text))
  }

  fun wasJustWritten(text: String): Boolean =
    text == lastText && (System.currentTimeMillis() - lastAt) < 5_000
}
