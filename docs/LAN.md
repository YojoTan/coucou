# Mochis on the local network — protocol v1

Two Coucous on the same network can find each other, pair, and then show each
other's status, send messages, send files and ask each other's Mochi. Both
builds (Windows `windows/src-tauri/src/lan/`, macOS `NotchBuddy/Sources/App/Lan*.swift`)
speak exactly this; the test vectors at the end are checked on both sides.

## Principles

- **Off by default.** Nothing listens, nothing is broadcast until the user turns
  it on in Settings → Mochis.
- **Explicit pairing.** A peer is trusted only after both users compared the same
  6-digit code on their screens and confirmed it. Nothing is accepted from an
  unpaired Mochi except a pairing request, which only ever shows a prompt.
- **End-to-end encryption.** Every connection runs an authenticated key exchange;
  all traffic after it is AES-256-GCM. Ephemeral keys: a recorded session can't
  be decrypted later.
- **Nothing silent.** A message, a file or a question always reaches the user as
  a prompt; files are never accepted without a click; a peer may only ask your
  Mochi if you switched that on, and the answer never touches your files.

## Identity

Each install has a long-term **Ed25519** key pair (Windows Credential Manager /
macOS Keychain). `id` = the first 8 bytes of SHA-256(public key), in lowercase hex
(16 characters). The trusted-peer list (`id`, `name`, public key) is not secret.

## Discovery — UDP 47801

While on, every 4 s, a beacon goes to `255.255.255.255:47801`; and every beacon
heard is answered straight back to its sender (unicast), at most once per 4 s per
peer. The unicast answer is what keeps two Mochis in sight of each other when
one side's broadcast gets lost — Windows often sends `255.255.255.255` out of a
virtual adapter (WSL, Hyper-V, VPN) — since one working direction is then enough:

```json
{"coucou":1,"id":"<16 hex>","name":"<≤40 chars>","port":<tcp port>,"key":"<base64 Ed25519 public key>"}
```

A beacon is ignored when it is over 1 KB, when `id` ≠ id(`key`), or when it is
our own. A peer not heard for 15 s is gone. The sender's address is the UDP
source address, never a field of the beacon.

## Connection — TCP `port`

Frames: a 4-byte big-endian length, then the payload (at most 256 KiB).

### Handshake (plaintext JSON frames)

1. Client → server
   `{"hello":1,"id","name","key":<b64 Ed25519 pk C>,"eph":<b64 X25519 pk>,"mode":"pair"|"session"}`
2. Server → client
   `{"hello":1,"id","name","key":<b64 Ed25519 pk S>,"eph":<b64 X25519 pk>,"sig":<b64>}`
3. Client → server `{"sig":<b64>}`

- `th` = SHA-256( `"coucou-lan-v1"` ‖ keyC ‖ ephC ‖ keyS ‖ ephS ) — raw 32-byte keys.
- Server signs `"coucou-lan-v1 server"` ‖ th; client signs `"coucou-lan-v1 client"` ‖ th.
- `shared` = X25519(own ephemeral, peer ephemeral).
- HKDF-SHA-256, salt = th, ikm = shared:
  `c2s` = expand(`"c2s"`, 32), `s2c` = expand(`"s2c"`, 32), `sas` = expand(`"sas"`, 4).
- The pairing code is u32-big-endian(`sas`) mod 1 000 000, six digits with leading zeros.
- `session` mode: the server only continues if keyC is trusted, and the client
  only if keyS is the key it paired with for that id.

### Encrypted frames

AES-256-GCM, no associated data. Nonce = 4 zero bytes ‖ 8-byte big-endian
counter, one counter per direction starting at 0. Payload = ciphertext ‖ 16-byte
tag. Any failure closes the connection. Each plaintext is one JSON object.

### Pairing (`mode: "pair"`)

Both sides show the code. When its user decides, each side sends
`{"t":"pair","ok":true|false}` and reads the other's. Only when both said yes
does each store the other as trusted. Two minutes without an answer is a no.

### Requests (`mode: "session"`) — one per connection

| Request | Reply |
| --- | --- |
| `{"t":"status?"}` | `{"t":"status","state":"idle\|working\|thinking\|approval\|finished\|error","label":"<≤80, may be empty>"}` |
| `{"t":"msg","text":"<≤2000>"}` | `{"t":"ok"}` |
| `{"t":"ask","text":"<≤4000>"}` | `{"t":"answer","ok":bool,"text":"…"}` |
| `{"t":"file","name":"<≤120>","size":N}` | `{"t":"file","ok":bool}`; if ok: `{"t":"chunk","data":"<b64, ≤48 KiB>"}`…, `{"t":"end","sha256":"<hex>"}` → `{"t":"ok"}` or `{"t":"error","text"}` |

A received file is saved as `Downloads/Coucou/<name>` (the name stripped of any
path, a suffix added when it exists), at most 512 MB, and only after its size
and SHA-256 matched.

## Test vectors

With `shared` = 32 × `0x11` and `th` = 32 × `0x22`:

| | |
| --- | --- |
| `c2s` | `79e710446fec5c1a25ca933ae813742df85a90d1c6dece6c53a2685334615be7` |
| `s2c` | `56dc67ea8dda757573d99b394936dfbd514aef17be380a46b392d44e72ede183` |
| pairing code | `887393` |
| `{"t":"ping"}` sealed under `c2s`, counter 0 | `e76f7fd2787a6fd5d917bb1df1e481fde6d915ccf46d0835a2f5d704` |
| `th` for keys 32×`01`, 32×`02`, 32×`03`, 32×`04` | `8571d68592452ea22865d5892957abd5b82d2ce955dde7b6affddc3c1a585dbc` |

Checked by `windows/src-tauri/src/lan/wire.rs` (cargo test) and
`tests/LanWireTests.swift` (CI, `scripts/test-lan-wire.sh`).
