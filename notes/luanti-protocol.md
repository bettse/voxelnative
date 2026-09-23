# Luanti network protocol, as read from the engine source

Written 2026-09-09 from `repos/luanti` at commit c5ba5f7 (2026-09-08, engine
5.17.0 line) plus the Python reference client in `repos/miney`. Everything here
is from code, not from `doc/protocol.txt` (which only covers the UDP handshake).

Purpose: enough detail to reimplement the Luanti client protocol for this project (originally targeted Godot, now Swift under `native/`) so it can
join a VoxeLibre server, receive the world, move, dig and place.

Local server to test against: Luanti 5.15.1 (`/Applications/luanti.app`), which
speaks protocol version 51. Latest engine is protocol 53. Differences 51 to 53
are small (listed in section 2).

Source pointers (all under `repos/luanti/src/`):

- `network/networkprotocol.h`   every opcode with a payload comment
- `network/networkprotocol.cpp` protocol version history
- `network/mtp/internal.h`      UDP framing (base header, packet types)
- `network/mtp/threads.cpp`     ACK and window rules (handlePacketType_Reliable)
- `network/clientopcodes.cpp`   which channel and reliability each client packet uses
- `network/clientpackethandler.cpp` how the real client parses each server packet
- `network/serverpackethandler.cpp` how the server parses client packets; join order
- `client/client.cpp`           sendInit, startAuth, sendPlayerPos, interact, sendReady
- `client/clientmedia.cpp`      media cache, remote HTTP media, request/receive
- `util/srp.cpp`, `util/auth.cpp` SRP-6a exactly as the engine does it
- `mapblock.cpp`, `mapnode.cpp` block wire format
- `nodedef.cpp`, `itemdef.cpp`, `tool.cpp`, `tileanimation.cpp`, `sound_spec.cpp`,
  `util/pointabilities.cpp`     content definition formats
- `client/content_cao.cpp`, `object_properties.cpp`, `server/*_sao.cpp` entities
- `inventory.cpp`               inventory text format
- `server/player_sao.cpp`       movement anti-cheat

## 1. Big picture

- Transport is a custom reliable layer over **UDP**, default port **30000**.
  All integers **big-endian**.
- Every game message is `u16 opcode` followed by a payload. Messages live
  inside "original" packets, or are chopped into "split" packets when bigger
  than one datagram. Either can be wrapped in a "reliable" packet that
  requires an ACK.
- The join sequence is: UDP connect, INIT, HELLO, SRP auth, AUTH_ACCEPT,
  INIT2, then the server dumps item definitions, node definitions, and a
  media announcement; client fetches media; client sends CLIENT_READY; server
  spawns the player and starts streaming map blocks.
- After that the client sends its position roughly 10 times a second
  (unreliable), acknowledges blocks, and sends INTERACT for dig/place.
- All game logic is server-side Lua. The client is a renderer plus local
  physics plus a small amount of prediction. That is why a new client can
  run VoxeLibre unmodified.

## 2. Versions to send

| thing | value | where |
|---|---|---|
| protocol_id | `0x4f457403` | mtp/internal.h |
| serialization version (map format) | 29 | serialization.h SER_FMT_VER_HIGHEST_READ |
| protocol version, client min | 37 | networkprotocol.h |
| protocol version, latest | 53 | networkprotocol.cpp |
| formspec API version | 11 | networkprotocol.cpp |

Server negotiates: `min(client max, server max)`. Against the local 5.15.1
server the session will run at 51. The client must branch on the negotiated
version in a handful of places:

- `>= 48`: ITEMDEF, NODEDEF, MEDIA, ANNOUNCE_MEDIA payloads are **zstd**
  (before that zlib, and announce uses base64 sha1 strings).
- `>= 51`: item images carry a TileAnimation after the name.
- `>= 52`: INVENTORY payload is a long string followed by a bool; HUDADD
  `size` is v2f instead of v2s32.
- `53`: no wire changes listed, just the 5.17 bump. New AO_CMD_STOP_ANIMATION
  (13) and animation track ids appear in entity messages.

Miney hardcodes protocol 39 and serialization 28 and still works, because the
server happily downgrades. Starting at 39 is a valid way to reduce surface
area for an MVP, but it means zlib instead of zstd and the old announce
format. I would target 48+ from the start: zstd is one dependency either way
(map blocks are zstd regardless of protocol version).

## 3. Primitive encodings

| name | bytes | notes |
|---|---|---|
| u8/u16/u32/u64, s8/s16/s32 | 1/2/4/8 | big-endian |
| bool | 1 | u8 |
| f32 | 4 | IEEE 754 big-endian ("new network float format", protocol 37+) |
| f1000 | 4 | s32, divide by 1000 |
| v2f / v3f | 8 / 12 | f32 each, X Y Z |
| v3s16 | 6 | s16 each |
| v3s32 | 12 | s32 each |
| v2s16, v2s32 | 4, 8 | |
| ARGB8 | 4 | u32 read as A,R,G,B bytes |
| string16 | 2+n | u16 length, then raw bytes (UTF-8 by convention) |
| string32 ("long string") | 4+n | u32 length, then raw bytes |
| wstring | 2+2n | u16 char count, then UTF-16BE code units |
| string16 array | | **u32** count, then u16 lengths[count], then all bytes concatenated |

`NetworkPacket >> std::string` is string16. `putLongString`/`readLongString`
is string32. Chat and the legacy access-denied reason are wstrings.

Units: node coordinates are integers. Float positions on the wire are in
"BS units" where one node is `BS = 10.0`. Player positions in PLAYERPOS and
INTERACT are `v3s32 = position_in_BS * 100`, so one node = 1000 on the wire.
Angles are degrees; on the wire in PLAYERPOS they are `s32 = degrees * 100`.

