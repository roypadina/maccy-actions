package com.royp.maccysync.core

// Mirror of docs/protocol/PROTOCOL.md. Must match the Mac app's SyncProtocol.swift.
object Protocol {
  const val VERSION = 1
  const val BONJOUR_TYPE = "_maccysync._tcp"
  const val DEFAULT_PORT = 53121
  const val INLINE_TEXT_CAP = 16_384
  const val THUMB_CAP = 65_536
  const val CHUNK_SIZE = 65_536
  const val MAX_FRAME = 17_825_792
  const val MAX_CONTENT = 16_777_216
  const val HISTORY_SYNC_COUNT = 50
  const val PING_INTERVAL_MS = 20_000L
  const val DEAD_TIMEOUT_MS = 60_000L
}
