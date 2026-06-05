package com.royp.maccysync.data

import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.RoomDatabase
import com.royp.maccysync.core.ItemMeta
import kotlinx.coroutines.flow.Flow

const val ORIGIN_LOCAL = "local"
const val ORIGIN_MAC = "mac"

@Entity(tableName = "clips")
data class ClipEntity(
  @PrimaryKey val id: String,
  val origin: String,
  val kind: String,
  val createdAt: Long,
  val size: Int,
  val mime: String?,
  val preview: String,
  val text: String?,
  val filename: String?,
  val thumb: String?,
  val contentPath: String? = null
) {
  fun toMeta() = ItemMeta(id, kind, createdAt, size, mime, preview, text, filename, thumb)
}

fun ItemMeta.toEntity(origin: String, contentPath: String? = null) = ClipEntity(
  id = id, origin = origin, kind = kind, createdAt = createdAt, size = size,
  mime = mime, preview = preview, text = text, filename = filename, thumb = thumb,
  contentPath = contentPath
)

@Dao
interface ClipDao {
  @Query("SELECT * FROM clips WHERE origin = :origin ORDER BY createdAt DESC LIMIT 200")
  fun observe(origin: String): Flow<List<ClipEntity>>

  @Query("SELECT * FROM clips WHERE id = :id LIMIT 1")
  suspend fun byId(id: String): ClipEntity?

  @Insert(onConflict = OnConflictStrategy.REPLACE)
  suspend fun upsert(entity: ClipEntity)

  @Query("SELECT * FROM clips WHERE origin = :origin ORDER BY createdAt DESC LIMIT :limit")
  suspend fun recent(origin: String, limit: Int): List<ClipEntity>

  @Query("DELETE FROM clips WHERE origin = :origin")
  suspend fun clearOrigin(origin: String)

  @Query("DELETE FROM clips WHERE origin = :origin AND id NOT IN (SELECT id FROM clips WHERE origin = :origin ORDER BY createdAt DESC LIMIT :keep)")
  suspend fun trim(origin: String, keep: Int)
}

@Database(entities = [ClipEntity::class], version = 1, exportSchema = false)
abstract class AppDatabase : RoomDatabase() {
  abstract fun clipDao(): ClipDao
}
