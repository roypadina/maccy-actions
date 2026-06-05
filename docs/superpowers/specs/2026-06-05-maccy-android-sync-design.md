# Maccy Android Sync — Design

Date: 2026-06-05
Status: Approved
Feature: Feature 1 — cross-device shared clipboard (Mac ⇄ Android)

## Goal

Let a Mac (Maccy Actions) and an Android phone browse and paste from each
other's clipboard history. A global shortcut on the Mac opens the phone's
clipboard history; the Android app shows the Mac's history. Each device keeps
its own active clipboard untouched — you browse the *remote* list and pull an
item on demand.

## Decisions (locked)

| Question | Decision |
|----------|----------|
| Transport | **LAN now, cloud later.** mDNS discovery + a direct end-to-end-encrypted socket on the local network, behind a `Transport` protocol so a cloud relay can be added later without touching sync/clipboard logic. |
| Android capture | **AccessibilityService (auto).** A background accessibility service monitors clipboard changes and auto-captures every copy — the technique real Android clipboard-history apps use to beat the Android 10+ background-read restriction. Sideload-only (Play would reject); fine for a personal fork. |
| Sync model | **Separate lists, browse on demand.** Each device keeps its own active clipboard. New clips stream to the peer in the background into a dedicated "remote device" history list. A shortcut opens the other device's history; pick an item → it is pasted/copied locally. No clobbering. |
| Pairing / security | **QR scan + E2E.** Mac shows a QR (host/port + cert fingerprint + one-time token). Phone scans with the camera, connects, returns its own fingerprint authenticated by the token. **TLS 1.3 with mutual cert-pinning** secures all traffic (no third-party crypto lib, no hand-rolled crypto). Pins persisted → auto-reconnect via mDNS. |
| Content types | **Text + images + files** (v1), with a size cap and chunked, lazy transfer (metadata pushed eagerly, bytes fetched on selection). |
| Android stack | **Native Kotlin + Jetpack Compose** — required for AccessibilityService, ClipboardManager, NsdManager (mDNS), camera/QR, file access. |
| Repo layout | **Monorepo.** `mobile/android/` now (room for `mobile/ios/` later), shared `docs/protocol/` spec as source of truth. |

## Repo layout

```
(root)               existing Mac app — Maccy/, Maccy.xcodeproj
mobile/
  android/           Kotlin + Compose app
  (ios/ later)
docs/
  protocol/          shared, language-agnostic wire-protocol spec (source of truth)
  superpowers/specs/ design docs
```

## Experience

- **Mac:** global shortcut (default `⌃⇧V`) opens a "Remote Clipboard" panel — the
  *phone's* history. Pick an item → fetched if needed → pasted locally. The Mac's
  own clipboard stays untouched.
- **Android:** the app (+ optional Quick Settings tile) shows two lists, "This
  phone" and "Mac". Tap a Mac item → it lands in the Android clipboard; paste
  normally. Android has no OS-level global "paste-from" hotkey — the app/tile is
  the closest. (An IME route for inline paste is deferred.)
- **Background:** each device auto-captures its own copies and streams *metadata*
  of new clips to the peer's remote list. Heavy bytes (images/files) are fetched
  lazily only when an item is selected.

## Shared protocol (`docs/protocol/`)

Transport-agnostic so a cloud relay can be added later. One persistent,
full-duplex connection. Length-prefixed messages:

- `Hello` — deviceId, name, platform, protocolVersion
- `HistorySync` — last N item metas on connect
- `ClipAdded` — one item meta: id, kind (text / image / file), createdAt, size,
  text-preview or thumbnail
- `ContentRequest{id}` → `ContentChunk{id, seq, bytes, last}` — lazy, chunked
  fetch of the full payload on selection
- `Ping` / `Pong` — keepalive

Small text ships inline in `ClipAdded`. Images send a thumbnail inline + full
bytes on request. Files send name/size/type + bytes on request.

## Security / pairing

- Each device holds a long-lived self-signed identity cert (Mac: Keychain;
  Android: Keystore).
- **TLS 1.3 with mutual cert-pinning.** Each side validates the peer against a
  pinned SHA-256 SPKI fingerprint (pin-only trust; CA chain ignored). Vetted on
  both platforms (Network.framework / Android TLS); no third-party crypto lib.
- **QR pairing:** Mac shows a QR = its host/port + cert fingerprint + one-time
  token. Phone scans (CameraX + ML Kit, fallback ZXing), connects, returns its
  own fingerprint authenticated by the token. Both persist the peer pin →
  auto-reconnect via mDNS.

## Mac components (`Maccy/Sync/`)

- `SyncTransport` protocol (LAN now / cloud later) + `LanTransport`
  (Network.framework `NWListener` server, Bonjour `_maccysync._tcp` advertise)
- `PeerSession` (TLS, handshake, read/write loop) · `SyncProtocol` (Codable +
  framing)
- `RemoteClipStore` (`@Observable`, persisted) — the phone's history
- `PairingManager` (identity cert in Keychain, QR gen via CoreImage, pin storage)
- New `showRemoteClipboard` global shortcut → `FloatingPanel` listing remote
  items, reusing the existing paste path
- New Settings pane `.sync` — pairing QR, paired devices, content-type toggles,
  enable/port
- Wire `Clipboard.shared.onNewCopy` → push `ClipAdded`; the existing
  `SendToAndroidAction` delegates here via the `SyncService` seam (zero engine
  change)

## Android components (`mobile/android/`)

- `ClipboardAccessibilityService` — auto-capture every copy → Room history →
  push to Mac
- `SyncForegroundService` — persistent notification, holds the TLS connection +
  NsdManager discovery + reconnect
- `SyncClient` (TLS pinned socket, protocol codec) · `PairingActivity` (camera
  QR scan)
- Room DB (local + Mac histories) · Compose UI (two-list home, pairing, settings,
  accessibility deep-link) · Quick Settings tile
- SAF for receiving files; identity cert via Keystore

## Build phases

1. **Protocol + crypto spec** — `docs/protocol/`: messages, framing, TLS-pin
   handshake, QR format (text first, then image/file)
2. **Mac: transport + pairing + remote store + shortcut/UI** — testable against a
   mock client
3. **Android: accessibility capture + foreground service + discovery + TLS client
   + pairing + Compose UI**
4. **Images + files** — chunked lazy transfer on both sides
5. **Hardening** — reconnect, size caps, multi-device, error states

## Known risks / caveats

- **Android clipboard-via-accessibility is undocumented.** It works for real
  clipboard apps, but some OEMs / Android versions restrict harder. Fallback:
  Quick-tile / share-sheet manual capture if a device blocks it.
- mDNS can be blocked by router AP-isolation / VLANs → the reason for "cloud
  later."
- A persistent foreground service costs battery (acceptable for personal use).
- Mutual TLS pinning across Network.framework + the Android stack is fiddly
  (custom trust evaluation) but standard.

## Out of scope (v1)

- Cloud relay (interface only)
- iOS app (`mobile/ios/` reserved)
- IME / inline paste on Android
- More than one paired phone (single-peer v1; multi-device is a hardening item)
