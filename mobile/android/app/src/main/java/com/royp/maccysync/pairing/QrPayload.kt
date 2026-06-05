package com.royp.maccysync.pairing

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

// Mirror of the QR JSON the Mac shows (see docs/protocol/PROTOCOL.md).
@Serializable
data class QrPayload(
  val v: Int = 1,
  val host: String,
  val hosts: List<String> = emptyList(),
  val port: Int,
  val idpub: String,
  val token: String,
  val name: String,
  val deviceId: String
)

object QrParser {
  private val json = Json { ignoreUnknownKeys = true }

  fun parse(text: String): QrPayload? =
    runCatching { json.decodeFromString(QrPayload.serializer(), text) }
      .getOrNull()
      ?.takeIf { it.idpub.isNotEmpty() && it.token.isNotEmpty() && it.host.isNotEmpty() }
}
