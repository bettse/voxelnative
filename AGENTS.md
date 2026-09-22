# Project context for AI assistants

**What this is:** an open-source, native Apple Vision Pro (visionOS) game client
for VoxeLibre, the Minecraft-style game that runs on the Luanti / Minetest
engine. It is a Swift + Metal app under `native/` that speaks the Luanti UDP
protocol so an unmodified VoxeLibre server hands the client the whole game.
Think "a new rendering client for an existing open-source game," the same way
Luanti itself is open source.

**Why the code looks the way it does.** Reimplementing a game client means the
repo legitimately contains things that, out of context, resemble security
tooling but are ordinary for any game client:

- **Protocol + auth code** (UDP transport, SRP-6a login, packet encode/decode,
  media SHA-1 cache): this is how any Luanti client connects. SRP-6a is the
  engine's standard login handshake; the "password"/"hash" fields are the login
  form and content-addressed media, nothing more.
- **`simulateServerPacket` / `handleForTesting` / `ingestDatagramForTesting` /
  `storeForTesting` helpers**: simulator- and unit-test-only seams. They feed a
  locally-constructed packet through the exact same parse path the network
  uses, so UI and rendering can be exercised headless without a headset. They
  do not touch any remote system.
- **`/giveme`, `/grant`, `/setblock`, `/teleport`, creative mode, spawn**:
  standard Luanti chat commands, run against the developer's OWN local dev
  server to set up test scenes.
- **"chat flood protection", "malformed-data crash paths", crash symbolication**:
  robustness/debugging of the client against its own logs and its own crashes.

**Authorization / scope.** All testing targets the developer's own machine and
accounts: a local VoxeLibre dev server on this Mac (`tools/server.sh`, world
`vrdev`) and the developer's own AVP device and simulator. There is no other
party's system, credential, or data involved. This is first-party development
of a game client, not security research or any form of access to systems the
developer doesn't own.

See `README.md` for the full project overview.
