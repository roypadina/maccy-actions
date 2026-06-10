import AppKit
import Defaults
import Foundation
import Network
import Observation
import UniformTypeIdentifiers

// Central LAN sync orchestrator. Mac is the server: it listens, advertises via
// Bonjour, accepts one phone, runs the handshake, then exchanges history/clips.
// Conforms to the existing `SyncService` seam used by SendToAndroidAction.
@MainActor
@Observable
final class LanSyncService: SyncService {
  static let shared = LanSyncService()

  enum State: Equatable { case off, listening, pairing, connected }

  private(set) var state: State = .off
  private(set) var connectedPeerName: String = ""
  /// QR JSON to display while pairing (nil when not pairing).
  private(set) var pairingQR: String?

  var pairedDevice: PairedDevice? { Defaults[.syncPairedDevice] }
  var isPaired: Bool { pairedDevice != nil }

  let identity = SyncIdentity.loadOrCreate()

  private var listener: NWListener?
  private var peer: PeerConnection?
  private var pairingToken: String?
  private var pendingPairingIdPub: Data?

  private var announced: [String: HistoryItem] = [:]
  // In-RAM receive (text/image): id -> accumulating bytes + continuation.
  private var fetchBuffers: [String: Data] = [:]
  private var fetchConts: [String: CheckedContinuation<Data, Error>] = [:]
  // Disk-streamed receive (file): id -> open write handle / destination / continuation.
  private var fetchFileHandles: [String: FileHandle] = [:]
  private var fetchFileURLs: [String: URL] = [:]
  private var fetchFileConts: [String: CheckedContinuation<URL, Error>] = [:]
  // Incoming-file progress (phone→Mac), for the notification shown while receiving.
  private struct Incoming { let name: String; let total: Int; var received: Int; var lastPct: Int }
  private var incoming: [String: Incoming] = [:]
  private var pingTimer: Timer?

  private static func byteString(_ count: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
  }

  // MARK: - Lifecycle

  func start() {
    guard Defaults[.syncEnabled] else { return }
    startListener()
  }

  func stop() {
    pingTimer?.invalidate()
    peer?.cancel()
    peer = nil
    listener?.cancel()
    listener = nil
    state = .off
    pairingQR = nil
    pairingToken = nil
  }

  func restart() {
    stop()
    start()
  }

  private func startListener() {
    guard listener == nil else { return }
    do {
      let params = NWParameters.tcp
      let portValue = UInt16(exactly: Defaults[.syncPort]) ?? SyncProtocol.defaultPort
      let port = NWEndpoint.Port(rawValue: portValue) ?? NWEndpoint.Port(rawValue: SyncProtocol.defaultPort)!
      let listener = try NWListener(using: params, on: port)
      listener.service = NWListener.Service(name: Defaults[.syncDeviceName], type: SyncProtocol.bonjourType)
      listener.newConnectionHandler = { [weak self] conn in
        Task { @MainActor in self?.accept(conn) }
      }
      listener.stateUpdateHandler = { [weak self] st in
        Task { @MainActor in self?.handleListenerState(st) }
      }
      listener.start(queue: .global(qos: .userInitiated))
      self.listener = listener
      if state == .off { state = .listening }
    } catch {
      state = .off
    }
  }

  private func handleListenerState(_ state: NWListener.State) {
    if case .failed = state {
      self.listener = nil
      if self.state != .connected { self.state = .off }
    }
  }

  // MARK: - Accept + wire a peer

