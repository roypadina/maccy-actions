package com.royp.maccysync.data

import android.content.Context
import androidx.room.Room
import com.royp.maccysync.core.ItemMeta
import kotlinx.coroutines.flow.Flow
import java.io.File

// Thin wrapper over Room + a content cache directory for fetched Mac payloads.
class ClipRepository(context: Context) {
  private val db = Room.databaseBuilder(
    context.applicationContext, AppDatabase::class.java, "maccy-clips.db"
  ).fallbackToDestructiveMigration().build()

  private val dao = db.clipDao()

  private val contentDir: File =
    File(context.filesDir, "remote-content").apply { mkdirs() }

  fun localClips(): Flow<List<ClipEntity>> = dao.observe(ORIGIN_LOCAL)
  fun macClips(): Flow<List<ClipEntity>> = dao.observe(ORIGIN_MAC)

  suspend fun byId(id: String): ClipEntity? = dao.byId(id)

  suspend fun upsertLocal(meta: ItemMeta) {
    dao.upsert(meta.toEntity(ORIGIN_LOCAL))
    dao.trim(ORIGIN_LOCAL, 200)
  }

  suspend fun upsertMac(meta: ItemMeta) {
    val existing = dao.byId(meta.id)
    dao.upsert(meta.toEntity(ORIGIN_MAC, contentPath = existing?.contentPath))
    dao.trim(ORIGIN_MAC, 200)
  }

  suspend fun replaceMacHistory(metas: List<ItemMeta>) {
    dao.clearOrigin(ORIGIN_MAC)
    metas.forEach { dao.upsert(it.toEntity(ORIGIN_MAC)) }
  }

  suspend fun recentLocal(limit: Int): List<ItemMeta> =
    dao.recent(ORIGIN_LOCAL, limit).map { it.toMeta() }

  // Content cache for fetched Mac image/file bytes.
  fun cachedContentFile(id: String): File? =
    File(contentDir, id).takeIf { it.exists() }

  suspend fun storeContent(id: String, bytes: ByteArray): File {
    val file = File(contentDir, id)
    file.writeBytes(bytes)
    val existing = dao.byId(id)
    if (existing != null) dao.upsert(existing.copy(contentPath = file.absolutePath))
    return file
  }

  suspend fun clearMac() {
    dao.clearOrigin(ORIGIN_MAC)
    contentDir.listFiles()?.forEach { it.delete() }
  }
}
