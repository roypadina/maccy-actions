package com.royp.maccysync.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

class SyncCoreTest {

  @Test fun uuidBytesRoundTrip() {
    val uuid = UUID.randomUUID()
    val bytes = uuidToBytes(uuid)
    assertEquals(16, bytes.size)
    assertEquals(uuid, bytesToUuid(bytes))
  }

  @Test fun controlMessagesRoundTrip() {
    val meta = ItemMeta("id-1", "image", 1_733_000_000_000L, 42, "image/png", "shot", null, "image.png", "QUJD")
    val messages = listOf(
      Control.hs1("AAA"),
      Control.hs2("BBB", "CCC", "DDD"),
      Control.hs3("EEE", "FFF", "GGG"),
      Control.hs3("EEE", "FFF", null),
      Control.hello("dev", "Phone"),
      Control.historySync(listOf(meta)),
      Control.clipAdded(meta),
      Control.contentRequest("x"),
      Control.contentBegin("x", "file", 10, "text/plain", "a.txt"),
      Control.contentError("x", "too_large"),
      Control.ping, Control.pong
    )
    for (message in messages) {
      val frame = FrameCodec.encode(message)
      val decoded = (FrameCodec.decode(frame) as Frame.ControlFrame).control
      assertEquals("type mismatch", message.t, decoded.t)
    }
  }

  @Test fun inlineTextPreserved() {
    val meta = ItemMeta("id", "text", 1L, 5, "text/plain", "hello", "hello", null, null)
    val decoded = (FrameCodec.decode(FrameCodec.encode(Control.clipAdded(meta))) as Frame.ControlFrame).control
    assertEquals("hello", decoded.item?.text)
    assertEquals(ItemMeta.Kind.text, decoded.item?.kindEnum)
  }

  @Test fun nullFieldsOmitted() {
    val json = String(Control.ping.encode())
    assertEquals("""{"t":"ping"}""", json)
  }

  @Test fun contentChunkRoundTrip() {
    val id = UUID.randomUUID()
    val bytes = ByteArray(300) { (it % 256).toByte() }
    val frame = FrameCodec.encode(ContentChunk(id, 7, true, bytes))
    val chunk = (FrameCodec.decode(frame) as Frame.ContentFrame).chunk
    assertEquals(id, chunk.id)
    assertEquals(7, chunk.seq)
    assertTrue(chunk.last)
    assertArrayEquals(bytes, chunk.bytes)
  }

  @Test fun signVerify() {
    val identity = Identity.generate()
    val message = "transcript".toByteArray()
    val signature = identity.sign(message)
    assertTrue(Identity.verify(signature, message, identity.publicKeyRaw))
    assertFalse(Identity.verify(signature, "other".toByteArray(), identity.publicKeyRaw))
    assertFalse(Identity.verify(signature, message, Identity.generate().publicKeyRaw))
  }

  @Test fun identitySeedRoundTrip() {
    val identity = Identity.generate()
    val restored = Identity.fromSeed(identity.seed)
    assertArrayEquals(identity.publicKeyRaw, restored.publicKeyRaw)
  }

  @Test fun derivedKeysMatchAndCipherInteroperates() {
    val clientEphPriv = Handshake.newEphemeral()
    val serverEphPriv = Handshake.newEphemeral()
    val clientEph = Handshake.publicBytes(clientEphPriv)
    val serverEph = Handshake.publicBytes(serverEphPriv)

    val clientShared = Handshake.sharedSecret(clientEphPriv, serverEph)
    val serverShared = Handshake.sharedSecret(serverEphPriv, clientEph)
    assertArrayEquals(clientShared, serverShared)

    val (c2sA, s2cA) = Handshake.deriveKeys(clientShared, clientEph, serverEph)
    val (c2sB, s2cB) = Handshake.deriveKeys(serverShared, clientEph, serverEph)
    assertArrayEquals(c2sA, c2sB)
    assertArrayEquals(s2cA, s2cB)

    val client = SessionCipher(c2sA, s2cA, isServer = false)
    val server = SessionCipher(c2sB, s2cB, isServer = true)
    for (i in 0 until 5) {
      val pt = "msg-$i".toByteArray()
      assertArrayEquals(pt, server.open(client.seal(pt)))
    }
    val reply = "reply".toByteArray()
    assertArrayEquals(reply, client.open(server.seal(reply)))
  }

  @Test fun tamperedCiphertextFails() {
    val key = ByteArray(32) { it.toByte() }
    val a = SessionCipher(key, key, isServer = false)
    val b = SessionCipher(key, key, isServer = true)
    val sealed = a.seal("secret".toByteArray())
    sealed[0] = (sealed[0].toInt() xor 0xFF).toByte()
    var threw = false
    try { b.open(sealed) } catch (e: Exception) { threw = true }
    assertTrue("tamper must fail auth", threw)
  }

