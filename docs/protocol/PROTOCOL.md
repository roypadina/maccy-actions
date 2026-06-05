# Maccy Sync Protocol v1

Source of truth for the wire protocol shared by the Mac app (`Maccy/Sync/`) and
the Android app (`mobile/android/`). Both sides MUST implement this identically.

## Roles & connection

- **Mac = server.** Listens on a TCP port, advertises it via Bonjour/mDNS
  service type `_maccysync._tcp` (TXT records: `id`, `name`, `pv`=protocolVersion).
- **Android = client.** Discovers the service via `NsdManager`, connects.
- One **persistent, full-duplex** TLS connection carries everything in both
  directions.
- Default port: `53121` (server may pick another; clients use the discovered/QR
  port).

## Security: signed ephemeral-ECDH handshake (STS) + AEAD

No TLS. The plain TCP stream opens with a 3-flight authenticated handshake using
only standard primitives available natively on both platforms (Mac: CryptoKit;
Android: BouncyCastle). This is a textbook signed-Diffie-Hellman (Station-to-
Station) construction — it is **not** a hand-rolled cipher.

Primitives: **X25519** (ephemeral key agreement), **Ed25519** (identity
signatures), **HKDF-SHA256** (key derivation), **ChaCha20-Poly1305** (AEAD).

- Each device owns a long-lived **Ed25519 identity keypair**. Mac stores the
  private key in the Keychain; Android in encrypted prefs / Keystore-wrapped.
- A device's **identity / pin** is its Ed25519 **public key** (32 raw bytes,
  base64). This is what the QR carries and what each side pins.

### Handshake flights (plaintext, length-prefixed JSON; see Framing)

```
1.  C → S   { "t": "hs1", "eph": "<b64 client X25519 ephemeral pub>" }
2.  S → C   { "t": "hs2", "eph": "<b64 server X25519 ephemeral pub>",
             "id": "<b64 server Ed25519 id pub>",
             "sig": "<b64 Ed25519 sig over (clientEph || serverEph)>" }
3.  C → S   { "t": "hs3", "id": "<b64 client Ed25519 id pub>",
             "sig": "<b64 Ed25519 sig over (clientEph || serverEph)>",
             "token": "<b64 32 bytes or null>" }
```

- The signed message in flights 2 & 3 is the 64-byte concatenation
  `clientEphPub(32) || serverEphPub(32)` — binding both ephemerals defeats MITM.
- Shared secret: `ss = X25519(localEph, remoteEph)`.
- Keys: `salt = clientEphPub || serverEphPub`,
  `k_c2s = HKDF-SHA256(ikm=ss, salt=salt, info="MaccySync-v1-c2s", L=32)`,
  `k_s2c = HKDF-SHA256(ikm=ss, salt=salt, info="MaccySync-v1-s2c", L=32)`.
- After flight 3 verifies, **all subsequent frames are AEAD-encrypted** (see
  Framing). Each side immediately sends an (encrypted) `hello`.

### Trust rules

- **Client (phone) → server (Mac):** the phone always knows the Mac's expected
  Ed25519 id pub (from the QR during pairing, or stored afterward). It MUST
  verify the `hs2` signature with that key **and** that `hs2.id` equals the
  expected key. Mismatch → abort (possible MITM).
- **Server (Mac) → client (phone):**
  - *Normal mode:* the Mac knows the phone's id pub (stored pin). It MUST verify
    the `hs3` signature against `hs3.id` **and** that `hs3.id` is a known paired
    pin.
  - *Pairing mode:* the Mac does not yet know the phone. It requires
    `hs3.token` to equal the active one-time pairing token, and the `hs3`
    signature to verify against the presented `hs3.id`. On success it stores the
    phone's `{deviceId, name, idPub}`, accepts, and invalidates the token.
- A valid `hs3` signature over both ephemerals always proves the sender owns the
  presented identity key.

### Pairing (QR + one-time token)

1. Mac generates (once) its Ed25519 identity. To pair, it generates a random
   **one-time token** (32 bytes), enters *pairing mode*, and displays a QR.
2. **QR payload** — UTF-8 JSON:
   ```json
   {
     "v": 1,
     "host": "192.168.1.20",
     "hosts": ["192.168.1.20", "10.0.0.5"],
     "port": 53121,
     "idpub": "<b64 Mac Ed25519 id public key, 32 bytes>",
     "token": "<b64 32 random bytes>",
     "name": "Roy's Mac",
     "deviceId": "<mac uuid>"
   }
   ```
   `host` is the primary address; `hosts` lists all candidate LAN IPs (try in
   order). `port` is the listening port.
3. Phone scans, stores the Mac's `idpub` (pin), connects, runs the handshake in
   pairing mode (puts the `token` in `hs3`), and verifies the Mac via `hs2`.
4. Mac validates the token, stores the phone's id pub, exits pairing mode.
5. Both sides now hold the other's id pub persistently → future connections run
   the handshake in normal mode and proceed straight to `hello` + `historySync`.

