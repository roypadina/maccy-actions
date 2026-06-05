package com.royp.maccysync.core

import java.nio.ByteBuffer
import java.util.UUID

data class ContentChunk(val id: UUID, val seq: Int, val last: Boolean, val bytes: ByteArray)

// A decoded plaintext frame (the unit that is, post-handshake, AEAD-encrypted).
sealed class Frame {
  data class ControlFrame(val control: Control) : Frame()
  data class ContentFrame(val chunk: ContentChunk) : Frame()
}

object FrameCodec {
  fun encode(control: Control): ByteArray {
    val payload = control.encode()
    val out = ByteArray(1 + payload.size)
    out[0] = 0x01
    System.arraycopy(payload, 0, out, 1, payload.size)
    return out
  }

  fun encode(chunk: ContentChunk): ByteArray {
    val buffer = ByteBuffer.allocate(1 + 16 + 4 + 1 + chunk.bytes.size)
    buffer.put(0x02)
    buffer.put(uuidToBytes(chunk.id))
    buffer.putInt(chunk.seq)
    buffer.put(if (chunk.last) 0x01 else 0x00)
    buffer.put(chunk.bytes)
    return buffer.array()
  }

  fun decode(frame: ByteArray): Frame {
    require(frame.isNotEmpty()) { "empty frame" }
    return when (frame[0]) {
      0x01.toByte() -> Frame.ControlFrame(decodeControl(frame.copyOfRange(1, frame.size)))
      0x02.toByte() -> {
        require(frame.size >= 22) { "malformed content frame" }
        val id = bytesToUuid(frame.copyOfRange(1, 17))
        val seq = ByteBuffer.wrap(frame, 17, 4).int
        val last = frame[21] != 0x00.toByte()
        val bytes = frame.copyOfRange(22, frame.size)
        Frame.ContentFrame(ContentChunk(id, seq, last, bytes))
      }
      else -> throw IllegalArgumentException("unknown frame kind ${frame[0]}")
    }
  }
}

fun uuidToBytes(uuid: UUID): ByteArray =
  ByteBuffer.allocate(16).putLong(uuid.mostSignificantBits).putLong(uuid.leastSignificantBits).array()

fun bytesToUuid(bytes: ByteArray): UUID {
  val buffer = ByteBuffer.wrap(bytes)
  return UUID(buffer.long, buffer.long)
}

fun int32BE(value: Int): ByteArray = ByteBuffer.allocate(4).putInt(value).array()
fun int32FromBE(bytes: ByteArray): Int = ByteBuffer.wrap(bytes).int
