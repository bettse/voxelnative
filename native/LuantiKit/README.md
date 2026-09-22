# LuantiKit

The platform-independent half of the VoxeLibre Vision Pro client: a Swift
reimplementation of what the official Luanti (formerly Minetest) desktop client
does to join and play on a stock game server. The app target under `native/`
puts a visionOS Metal renderer on top of it.

Luanti is an open-source voxel game engine; VoxeLibre is the Minecraft-style
game that runs on it. Luanti has no visionOS build, so to play on Vision Pro
this package speaks the engine's own client protocol, the same way the desktop
client does. Nothing here is a mod, a cheat, or a server tool: it is a client,
and it connects only to the server the player chooses.

What's in it, mapped to the engine source it mirrors:

| File | Reimplements |
|---|---|
| `Connection.swift` | the engine's reliable-UDP transport (`src/network/connection.cpp`): packet framing, ACKs, resends, split reassembly |
| `SRP.swift` | the engine's login handshake (`src/util/srp.cpp`, SRP-6a); the player's password is never sent |
| `Client.swift` | the join sequence and message dispatch (`src/client/client.cpp`), then the game state: definitions, media, map, entities, HUD, inventories |
| `PacketReader/Writer.swift` | the wire serialisation (`src/util/serialize.h`) |
| `Opcodes.swift` | the TOCLIENT/TOSERVER message ids (`src/network/networkprotocol.h`) |
| `NodeRegistry`, `ItemRegistry` | NODEDEF / ITEMDEF parsing (`src/nodedef.cpp`, `src/itemdef.cpp`) |
| `MediaManager.swift` | the announce/request media download with SHA-1 content addressing |
| `TextureAtlas`, `TextureModifiers` | the engine's texture-modifier language (`[combine`, `[colorize`, ...) from `src/client/tile.cpp` |
| `WorldMap`, `WorldMesher` | map block storage and the mesh generation (`src/client/mapblock_mesh.cpp`, drawtypes from `content_mapblock.cpp`) |
| `B3DLoader`, `OBJLoader` | Irrlicht's model formats, for mobs and mesh nodes |
| `Formspec.swift` | the formspec UI description language (chests, furnaces, crafting) |
| `Zstd`, `Zlib`, `Vorbis` | the codecs the engine uses for blocks and sounds |

Test seams (`simulateServerPacket`, `handleForTesting`, `storeForTesting`) feed
locally-built data through the same parse paths the network uses so the
simulator and unit tests can exercise them without a headset or a socket.

Tests: `swift test` from this directory.