Coordinate frame: Irrlicht, **left-handed, Y up, +Z forward**. Godot is
right-handed, Y up, -Z forward. Convert by negating Z (or X) consistently for
positions, velocities and yaw. Server-side look direction is built as
`(0,0,1)` rotated by pitch around X then by yaw around Y. Verify the sign of
pitch and yaw empirically on the first connect; it is cheap to get wrong and
the block streamer prioritises blocks in front of the camera.

## 4. UDP framing (mtp)

Every datagram starts with the 7-byte base header:

```
u32 protocol_id   = 0x4f457403
u16 sender_peer_id  (0 = not yet assigned, 1 = the server)
u8  channel         (0, 1 or 2)
```

Then one packet of type:

```
0 CONTROL   u8 type=0, u8 controltype, [args]
              controltype 0 ACK         u16 seqnum
              controltype 1 SET_PEER_ID u16 new_peer_id
              controltype 2 PING        (no args)
              controltype 3 DISCO       (no args)
1 ORIGINAL  u8 type=1, then message bytes (u16 opcode + payload)
2 SPLIT     u8 type=2, u16 split_seqnum, u16 chunk_count, u16 chunk_num, chunk bytes
3 RELIABLE  u8 type=3, u16 seqnum, then exactly one CONTROL/ORIGINAL/SPLIT packet
```

Rules:

- **Channels are independent sequence spaces.** Keep separate incoming and
  outgoing seqnum counters and split reassembly buffers per channel. The
  server uses all three toward the client.
- Seqnums start at **65500** and wrap at 65535 (u16). "Higher" is decided
  modulo 65536 with a half-range window (`seqnum_higher`).
- On receiving a RELIABLE: if seqnum is within `[next_expected, next_expected
  + 0x8000)` send an ACK (CONTROL/ACK on the same channel, unreliable). If it
  equals `next_expected`, process it and increment. If it is ahead, buffer it
  and process in order later. If it is behind (already seen), re-send the ACK
  and drop it. Beyond the window, drop silently.
- The server ACKs client reliables the same way. Keep sent reliables until
  ACKed; resend after **0.5 s** (engine default, adaptive with exponential
  backoff). Keep at most **64** unACKed in flight to start (engine starting
  window); the engine grows toward 2048. Miney uses a fixed 64 and it's fine.
- Datagram size limit the engine uses is **512 bytes** including headers.
  Anything larger goes as SPLIT chunks. All chunks of a split message share
  `split_seqnum`; reassemble when `chunk_count` chunks are present. Split
  chunks inside reliables are guaranteed complete; unreliable splits time out
  and are dropped.
- A reliable packet may not contain another reliable packet.
- **Peer timeout is 30 s** with no traffic (CONNECTION_TIMEOUT). Send a
  CONTROL/PING every few seconds when idle; PLAYERPOS traffic also counts.
- To disconnect send CONTROL/DISCO.

Connecting:

1. Client sends any packet with `sender_peer_id = 0`. The engine sends an
   empty RELIABLE/ORIGINAL with seqnum 65500; miney sends just the 7-byte base
   header and that works too.
2. Server replies with RELIABLE(seqnum 65500) wrapping CONTROL/SET_PEER_ID
   `u16 peer_id`. The client must **ACK it** (seqnum 65500, channel 0) or the
   server keeps resending. Use that peer_id in every later base header.

## 5. Join sequence and state machine

Server-side states (`server/clientiface.h`): Created, HelloSent,
AwaitingInit2, InitDone, DefinitionsSent, Active. The client's job at each step:

```
C->S  TOSERVER_INIT (0x02)            channel 1, unreliable in the engine (reliable also fine)
S->C  TOCLIENT_HELLO (0x02)
C->S  TOSERVER_SRP_BYTES_A (0x51)     or TOSERVER_FIRST_SRP (0x50) to register
S->C  TOCLIENT_SRP_BYTES_S_B (0x60)
C->S  TOSERVER_SRP_BYTES_M (0x52)
S->C  TOCLIENT_AUTH_ACCEPT (0x03)     or TOCLIENT_ACCESS_DENIED (0x0A)
C->S  TOSERVER_INIT2 (0x11)
S->C  TOCLIENT_ITEMDEF (0x3d)
S->C  TOCLIENT_NODEDEF (0x3a)
S->C  TOCLIENT_ANNOUNCE_MEDIA (0x3c)
S->C  TOCLIENT_ACTIVE_OBJECT_REMOVE_ADD (0x31)   (your own player object)
S->C  TOCLIENT_DETACHED_INVENTORY (0x43) x N
S->C  TOCLIENT_MOVEMENT (0x45)
S->C  TOCLIENT_TIME_OF_DAY (0x29)
S->C  TOCLIENT_CSM_RESTRICTION_FLAGS (0x2A)
      [client fetches media: cache, HTTP remote_media, then TOSERVER_REQUEST_MEDIA / TOCLIENT_MEDIA]
C->S  TOSERVER_CLIENT_READY (0x43)
S->C  TOCLIENT_UPDATE_PLAYER_LIST (0x56)
      [server runs on_joinplayer: HUD, inventory, formspec, HP, breath, privileges,
       MOVE_PLAYER to spawn, sky/sun/moon/stars/clouds/lighting, then blocks]
```

Blocks are only streamed once the client is `Active`, i.e. after CLIENT_READY.

### 5.1 TOSERVER_INIT (0x02)

```
u8  serialization version     29
u16 unused                    0
u16 min protocol version      37
u16 max protocol version      53
string16 player name
```

Player name: letters, digits, `-` and `_`. Case is preserved in the name but
SRP uses the lowercased name for the verifier (see 6). Miney lowercases
before sending; the engine does not.

### 5.2 TOCLIENT_HELLO (0x02)

```
u8  serialization version (negotiated)
u16 unused
u16 protocol version (negotiated)
u32 auth mechanisms bitmask   bit0 legacy password, bit1 SRP, bit2 FIRST_SRP
string16 unused
```

Choose: SRP if bit1 (account exists), else FIRST_SRP if bit2 (server allows
registration for this new name), else legacy. A fresh dedicated server offers
FIRST_SRP for unknown names by default.

