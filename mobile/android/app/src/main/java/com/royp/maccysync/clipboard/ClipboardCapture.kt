package com.royp.maccysync.clipboard

import android.content.ClipboardManager
import android.content.Context
import com.royp.maccysync.core.ItemMeta
import com.royp.maccysync.core.Protocol
import java.util.UUID

// Reads the current primary clip text and turns it into an ItemMeta. Only text
// is captured outbound on the phone (image/file from the Android clipboard are
// rare and access-restricted); the phone still receives all kinds from the Mac.
object ClipboardCapture {
  fun currentText(context: Context): String? {
    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    val clip = cm.primaryClip ?: return null
    if (clip.itemCount == 0) return null
    val text = clip.getItemAt(0).coerceToText(context)?.toString() ?: return null
    return text.ifBlank { null }
  }

  fun metaFor(text: String): ItemMeta {
    val size = text.toByteArray(Charsets.UTF_8).size
    return ItemMeta(
      id = UUID.randomUUID().toString(),
      kind = "text",
      createdAt = System.currentTimeMillis(),
      size = size,
      mime = "text/plain",
      preview = text.take(280),
      text = if (size <= Protocol.INLINE_TEXT_CAP) text else null,
      filename = null,
      thumb = null
    )
  }
}
