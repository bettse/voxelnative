# Native visionOS implementation: feasibility assessment

Date: 2026-09-10. Written after the Godot 4.8-dev4 path hit a wall: its
pre-release visionOS renderer cannot build the foveated immersive framebuffer
(see notes/plan.md "Known issues" and the memory `avp-black-world-root-cause`).
This assesses reimplementing the client natively in Swift + Metal.

## Spike result: PASSED (2026-09-10)

Phase 1 done and confirmed on device. A Swift + CompositorServices + Metal app
(native/) renders a rotating textured cube in full immersion with foveation on,
on the Vision Pro -- the exact thing Godot 4.8-dev4 could not do. Gotchas found:
Swift 5 language mode (the Apple template is not strict-concurrency clean), the
Metal toolchain must be downloaded (xcodebuild -downloadComponent MetalToolchain),
and the app Info.plist MUST declare an immersive scene in UIApplicationSceneManifest
(UIApplicationPreferredDefaultSceneSessionRole = CPSceneSessionRoleImmersiveSpaceApplication
+ a UISceneConfigurations entry with UISceneInitialImmersionStyle = UIImmersionStyleFull)
or openImmersiveSpace returns .error. Build/deploy: native/deploy.sh. The
rendering-path risk is retired; the rest is the client port (phases 2-6 below).

## Verdict

Native is feasible with no fundamental blockers. It replaces the two things
Godot was weakest at -- immersive rendering and PSVR2 input -- with shipping,
STABLE Apple frameworks (visionOS 26), instead of a dev-build engine module.
Everything else is a port of logic we have already written and debugged, with
a 40K-line protocol spec (notes/luanti-protocol.md) to work from.

## The stack (each layer, the framework, the risk)

- Immersive rendering: CompositorServices (`ImmersiveSpace` + `CompositorLayer`)
  driving Metal. This is Apple's official, documented path for fully immersive
  apps (WWDC23/24/25, "Drawing fully immersive content using Metal"). Its
  LayerRenderer configures foveation correctly by design -- the exact thing
  that crashes Godot's framebuffer is a first-class, working feature here.
  visionOS 26 changed the loop so `queryDrawables` returns 1-2 drawables. RISK:
  low; this is the intended API, but it is hand-written Metal, which is real work.
- Controllers: PSVR2 Sense controllers are NATIVELY supported in visionOS 26
  (Apple sells them for AVP). 6DoF tracking, capacitive finger touch, vibration,
  via the Game Controller framework. Not supported: the resistive triggers and
  precision haptics. RISK: low. This is cleaner than Godot's ARKit-accessory hack.
- Networking: Luanti's custom reliable UDP over `Network` framework
  (`NWConnection`, .udp). RISK: low. Straight port of scripts/net/luanti_connection.gd.
- Login crypto (SRP-6a): a Swift BigInt package with `power(exp, modulus)`
  modular exponentiation (e.g. leif-ibsen/BigInt or attaswift/BigInt) + CryptoKit
  for SHA-256. RISK: low. We already have the reference in srp.gd/bigint.gd and
  it is validated against a real server; the Swift libs remove the hand-rolled
  30-bit-limb bignum entirely.
- Compression: map blocks are zstd (proto 52+), older data and definitions are
  zlib. SWCompression (pure Swift) covers both; or Facebook's official zstd SPM
  package + Apple's Compression framework for zlib. RISK: low.
- Textures: node tiles in a Metal 2D texture array (`MTLTextureType.type2DArray`),
  the direct analog of the Godot Texture2DArray atlas. RISK: low.
- World meshing: port mesher.gd to build `MTLBuffer` vertex/index data per chunk.
  The algorithm (drawtypes, param2 rotation, palette tint, day/night light banks)
  is done and documented. RISK: medium -- most code, but no unknowns.
- SHA-1 for the media cache: CryptoKit `Insecure.SHA1`. RISK: none.

## What transfers vs. what is rewritten

Transfers (the expensive part, already paid):
- The protocol reverse-engineering and wire formats: notes/luanti-protocol.md
  (40K), notes/ui-textures-models.md, notes/godot-visionos.md. This is the spec.
- The GDScript client as a working REFERENCE IMPLEMENTATION and a desktop test
  bed for protocol changes -- keep it; it still runs against the dev server.
- Downloaded media assets and the dev server tooling (tools/).
- All the debugging knowledge: the string16-array u32 count, the trailing
  BLOCKDATA byte before zstd, faces toward unknown neighbours, etc.

Rewritten (in Swift): all ~6,760 lines of GDScript, but as a port, not research.
Rough surface by area: net 1509, content 1234, world 1086, ui 876, game/player/
interaction 1050, models 472, entities 372.

## Phased plan (feature parity with today's client)

1. Metal immersive spike: `ImmersiveSpace` + `CompositorLayer` rendering one
   textured, stereo, foveated cube on the device. Proves the exact thing Godot
   failed at. FIRST, because it retires the biggest risk. ~a few days.
2. Transport + SRP + join to CLIENT_READY + chat. ~1 week.
3. Definitions + media + texture array (with zstd/zlib). ~1 week.
4. Block decode + mesher -> Metal chunk meshes. Milestone: "stand in the world
   on the headset." ~1.5-2 weeks.
5. Player physics + locomotion + interaction (dig/place) + PSVR2 input mapping.
   ~1.5-2 weeks.
6. Entities (b3d/obj mobs), then formspec/HUD/inventory UI. ~2-3 weeks.

Rough total to parity: ~6-10 focused weeks; "in the world on the headset"
(phases 1-4) is reachable in ~3-4 weeks, faster than a from-scratch client
because the logic and protocol are already solved.

## Recommended first step

Build phase 1 only: a minimal Swift/Metal ImmersiveSpace that renders a single
textured cube in stereo with foveation on the actual device. It is small, and a
pass/fail on it tells us definitively that the native rendering path works
before committing to the full port. If the cube renders in the headset, the
strategy is sound and we proceed phase by phase.

## Risks / unknowns

- Hand-written Metal stereo rendering is more code than an engine gives you;
  the spike de-risks it early.
- PSVR2 trigger resistance and precision haptics are unavailable natively (Apple
  limitation) -- our button mapping already only needs digital triggers/grips.
- No third-party engine means no free physics/scene graph; the client is simple
  enough (a voxel world + a character controller) that this is manageable, and
  the GDScript version shows exactly what is needed.
- Effort is real (weeks), but it is the only path that does not depend on
  pre-release software for the core goal.