### 5.3 TOCLIENT_AUTH_ACCEPT (0x03)

```
v3f unused (12 bytes)
u64 map seed
f32 recommended send interval (seconds, use it for PLAYERPOS cadence, ~0.1)
u32 sudo auth mechanisms
```

Miney parses the first 12 bytes as an s32 position. That is wrong; they are
floats and unused. Spawn position arrives later in MOVE_PLAYER.

### 5.4 TOCLIENT_ACCESS_DENIED (0x0A)

```
u8 code    (0 wrong password, 1 unexpected data, 2 singleplayer, 3 wrong version,
            4 bad chars in name, 5 name not allowed, 6 too many users,
            7 empty password, 8 already connected, 9 server fail, 10 custom,
            11 shutdown, 12 crash)
string16 custom reason (may be absent)
u8 reconnect flag (may be absent)
```

### 5.5 TOSERVER_INIT2 (0x11)

```
string16 language code (may be empty; controls which translation files are announced)
```

### 5.6 TOSERVER_CLIENT_READY (0x43)

```
u8 major, u8 minor, u8 patch, u8 reserved(0)
string16 full version string (free text)
u16 formspec API version   (the engine sends 11; miney sends 4)
```

Servers older than 5.1 don't read the last field. VoxeLibre checks
`formspec_version` in some places to pick layouts; send the real number the
client can render, once formspecs are implemented.

## 6. SRP-6a authentication, exactly as the engine does it

Library: csrp (`util/srp.cpp`), SHA-256, 2048-bit group (`SRP_NG_2048`,
the RFC 5054 2048-bit N, g = 2). Miney's `srp.py` has the N hex inline and is
a working Python port worth copying.

Definitions (all big-endian byte strings, `|` is concatenation, `PAD(x)`
left-pads to the byte length of N):

- `I` = player name **as sent** (case preserved), used inside M.
- `I_v` = lowercase(player name), used inside x. (client.cpp passes both.)
- `x = H( s | H( I_v | ":" | password ) )`  (`calculate_x`, then `H_ns`)
- `k = H( PAD(N) | PAD(g) )`  (`H_nn`)
- `A = g^a mod N`, a random. Send A raw, no padding (`mpz_to_bin`).
- `u = H( PAD(A) | PAD(B) )`
- `S = (B - k * g^x) ^ (a + u*x) mod N`
- `K = H(S)`  (session key, raw S bytes, no padding)
- `M = H( (H(N) xor H(g)) | H(I) | s | A | B | K )` where N and g are hashed
  unpadded, A and B unpadded (`calculate_M`).
- Server proof `H_AMK` is not sent back to the client; AUTH_ACCEPT is the
  success signal.

Packets:

```
TOSERVER_SRP_BYTES_A (0x51):  string16 A, u8 based_on (1 = password, 0 = legacy hash)
TOCLIENT_SRP_BYTES_S_B (0x60): string16 s, string16 B
TOSERVER_SRP_BYTES_M (0x52):  string16 M
```

Registration (FIRST_SRP, 0x50): client picks a random 16-byte salt s,
computes `v = g^x mod N` with `x` as above using the lowercased name, sends
`string16 s, string16 v, u8 is_empty_password`. Server stores `#1#b64(s)#b64(v)`.

Legacy mechanism (bit0): password is replaced by
`base64(sha1(name + password))` and `based_on = 0`. Not needed for a fresh
server.

Empty passwords: allowed by default (`disallow_empty_password = false`).
Miney warns that names with capitals fail after registration because it
lowercases for FIRST_SRP but the engine mixes cases; safest is to use an
all-lowercase player name for the VR client.

## 7. Client to server packets (channel, reliable) and payloads

From `clientopcodes.cpp`:

| opcode | name | ch | rel | payload |
|---|---|---|---|---|
| 0x02 | INIT | 1 | no | see 5.1 |
| 0x11 | INIT2 | 1 | yes | string16 lang |
| 0x17/18/19 | MODCHANNEL_JOIN/LEAVE/MSG | 0 | yes | string16 channel [, string16 msg] |
| 0x23 | PLAYERPOS | 0 | **no** | see 7.1 |
| 0x24 | GOTBLOCKS | 2 | yes | u8 count, v3s16[count] |
| 0x25 | DELETEDBLOCKS | 2 | yes | u8 count, v3s16[count] |
| 0x31 | INVENTORY_ACTION | 0 | yes | text, see 12 |
| 0x32 | CHAT_MESSAGE | 0 | yes | wstring |
| 0x35 | DAMAGE | 0 | yes | u16 hp delta (fall damage etc, client-computed) |
| 0x37 | PLAYERITEM | 0 | yes | u16 hotbar index |
| 0x38 | RESPAWN_LEGACY | 0 | yes | (pre-46 servers only) |
| 0x39 | INTERACT | 0 | yes | see 7.2 |
| 0x3a | REMOVED_SOUNDS | 2 | yes | u16 n, s32 ids |
| 0x3b | NODEMETA_FIELDS | 0 | yes | v3s16 pos, string16 formname, u16 n {string16 key, string32 value} |
| 0x3c | INVENTORY_FIELDS | 0 | yes | string16 formname, u16 n {string16 key, string32 value} |
| 0x40 | REQUEST_MEDIA | 1 | yes | u16 n, string16 names |
| 0x41 | HAVE_MEDIA | 2 | yes | u8 n, u32 tokens (dynamic media only) |
| 0x43 | CLIENT_READY | 1 | yes | see 5.6 |
| 0x50 | FIRST_SRP | 1 | yes | string16 s, string16 v, u8 empty |
| 0x51 | SRP_BYTES_A | 1 | yes | string16 A, u8 based_on |
| 0x52 | SRP_BYTES_M | 1 | yes | string16 M |
| 0x53 | UPDATE_CLIENT_INFO | 2 | yes | u32 w, u32 h, f32 gui_scaling, f32 hud_scaling, f32 max_fs_w, f32 max_fs_h, bool touch |

