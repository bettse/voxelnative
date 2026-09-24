# 🕶️🧱 A native Luanti client for Apple Vision Pro

Play Luanti / Minetest games in full immersion on Apple Vision Pro. 🎮 It is a
native Swift + Metal client that speaks the Luanti UDP protocol directly, so an
unmodified Luanti server hands you the whole game for free. Fully open source. ✨

It's built and tested against [VoxeLibre](https://git.minetest.land/VoxeLibre/VoxeLibre)
(the Minecraft-style flagship game), so that's where the UX polish is focused,
but the protocol layer is game-agnostic and will connect to any Luanti server.

🌐 **Website:** https://bettse.github.io/voxelnative/

> [!IMPORTANT]
> **🤖 AI disclaimer.** This project was built largely with the help of an AI
> coding assistant (an LLM). The code, comments, and this README may contain
> mistakes, half-truths, or things that drifted out of date. Please read the
> code and verify anything before you rely on it, and don't assume a described
> feature works exactly as written until you've seen it yourself. Bug reports
> and fixes are very welcome. 🙏

The client renders the real world in stereo with Compositor Services, streams
and meshes live map blocks, and lets you walk around, dig, place, and poke at
inventories using the PSVR2 Sense controllers (or a Bluetooth keyboard plus
gaze and pinch).

## 🚀 Why a whole new client

- 🐧 Luanti (formerly Minetest) has no iOS or visionOS build and no VR mode on
  any platform. Its renderer is OpenGL/Irrlicht, and visionOS has no OpenGL.
- 📺 Streaming tools (ALVR, Moonlight) only give you a flat window, not real
  stereo immersion.
- 🍰 VoxeLibre is pure Lua and runs unchanged on the server side, so a client
  that speaks the Luanti protocol gets the entire game with no server mods.

## 🎯 What works today

It connects to a Luanti server (VoxeLibre is the daily driver), streams the real
map, and renders it live in the headset. Highlights:

- 🌍 **World streaming and meshing**: live map-block decode (zstd + zlib) and a
  greedy-ish mesher that turns nodes into Metal geometry, with block unloading as
  you move.
- 🧱 **Real drawtypes**: normal cubes, nodebox slabs/stairs/walls/fences,
  plantlike, leaves with see-through allfaces, glasslike, torches, rails, fire,
  signs, beds, and more, plus facedir/wallmounted/4dir rotations.
- 🎨 **Real textures and tinting**: actual PNG textures from the server media
  pipeline packed into an sRGB atlas, texture modifiers (`^`, `[combine`,
  crops, colorize, etc.), and biome palette tinting (green grass and leaves,
  blue water).
- 💧 **Translucent water** and a **day/night sky** with sun, moon, stars, and
  clouds, plus per-node lighting and light-driven color.
- 🐷 **Entities and mobs** as real animated b3d models, with nametags, sprite
  animations, texture-mod overlays, and dropped items shown with their icons.
- 🧰 **HUD**: hotbar, wielded item, health/breath/armor/XP bars, hunger, and
  advancement toasts.
- 🎒 **Inventory and formspecs**: a working formspec renderer (lists, labels,
  buttons, fields, images, item images, tooltips, checkboxes, containers,
  listrings) so chests, furnaces, the crafting grid, enchanting tables, anvils,
  beacons, and the creative menu all function, with client-side inventory
  prediction to match desktop feel. 3D isometric icons for node items.
- 🔊 **Audio**: decodes Ogg Vorbis sounds ourselves (AVFoundation cannot), with
  a master/music/sfx volume model and node-sound prediction.
- 🏃 **Physics and locomotion**: gaze-relative walking, jumping, sprinting,
  sneaking, swimming, climbing ladders/climbables, and collision against real
  node collision boxes.
- 🖐️ **Input**: PSVR2 Sense controllers (6DoF, sticks, triggers, grips,
  buttons, and haptic feedback on dig/hit/damage where the controller supports it). A Bluetooth
  keyboard works as the alternative, using desktop Luanti's keys, with gaze to aim and a pinch to
  click. Mice and trackpads don't reach a fully immersive app on visionOS, so they aren't supported.

Still a work in progress and rough in places, but the core loop of joining a
server and playing is real. 🛠️

## 🗂️ Repo layout

- `native/` 🍎 the visionOS app (`VoxelNative`) and the LuantiKit package.
  - `native/Sources/`: the app: immersive Metal renderer (`Renderer.swift`),
    the world session that drives the client (`WorldSession.swift`), input
    (`GameInput.swift`), audio (`AudioManager.swift`), player physics
    (`PlayerState.swift`), the SwiftUI launcher (`ContentView.swift`), and app
    setup (`App.swift`, `AppModel.swift`).
  - `native/LuantiKit/`: a Swift package that is a standalone **Luanti protocol
    client**: UDP transport and reliability (`Connection.swift`), SRP-6a auth
    (`SRP.swift`), the high-level client (`Client.swift`), NODEDEF/ITEMDEF
    registries, media, world map + mesher, texture atlas, formspecs, active
    objects, b3d/obj loaders, and zstd/zlib. Builds for macOS and visionOS.
  - `native/docs/`: reference screenshots and checklists (sim-test checklist,
    HUD review, desktop parity refs).
