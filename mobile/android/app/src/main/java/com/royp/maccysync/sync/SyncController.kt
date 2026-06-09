package com.royp.maccysync.sync

import android.content.Context
import android.net.Uri
import android.util.Log
import com.royp.maccysync.Prefs
import com.royp.maccysync.clipboard.ClipboardCapture
import com.royp.maccysync.clipboard.ClipboardWriter
import com.royp.maccysync.clipboard.FileImport
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
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
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
  // Liveness: the Mac pings every ~20s; if we hear nothing for DEAD_TIMEOUT the
  // socket is half-open (typically after Doze) — drop it so the loop redials.
  @Volatile private var lastRxAt = 0L
  @Volatile private var connectedHost: String? = null

  private val fetchBuffers = ConcurrentHashMap<String, ByteArrayOutputStream>()
  private val fetchWaiters = ConcurrentHashMap<String, CompletableDeferred<ByteArray>>()
  // Disk-streamed file downloads (never buffer 256 MiB in RAM).
  private val fetchFileStreams = ConcurrentHashMap<String, FileOutputStream>()
  private val fetchFileTargets = ConcurrentHashMap<String, File>()
  private val fetchFileWaiters = ConcurrentHashMap<String, CompletableDeferred<File>>()

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
        val p = peer
        if (p == null) {
          runCatching { connectOnce() }
            .onFailure { Log.w(TAG, "connectOnce failed: ${it.message}", it); _state.value = ConnState.Disconnected }
        } else if (lastRxAt > 0 && System.currentTimeMillis() - lastRxAt > Protocol.DEAD_TIMEOUT_MS) {
          // Half-open (Doze / network change) — Mac pings every 20s, so >60s silence = dead.
          Log.w(TAG, "connection stale (${System.currentTimeMillis() - lastRxAt}ms), reconnecting")
          runCatching { p.cancel() }
          if (peer === p) peer = null
          connectedHost = null
          _state.value = ConnState.Disconnected
        }
        delay(4_000)
      }
    }
  }

  private fun connectOnce() {
    val expected = prefs.macIdPub?.fromB64() ?: run { Log.w(TAG, "no macIdPub"); return }
    // The mDNS-discovered current address (prefs.macHost) goes first, then the
    // stored candidates (LAN + Tailscale). Dedup keeps it from being retried.
    val candidates = (listOfNotNull(prefs.macHost) + prefs.macHosts).distinct()
    if (candidates.isEmpty()) { Log.w(TAG, "no macHost"); return }
    _state.value = ConnState.Connecting
    // Try each candidate (LAN first, Tailscale last) until one TCP-connects. The
    // handshake still pins the Mac's idPub, so trying multiple hosts is safe.
    var socket: Socket? = null
    var used: String? = null
    for (host in candidates) {
      val s = Socket()
      try {
        Log.i(TAG, "connecting to $host:${prefs.macPort}")
        s.connect(InetSocketAddress(host, prefs.macPort), 4_000)
        socket = s; used = host
        Log.i(TAG, "tcp connected to $host:${prefs.macPort}")
        break
      } catch (e: Exception) {
        Log.w(TAG, "connect $host failed: ${e.message}")
        runCatching { s.close() }
      }
    }
    if (socket == null) { _state.value = ConnState.Disconnected; return }
    used?.let { if (prefs.macHost != it) prefs.macHost = it }
    connectedHost = used
    lastRxAt = System.currentTimeMillis()
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
        prefs.savePaired(payload.idpub, payload.name, payload.host, payload.port, payload.deviceId, payload.hosts)
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

  /**
   * mDNS resolved the Mac's current LAN address. Make it the first connect
   * candidate; if we're currently bound to a different (likely dead) address —
   * e.g. the Mac's DHCP IP changed — drop the socket so the loop redials the new
   * one immediately instead of waiting out the dead-timeout.
   */
  fun onDiscovered(host: String, port: Int) {
    prefs.macPort = port
    if (prefs.macHost != host) prefs.macHost = host
    prefs.macHosts = listOf(host) + prefs.macHosts  // setter dedups → host stays first
    val cur = connectedHost
    if (peer != null && cur != null && cur != host) {
      Log.i(TAG, "discovered new Mac address $host (was $cur), reconnecting")
      runCatching { peer?.cancel() }
      peer = null
      connectedHost = null
      _state.value = ConnState.Disconnected
    }
  }

  // MARK: peer wiring

  private fun attachHandlers(peer: PeerSocket, pairing: Boolean, onEstablished: (() -> Unit)?) {
    peer.onEstablished = {
      Log.i(TAG, "handshake established")
      peer.send(Control.hello(prefs.deviceId, prefs.deviceName))
      scope.launch { sendHistorySync(peer) }
      _state.value = ConnState.Connected
      if (prefs.macName != null) _peerName.value = prefs.macName!!
      onEstablished?.invoke()
    }
    peer.onControl = { message -> scope.launch { handleControl(peer, message) } }
    peer.onContent = { chunk -> handleContent(chunk) }
    peer.onClosed = { error ->
      Log.w(TAG, "peer closed: ${error?.message}", error)
      if (this.peer === peer) {
        this.peer = null
        connectedHost = null
        if (_state.value != ConnState.Pairing) _state.value = ConnState.Disconnected
      }
      fetchWaiters.values.forEach { it.completeExceptionally(IOException("connection closed")) }
      fetchWaiters.clear()
      fetchBuffers.clear()
      fetchFileWaiters.values.forEach { it.completeExceptionally(IOException("connection closed")) }
      fetchFileWaiters.clear()
      fetchFileStreams.values.forEach { runCatching { it.close() } }
      fetchFileStreams.clear()
      fetchFileTargets.values.forEach { it.delete() }
      fetchFileTargets.clear()
    }
  }

  private suspend fun sendHistorySync(peer: PeerSocket) {
    // Phone→Mac is explicit-only now: nothing is bulk-pushed on connect. Clips go
    // to the Mac solely via the notification (current clip) or a per-clip tap.
    peer.send(Control.historySync(emptyList()))
  }

  // MARK: inbound

  private suspend fun handleControl(peer: PeerSocket, message: Control) {
    lastRxAt = System.currentTimeMillis()
    when (message.t) {
      "hello" -> {
        message.name?.let { _peerName.value = it; prefs.macName = it }
        // Learn the Mac's full address set (incl. Tailscale) so a LAN-paired phone
        // can later reach it over WAN. Merge keeps the LAN-first ordering.
        message.hosts?.takeIf { it.isNotEmpty() }?.let { prefs.macHosts = prefs.macHosts + it }
        _state.value = ConnState.Connected
      }
      "historySync" -> repo.replaceMacHistory(message.items ?: emptyList())
      "requestHistory" -> sendHistorySync(peer)
      "clipAdded" -> message.item?.let { repo.upsertMac(it) }
      "contentRequest" -> message.id?.let { serveContent(peer, it) }
      "contentBegin" -> message.id?.let { id ->
        if (message.kind == "file") {
          // Stream straight to a temp file in the cache dir.
          val tmp = File(appContext.cacheDir, "dl-$id")
          runCatching { fetchFileStreams[id] = FileOutputStream(tmp) }
            .onSuccess { fetchFileTargets[id] = tmp }
            .onFailure { fetchFileWaiters.remove(id)?.completeExceptionally(it) }
        } else {
          fetchBuffers[id] = ByteArrayOutputStream()
        }
      }
      "contentError" -> message.id?.let { id ->
        val err = IOException(message.reason ?: "content error")
        fetchWaiters.remove(id)?.completeExceptionally(err)
        fetchBuffers.remove(id)
        fetchFileStreams.remove(id)?.let { runCatching { it.close() } }
        fetchFileTargets.remove(id)?.delete()
        fetchFileWaiters.remove(id)?.completeExceptionally(err)
      }
      "ping" -> peer.send(Control.pong)
      else -> {}
    }
  }

  private fun handleContent(chunk: ContentChunk) {
    lastRxAt = System.currentTimeMillis()
    val id = chunk.id.toString()
    // File stream → write straight to disk.
    val fileStream = fetchFileStreams[id]
    if (fileStream != null) {
      runCatching { fileStream.write(chunk.bytes) }
      if (!chunk.last) return
      runCatching { fileStream.close() }
      fetchFileStreams.remove(id)
      val target = fetchFileTargets.remove(id)
      if (target != null) fetchFileWaiters.remove(id)?.complete(target)
      else fetchFileWaiters.remove(id)?.completeExceptionally(IOException("no target"))
      return
    }
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
    val uuid = runCatching { UUID.fromString(id) }.getOrNull()
      ?: run { peer.send(Control.contentError(id, "bad_id")); return }

    // Text ships from RAM; files stream off disk (so a 256 MiB upload never loads whole).
    if (entity.kind == "text") {
      val bytes = (entity.text ?: "").toByteArray(Charsets.UTF_8)
      if (bytes.size > Protocol.MAX_CONTENT) { peer.send(Control.contentError(id, "too_large")); return }
      peer.send(Control.contentBegin(id, "text", bytes.size, entity.mime, entity.filename))
      if (bytes.isEmpty()) { peer.send(ContentChunk(uuid, 0, true, ByteArray(0))); return }
      var seq = 0; var offset = 0
      while (offset < bytes.size) {
        val end = minOf(offset + Protocol.CHUNK_SIZE, bytes.size)
        peer.send(ContentChunk(uuid, seq, end >= bytes.size, bytes.copyOfRange(offset, end)))
        seq++; offset = end
      }
      return
    }

    val file = entity.contentPath?.let { File(it) }
    if (file == null || !file.exists()) { peer.send(Control.contentError(id, "not_found")); return }
    val size = file.length()
    if (size > Protocol.MAX_CONTENT) { peer.send(Control.contentError(id, "too_large")); return }
    peer.send(Control.contentBegin(id, entity.kind, size.toInt(), entity.mime, entity.filename))
    if (size == 0L) { peer.send(ContentChunk(uuid, 0, true, ByteArray(0))); return }
    file.inputStream().use { input ->
      val buf = ByteArray(Protocol.CHUNK_SIZE)
      var seq = 0
      var sent = 0L
      while (true) {
        val n = input.read(buf)
        if (n <= 0) break
        sent += n
        peer.send(ContentChunk(uuid, seq, sent >= size, buf.copyOf(n)))
        seq++
      }
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

  // Streams a Mac file to a temp file on disk (the contentBegin handler opens the
  // stream once it learns kind == file). Generous timeout for big transfers.
  private suspend fun fetchContentToFile(id: String): File {
    val peer = this.peer ?: throw IOException("not connected")
    val waiter = CompletableDeferred<File>()
    fetchFileWaiters[id] = waiter
    peer.send(Control.contentRequest(id))
    return withTimeout(300_000) { waiter.await() }
  }

  // MARK: outbound (local clip -> Mac)

  /**
   * Record a freshly observed/shared text clip. Skips our own clipboard writes
   * (echo) and consecutive duplicates, stores it locally so it shows in the
   * phone list 1:1, then pushes it to the Mac. `auto` capture (accessibility,
   * foreground read) respects the "send my copies" toggle; explicit user
   * actions (share, tile, notification) always push when connected.
   */
  fun onLocalText(rawText: String, auto: Boolean = true, onResult: ((Boolean) -> Unit)? = null) {
    scope.launch {
      var pushed = false
      if (rawText.isNotBlank() &&
        !ClipboardWriter.wasJustWritten(rawText) &&
        repo.latestLocalText() != rawText &&
        // Auto-capture must not refile a clip that came FROM the Mac (it lands on
        // the phone clipboard when you tap a "From Mac" row) back into "This Phone".
        (!auto || !repo.macHasText(rawText))
      ) {
        val meta = ClipboardCapture.metaFor(rawText)
        repo.upsertLocal(meta)
        // Auto-capture NEVER pushes — it only fills the phone's own list. Pushing
        // to the Mac is explicit only (share/tile here; notification + per-clip tap
        // elsewhere).
        if (!auto && _state.value == ConnState.Connected) {
          peer?.send(Control.clipAdded(meta)); pushed = true
        }
      }
      onResult?.let { cb -> withContext(Dispatchers.Main) { cb(pushed) } }
    }
  }

  /**
   * Call when the app returns to the foreground. Samsung freezes the whole process
   * in the background, so a connection can be silently half-open. If we haven't
   * heard from the Mac recently, drop + redial; otherwise just pull the latest
   * history so the list is current the instant the user opens the app.
   */
  fun nudge() {
    if (!running) return
    val p = peer ?: return  // reconnect loop will dial
    scope.launch {
      if (System.currentTimeMillis() - lastRxAt > 8_000) {
        Log.i(TAG, "foreground nudge: stale, reconnecting")
        runCatching { p.cancel() }
        if (peer === p) peer = null
        connectedHost = null
        _state.value = ConnState.Disconnected
      } else {
        runCatching { p.send(Control.requestHistory) }
      }
    }
  }

  // MARK: bringing a file INTO the phone list (picker / share-sheet)

  /**
   * Import a picked/shared file URI into the phone's "This Phone" list as a file
   * clip (copied into app storage so it survives). Does NOT upload — the user taps
   * the clip's Upload button to send it. onResult(false) on copy failure / over cap.
   */
  fun importFile(uri: Uri, upload: Boolean = false, onResult: (Boolean) -> Unit) {
    scope.launch {
      val imported = withContext(Dispatchers.IO) { FileImport.fromUri(appContext, uri) }
      if (imported == null) { withContext(Dispatchers.Main) { onResult(false) }; return@launch }
      repo.upsertLocal(imported.meta, imported.contentPath)
      // Share-sheet import is an explicit "send" → push now (the Mac pulls the bytes).
      // The + picker just stages the clip; the user taps Upload when ready.
      if (upload) peer?.let { it.send(Control.clipAdded(imported.meta)) }
      withContext(Dispatchers.Main) { onResult(true) }
    }
  }

  /**
   * On app open: always surface the current clipboard value in the "This Phone"
   * list so it's there to send. Unlike auto-capture this ignores the Mac-origin
   * guard (the user explicitly opened the app and wants to see/send the current
   * clip), but still skips our own just-written value and avoids spamming a
   * duplicate when it already sits at the top. Never auto-sends.
   */
  fun captureForList(rawText: String) {
    scope.launch {
      if (rawText.isNotBlank() &&
        !ClipboardWriter.wasJustWritten(rawText) &&
        repo.latestLocalText() != rawText
      ) {
        repo.upsertLocal(ClipboardCapture.metaFor(rawText))
      }
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
        val tmp = runCatching { fetchContentToFile(meta.id) }.getOrNull() ?: return false
        val ok = FileSaver.saveDownloadStreamed(appContext, meta.filename ?: "${meta.id}.bin", meta.mime, tmp)
        tmp.delete()
        ok
      }
    }
  }

  // MARK: explicit phone -> Mac push

  fun isConnected(): Boolean = peer != null

  /**
   * Push one already-stored phone clip to the Mac on a background thread.
   * Files are allowed here — this is the explicit per-clip tap. onResult(false)
   * if not connected. MUST be async: peer.send() does blocking socket IO and
   * crashed the app when called on the UI thread (NetworkOnMainThreadException).
   */
  fun sendToMac(meta: ItemMeta, onResult: (Boolean) -> Unit) {
    scope.launch {
      val ok = peer?.let { it.send(Control.clipAdded(meta)); true } ?: false
      withContext(Dispatchers.Main) { onResult(ok) }
    }
  }

  /**
   * Notification tap: send the clip the user just copied (read by a focused
   * activity — the only place a read is allowed) to the Mac. Stores it in the
   * phone's own list too. Skips our own writes and Mac-origin text. Waits briefly
   * for the connection in case the app was frozen and is reconnecting.
   * onResult(false) if not connected or nothing to send.
   */
  fun sendCurrentToMac(currentText: String?, onResult: (Boolean) -> Unit) {
    scope.launch {
      // The app may have been frozen in the background — give the reconnect a moment.
      var p = peer
      var waited = 0
      while (p == null && waited < 6_000) { delay(500); waited += 500; p = peer }
      var ok = false
      val text = currentText
      if (p != null && !text.isNullOrBlank() &&
        !ClipboardWriter.wasJustWritten(text) && !repo.macHasText(text)
      ) {
        val meta = ClipboardCapture.metaFor(text)
        if (repo.latestLocalText() != text) repo.upsertLocal(meta)
        p.send(Control.clipAdded(meta)); ok = true
      }
      withContext(Dispatchers.Main) { onResult(ok) }
    }
  }

  private companion object { const val TAG = "MaccySync" }
}