### 7.1 TOSERVER_PLAYERPOS (0x23), and the shared "player pos" block

Sent unreliably on channel 0 about every `recommended_send_interval`
(0.1 s). The engine stops repeating after 5 identical sends; resume on change.

```
v3s32 position * 100        (position in BS units, so node coords * 1000)
v3s32 speed * 100
s32   pitch * 100           degrees
s32   yaw * 100             degrees
u32   keys pressed          bit0 up, 1 down, 2 left, 3 right, 4 jump, 5 aux1,
                            6 sneak, 7 dig, 8 place, 9 zoom
u8    fov * 80              (radians * 80, so ~72 for 90 degrees; capped 255)
u8    wanted_range / 16     ceil, in map blocks. Drives how far the server sends.
u8    camera_inverted       0
f32   movement_speed        0..1 analog magnitude (used for animations)
f32   movement_direction    radians relative to yaw
```

The same block (without the u16 opcode) is appended to INTERACT.

Position semantics: it is the **feet position of the player's collision box**
(base position). The server derives the eye position as base + `eye_height`
from the player's ObjectProperties (VoxeLibre sets its own). For VR: send
(play-space origin + locomotion offset + headset XZ), not the headset's Y.

### 7.2 TOSERVER_INTERACT (0x39)

```
u8  action        0 START_DIGGING (also "punch"), 1 STOP_DIGGING, 2 DIGGING_COMPLETED,
                  3 PLACE, 4 USE (use wielded item), 5 ACTIVATE (right-click air)
u16 wield index   hotbar slot
string32 PointedThing:
      u8 version 0
      u8 type    0 nothing, 1 node, 2 object
      if node:   v3s16 under (the node hit), v3s16 above (the air node in front of the face)
      if object: u16 object id
then the player pos block from 7.1
```

Server checks (`serverpackethandler.cpp`, only when `anticheat_flags` has the
relevant bits, which is the default on multiplayer, and never in singleplayer
mode):

- distance from **eye position** to the target node/object must be
  `<= tool range + 2.6` nodes. Range comes from the wielded item definition
  (`range`, default 4.0), else the hand's.
- DIGGING_COMPLETED must follow a START_DIGGING on the same node, and the
  elapsed time must be at least the dig time computed from node groups and
  tool capabilities (`getDigParams`, section 14), with a small lag pool.
- "interact" privilege required.

Flow for digging: send START (0) once when the trigger is pressed on a node,
compute the dig time locally, keep pointing, send COMPLETED (2) after that
time, or STOP (1) if the ray leaves the node. The server then sends
REMOVENODE plus inventory updates. The engine also predicts by removing the
node locally; an MVP can skip prediction.

Flow for placing: send PLACE (3) with the pointed node; server calls the
item's `on_place` and sends ADDNODE. For items with `node_placement_prediction`
the engine places locally first.

### 7.3 Block acknowledgement

The server keeps at most `max_simultaneous_block_sends_per_client` (default
40) blocks in flight per client and waits for GOTBLOCKS before sending more.
Send GOTBLOCKS with the block position for every BLOCKDATA received (batch up
to 255 per packet). Send DELETEDBLOCKS when the client drops a block from
memory so the server knows to resend it later.

Which blocks the server sends (`clientiface.cpp` GetNextBlocks): spiral out
from the player's block, up to `wanted_range` blocks but no more than
`max_block_send_distance` (default 12), prioritising blocks inside the FOV
cone built from pitch/yaw/fov; blocks within `block_send_optimize_distance`
(4) are sent regardless of direction. Server-side occlusion culling is on by
default. Practical consequence: a VR client should send the **headset's**
yaw and pitch and a wide fov so the streamer prioritises the right blocks.

## 8. Server to client packets the client must handle

Only the ones needed for a playable client. See `networkprotocol.h` for the
rest (sounds, particles, sky, HUD, formspecs).