  private func accept(_ connection: NWConnection) {
    let trust: PeerConnection.Trust
    if pairingToken != nil {
      trust = PeerConnection.Trust(expectedPeerIdPub: nil, pairingToken: pairingToken)
    } else if let paired = pairedDevice, let idPub = Data(base64Encoded: paired.idPub) {
      trust = PeerConnection.Trust(expectedPeerIdPub: idPub, pairingToken: nil)
    } else {
      connection.cancel()  // nothing paired and not pairing
      return
    }

    peer?.cancel()
    let peer = PeerConnection(role: .server, connection: connection, identity: identity, trust: trust)
    self.peer = peer

    peer.onEstablished = { [weak self] in
      Task { @MainActor in self?.onEstablished() }
    }
    peer.onControl = { [weak self] msg in
      Task { @MainActor in self?.handleControl(msg) }
    }
    peer.onContent = { [weak self] chunk in
      Task { @MainActor in self?.handleContent(chunk) }
    }
    peer.onNewPairing = { [weak self] idPub in
      Task { @MainActor in self?.pendingPairingIdPub = idPub }
    }
    peer.onClosed = { [weak self] _ in
      Task { @MainActor in self?.onPeerClosed(peer) }
    }
    peer.start()
  }

  private func onEstablished() {
    send(.hello(deviceId: Defaults[.syncDeviceId], name: Defaults[.syncDeviceName],
                platform: "macos", protocolVersion: SyncProtocol.version,
                hosts: Self.localIPv4Addresses()))
    sendHistorySync()
    startPingTimer()
  }

  private func onPeerClosed(_ closed: PeerConnection) {
    guard peer === closed else { return }
    peer = nil
    pingTimer?.invalidate()
    connectedPeerName = ""
    // Resume any pending fetches with failure.
    for (_, cont) in fetchConts { cont.resume(throwing: SyncCryptoError.openFailed) }
    fetchConts.removeAll()
    fetchBuffers.removeAll()
    for (_, cont) in fetchFileConts { cont.resume(throwing: SyncCryptoError.openFailed) }
    fetchFileConts.removeAll()
    for (_, handle) in fetchFileHandles { try? handle.close() }
    fetchFileHandles.removeAll()
    fetchFileURLs.removeAll()
    // Any in-flight incoming file died with the connection — make it visible.
    for (id, inc) in incoming {
      Notifier.progress(id: "sync-rx-\(id)", title: "Transfer interrupted", body: "\(inc.name) — connection dropped")
    }
    incoming.removeAll()
    state = listener != nil ? .listening : .off
  }

  private func send(_ message: SyncMessage) {
    peer?.send(message)
  }

  // MARK: - Inbound control

