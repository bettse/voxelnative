# Prior art (web search, 2026-09-09)

Question: has a VR client for Luanti, a Luanti client on Apple Vision Pro,
or a third-party Luanti protocol client been built before?

Short answer: nobody has combined Godot, Luanti and Vision Pro. The halves
exist separately and are all weeks old.

## Most relevant

1. **Goanna** (p0ss, https://github.com/p0ss/Goanna, created 2026-08-16,
   v0.6.1-alpha 2026-09-02, LGPL-2.1+). A Luanti client as a Godot 4.5
   GDExtension: compiles Luanti's own networking, SRP, definitions, mapblock
   meshing, collision and the Irrlicht b3d/x/obj/glTF loaders from a Luanti
   submodule into a static library; Godot renders. Protocol coverage is
   broad (blocks, entities with skeletal animation, sounds, HUD, formspecs,
   dig/place). Linux only, Forward+/Vulkan only by design, ~2.4 GB VRAM,
   no XR. Tested mostly with Mineclonia; mentions VoxeLibre.
   Why it matters: proof the whole client can live inside Godot, and its
   `cmake/luanti_core.cmake` + `src/transplant/` layout is a recipe if we
   ever want native meshing. Obstacles for us: C++ build for visionOS,
   Forward+ only (visionOS XR needs Mobile), LGPL, alpha.
2. **paradust7/luanti `xr` branch** (https://github.com/paradust7/luanti/tree/xr,
   https://dustlabs.io/minetestvr.html). OpenXR inside the C++ client
   (IrrlichtMt OpenXR session, grip/aim actions, stereo render path). PCVR
   alpha since 2024; standalone Quest build added 2026-08. No Vision Pro,
   no controllers beyond laser pointer. Reference for how they put Luanti's
   camera, HUD and formspecs into stereo.
3. **Luantium** (https://github.com/gitmaster12345677808/Luantium,
   2026-08-29). Another OpenXR fork for standalone Quest/Pico with APKs.
   Brand-new account; hasn't been vetted, so approach with the usual caution.
4. **HimbeerserverDE/mt** (Go, MIT, tracks Luanti 5.17). The most complete
   external wire-format implementation (rudp, all commands, mapblocks,
   defs, media, entities, inventory, formspec). Best reference if a field
   layout is in doubt.
5. **luanti-rs** (Rust, MIT, https://github.com/kawogi/luanti-rs) plus
   **cubetonic** (https://github.com/grorp/cubetonic, a Luanti core dev's
   wgpu client experiment, 2025). Protocol crates work; client is a toy.

## Also seen

- Luanti issues #8586 (VR, open since 2019, no activity), #14315 (closed),
  #9835 "port to Godot" (closed, won't add). Core devs are not pursuing VR.
- No visionOS project of any kind for Luanti, Minetest or MultiCraft.
- Other protocol libs: minetest-go/minetest_client (Go, WIP),
  otterminetest/luanti_ts (TypeScript, unmaintained), MinetestProtocolJ
  (Java, early), miney (Python, needs a server mod for most features).
- DonFlymoor/minetest-openXR is a name-only fork with no XR code.
- No Godot b3d importer exists anywhere; Goanna compiles Luanti's.

## What this changes for us

Nothing in direction. It confirms the pure-GDScript, Mobile-renderer,
MIT approach is the only one that fits visionOS, and gives two references
to read when stuck: Goanna for Godot-side structure and HimbeerserverDE/mt
for wire formats.