- `notes/` 📓 research writeups: `luanti-protocol.md` (wire formats),
  `ui-textures-models.md` (formspecs, HUD, texture modifiers, b3d),
  `native-visionos-assessment.md`, `prior-art.md`.
- `tools/` 🔧 the local VoxeLibre dev server, media server, and join-fixture capture.
- `repos/` 📚 upstream repos cloned just for reading (not vendored): `luanti`
  (engine source, protocol in `src/network/`) and `miney` (a Python protocol
  client, proof the protocol works from outside the engine).

## 🏗️ Build and run

You need a Mac with Xcode 26, `xcodegen` on your PATH, and (for the headset) a
paired Apple Vision Pro. The Xcode project is generated from
`native/project.yml`, so run `xcodegen generate` in `native/` (the scripts below
do this for you) and open `VoxelNative.xcodeproj`.

Handy helpers, all run from `native/`:

- 🖥️ `./sim.sh`: build for the visionOS Simulator, launch, and screenshot the
  immersive view. No headset needed. It passes `-vrdev.*` dev flags to auto-connect
  and fake up a wield item so the headless loop can render something. The app log
  lands in the sim container at `Documents/native.log`.
- 🥽 `./deploy.sh [--force]`: build and install on the paired Vision Pro. It is
  **install-only**: it never auto-launches (the launch handshake hangs on this
  connection, so you launch from the headset yourself), and it skips the install
  if the app looks like it is currently running (a live test) unless you pass
  `--force`. It also works around the Xcode 26 clang-probe deadlock.
- 🧑‍🍳 `make` targets wrap the common chores: `make sim`, `make deploy`,
  `make devlog` (pull the headset's log + screenshots), `make test`, and
  `make integration`. Run `make help` to list them.

Server-side, `tools/server.sh` runs a local VoxeLibre dev server (config in
`tools/server.conf`) and `tools/media_server.py` serves media over HTTP. In the
simulator the app connects to `127.0.0.1`; on device you enter your server's
address on the launcher screen (there's no baked-in default).

## 🧪 Tests

LuantiKit has a real test suite (protocol codecs, drawtype meshing, formspecs,
inventory prediction, SRP auth, b3d animation, and more). Run them from
`native/LuantiKit/`:

```sh
swift test
```

There is also an integration test that joins a running dev server with a
throwaway account and checks auth/spawn/block streaming:

```sh
LUANTI_DEV_SERVER=127.0.0.1:30000 swift test --filter DevServerJoinTests
```

`luantikit-joincheck` is a small macOS CLI target for headless protocol checks
against your own local dev server (`tools/server.sh`) without any of the
graphics: it performs the same join sequence as the official client and prints
what streamed in. It's a separate package target and isn't part of the app.

## 📋 Requirements

- 🥽 Apple Vision Pro running visionOS 26+ (the app targets visionOS 26).
- 🖥️ A Mac with Xcode 26 and `xcodegen` for building and deploying.
- 🌐 A reachable Luanti / VoxeLibre server (a local dev server works great).
- 🎮 Optional: PSVR2 Sense controllers for the best experience. A Bluetooth
  keyboard also works (gaze aims, pinch clicks); mice and trackpads don't.

## 🔗 Key references

- Luanti protocol outline (incomplete): `repos/luanti/doc/protocol.txt`. The real
  spec is the C++ in `src/network/`.
- VoxeLibre: https://github.com/VoxeLibre/VoxeLibre
- Compositor Services (immersive Metal):
  https://developer.apple.com/documentation/compositorservices/drawing-fully-immersive-content-using-metal
- Spatial accessory input (PSVR2), WWDC25 session 289:
  https://developer.apple.com/videos/play/wwdc2025/289/

## ⚠️ Gotchas

- 🎮 On visionOS the PSVR2 gives 6DoF, buttons, sticks, and haptics (where the controller exposes them).
  Precision haptics and adaptive triggers do not come through.
- 🕳️ The depth buffer is used for reprojection, so a pixel at depth 0 gets
  dropped to black. The sky pass writes a tiny non-zero depth to avoid that.
- 🎨 The texture atlas must be sRGB (`rgba8Unorm_srgb`) while the drawable is
  linear.
- 👀 The server frustum-culls block streaming toward your reported look
  direction, so the client sends head yaw/pitch in PLAYERPOS.

## 📜 License

The code in this repository is licensed under the **GNU Lesser General Public
License v2.1 or later** (LGPL-2.1+) — see [`LICENSE`](LICENSE). That matches
the Luanti / Minetest engine (also LGPL-2.1+) whose network protocol this client
reimplements from scratch in Swift.

This is a clean-room reimplementation of the Luanti wire protocol, not a
derivative of the engine's C++ source. It bundles no game content: VoxeLibre and
Luanti textures, sounds, models, and Lua are downloaded from the server you
connect to and remain under their own licenses (CC BY-SA 3.0/4.0, GPL, etc.).
The only game assets committed here are a couple of small mesh files under
`native/LuantiKit/Tests/.../Fixtures/` used by the unit tests; those are from
VoxeLibre (© its authors, CC BY-SA 4.0) and are included for testing only.