  @Test fun handshakeAndEncryptedClipOverLoopback() {
    val serverId = Identity.generate()
    val clientId = Identity.generate()
    val server = ServerSocket(0)
    val port = server.localPort

    val serverReady = CountDownLatch(1)
    val clientReady = CountDownLatch(1)
    val gotClip = CountDownLatch(1)
    val serverPeerRef = AtomicReference<PeerSocket?>()

    thread {
      val conn = server.accept()
      val peer = PeerSocket(PeerSocket.Role.SERVER, conn, serverId,
        PeerSocket.Trust(clientId.publicKeyRaw, null))
      serverPeerRef.set(peer)
      peer.onEstablished = { serverReady.countDown() }
      peer.onControl = { if (it.t == "clipAdded") gotClip.countDown() }
      peer.start()
    }

    val clientSocket = Socket(InetAddress.getByName("127.0.0.1"), port)
    val client = PeerSocket(PeerSocket.Role.CLIENT, clientSocket, clientId,
      PeerSocket.Trust(serverId.publicKeyRaw, null))
    client.onEstablished = {
      clientReady.countDown()
      client.send(Control.clipAdded(ItemMeta("c1", "text", 0L, 3, "text/plain", "foo", "foo", null, null)))
    }
    client.start()

    assertTrue("server established", serverReady.await(10, TimeUnit.SECONDS))
    assertTrue("client established", clientReady.await(10, TimeUnit.SECONDS))
    assertTrue("server got clip", gotClip.await(10, TimeUnit.SECONDS))

    client.cancel()
    serverPeerRef.get()?.cancel()
    server.close()
  }

  @Test fun pairingModeAcceptsValidToken() {
    val serverId = Identity.generate()
    val clientId = Identity.generate()
    val server = ServerSocket(0)
    val port = server.localPort
    val token = "secret-token"

    val serverReady = CountDownLatch(1)
    val clientReady = CountDownLatch(1)
    val capturedClientPin = AtomicReference<ByteArray?>()
    val serverPeerRef = AtomicReference<PeerSocket?>()

    thread {
      val conn = server.accept()
      val peer = PeerSocket(PeerSocket.Role.SERVER, conn, serverId,
        PeerSocket.Trust(expectedPeerIdPub = null, pairingToken = token))
      serverPeerRef.set(peer)
      peer.onNewPairing = { capturedClientPin.set(it) }
      peer.onEstablished = { serverReady.countDown() }
      peer.start()
    }

    val clientSocket = Socket(InetAddress.getByName("127.0.0.1"), port)
    val client = PeerSocket(PeerSocket.Role.CLIENT, clientSocket, clientId,
      PeerSocket.Trust(expectedPeerIdPub = serverId.publicKeyRaw, pairingToken = token))
    client.onEstablished = { clientReady.countDown() }
    client.start()

    assertTrue(serverReady.await(10, TimeUnit.SECONDS))
    assertTrue(clientReady.await(10, TimeUnit.SECONDS))
    assertNotNull(capturedClientPin.get())
    assertArrayEquals(clientId.publicKeyRaw, capturedClientPin.get())

    client.cancel()
    serverPeerRef.get()?.cancel()
    server.close()
  }

  @Test fun clientAbortsOnWrongServerIdentity() {
    val serverId = Identity.generate()
    val clientId = Identity.generate()
    val imposterPin = Identity.generate().publicKeyRaw
    val server = ServerSocket(0)
    val port = server.localPort

    val clientClosed = CountDownLatch(1)
    val serverPeerRef = AtomicReference<PeerSocket?>()

    thread {
      val conn = server.accept()
      val peer = PeerSocket(PeerSocket.Role.SERVER, conn, serverId,
        PeerSocket.Trust(clientId.publicKeyRaw, null))
      serverPeerRef.set(peer)
      peer.start()
    }

    val clientSocket = Socket(InetAddress.getByName("127.0.0.1"), port)
    val client = PeerSocket(PeerSocket.Role.CLIENT, clientSocket, clientId,
      PeerSocket.Trust(imposterPin, null))
    val established = AtomicReference(false)
    client.onEstablished = { established.set(true) }
    client.onClosed = { clientClosed.countDown() }
    client.start()

    assertTrue("client should abort", clientClosed.await(10, TimeUnit.SECONDS))
    assertFalse("must not establish with wrong pin", established.get())

    client.cancel()
    serverPeerRef.get()?.cancel()
    server.close()
  }
}