(The earlier `pairRequest`/`pairAccepted` control messages are folded into the
handshake's `hs3.token`; no separate pairing control message is needed.)

## Framing

Every wire unit is **length-prefixed**: `[ 4 bytes big-endian uint32 length N ]`
followed by `N` bytes.

**During the handshake** (flights `hs1`/`hs2`/`hs3`), the `N` bytes are a
plaintext **frame** (see below) — always a `kind = 0x01` control message.

**After the handshake**, the `N` bytes are an **AEAD ciphertext**: the sender
encrypts a plaintext **frame** with its send key (`k_c2s` for the client,
`k_s2c` for the server) using ChaCha20-Poly1305. The 12-byte nonce is a
per-direction message counter (big-endian uint64 in the low 8 bytes, high 4
bytes zero), starting at 0 and incremented once per encrypted frame. The nonce
is **not** transmitted (both sides track it). No additional authenticated data.
The transmitted bytes are `ciphertext || 16-byte Poly1305 tag`. The receiver
decrypts with its receive key + receive counter to recover the plaintext frame.

A **frame** (the plaintext unit, encrypted or not):

```
[ 1 byte   | kind ]
[ rest     | payload ]
```

- `kind = 0x01` — **Control**: payload is UTF-8 JSON (a message object, below).
- `kind = 0x02` — **Content chunk** (binary): payload is
  ```
  [ 16 bytes | itemId as raw UUID bytes ]
  [ 4 bytes  | seq, big-endian uint32, starting at 0 ]
  [ 1 byte   | flags: bit0 = last chunk ]
  [ rest     | raw content bytes for this chunk ]
  ```

Max frame length: **17 MB** (`0x01100000`); receivers MUST reject larger.
Chunk size for content: **64 KiB** of payload bytes per chunk.

## Control messages (`kind = 0x01`, JSON)

Every control message has a string field `t` (type). Unknown `t` → ignore.

### Handshake

```json
{ "t": "hello", "deviceId": "<uuid>", "name": "Roy's Mac",
  "platform": "macos" | "android", "protocolVersion": 1 }
```
Sent by **both** sides immediately after the TLS connection is up (normal mode).
A side MUST NOT send history/clips before it has sent and received `hello`.

(Pairing authentication happens in the handshake via `hs3.token`; there are no
separate pairing control messages.)

### History & clips

```json
{ "t": "historySync", "items": [ <ItemMeta>, ... ] }
{ "t": "clipAdded", "item": <ItemMeta> }
```
On connect (after `hello` both ways), each side sends one `historySync` with its
most recent items (default **50**, newest first). Each new local copy → one
`clipAdded`.

**ItemMeta**:
```json
{
  "id": "<uuid>",
  "kind": "text" | "image" | "file",
  "createdAt": 1733356800000,        // unix millis
  "size": 12345,                     // total content bytes
  "mime": "text/plain",              // best-effort
  "preview": "first line / caption", // short human label, always present
  "text": "full text or null",       // text kind only, present iff size <= INLINE_TEXT_CAP
  "filename": "photo.png or null",   // file/image kind
  "thumb": "<base64 PNG or null>"    // image kind, <= THUMB_CAP bytes
}
```

### Lazy content fetch

When a receiver needs full bytes it does not already have (large text, full-res
image, file), it requests them:

```json
{ "t": "contentRequest", "id": "<uuid>" }
```
The owner replies with a `contentBegin`, then one or more **content-chunk**
frames (`kind 0x02`) with the same `id`, `seq` 0..n, last chunk flagged:
```json
{ "t": "contentBegin", "id": "<uuid>", "kind": "image"|"file"|"text",
  "size": 12345, "mime": "image/png", "filename": "photo.png or null" }
```
On error (unknown id, too large, read failure):
```json
{ "t": "contentError", "id": "<uuid>", "reason": "<string>" }
```
The receiver reassembles chunks in `seq` order until the `last` flag.

### Keepalive

```json
{ "t": "ping" }
{ "t": "pong" }
```
Each side sends `ping` every **20 s** of idle; expects `pong`. No traffic for
**60 s** → consider the connection dead and reconnect.

## Constants

| Name | Value |
|------|-------|
| `PROTOCOL_VERSION` | `1` |
| Bonjour type | `_maccysync._tcp` |
| Default port | `53121` |
| `INLINE_TEXT_CAP` | `16384` bytes (16 KiB) — text at/under ships inline in ItemMeta |
| `THUMB_CAP` | `65536` bytes (64 KiB) — image thumbnail max |
| `CHUNK_SIZE` | `65536` bytes (64 KiB) |
| `MAX_FRAME` | `17825792` bytes (17 MiB) |
| `MAX_CONTENT` | `16777216` bytes (16 MiB) — content over this → `contentError "too_large"` |
| `HISTORY_SYNC_COUNT` | `50` |
| `PING_INTERVAL` | `20 s` |
| `DEAD_TIMEOUT` | `60 s` |

## Notes

- All UUIDs are lowercase canonical (`8-4-4-4-12`). The 16-byte content-chunk
  itemId is the raw big-endian bytes of that UUID.
- `createdAt` is unix epoch **milliseconds**.
- Text `kind` items at/under `INLINE_TEXT_CAP` need no `contentRequest`.
- A device de-dupes remote items by `id`. Re-receiving a known `id` updates
  ordering, not content.
- v1 is single-peer per side (one Mac ↔ one phone). The protocol does not
  prevent more, but UIs assume one paired peer.
