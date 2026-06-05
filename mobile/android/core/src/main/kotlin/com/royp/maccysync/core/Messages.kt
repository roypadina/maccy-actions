package com.royp.maccysync.core

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

// Wire item metadata. Field names + optionality match ItemMeta in SyncProtocol.swift.
@Serializable
data class ItemMeta(
  val id: String,
  val kind: String,                 // "text" | "image" | "file"
  val createdAt: Long,              // unix epoch millis
  val size: Int,
  val mime: String? = null,
  val preview: String,
  val text: String? = null,         // present iff text kind and size <= INLINE_TEXT_CAP
  val filename: String? = null,
  val thumb: String? = null         // base64 PNG, image kind only
) {
  enum class Kind { text, image, file }
  val kindEnum: Kind get() = runCatching { Kind.valueOf(kind) }.getOrDefault(Kind.text)
}

// A single flat control-message shape with a `t` discriminator, mirroring the
// Swift custom Codable. Absent/null fields are omitted on the wire.
@Serializable
data class Control(
  val t: String,
  val eph: String? = null,
  val id: String? = null,
  val sig: String? = null,
  val token: String? = null,
  val deviceId: String? = null,
  val name: String? = null,
  val platform: String? = null,
  val protocolVersion: Int? = null,
  val items: List<ItemMeta>? = null,
  val item: ItemMeta? = null,
  val kind: String? = null,
  val size: Int? = null,
  val mime: String? = null,
  val filename: String? = null,
  val reason: String? = null
) {
  companion object {
    @OptIn(ExperimentalSerializationApi::class)
    val json = Json {
      explicitNulls = false
      encodeDefaults = false
      ignoreUnknownKeys = true
    }

    fun hs1(eph: String) = Control(t = "hs1", eph = eph)
    fun hs2(eph: String, id: String, sig: String) = Control(t = "hs2", eph = eph, id = id, sig = sig)
    fun hs3(id: String, sig: String, token: String?) = Control(t = "hs3", id = id, sig = sig, token = token)
    fun hello(deviceId: String, name: String) =
      Control(t = "hello", deviceId = deviceId, name = name, platform = "android", protocolVersion = Protocol.VERSION)
    fun historySync(items: List<ItemMeta>) = Control(t = "historySync", items = items)
    fun clipAdded(item: ItemMeta) = Control(t = "clipAdded", item = item)
    fun contentRequest(id: String) = Control(t = "contentRequest", id = id)
    fun contentBegin(id: String, kind: String, size: Int, mime: String?, filename: String?) =
      Control(t = "contentBegin", id = id, kind = kind, size = size, mime = mime, filename = filename)
    fun contentError(id: String, reason: String) = Control(t = "contentError", id = id, reason = reason)
    val ping = Control(t = "ping")
    val pong = Control(t = "pong")
  }

  fun encode(): ByteArray = json.encodeToString(serializer(), this).toByteArray(Charsets.UTF_8)
}

fun decodeControl(bytes: ByteArray): Control =
  Control.json.decodeFromString(Control.serializer(), String(bytes, Charsets.UTF_8))
