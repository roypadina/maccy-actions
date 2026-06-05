package com.royp.maccysync.clipboard

import android.content.ContentValues
import android.content.Context
import android.os.Environment
import android.provider.MediaStore

// Saves received image/file payloads via MediaStore (scoped storage, no runtime
// permission needed on API 29+).
object FileSaver {
  fun saveImage(context: Context, name: String, bytes: ByteArray): Boolean =
    write(context, MediaStore.Images.Media.EXTERNAL_CONTENT_URI, name, "image/png",
          Environment.DIRECTORY_PICTURES + "/MaccySync", bytes)

  fun saveDownload(context: Context, name: String, mime: String?, bytes: ByteArray): Boolean =
    write(context, MediaStore.Downloads.EXTERNAL_CONTENT_URI, name,
          mime ?: "application/octet-stream", Environment.DIRECTORY_DOWNLOADS + "/MaccySync", bytes)

  private fun write(
    context: Context,
    collection: android.net.Uri,
    name: String,
    mime: String,
    relativePath: String,
    bytes: ByteArray
  ): Boolean {
    val resolver = context.contentResolver
    val values = ContentValues().apply {
      put(MediaStore.MediaColumns.DISPLAY_NAME, name)
      put(MediaStore.MediaColumns.MIME_TYPE, mime)
      put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
    }
    val uri = resolver.insert(collection, values) ?: return false
    return runCatching {
      resolver.openOutputStream(uri)?.use { it.write(bytes) } ?: return false
      true
    }.getOrDefault(false)
  }
}
