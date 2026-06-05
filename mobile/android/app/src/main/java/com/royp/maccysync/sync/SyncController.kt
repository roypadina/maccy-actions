package com.royp.maccysync.sync

import android.content.Context
import com.royp.maccysync.Prefs
import com.royp.maccysync.clipboard.ClipboardWriter
import com.royp.maccysync.clipboard.FileSaver
import com.royp.maccysync.core.Control
import com.royp.maccysync.core.ContentChunk
import com.royp.maccysync.core.Identity
import com.royp.maccysync.core.ItemMeta
import com.royp.maccysync.core.PeerSocket
import com.royp.maccysync.core.Protocol
import com.royp.maccysync.core.fromB64
import com.royp.maccysync.data.ClipRepository
import com.royp.maccysync.pairing.QrPayload
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withTimeout
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

// Client-side sync brain: maintains the connection to the Mac, exchanges history
// and clips, serves/fetches content, and applies remote clips locally.
class SyncController(
  private val appContext: Context,
  private val prefs: Prefs,
  private val repo: ClipRepository
) {
  enum class ConnState { Disconnected, Connecting, Connected, Pairing }

  private val _state = MutableStateFlow(ConnState.Disconnected)
  val state: StateFlow<ConnState> = _state
  private val _peerName = MutableStateFlow(prefs.macName ?: "")
  val peerName: StateFlow<String> = _peerName

  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
  private val identity: Identity = prefs.identity()
  private var peer: PeerSocket? = null
  @Volatile private var running = false
  private var reconnectJob: Job? = null

  private val fetchBuffers = ConcurrentHashMap<String, ByteArrayOutputStream>()
  private val fetchWaiters = ConcurrentHashMap<String, CompletableDeferred<ByteArray>>()

  // MARK: lifecycle

  fun start() {
    if (!prefs.syncEnabled || !prefs.isPaired) return
    running = true
    startReconnectLoop()
  }

  fun stop() {
    running = false
    reconnectJob?.cancel()
    peer?.cancel()
    peer = null
    _state.value = ConnState.Disconnected
  }

  private fun startReconnectLoop() {
    reconnectJob?.cancel()
    reconnectJob = scope.launch {
      while (running && isActive) {
        if (peer == null) {
          runCatching { connectOnce() }
            .onFailure { _state.value = ConnState.Disconnected }
        }
        delay(4_000)
      }
    }
  }

  private fun connectOnce() {
    val host = prefs.macHost ?: return
    val expected = prefs.macIdPub?.fromB64() ?: return
    _state.value = ConnState.Connecting
    val socket = Socket()
    socket.connect(InetSocketAddress(host, prefs.macPort), 5_000)
    val peer = PeerSocket(PeerSocket.Role.CLIENT, socket, identity,
      PeerSocket.Trust(expectedPeerIdPub = expected, pairingToken = null))
    attachHandlers(peer, pairing = false, onEstablished = null)
    this.peer = peer
    peer.start()
  }

  // MARK: pairing

  fun startPairing(payload: QrPayload, onResult: (Boolean, String?) -> Unit) {
    stop()
    _state.value = ConnState.Pairing
    scope.launch {
      val established = CompletableDeferred<Boolean>()
      try {
        val socket = Socket()
        socket.connect(InetSocketAddress(payload.host, payload.port), 5_000)
        val peer = PeerSocket(PeerSocket.Role.CLIENT, socket, identity,
          PeerSocket.Trust(expectedPeerIdPub = payload.idpub.fromB64(), pairingToken = payload.token))
        attachHandlers(peer, pairing = true, onEstablished = { established.complete(true) })
        this@SyncController.peer = peer
        peer.start()
        withTimeout(8_000) { established.await() }
        prefs.savePaired(payload.idpub, payload.name, payload.host, payload.port, payload.deviceId)
        prefs.syncEnabled = true
        running = true
        startReconnectLoop()
        onResult(true, null)
      } catch (e: Exception) {
        peer?.cancel(); peer = null
        _state.value = ConnState.Disconnected
        onResult(false, e.message)
      }
    }
  }

  fun unpair() {
    stop()
    prefs.clearPaired()
    scope.launch { repo.clearMac() }
  }

  // MARK: peer wiring

  private fun attachHandlers(peer: PeerSocket, pairing: Boolean, onEstablished: (() -> Unit)?) {
    peer.onEstablished = {
      peer.send(Control.hello(prefs.deviceId, prefs.deviceName))
      scope.launch { sendHistorySync(peer) }
      _state.value = ConnState.Connected
      if (prefs.macName != null) _peerName.value = prefs.macName!!
      onEstablished?.invoke()
    }
    peer.onControl = { message -> scope.launch { handleControl(peer, message) } }
    peer.onContent = { chunk -> handleContent(chunk) }
    peer.onClosed = {
      if (this.peer === peer) {
        this.peer = null
        if (_state.value != ConnState.Pairing) _state.value = ConnState.Disconnected
      }
      fetchWaiters.values.forEach { it.completeExceptionally(IOException("connection closed")) }
      fetchWaiters.clear()
      fetchBuffers.clear()
    }
  }

  private suspend fun sendHistorySync(peer: PeerSocket) {
    if (!prefs.sendText) { peer.send(Control.historySync(emptyList())); return }
    val items = repo.recentLocal(Protocol.HISTORY_SYNC_COUNT)
    peer.send(Control.historySync(items))
  }

  // MARK: inbound

  private suspend fun handleControl(peer: PeerSocket, message: Control) {
    when (message.t) {
      "hello" -> {
        message.name?.let { _peerName.value = it; prefs.macName = it }
        _state.value = ConnState.Connected
      }
      "historySync" -> repo.replaceMacHistory(message.items ?: emptyList())
      "clipAdded" -> message.item?.let { repo.upsertMac(it) }
      "contentRequest" -> message.id?.let { serveContent(peer, it) }
      "contentBegin" -> message.id?.let { fetchBuffers[it] = ByteArrayOutputStream() }
      "contentError" -> message.id?.let { id ->
        fetchWaiters.remove(id)?.completeExceptionally(IOException(message.reason ?: "content error"))
        fetchBuffers.remove(id)
      }
      "ping" -> peer.send(Control.pong)
      else -> {}
    }
  }

  private fun handleContent(chunk: ContentChunk) {
    val id = chunk.id.toString()
    val buffer = fetchBuffers[id] ?: return
    buffer.write(chunk.bytes)
    if (!chunk.last) return
    val data = buffer.toByteArray()
    fetchBuffers.remove(id)
    scope.launch { repo.storeContent(id, data) }
    fetchWaiters.remove(id)?.complete(data)
  }

  // MARK: serving local content to the Mac

  private suspend fun serveContent(peer: PeerSocket, id: String) {
    val entity = repo.byId(id)
    if (entity == null) { peer.send(Control.contentError(id, "not_found")); return }
    val bytes: ByteArray = when (entity.kind) {
      "text" -> (entity.text ?: "").toByteArray(Charsets.UTF_8)
      else -> entity.contentPath?.let { File(it).readBytes() }
        ?: run { peer.send(Control.contentError(id, "not_found")); return }
    }
    if (bytes.size > Protocol.MAX_CONTENT) { peer.send(Control.contentError(id, "too_large")); return }
    peer.send(Control.contentBegin(id, entity.kind, bytes.size, entity.mime, entity.filename))
    val uuid = runCatching { UUID.fromString(id) }.getOrNull()
      ?: run { peer.send(Control.contentError(id, "bad_id")); return }
    if (bytes.isEmpty()) { peer.send(ContentChunk(uuid, 0, true, ByteArray(0))); return }
    var seq = 0
    var offset = 0
    while (offset < bytes.size) {
      val end = minOf(offset + Protocol.CHUNK_SIZE, bytes.size)
      val slice = bytes.copyOfRange(offset, end)
      peer.send(ContentChunk(uuid, seq, end >= bytes.size, slice))
      seq++; offset = end
    }
  }

  // MARK: fetching Mac content

  private suspend fun fetchContent(id: String): ByteArray {
    repo.cachedContentFile(id)?.let { return it.readBytes() }
    val peer = this.peer ?: throw IOException("not connected")
    val waiter = CompletableDeferred<ByteArray>()
    fetchWaiters[id] = waiter
    fetchBuffers[id] = ByteArrayOutputStream()
    peer.send(Control.contentRequest(id))
    return withTimeout(30_000) { waiter.await() }
  }

  // MARK: outbound (local clip -> Mac)

  fun captureLocal(meta: ItemMeta) {
    scope.launch {
      repo.upsertLocal(meta)
      if (_state.value == ConnState.Connected) peer?.send(Control.clipAdded(meta))
    }
  }

  // MARK: applying a Mac clip on this phone

  suspend fun applyMacClip(meta: ItemMeta): Boolean {
    return when (meta.kindEnum) {
      ItemMeta.Kind.text -> {
        val text = meta.text ?: runCatching { fetchContent(meta.id).toString(Charsets.UTF_8) }.getOrNull()
        if (text == null) false else { ClipboardWriter.setText(appContext, text); true }
      }
      ItemMeta.Kind.image -> {
        val bytes = runCatching { fetchContent(meta.id) }.getOrNull() ?: return false
        FileSaver.saveImage(appContext, meta.filename ?: "${meta.id}.png", bytes)
      }
      ItemMeta.Kind.file -> {
        val bytes = runCatching { fetchContent(meta.id) }.getOrNull() ?: return false
        FileSaver.saveDownload(appContext, meta.filename ?: "${meta.id}.bin", meta.mime, bytes)
      }
    }
  }
}
