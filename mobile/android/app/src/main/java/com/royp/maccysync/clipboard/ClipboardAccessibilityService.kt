package com.royp.maccysync.clipboard

import android.accessibilityservice.AccessibilityService
import android.content.ClipboardManager
import android.content.Context
import android.view.accessibility.AccessibilityEvent
import com.royp.maccysync.MaccyApp

// An active AccessibilityService is permitted to read the clipboard in the
// background on Android 10+ — the technique real clipboard-history apps use to
// auto-capture copies. We listen for primary-clip changes and forward text.
class ClipboardAccessibilityService : AccessibilityService() {
  private var clipboard: ClipboardManager? = null
  private val listener = ClipboardManager.OnPrimaryClipChangedListener { onClipChanged() }

  override fun onServiceConnected() {
    super.onServiceConnected()
    val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    cm.addPrimaryClipChangedListener(listener)
    clipboard = cm
  }

  override fun onAccessibilityEvent(event: AccessibilityEvent?) { /* clipboard listener handles capture */ }

  override fun onInterrupt() { }

  override fun onDestroy() {
    clipboard?.removePrimaryClipChangedListener(listener)
    super.onDestroy()
  }

  private fun onClipChanged() {
    val text = ClipboardCapture.currentText(this) ?: return
    if (ClipboardWriter.wasJustWritten(text)) return
    val controller = MaccyApp.from(this).controller
    controller.captureLocal(ClipboardCapture.metaFor(text))
  }
}
