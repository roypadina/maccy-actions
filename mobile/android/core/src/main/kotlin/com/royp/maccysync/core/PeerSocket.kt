package com.royp.maccysync.core

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.EOFException
import java.io.IOException
import java.net.Socket
import kotlin.concurrent.thread

// One framed connection: runs the signed-ECDH handshake then reads/writes
// length-prefixed AEAD frames. Mirrors PeerConnection.swift. Blocking IO on a
// dedicated thread; callbacks fire on that thread.
class PeerSocket(
  private val role: Role,
  private val socket: Socket,
  private val identity: Identity,
  private val trust: Trust
) {
  enum class Role { SERVER, CLIENT }

  data class Trust(val expectedPeerIdPub: ByteArray?, val pairingToken: String?)

  var onEstablished: (() -> Unit)? = null
  var onControl: ((Control) -> Unit)? = null
  var onContent: ((ContentChunk) -> Unit)? = null
  var onClosed: ((Throwable?) -> Unit)? = null
  var onNewPairing: ((ByteArray) -> Unit)? = null

  private val input = BufferedInputStream(socket.getInputStream())
  private val output = BufferedOutputStream(socket.getOutputStream())
  private val sendLock = Any()
  private var cipher: SessionCipher? = null
  @Volatile private var closed = false
  private var worker: Thread? = null

  private lateinit var ephPriv: org.bouncycastle.crypto.params.X25519PrivateKeyParameters
  private lateinit var clientEph: ByteArray
  private lateinit var serverEph: ByteArray

  fun start() {
    worker = thread(name = "peer-socket") {
      try {
        handshake()
        onEstablished?.invoke()
        readLoop()
      } catch (t: Throwable) {
        fail(t)
      }
    }
  }

  fun cancel() {
    if (closed) return
    closed = true
    runCatching { socket.close() }
    onClosed?.invoke(null)
  }

  // MARK: sending

  fun send(control: Control) = sendEncrypted(FrameCodec.encode(control))
  fun send(chunk: ContentChunk) = sendEncrypted(FrameCodec.encode(chunk))

  private fun sendEncrypted(frame: ByteArray) {
    val cipher = this.cipher ?: return
    synchronized(sendLock) {
      writeRaw(cipher.seal(frame))
    }
  }

  private fun sendHandshake(control: Control) {
    synchronized(sendLock) { writeRaw(FrameCodec.encode(control)) }
  }

  private fun writeRaw(payload: ByteArray) {
    output.write(int32BE(payload.size))
    output.write(payload)
    output.flush()
  }

  // MARK: handshake

  private fun handshake() {
    ephPriv = Handshake.newEphemeral()
    val ephPub = Handshake.publicBytes(ephPriv)
    when (role) {
      Role.CLIENT -> {
        clientEph = ephPub
        sendHandshake(Control.hs1(eph = clientEph.b64()))
        val hs2 = readControl()
        require(hs2.t == "hs2") { "expected hs2" }
        serverEph = hs2.eph!!.fromB64()
        val serverId = hs2.id!!.fromB64()
        val expected = trust.expectedPeerIdPub ?: throw IOException("no pinned server id")
        require(serverId.contentEquals(expected)) { "server id mismatch (MITM?)" }
        val transcript = Handshake.transcript(clientEph, serverEph)
        require(Identity.verify(hs2.sig!!.fromB64(), transcript, serverId)) { "bad server signature" }
        val mySig = identity.sign(transcript)
        sendHandshake(Control.hs3(id = identity.publicKeyRaw.b64(), sig = mySig.b64(), token = trust.pairingToken))
        finish(peerEph = serverEph, isServer = false)
      }
      Role.SERVER -> {
        serverEph = ephPub
        val hs1 = readControl()
        require(hs1.t == "hs1") { "expected hs1" }
        clientEph = hs1.eph!!.fromB64()
        val transcript = Handshake.transcript(clientEph, serverEph)
        sendHandshake(Control.hs2(eph = serverEph.b64(), id = identity.publicKeyRaw.b64(), sig = identity.sign(transcript).b64()))
        val hs3 = readControl()
        require(hs3.t == "hs3") { "expected hs3" }
        val clientId = hs3.id!!.fromB64()
        require(Identity.verify(hs3.sig!!.fromB64(), transcript, clientId)) { "bad client signature" }
        val expected = trust.expectedPeerIdPub
        if (expected != null) {
          require(clientId.contentEquals(expected)) { "unknown client" }
        } else {
          val token = trust.pairingToken
          require(!token.isNullOrEmpty() && hs3.token == token) { "bad pairing token" }
          onNewPairing?.invoke(clientId)
        }
        finish(peerEph = clientEph, isServer = true)
      }
    }
  }

  private fun finish(peerEph: ByteArray, isServer: Boolean) {
    val shared = Handshake.sharedSecret(ephPriv, peerEph)
    val (c2s, s2c) = Handshake.deriveKeys(shared, clientEph, serverEph)
    cipher = SessionCipher(c2s, s2c, isServer)
  }

  // MARK: reading

  private fun readLoop() {
    val cipher = this.cipher ?: return
    while (!closed) {
      val payload = readFrameBytes()
      val plain = cipher.open(payload)
      when (val frame = FrameCodec.decode(plain)) {
        is Frame.ControlFrame -> onControl?.invoke(frame.control)
        is Frame.ContentFrame -> onContent?.invoke(frame.chunk)
      }
    }
  }

  private fun readControl(): Control {
    val frame = FrameCodec.decode(readFrameBytes())
    return (frame as? Frame.ControlFrame)?.control ?: throw IOException("expected control frame")
  }

  private fun readFrameBytes(): ByteArray {
    val len = int32FromBE(readExactly(4))
    if (len <= 0 || len > Protocol.MAX_FRAME) throw IOException("bad frame length $len")
    return readExactly(len)
  }

  private fun readExactly(n: Int): ByteArray {
    val buffer = ByteArray(n)
    var offset = 0
    while (offset < n) {
      val read = input.read(buffer, offset, n - offset)
      if (read < 0) throw EOFException("stream closed")
      offset += read
    }
    return buffer
  }

  private fun fail(error: Throwable?) {
    if (closed) return
    closed = true
    runCatching { socket.close() }
    onClosed?.invoke(error)
  }
}