| opcode | name | payload |
|---|---|---|
| 0x02 | HELLO | 5.2 |
| 0x03 | AUTH_ACCEPT | 5.3 |
| 0x0A | ACCESS_DENIED | 5.4 |
| 0x20 | BLOCKDATA | v3s16 blockpos, then section 10 |
| 0x21 | ADDNODE | v3s16 pos, u16 param0, u8 param1, u8 param2 (4 bytes for ser ver 29), u8 keep_metadata |
| 0x22 | REMOVENODE | v3s16 pos (becomes air) |
| 0x27 | INVENTORY | proto>=52: string32 text, bool skip_wield_anim; else the rest of the packet is text. Section 12 |
| 0x29 | TIME_OF_DAY | u16 time 0..23999, f32 time_speed |
| 0x2A | CSM_RESTRICTION_FLAGS | u64 flags, u32 node range (ignore) |
| 0x2B | PLAYER_SPEED | v3f velocity to add (knockback) |
| 0x2C | MEDIA_PUSH | dynamic media: string16 raw sha1, string16 filename, u32 token, bool cache. Fetch via REQUEST_MEDIA or remote, reply HAVE_MEDIA |
| 0x2F | CHAT_MESSAGE | u8 version(1), u8 type, wstring sender, wstring message, u64 timestamp |
| 0x31 | ACTIVE_OBJECT_REMOVE_ADD | section 11 |
| 0x32 | ACTIVE_OBJECT_MESSAGES | repeated {u16 id, string16 msg} until end |
| 0x33 | HP | u16 hp, bool damage_effect |
| 0x34 | MOVE_PLAYER | v3f pos (BS units), f32 pitch, f32 yaw. Teleport/spawn. Must apply. |
| 0x36 | FOV | f32 fov, bool is_multiplier, f32 transition |
| 0x38 | MEDIA | section 9 |
| 0x3a | NODEDEF | string32 blob (zstd if proto>=48 else zlib), section 13.2 |
| 0x3c | ANNOUNCE_MEDIA | section 9 |
| 0x3d | ITEMDEF | string32 blob (zstd/zlib), section 13.1 |
| 0x3f/0x40/0x55 | PLAY_SOUND / STOP_SOUND / FADE_SOUND | later |
| 0x41 | PRIVILEGES | u16 n, string16 names |
| 0x42 | INVENTORY_FORMSPEC | string32 formspec (the player's inventory UI) |
| 0x43 | DETACHED_INVENTORY | string16 name, bool keep_inv, then inventory text |
| 0x44 | SHOW_FORMSPEC | string32 formspec, string16 formname. Empty formspec = close |
| 0x45 | MOVEMENT | 12 x f32 in nodes/s or nodes/s^2: accel default, air, fast; speed walk, crouch, fast, climb, jump; liquid fluidity, fluidity smooth, sink; gravity |
| 0x46/47/53/64 | particles | later |
| 0x49..0x4d | HUD add/rm/change/flags/param | section 15 |
| 0x4e | BREATH | u16 |
| 0x4f, 0x5a, 0x5b, 0x5c, 0x54, 0x63 | sky, sun, moon, stars, clouds, lighting | cosmetic, later |
| 0x50 | OVERRIDE_DAY_NIGHT_RATIO | bool, u16 |
| 0x51 | LOCAL_PLAYER_ANIMATIONS | own model animation frames |
| 0x52 | EYE_OFFSET | v3f first, v3f third, v3f third_front (camera offsets in BS) |
| 0x56 | UPDATE_PLAYER_LIST | u8 type (0 init, 1 add, 2 remove), u16 n, string16 names |
| 0x59 | NODEMETA_CHANGED | zstd/zlib blob of a NodeMetadataList with absolute positions |
| 0x5d | MOVE_PLAYER_REL | v3f delta |
| 0x60 | SRP_BYTES_S_B | 6 |
| 0x61 | FORMSPEC_PREPEND | string16 |
| 0x62 | MINIMAP_MODES | ignore |

Unknown opcodes: skip the packet.

## 9. Media (textures, sounds, models)

ANNOUNCE_MEDIA (0x3c), proto >= 48:

```
string32 zstd( string16 array of file names )
20 bytes raw sha1 per file, in the same order
string16 remote media servers, comma separated base URLs (may be empty)
```

(Older: u16 count, then {string16 name, string16 base64(sha1)}, then the URL string.)

Client resolution order, mirroring `clientmedia.cpp`:

1. Local cache keyed by hex(sha1). Persist it; VoxeLibre's media is
   ~72 MB on disk (2891 PNG, 449 OGG, 72 b3d, 43 obj) and a first join over
   UDP at 512-byte packets is slow.
2. For each remote server: GET `baseurl + "index.mth"`. Format: u32
   signature `MTHASHSET_FILE_SIGNATURE`, u16 version 1, then 20-byte sha1s.
   Files present there are fetched with GET `baseurl + hex(sha1)`. Verify sha1.
3. Everything else: TOSERVER_REQUEST_MEDIA (0x40) `u16 n, string16 names`.
   The server answers with TOCLIENT_MEDIA (0x38) bunches of ~5 KB:
   `u16 num_bunches, u16 bunch_index, u32 num_files, {string16 name,
   string32 data}`; data is zstd-compressed when proto >= 48. Verify sha1.
   **The server sends each file at most once per session**; a second request
   for the same name is ignored with a warning.

Model formats in VoxeLibre: `.b3d` (Blitz3D, 72 files, all mobs and the
player) and `.obj` (43). Godot has no built-in b3d importer. The format is
simple and documented (chunks: BB3D, TEXS, BRUS, NODE, MESH, BONE, ANIM,
KEYS). Budget a small runtime b3d loader. Textures are PNG, fine. Sounds are
OGG Vorbis, fine.

Texture strings in node and entity definitions are Luanti "texture
modifiers", e.g. `default_stone.png^[colorize:#ff0000:60` or
`[combine:16x16:0,0=a.png`. The client must implement a subset: plain name,
`^` overlay, `[colorize`, `[transform`, `[multiply`, `[opacity`, `[crack`
(engine-generated dig cracks). Grep VoxeLibre for which ones it actually
uses before deciding the subset.

## 10. Map blocks

Block position `b` covers nodes `b*16 .. b*16+15`. Node index inside a
block: `i = (z*16 + y)*16 + x`.

TOCLIENT_BLOCKDATA (0x20): `v3s16 blockpos`, then `MapBlock::serialize(ver
29, disk=false)`, then `u8 network_specific_version = 2`. The block body is a
single **zstd frame** (frames are self-delimiting, so decompress the frame
and expect exactly one trailing byte). Decompressed:

```
u8  flags            bit0 is_underground, bit1 legacy day/night differs, bit3 NOT generated
u16 lighting_complete
u8  content_width    always 2
u8  params_width     always 2
u16 param0[4096]     node content ids, index order above
u8  param1[4096]     light: low nibble day, high nibble night, 0..15 (15 = sunlight)
u8  param2[4096]     rotation/level/color, meaning depends on the node's paramtype2
NodeMetadataList:
    u8 version       0 = empty, else 1 or 2
    u16 count
    per entry: u16 packed pos (x + 16*y + 256*z)
               u32 num_vars {string16 key, string32 value, [ver 2: u8 private]}
               Inventory text (section 12)
```

Content ids are the global ids from NODEDEF (no per-block name table on the
network). Fixed ids: **125 unknown, 126 air, 127 ignore**. Everything else is
whatever the server assigned; VoxeLibre has a few thousand.

ADDNODE carries one MapNode as `u16 param0, u8 param1, u8 param2`.

Light only means something for nodes with `param_type == CPT_LIGHT` (1).
For an MVP, ignore param1 and light the scene in Godot; later, feed day
light into vertex colour for the Minecraft look.

## 11. Entities (active objects)

TOCLIENT_ACTIVE_OBJECT_REMOVE_ADD (0x31):

```
u16 removed_count, u16 ids...
u16 added_count, per object: u16 id, u8 type (7 Lua entity, 100 player), string32 init data
```

Init data (GenericCAO::processInitData):

```
u8  version 1
string16 name            (player name, or entity type name like "mobs_mc:zombie")
u8  is_player
u16 id
v3f position (BS units)
v3f rotation (degrees, x y z)
u16 hp
u8  message count, then that many string32 messages, each a normal AO command below
```

Your own player arrives as a player object with your name; the engine hides
it and binds it to the local player (collision box, eye height, physics
override come from its SET_PROPERTIES).

TOCLIENT_ACTIVE_OBJECT_MESSAGES (0x32): repeated `u16 id, string16 msg`.
Each msg starts with `u8 cmd`:

```
0  SET_PROPERTIES        ObjectProperties v4 (below)
1  UPDATE_POSITION       v3f pos, v3f vel, v3f acc, v3f rot, u8 interpolate, u8 is_end, f32 update_interval
2  SET_TEXTURE_MOD       string16 modifier appended to textures
3  SET_SPRITE            v2s16 base, u16 frames, f32 frame_len, u8 select_by_yaw_pitch
4  PUNCHED               u16 new hp
5  UPDATE_ARMOR_GROUPS   u16 n {string16 group, s16 rating}
6  SET_ANIMATION         v2f frame range, f32 fps, f32 blend, u8 NOT loop, [u16 track tag(+string16), s32 priority, f32 cur_frame] (5.17)
7  SET_BONE_POSITION     string16 bone, v3f pos, v3f rot deg, [v3f scale, 3x f32 interp, u8 absolute bits]
8  ATTACH_TO             s16 parent id (0 = detach), string16 bone, v3f pos, v3f rot, u8 force_visible
9  SET_PHYSICS_OVERRIDE  f32 speed, jump, gravity, u8 NOT sneak, NOT sneak_glitch, NOT new_move, [7 f32], [3 f32]
11 SPAWN_INFANT          u16 child id, u8 type
12 SET_ANIMATION_SPEED   f32 fps, [track tag]
13 STOP_ANIMATION        track tag
```

ObjectProperties (version u8 = 4):

```
u16 hp_max, u8 physical, u32 unused, v3f collisionbox min, v3f max (node units),
v3f selectionbox min, v3f max, u8 pointable,
string16 visual ("cube","sprite","upright_sprite","mesh","wielditem","item","node"),
v3f visual_size, u16 n {string16 texture}, v2s16 spritediv, v2s16 initial_sprite_basepos,
u8 is_visible, u8 makes_footstep_sound, f32 automatic_rotate, string16 mesh,
u16 n {ARGB8 color}, u8 collide_with_objects, f32 stepheight,
u8 automatic_face_movement_dir, f32 offset, u8 backface_culling,
string16 nametag, ARGB8 nametag_color, f32 automatic_face_movement_max_rotation_per_sec,
string16 infotext, string16 wield_item, s8 glow, u16 breath_max, f32 eye_height,
f32 zoom_fov, u8 use_texture_alpha,
then optional (read while bytes remain): string16 damage_texture_modifier, u8 shaded,
u8 show_on_minimap, ARGB8 nametag_bgcolor, u8 rotate_selectionbox,
u16 node.param0, u8 param1, u8 param2, ...
```

VoxeLibre mobs are `visual = "mesh"` with b3d models and server-driven
animations (SET_ANIMATION with frame ranges). Dropped items are `wielditem`
or `item` visuals showing the item's inventory image or node cube. Players
are meshes (`mcl_player`'s b3d) with bone overrides for arm poses.

## 12. Inventory text format

Line-based, `\n` separated. Inventory:

```
List <name> <size>
Width <n>
Item <itemstring>
Empty
Keep                      (incremental update: slot unchanged)
KeepList <name>           (incremental update: whole list unchanged, sent instead of List)
EndInventoryList
...
EndInventory
```

Itemstring: `name [count [wear ["metadata"]]]`, e.g. `mcl_core:stone 64`,
`mcl_tools:pick_iron 1 120`. Metadata is a JSON-style quoted string whose
content is `\x01key\x02value\x01...` pairs. Names with spaces/quotes are
JSON-quoted.

Inventory locations for INVENTORY_ACTION: `current_player`,
`nodemeta:x,y,z`, `detached:<name>`.

TOSERVER_INVENTORY_ACTION (0x31) text:

```
Move <count> <from_inv> <from_list> <from_index> <to_inv> <to_list> <to_index>
MoveSomewhere <count> <from_inv> <from_list> <from_index> <to_inv> <to_list>
Drop <count> <inv> <list> <index>
Craft <count> <inv>
```

VoxeLibre player lists: `main` (36, hotbar is the first 9), `craft`,
`craftpreview`, `armor`, `offhand`, plus enchanting/anvil detached ones.

## 13. Content definitions

### 13.1 TOCLIENT_ITEMDEF

`string32 blob`, blob = zstd (proto>=48) or zlib of:

```
u8 version 0
u16 count, per item: string16 wrapper -> ItemDefinition
u16 alias count, per alias: string16 name, string16 convert_to
```

ItemDefinition (version u8 = 6):

```
u8 type              0 none, 1 node, 2 craft, 3 tool
string16 name, string16 description
ItemImageDef inventory_image   = string16 name [+ TileAnimation if proto>=51]
ItemImageDef wield_image
v3f wield_scale, s16 stack_max, u8 usable, u8 liquids_pointable
string16 tool_capabilities blob (empty = none):
    u8 version(>=4), f32 full_punch_interval, s16 max_drop_level,
    u32 n groupcaps {string16 group, s16 uses, s16 maxlevel, u32 n {s16 level, f32 time}},
    u32 n damage_groups {string16 group, s16 rating}, [v5: u16 punch_attack_uses]
u16 n groups {string16 name, s16 value}
string16 node_placement_prediction
SoundSpec place, place_failed      = string16 name, f32 gain, f32 pitch, f32 fade
f32 range                          (interaction reach in nodes; 4.0 default)
string16 palette_image, ARGB8 color
ItemImageDef inventory_overlay, wield_overlay
optional tail, read while bytes remain:
string16 short_description
[proto<=43: u8 place_param2]
SoundSpec use, use_air
u8 has_param2, [u8 place_param2]
u8 wallmounted_rotate_vertical
TouchInteraction: 3 x u8
string16 pointabilities blob (u8 ver 0, then 4 maps: u32 n {string16, u8 type})
u8 has_wear_bar, [WearBarParams]
```

### 13.2 TOCLIENT_NODEDEF

`string32 blob`, blob = zstd/zlib of:

```
u8 version 1
u16 count
string32 body, body = repeated { u16 content id, string16 wrapper -> ContentFeatures }
```

ContentFeatures (version u8 = 13):

```
string16 name
u16 n groups {string16 name, s16 value}
u8 param_type        0 none, 1 light
u8 param_type_2      0 none,1 full,2 flowingliquid,3 facedir,4 wallmounted,5 leveled,
                     6 degrotate,7 meshoptions,8 color,9 colored_facedir,
                     10 colored_wallmounted,11 glasslike_liquid_level,
                     12 colored_degrotate,13 4dir,14 colored_4dir
u8 drawtype          0 normal,1 airlike,2 liquid,3 flowingliquid,4 glasslike,5 allfaces,
                     6 allfaces_optional,7 torchlike,8 signlike,9 plantlike,10 fencelike,
                     11 raillike,12 nodebox,13 glasslike_framed,14 firelike,
                     15 glasslike_framed_optional,16 mesh,17 plantlike_rooted
string16 mesh        (obj/b3d file name for drawtype mesh)
f32 visual_scale
u8 6, then 6 TileDef (tiles: +Y, -Y, +X, -X, +Z, -Z)
6 TileDef overlay
u8 6 (CF_SPECIAL_COUNT), 6 TileDef special (liquid flowing textures etc)
u8 legacy alpha, u8 r, u8 g, u8 b, string16 palette_name
u8 waving, u8 connect_sides, u16 n {u16 connects_to id}
ARGB8 post_effect_color, u8 leveled
u8 light_propagates, u8 sunlight_propagates, u8 light_source
u8 is_ground_content
u8 walkable, u8 pointable (0 not pointable, 1 pointable, 2 blocks the ray), u8 diggable, u8 climbable, u8 buildable_to,
u8 rightclickable, u32 damage_per_second
u8 liquid_type (0 none,1 flowing,2 source), string16 alt_flowing, string16 alt_source,
u8 viscosity, u8 renewable, u8 range, u8 drowning, u8 floodable
NodeBox node_box, NodeBox selection_box, NodeBox collision_box
SoundSpec footstep, dig, dug
u8 legacy_facedir_simple, u8 legacy_wallmounted
optional tail: string16 node_dig_prediction, u8 leveled_max, u8 alpha (0 blend,1 clip,2 opaque),
u8 move_resistance, u8 liquid_move_physics, u8 post_effect_color_shaded
```

TileDef:

```
u8 version 6
string16 texture name (with modifiers)
TileAnimation: u8 type (0 none; 1 vertical frames: u16 aspect_w, u16 aspect_h, f32 length;
                        2 sheet: u8 frames_w, u8 frames_h, f32 frame_length)
u16 flags  bit0 backface_culling, bit1 tileable_h, bit2 tileable_v,
           bit3 has_color -> u8 r,g,b ; bit4 has_scale -> u8 scale ; bit5 has_align_style -> u8
```

NodeBox (version u8 = 6, then u8 type): 0 regular; 1 fixed and 3 leveled:
`u16 n {v3f min, v3f max}`; 2 wallmounted: 3 pairs of v3f (top, bottom,
side); 4 connected: 15 lists of `u16 n {v3f, v3f}` in the order fixed,
connect top/bottom/front/left/back/right, disconnected
top/bottom/front/left/back/right, disconnected, disconnected_sides. Boxes are
in node units (-0.5..0.5).

VoxeLibre drawtype usage (static grep of register_node call sites; runtime
counts are higher because many nodes are registered in loops):

| drawtype | sites |
|---|---|
| nodebox | 88 |
| plantlike | 37 |
| mesh | 34 |
| plantlike_rooted | 10 |
| airlike | 8 |
| normal | 5 (but the loops make this the bulk of the world: stone, dirt, logs, planks, ores) |
| signlike, glasslike, firelike, allfaces_optional | 3 each |
| raillike, liquid, flowingliquid, glasslike_framed_optional | 2 each |

param2: facedir 110, meshoptions 21, wallmounted 15, color 7, then a handful
of degrotate, 4dir, glasslikeliquidlevel, flowingliquid, leveled,
colorwallmounted. So a mesher needs: cubes, nodebox cuboids with facedir/
wallmounted/4dir rotation, plantlike crosses, allfaces (leaves), liquids
(flat tops for MVP), mesh nodes (obj/b3d), glasslike. Rails, torches, fire,
signs can be stand-ins early on.

## 14. Physics and anti-cheat, what a VR client must respect

- Movement is **client authoritative** within limits. Server checks
  horizontal distance per tick against max(walk, crouch[, fast]) speed
  times elapsed time, with a lag pool of at least 5 s, and vertical up-speed
  against 2 x jump speed or climb speed. Teleports (MOVE_PLAYER) reset it.
  Room-scale walking is well within walk speed. Smooth-locomotion via the
  stick at walk speed is fine. Snap-teleport locomotion would need to stay
  under ~4.3 nodes/s averaged, or be implemented as short dashes.
- MOVEMENT packet values (nodes/s) define walk speed etc. VoxeLibre sets
  `movement_speed_walk` ~4.317 to match Minecraft, and sprint via physics
  override on the player object (SET_PHYSICS_OVERRIDE `speed`).
- Gravity, collision with `walkable` nodes, climbing, swimming are all
  client-side; the server only sanity-checks. Godot's CharacterBody3D with
  a capsule against a generated collision mesh is enough. Use the node's
  `collision_box` (nodebox) when present, else a full cube if `walkable`.
- Dig time (`tool.cpp` getDigParams): for each tool groupcap that matches a
  node group with `rating`, `time = cap.times[rating]`, divided by
  `(cap.maxlevel - node.level)` if that difference is > 1; take the minimum
  over groups. Nodes with group `dig_immediate` 2 or 3 take 0.5 s or 0 s.
  If no tool cap matches, use the hand's caps (item name `""`). If the
  computed time is under 2 s the server allows it from a time pool; long
  digs must take at least 1/1.2 of the computed time. Send COMPLETED no
  earlier than the computed time.
- Reach: the wielded item's `range` (VoxeLibre hand and tools use the
  default 4.0, check `mcl_tools`) plus 2.6 tolerance, measured from the
  eye. Aim rays from the controller but clamp the hit to that distance.
- HP: the client sends TOSERVER_DAMAGE for fall damage it computes locally
  (engine does this in LocalPlayer). VoxeLibre also computes fall damage
  server-side in some paths; fine to omit at first.

## 15. Things the server assumes a client can draw

These are not optional for a playable VoxeLibre session, but can be staged:

1. **HUD elements** (HUDADD/HUDCHANGE/HUDRM): health, hunger, armor, XP bar,
   breath, boss bars, the hotbar itself (server-side builtin since proto
   46), crosshair flag, wielded item name. VoxeLibre has 44 hud_add sites.
   Types: image, text, statbar, inventory, waypoint, image_waypoint,
   compass, minimap, hotbar. Render as a wrist or floating panel in VR.
2. **Formspecs** (SHOW_FORMSPEC, INVENTORY_FORMSPEC, FORMSPEC_PREPEND,
   NODEMETA fields): player inventory with 2x2 crafting, crafting table 3x3,
   chests, furnaces, enchanting, anvil, the death/respawn screen
   (`__builtin:death`, reply INVENTORY_FIELDS with `btn_respawn=true`). The
   formspec language is in `repos/luanti/doc/lua_api.md` under "Formspec".
   VoxeLibre has 79 formspec call sites. Plan: render formspecs as a flat
   panel with a laser pointer; only the elements VoxeLibre uses (`list`,
   `image`, `button`, `image_button`, `label`, `field`, `listring`,
   `background`, `tooltip`, `style`, `scroll_container`).
3. **Chat** display and input (optional early).
4. **Sounds** (PLAY_SOUND positional/object/local) and **particles**: pure
   polish, skip in the MVP.
5. **Sky/time**: TIME_OF_DAY drives day/night; SET_SKY etc are cosmetic.

## 16. Scale numbers for VoxeLibre 0.91.2 (installed copy)

- Registered content (grep of call sites): 472 register_node, 232
  craftitem/tool, 118 entity/mob registrations. Runtime node count is a few
  thousand ids.
- Media on disk: 2891 PNG, 449 OGG, 72 b3d, 43 obj, about 72 MB.
- NODEDEF over the wire is a few MB compressed; the engine sends it as one
  reliable split message, thousands of 512-byte chunks. Expect a couple of
  seconds on LAN.

## 17. Original implementation order (Godot-era plan, superseded by `native/`)

1. **Transport**: base header, reliable/ACK/window per channel, split
   reassembly, resend, ping, disconnect. Godot: `PacketPeerUDP` on a thread
   or polled in `_process`. This is the one piece worth unit-testing against
   miney's behaviour and the real server side by side.
2. **Handshake + SRP**: SHA-256 exists in Godot (`HashingContext`); 2048-bit
   modular exponentiation does not. Options: a GDExtension in C/Rust with a
   bignum, or a pure-GDScript bigint (slow but a handful of modpows per
   login is fine). Verify against miney's `srp.py` with a fixed `a`.
3. **Definitions**: zstd decode (Godot has no zstd in GDScript; there is
   `FileAccess.get_compressed`/`PackedByteArray.decompress` with
   `COMPRESSION_ZSTD`, which does exist, check it accepts raw frames of
   unknown size via `decompress_dynamic`). Parse ITEMDEF, NODEDEF into
   dictionaries. Media: cache dir keyed by sha1, HTTP remote first, then
   REQUEST_MEDIA. Load PNGs into a texture atlas.
4. **Blocks**: decode BLOCKDATA into 16^3 arrays, GOTBLOCKS, greedy or naive
   mesher for `normal`/`allfaces`/`glasslike`/`liquid` first, then
   `nodebox`, `plantlike`, `mesh`. Chunk collision shapes.
5. **Player**: MOVE_PLAYER spawn, PLAYERPOS at 10 Hz from the XR origin,
   gravity/collision, headset yaw/pitch as look.
6. **Interaction**: controller ray to node (DDA through the block arrays),
   START/COMPLETED/STOP digging with local dig time, PLACE, PLAYERITEM for
   hotbar, wielded item shown in the controller hand.
7. **Entities**: spawn/remove, UPDATE_POSITION interpolation, `wielditem`
   drops as billboards, mobs as static placeholder capsules; b3d loader and
   animations later.
8. **HUD panel, death screen, inventory formspec.** Then the long tail.

## 18. Open items not yet read

- Formspec grammar (doc/lua_api.md) and VoxeLibre's `mcl_formspec` prepend.
- HUD element definitions (`hud.h`) in detail.
- Sound and particle packets.
- Texture modifier language (`client/tile.cpp` / `texturesource.cpp`).
- b3d format details for the loader.
- Exact VoxeLibre player properties (eye height, collision box) and
  `mcl_playerphysics` overrides, to size the VR body.
- Whether Godot's built-in zstd decompressor accepts the engine's frames.
