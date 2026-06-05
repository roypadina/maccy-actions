# Maccy Sync — Android

Companion app for the Mac **Maccy Actions** clipboard manager. Browse and paste
from your Mac's clipboard on the phone, and auto-sync the phone's copies back to
the Mac over the LAN. See `../../docs/protocol/PROTOCOL.md` for the wire protocol
and `../../docs/superpowers/specs/2026-06-05-maccy-android-sync-design.md` for
the design.

## Modules

- **`:core`** — pure-JVM, no Android deps. The wire protocol (`Protocol`,
  `Control`/`ItemMeta`, `FrameCodec`), crypto (`Identity` Ed25519, `Handshake`
  X25519/HKDF, `SessionCipher` ChaCha20-Poly1305), and `PeerSocket` (the signed
  -ECDH handshake + AEAD framing). This is the byte-for-byte counterpart of the
  Mac's `Maccy/Sync/`. Unit-tested in isolation.
- **`:app`** — Android app: Room storage, `SyncController` (client lifecycle),
  `ClipboardAccessibilityService` (auto-capture), `SyncForegroundService`,
  `PairingActivity` (CameraX + ML Kit QR scan), Quick Settings tile, Compose UI.

## Build & test

Requires JDK 17 and the Android SDK (cmdline-tools). With `local.properties`
pointing at the SDK:

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
./gradlew :core:test          # protocol + crypto + loopback handshake tests
./gradlew :app:assembleDebug  # build the debug APK
./gradlew installDebug        # install to a connected device/emulator
```

## Pairing

1. On the Mac: **Maccy ▸ Settings ▸ Sync ▸ Pair New Device** shows a QR.
2. On the phone: **Settings ▸ Pair with Mac**, scan the QR.
3. Grant **Accessibility** access (Settings card) so copies auto-capture.

Both devices must be on the same Wi-Fi (LAN). The QR carries the Mac's address,
Ed25519 identity, and a one-time pairing token; the connection is end-to-end
encrypted and the identities are pinned for auto-reconnect.

## Notes / limitations (v1)

- Outbound capture from the phone is **text only** (Android image/file clipboard
  access is restricted); the phone still **receives** text, images, and files
  from the Mac (images/files are saved via MediaStore).
- Auto-capture relies on an AccessibilityService — sideload only (Google Play
  rejects clipboard-reading accessibility services). The Quick Settings tile is a
  manual capture fallback.
- mDNS auto-discovery refreshes the Mac address; the QR-provided address is the
  primary path.