  private func handleControl(_ message: SyncMessage) {
    switch message {
    case let .hello(deviceId, name, _, _, _):
      connectedPeerName = name
      state = .connected
      if let idPub = pendingPairingIdPub {
        Defaults[.syncPairedDevice] = PairedDevice(
          deviceId: deviceId, name: name, idPub: idPub.base64EncodedString(), pairedAt: Date())
        pendingPairingIdPub = nil
        pairingToken = nil
        pairingQR = nil
      }

    case let .historySync(items):
      items.forEach { ingestPhoneClip($0) }

    case .requestHistory:
      sendHistorySync()

    case let .clipAdded(item):
      ingestPhoneClip(item)

    case let .contentRequest(id):
      serveContent(id: id)

    case let .contentBegin(id, kind, size, _, filename):
      if kind == ItemMeta.Kind.file.rawValue {
        // Stream a file straight to disk (never buffer 256 MiB in RAM).
        let dest = SyncContent.phoneFileURL(id: id, filename: filename)
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: dest) {
          fetchFileHandles[id] = handle
          fetchFileURLs[id] = dest
          // Show a "Receiving …" notification with live % so a large transfer is
          // visible (and a stall/failure is obvious instead of silent).
          let name = filename ?? "file"
          incoming[id] = Incoming(name: name, total: size, received: 0, lastPct: -1)
          let from = connectedPeerName.isEmpty ? "Phone" : connectedPeerName
          Notifier.progress(id: "sync-rx-\(id)", title: "Receiving from \(from)",
                            body: size > 0 ? "\(name) — 0% of \(Self.byteString(size))" : name)
        } else {
          fetchFileConts.removeValue(forKey: id)?.resume(throwing: SyncCryptoError.openFailed)
        }
      } else {
        fetchBuffers[id] = Data()
      }

    case let .contentError(id, _):
      if let cont = fetchConts.removeValue(forKey: id) {
        cont.resume(throwing: SyncCryptoError.openFailed)
      }
      fetchBuffers[id] = nil
      if let handle = fetchFileHandles.removeValue(forKey: id) { try? handle.close() }
      fetchFileURLs[id] = nil
      fetchFileConts.removeValue(forKey: id)?.resume(throwing: SyncCryptoError.openFailed)
      if let inc = incoming.removeValue(forKey: id) {
        Notifier.progress(id: "sync-rx-\(id)", title: "Transfer failed", body: inc.name)
      }

    case .ping:
      send(.pong)

    case .pong, .hs1, .hs2, .hs3:
      break
    }
  }

  private func handleContent(_ chunk: ContentChunk) {
    let id = chunk.id.uuidString.lowercased()
    // File stream → write straight to the open handle.
    if let handle = fetchFileHandles[id] {
      try? handle.write(contentsOf: chunk.bytes)
      // Update the receiving notification (throttled to ~every 5%).
      if var inc = incoming[id] {
        inc.received += chunk.bytes.count
        let pct = inc.total > 0 ? Int(Double(inc.received) / Double(inc.total) * 100) : 0
        if chunk.last || pct >= inc.lastPct + 5 {
          inc.lastPct = pct
          let from = connectedPeerName.isEmpty ? "Phone" : connectedPeerName
          Notifier.progress(id: "sync-rx-\(id)", title: "Receiving from \(from)",
                            body: "\(inc.name) — \(pct)% of \(Self.byteString(inc.total))")
        }
        incoming[id] = inc
      }
      guard chunk.last else { return }
      try? handle.close()
      fetchFileHandles[id] = nil
      let url = fetchFileURLs.removeValue(forKey: id)
      if let inc = incoming.removeValue(forKey: id) {
        Notifier.progress(id: "sync-rx-\(id)", title: "Received \(inc.name)",
                          body: "From \(connectedPeerName.isEmpty ? "Phone" : connectedPeerName) · \(Self.byteString(inc.total))")
      }
      if let cont = fetchFileConts.removeValue(forKey: id) {
        if let url { cont.resume(returning: url) } else { cont.resume(throwing: SyncCryptoError.openFailed) }
      }
      return
    }
    var buffer = fetchBuffers[id] ?? Data()
    buffer.append(chunk.bytes)
    fetchBuffers[id] = buffer
    guard chunk.last else { return }
    fetchBuffers[id] = nil
    if let cont = fetchConts.removeValue(forKey: id) {
      cont.resume(returning: buffer)
    }
  }

  // Merge a phone clip into the local clipboard history as a real HistoryItem
  // (tagged `.fromPhone`) AND put it on the Mac clipboard so it's immediately
  // pasteable. phone→Mac is explicit-only, so every arriving clip is a deliberate
  // "send to Mac" — making it the current clipboard is the expected result.
  // Text is inline; image/file content is fetched on arrival.
  private func ingestPhoneClip(_ meta: ItemMeta) {
    Task { @MainActor in
      switch meta.kindEnum {
      case .file:
        // Auto-download the explicitly-uploaded file to disk and add it to history
        // (badged .fromPhone). NO clipboard takeover — the user pastes/saves it from
        // the list when they want it.
        guard let url = try? await fetchContentToFile(id: meta.id),
              let item = SyncContent.fileHistoryItem(at: url, meta: meta, peerName: connectedPeerName)
        else { return }
        History.shared.add(item)

      case .image:
        guard let content = try? await fetchContent(id: meta.id) else { return }
        addPhoneClip(meta, content: content)

      case .text:
        var content: Data?
        if meta.text == nil {
          content = try? await fetchContent(id: meta.id)
          if content == nil { return }
        }
        addPhoneClip(meta, content: content)
      }
    }
  }

  // Text/image: merge into history AND set the Mac clipboard (explicit phone send →
  // making it current is expected). apply stamps .fromMaccy so there's no echo.
  private func addPhoneClip(_ meta: ItemMeta, content: Data?) {
    if let item = SyncContent.historyItem(for: meta, content: content, peerName: connectedPeerName) {
      History.shared.add(item)
    }
    SyncContent.apply(meta: meta, content: content)
  }

  // MARK: - Serving content to the peer

  private func serveContent(id: String) {
    guard let item = announced[id] else {
      NSLog("MaccySync serveContent NOT ANNOUNCED id=\(id)")
      send(.contentError(id: id, reason: "not_found")); return
    }
    guard let uuid = UUID(uuidString: id) else { send(.contentError(id: id, reason: "bad_id")); return }
    NSLog("MaccySync serveContent id=\(id) fileURLs=\(item.fileURLs.count) kind=\(item.fileURLs.first != nil ? "file" : "other")")
    // Files stream from disk (no whole-file load); text/image stay in RAM.
    if let url = item.fileURLs.first {
      serveFile(id: id, uuid: uuid, url: url)
      return
    }
    guard let full = SyncContent.fullContent(for: item) else {
      send(.contentError(id: id, reason: "not_found")); return
    }
    guard full.data.count <= SyncProtocol.maxContent else {
      send(.contentError(id: id, reason: "too_large")); return
    }
    send(.contentBegin(id: id, kind: full.kind.rawValue, size: full.data.count,
                       mime: full.mime, filename: full.filename))
    sendDataChunks(uuid: uuid, data: full.data)
  }

  // Stream a file from disk → chunks. Reads on the main actor but yields between
  // chunks so the UI stays responsive even for a large (256 MiB) transfer.
  private func serveFile(id: String, uuid: UUID, url: URL) {
    // Sandboxed app: a copied file's URL may need its security scope re-asserted
    // before we can read its bytes. Harmless (returns false) if there's no scope.
    let scoped = url.startAccessingSecurityScopedResource()
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attrs?[.size] as? Int) ?? 0
    let readable = FileManager.default.isReadableFile(atPath: url.path)
    NSLog("MaccySync serveFile path=\(url.path) size=\(size) scoped=\(scoped) readable=\(readable)")
    guard size <= SyncProtocol.maxContent else {
      if scoped { url.stopAccessingSecurityScopedResource() }
      send(.contentError(id: id, reason: "too_large")); return
    }
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      NSLog("MaccySync serveFile OPEN FAILED (sandbox?) path=\(url.path)")
      if scoped { url.stopAccessingSecurityScopedResource() }
      send(.contentError(id: id, reason: "not_found")); return
    }
    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    let name = url.lastPathComponent
    let dest = connectedPeerName.isEmpty ? "Phone" : connectedPeerName
    send(.contentBegin(id: id, kind: ItemMeta.Kind.file.rawValue, size: size,
                       mime: mime, filename: name))
    Notifier.progress(id: "sync-tx-\(id)", title: "Sending to \(dest)",
                      body: "\(name) — 0% of \(Self.byteString(size))")
    if size == 0 {
      peer?.send(ContentChunk(id: uuid, seq: 0, last: true, bytes: Data()))
      try? handle.close()
      if scoped { url.stopAccessingSecurityScopedResource() }
      Notifier.progress(id: "sync-tx-\(id)", title: "Sent \(name)", body: "To \(dest)")
      return
    }
    Task { @MainActor in
      defer { try? handle.close(); if scoped { url.stopAccessingSecurityScopedResource() } }
      var seq: UInt32 = 0
      var offset = 0
      var lastPct = -1
      while offset < size {
        guard let chunk = try? handle.read(upToCount: SyncProtocol.chunkSize), !chunk.isEmpty else { break }
        offset += chunk.count
        peer?.send(ContentChunk(id: uuid, seq: seq, last: offset >= size, bytes: chunk))
        let pct = Int(Double(offset) / Double(size) * 100)
        if offset >= size || pct >= lastPct + 5 {
          lastPct = pct
          Notifier.progress(id: "sync-tx-\(id)", title: "Sending to \(dest)",
                            body: "\(name) — \(pct)% of \(Self.byteString(size))")
        }
        seq += 1
        await Task.yield()
      }
      Notifier.progress(id: "sync-tx-\(id)", title: "Sent \(name)", body: "To \(dest)")
    }
  }

  private func sendDataChunks(uuid: UUID, data: Data) {
    if data.isEmpty {
      peer?.send(ContentChunk(id: uuid, seq: 0, last: true, bytes: Data()))
      return
    }
    var seq: UInt32 = 0
    var offset = 0
    while offset < data.count {
      let end = Swift.min(offset + SyncProtocol.chunkSize, data.count)
      let slice = data.subdata(in: offset..<end)
      peer?.send(ContentChunk(id: uuid, seq: seq, last: end >= data.count, bytes: slice))
      seq += 1
      offset = end
    }
  }

  // MARK: - Fetching content from the peer

  func fetchContent(id: String) async throws -> Data {
    return try await withCheckedThrowingContinuation { cont in
      fetchConts[id] = cont
      fetchBuffers[id] = Data()
      send(.contentRequest(id: id))
    }
  }

  // Like fetchContent but streams a file to disk (the contentBegin handler opens
  // the write handle once it learns kind == file). Returns the on-disk URL.
  func fetchContentToFile(id: String) async throws -> URL {
    return try await withCheckedThrowingContinuation { cont in
      fetchFileConts[id] = cont
      send(.contentRequest(id: id))
    }
  }

  /// Pull a remote item to the local pasteboard. Returns true on success.
  func applyRemote(_ meta: ItemMeta) async -> Bool {
    var content: Data?
    if meta.kindEnum == .text, meta.text != nil {
      content = nil
    } else {
      content = try? await fetchContent(id: meta.id)
      if content == nil { return false }
    }
    return SyncContent.apply(meta: meta, content: content)
  }

  // MARK: - Outbound (local copy -> peer)

  // Ask the phone to (re)send its full clipboard history — used when the Remote
  // Clipboard panel opens, so it always shows the phone's current list.
  func requestHistory() {
    guard peer != nil else { return }
    send(.requestHistory)
  }

  private func sendHistorySync() {
    let recent = recentLocalItems()
    var metas: [ItemMeta] = []
    for item in recent {
      let id = UUID().uuidString
      guard let meta = SyncContent.meta(
        for: item, id: id,
        sendText: Defaults[.syncSendText],
        sendImages: Defaults[.syncSendImages],
        sendFiles: Defaults[.syncSendFiles]) else { continue }
      announced[id] = item
      metas.append(meta)
    }
    send(.historySync(items: metas))
  }

  func pushClip(_ item: HistoryItem) {
    // Never push back a clip that came FROM the phone (no echo loop), and never
    // our own Maccy-originated copies.
    guard peer != nil, !item.fromMaccy, !item.fromPhone else { return }
    let id = UUID().uuidString
    guard let meta = SyncContent.meta(
      for: item, id: id,
      sendText: Defaults[.syncSendText],
      sendImages: Defaults[.syncSendImages],
      sendFiles: Defaults[.syncSendFiles]) else { return }
    announced[id] = item
    send(.clipAdded(item: meta))
  }

  // Explicit "Send to Phone" — sends any kind including files, ignoring the
  // auto-send filters. This is the only path that pushes a file to the phone.
  func sendItem(_ item: HistoryItem) {
    guard peer != nil else { return }
    let id = UUID().uuidString
    guard let meta = SyncContent.meta(
      for: item, id: id, sendText: true, sendImages: true, sendFiles: true) else { return }
    announced[id] = item
    send(.clipAdded(item: meta))
  }

  private func recentLocalItems() -> [HistoryItem] {
    Array(AppState.shared.history.all.prefix(SyncProtocol.historySyncCount).map { $0.item })
  }

  // MARK: - SyncService (used by SendToAndroidAction)

  func send(_ value: String) async throws {
    guard peer != nil else { return }
    let id = UUID().uuidString
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let meta = ItemMeta(id: id, kind: "text", createdAt: now, size: value.utf8.count,
                        mime: "text/plain", preview: String(value.prefix(280)),
                        text: value, filename: nil, thumb: nil)
    send(.clipAdded(item: meta))
  }

  // MARK: - Pairing

  func enterPairingMode() {
    if Defaults[.syncEnabled] == false { Defaults[.syncEnabled] = true }
    startListener()
    let token = Self.randomToken()
    pairingToken = token
    pendingPairingIdPub = nil
    state = .pairing
    pairingQR = buildQRPayload(token: token)
  }

  func cancelPairing() {
    pairingToken = nil
    pairingQR = nil
    pendingPairingIdPub = nil
    state = (peer != nil) ? .connected : (listener != nil ? .listening : .off)
  }

  func unpair() {
    Defaults[.syncPairedDevice] = nil
    peer?.cancel()
    peer = nil
    // Phone clips already merged into the local history stay (they're regular,
    // badged clips now).
    state = listener != nil ? .listening : .off
  }

  private func buildQRPayload(token: String) -> String {
    let hosts = Self.localIPv4Addresses()
    let payload: [String: Any] = [
      "v": 1,
      "host": hosts.first ?? "",
      "hosts": hosts,
      "port": Defaults[.syncPort],
      "idpub": identity.pin,
      "token": token,
      "name": Defaults[.syncDeviceName],
      "deviceId": Defaults[.syncDeviceId]
    ]
    let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    return String(data: data, encoding: .utf8) ?? ""
  }

  // MARK: - Keepalive

  private func startPingTimer() {
    pingTimer?.invalidate()
    pingTimer = Timer.scheduledTimer(withTimeInterval: SyncProtocol.pingInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.send(.ping) }
    }
  }

  // MARK: - Helpers

  static func randomToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes).base64EncodedString()
  }

  // Candidate addresses the phone can dial, LAN first and Tailscale last. Tailscale
  // runs on a utun interface with a 100.64.0.0/10 (CGNAT) address — including it is
  // what lets sync work over WAN when both devices are on the same tailnet.
  static func localIPv4Addresses() -> [String] {
    var lan: [String] = []
    var tailscale: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return lan }
    defer { freeifaddrs(ifaddr) }
    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let current = pointer {
      defer { pointer = current.pointee.ifa_next }
      let flags = Int32(current.pointee.ifa_flags)
      let addr = current.pointee.ifa_addr.pointee
      guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
            (flags & IFF_LOOPBACK) == 0,
            addr.sa_family == UInt8(AF_INET) else { continue }
      let name = String(cString: current.pointee.ifa_name)
      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(current.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname,
                        socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
      let ip = String(cString: hostname)
      guard !ip.isEmpty, !ip.hasPrefix("169.254") else { continue }
      if isTailscaleIP(ip) {
        if !tailscale.contains(ip) { tailscale.append(ip) }
      } else if name.hasPrefix("en") {
        if !lan.contains(ip) { lan.append(ip) }
      }
    }
    return lan + tailscale
  }

  /// True for a Tailscale CGNAT address (100.64.0.0/10 → 100.64.x – 100.127.x).
  static func isTailscaleIP(_ ip: String) -> Bool {
    let parts = ip.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4 else { return false }
    return parts[0] == 100 && (64...127).contains(parts[1])
  }
}
