# visionOS Simulator test checklist (native Luanti / VoxeLibre client)

Goal: catch visual and logic bugs in the headless simulator **before** they reach the physical Vision Pro. Two bugs that should have been caught here and weren't — the **wielded chest rendered at the wrong (huge) size** and the **inventory chest icon rendered flattened** — are called out inline below with the exact setup that would have surfaced them.

## How the sim is driven

`native/sim.sh` builds for the sim (UDID `AAA51166-3572-43B8-9B71-9090483A2301`), installs, launches with a fixed set of dev flags, waits 14 s, and screenshots to `/tmp/voxel_sim.png`:

```
xcrun simctl launch <SIM> dev.ericbetts.voxelnative \
  -vrdev.autoConnect 1 -vrdev.day 1 -vrdev.fakeWield 1 -vrdev.fakeXp 1 \
  -vrdev.fakeNametag 1 -vrdev.fakeHud 1  <SIM_EXTRA_ARGS...>
```

Add flags via `SIM_EXTRA_ARGS` (space-split). A later `-vrdev.X 0` overrides a baked-in default:

```
SIM_EXTRA_ARGS="-vrdev.spawnMob 1 -vrdev.fakeNametag 0" ./sim.sh
SIM_EXTRA_ARGS="-vrdev.pitch -45 -vrdev.fakeWield 0" ./sim.sh /tmp/beds.png
```

Where to read results:
- **Screenshot:** `/tmp/voxel_sim.png` (or the 2nd arg to `sim.sh`). If the 14 s capture landed before the world streamed in (dark/see-through faces), take a later one of the same run: `xcrun simctl io <SIM> screenshot /tmp/later.png`.
- **Log:** app stdout goes to `Documents/native.log` in the app container, NOT the console:
  `cat "$(xcrun simctl get_app_container booted dev.ericbetts.voxelnative data)/Documents/native.log"`. Logic aids (`[simcmd]`, `[eattest]`, `[simmob]`, `[simride]`, `[realhud]`, `[hotbar]`) print there.

Prereqs (see `sim-passthrough-washout` memory): the dev server must be up (sim connects to `127.0.0.1`), and each run needs a **unique** player name or the server denies the relaunch (ACCESS_DENIED 8) until the old peer times out (~30 s). `sim.sh`/ContentView use a random `vrdev-XXXX`; override with `-vrdev.name <name>`.

Real server-driven scenes (`vrdev-world-testing` memory): the dev world is fair game to modify. Use `-vrdev.cmd "cmd1;;cmd2"` (";;"-separated chat commands, fired once the player exists) for `/grantme all`, `/giveme`, `/teleport`, `/setblock`, creative. These beat local node injection, which lands buried at the busy jungle spawn.

---

## Every existing `-vrdev.*` hook (what each lets you verify headlessly)

Connection / camera / render:
- `vrdev.autoConnect 1` — skip the launcher, connect straight to the selected server.
- `vrdev.name <s>` — force the player name (avoid same-name reconnect denial).
- `vrdev.day 1` — force full daylight so interiors/mobs aren't lost to night.
- `vrdev.pitch <deg>` / `vrdev.yaw <deg>` — rotate the fake head (and the head-locked hands with it). Look up (`60`) for sky, down (`-45`/`-85`) for floor scenes.
- `vrdev.noFakeHands 1` — hide the stub hands.
- `vrdev.noCull 1` — disable back-face culling (debug see-through geometry).
- `vrdev.keepShots 1` — don't clear old screenshots at launch.

HUD / wield stubs (dev account inventory is empty, so these fake what never shows):
- `vrdev.fakeWield 1` — stub a **cube** wield (dirt/grass/stone) + wrist hotbar cells + per-cell wear + a "64" stack count + armor 15 + full-bright wield.
- `vrdev.fakeWieldItem 1` — force the **item/tool** wield path (extruded pickaxe silhouette) instead of a cube.
- `vrdev.fakeSwing 1` — force the dig swing animation on the wield.
- `vrdev.fakeXp 1` — stub XP level 7 @ 60%.
- `vrdev.fakeNametag 1` — a "Steve" nametag 3 nodes ahead.
- `vrdev.fakeHud 1` — a boss bar (Ender Dragon) + a potion-effect element.
- `vrdev.realHud 1` — inject the REAL server HUDADD packets (armor statbar id 300, XP level text id 301) through the actual parse path, as they arrive on device.

Panels / formspecs:
- `vrdev.openInventory 1` — open the player inventory panel ~8 s in.
- `vrdev.fakeStation 1` — open a canned station formspec (cartography-table labels + a small list) to check formspec label/list layout.
- `vrdev.openKeyboard 1` — pop the on-screen keyboard (prefilled "hello world") ~6 s in.

Scene aids (locally injected nodes/entities; re-assert against server streaming where noted):
- `vrdev.spawnMob 1` — a row of 6 texture-tricky mobs (cow w/ walk+head-swivel, skeleton, horse composite skin, zombie, witch, pitched arrow) at distinct yaws + a dropped dirt node and a dropped diamond pick.
- `vrdev.spawnBed 1` — 4 beds (each foot+head mesh nodes), one per facedir 0..3, on a carved stone floor.
- `vrdev.spawnGlass 1` — a 3×3 red stained-glass wall with a gold wall behind it (translucency check); re-asserts over ~3.5 s so server streams don't overwrite it.
- `vrdev.spawnRails 1` — a straight run, an L-corner, a T, and a cross of rails in a carved pit (view from above with `-vrdev.pitch -85`).
- `vrdev.rideTest 1` — inject a vehicle AO ahead+up and attach the player to it.
- `vrdev.eatTest 1` — the hold-to-eat state machine: gives golden apples, drives the place-hold, logs stack count before/after (verifies mechanic, not the hand-at-mouth geometry).

Server-driven:
- `vrdev.cmd "c1;;c2"` — fire chat commands after spawn (real server-streamed scenes).

---

## 1. Wielded item rendering (scale + pose)

Verify the item in the hand matches desktop scale/pose for each item class. The wield path has three branches: **cube** (normal-drawtype nodes), **mesh** (mesh-drawtype nodes: chest, bed), and **item** (tools/craftitems, extruded from the icon). The mesh branch is the one that shipped broken.

- [ ] **Cube node wield (baseline).** `./sim.sh` (fakeWield is on by default). Look for: a dirt/grass cube in the hand at roughly one-node scale, shaded, not clipping the face. Log: none needed.

- [ ] **Tool/item wield.** `SIM_EXTRA_ARGS="-vrdev.fakeWieldItem 1" ./sim.sh /tmp/wield-tool.png`. Look for: an extruded pickaxe silhouette (a shaped tool, not a flat square or a solid cube), held at a plausible angle.

- [ ] **Swing animation.** `SIM_EXTRA_ARGS="-vrdev.fakeSwing 1" ./sim.sh`. Look for: the wield tilted/mid-swing rather than at rest.

- [ ] **MESH-node wield (chest) — the size bug.** fakeWield can't reach the mesh branch (it only stubs cubes/items), so use the real inventory path:
  `SIM_EXTRA_ARGS='-vrdev.fakeWield 0 -vrdev.cmd /giveme mcl_chests:chest 1' ./sim.sh /tmp/wield-chest.png`
  (giveme lands the chest in main slot 0; wieldIndex defaults to 0, so the real `.mesh` wield branch draws it.) Look for: a **single-node-sized** chest model in the hand. **A chest that fills the view / dwarfs the hand is the size bug.** Compare against the cube-wield scale from the baseline shot. Also verify the model is a chest (textured b3d), not a fallback flat icon.
  - Note: this needs the chest's `.b3d` to have downloaded; if it shows a flat icon instead, the model hadn't arrived — take a later screenshot.
  - Gap: there is no one-flag way to force-wield an arbitrary mesh node. See "Suggested new sim hooks" (`-vrdev.wield <itemstring>`).

- [ ] **MESH-node wield (bed).** Same pattern with `mcl_beds:bed_red`. Look for: bed model at node scale in hand, not oversized.

- [ ] **Wield light shading.** Non-fakeWield runs shade the wield by the light at the eye node. In a lit area it should look lit; verify it isn't rendering full-bright and reading as if it emits light.

---

## 2. Inventory / formspec rendering

- [ ] **Player inventory layout.** `SIM_EXTRA_ARGS="-vrdev.openInventory 1" ./sim.sh /tmp/inv.png`. Look for: the 9×N grid, hotbar row, armor slots, crafting grid + output cell, all aligned; no blank cells where an item exists.

- [ ] **Inventory icon for a MESH node (chest) — the flattened-icon bug.** The icon rule is: item `inventory_image` if present, else the node's **first flat face tile** (`nodeIconTile`). Mesh nodes like the chest usually have no `inventory_image`, so they fall back to a **flat 2D face** instead of desktop's 3D isometric render.
  `SIM_EXTRA_ARGS='-vrdev.openInventory 1 -vrdev.cmd /giveme mcl_chests:chest 5' ./sim.sh /tmp/inv-chest.png`
  Look for: the chest cell. **A flat single-face square (a plank-like texture) is the flattened-icon bug** — desktop shows a 3D chest. Confirms whether the client needs an isometric cube/mesh icon renderer for mesh/normal nodes lacking an inventory_image.

- [ ] **Icon for a normal cube node.** Same run — check a dirt/stone cell (`/giveme mcl_core:dirt 64`). Even a plain cube shows as a flat top-face tile here vs. desktop's 3D cube; decide if that's acceptable or also needs the iso renderer.

- [ ] **Item icons (tools/craftitems).** `-vrdev.cmd "/giveme mcl_tools:pick_diamond 1;;/giveme mcl_core:apple 20"`. Look for: real inventory_image icons, correct aspect (not stretched/flattened), stack count "20" on the apple.

- [ ] **Station / container formspec layout.** `SIM_EXTRA_ARGS="-vrdev.fakeStation 1" ./sim.sh /tmp/station.png`. Look for: labels ("Cartography Table", "Map", "Paper") positioned correctly, the player-inventory list rendered below. This is a canned formspec — it does NOT exercise a real chest/furnace UI (see gaps).

- [ ] **Real container UI (chest/furnace) — gap.** No current flag opens a real container formspec headlessly (opening one needs a right-click gesture on a placed node, which the sim can't deliver). Workaround requires manual placement on device. See "Suggested new sim hooks" (`-vrdev.openContainer`).

- [ ] **Crafting output cell.** With items in the crafting grid via a formspec, verify the `craftpreview` output cell renders and the craft-to-hand pickup works (log the inventory action). Limited headless because grid placement needs clicks.

- [ ] **Armor slots.** `SIM_EXTRA_ARGS="-vrdev.realHud 1" ./sim.sh` shows the armor statbar; for the inventory armor SLOTS, giveme armor pieces and open inventory: `-vrdev.cmd "/giveme mcl_armor:chestplate_diamond 1"`. Verify the armor slot column renders the piece icons.

- [ ] **On-screen keyboard layout.** `SIM_EXTRA_ARGS="-vrdev.openKeyboard 1" ./sim.sh /tmp/kbd.png`. Look for: full key grid, prefilled "hello world" text, no clipped rows.

---

## 3. Dropped-item entities

- [ ] **Dropped node + dropped tool.** `SIM_EXTRA_ARGS="-vrdev.spawnMob 1" ./sim.sh /tmp/drops.png` (spawnMob also spawns a dropped dirt node and a dropped diamond pick). Look for: the dirt drops as a small 3D **cube** (node-cube fallback), the pick as its flat inventory image; neither invisible/white.

- [ ] **Real server drop via auto-dig — gap.** `-vrdev.fakeSwing` only animates; it doesn't actually dig. There's no flag that digs a node and produces a real server `__builtin:item` drop. To get a real drop you'd `/giveme` + place + dig, which needs gestures. See "Suggested new sim hooks" (`-vrdev.autoDig`).

---

## 4. Drawtypes

- [ ] **Mesh nodes (bed).** `SIM_EXTRA_ARGS="-vrdev.spawnBed 1 -vrdev.pitch -45" ./sim.sh /tmp/beds.png`. Look for: 4 beds, one per facedir 0..3, correct foot/head seam, the 64px UV sheet's TOP texture correct (not stretched), no gap between halves.

- [ ] **Glass / alpha (translucency).** `SIM_EXTRA_ARGS="-vrdev.spawnGlass 1" ./sim.sh /tmp/glass.png`. Look for: the gold wall tinted **red through** the glass — not an opaque pane and not a holey one. (Valid in sim because there's opaque geometry behind it; per `sim-passthrough-washout`, only alpha with NOTHING behind it is misleading in the sim.)

- [ ] **Rails (raillike connection/rotation).** `SIM_EXTRA_ARGS="-vrdev.spawnRails 1 -vrdev.pitch -85" ./sim.sh /tmp/rails.png`. Look for: straight run flat; the L-corner curving toward BOTH neighbours (a wrong bend = the Z-mirror flip); T and cross tiles correct.

- [ ] **Plantlike / crops, nodebox (fences/walls/buttons), torches, liquids — gap in one-flag coverage.** No dedicated spawn aid; use `-vrdev.cmd` to build a real scene:
  `SIM_EXTRA_ARGS='-vrdev.cmd /grantme all;;/giveme mcl_fences:fence 20;;/giveme mcl_torches:torch 20;;/giveme mcl_flowers:tulip_red 20' ./sim.sh`
  then place them on device — or `/setblock` them in front and screenshot. Look for: fences connecting to neighbours (nodebox), torches attached at the right angle, plantlike crops as crossed billboards (not flat squares), liquids with a flowing surface. Note: placement generally needs a gesture, so `/setblock <pos> <node>` via `-vrdev.cmd` is the headless route.
  Example fully headless liquid check: `-vrdev.cmd "/teleport 0 200 0;;/setblock 0 199 2 mcl_core:water_source"` then `-vrdev.pitch -30`.

---

## 5. Mobs

- [ ] **Rendering + textures (no blank/white surfaces).** `SIM_EXTRA_ARGS="-vrdev.spawnMob 1" ./sim.sh /tmp/mobs.png`. Look for: cow, skeleton, horse (composite base^markings skin resolves — not blank), zombie, witch all textured; no all-white surfaces (the multi-surface skin case, #72).

- [ ] **Ground placement.** Look for: each mob's feet on the ground, not floating or half-sunk (collisionbox top drives the fit, #67).

- [ ] **Facing (yaw).** Mobs spawn at distinct yaws (0/90/180/270). Look for: each faces a different direction; yaw 90 and 270 must NOT look identical (mirror bug, #91).

- [ ] **Pitch (arrow).** The arrow spawns at pitch 40. Look for: its shaft tilted off horizontal while the pitch-0 mobs stay upright (#128).

- [ ] **Walk animation + head-swivel (cow).** Take two screenshots a second apart of the same run; the cow's legs should differ (walk anim, #82) and its head is swiveled 40° (#124).

- [ ] **Nametag.** Look for: "Bessie"/"Skeleton"/etc. labels above the mobs, legible, billboarded toward the camera (#118).

- [ ] **Hit flash — gap.** No flag triggers a damage flash on a mob. Would need a hurt/animation message injection. See "Suggested new sim hooks".

---

## 6. Physics the sim CAN exercise against the real server

These run the real server physics; verify by screenshot AND by the player position in `native.log`.

- [ ] **Spawn-embed / unstick.** `-vrdev.cmd "/teleport 0 200 0"` into open air, or `/setblock` the player into stone then confirm the client pushes out. Look for: the camera ends up standing on a surface, not buried (black faces all around) or falling forever.

- [ ] **Teleport-into-terrain.** `-vrdev.cmd "/teleport <x> <y> <z>"` into a hillside; verify the client resolves to a valid standing position (groundHeight scan) rather than clipping inside.

- [ ] **Climbable ladders.** `-vrdev.cmd "/grantme all;;/giveme mcl_core:ladder 10"` + place a ladder column (or `/setblock`), then verify climb. Note: sustained climb needs a movement input the sim can't script per-frame; this is partially headless. See gaps.

- [ ] **Sneak edge-glue.** Requires holding sneak while walking off an edge — needs scripted movement input the sim lacks. Currently device-only. See "Suggested new sim hooks" (`-vrdev.walk`).

- [ ] **Movement resistance (water/cobweb/soul sand).** `/setblock` the medium in front, teleport in, and read the position delta over time in the log. Screenshot shows the medium; the resistance itself reads from log position rate.

- [ ] **Ride / attach.** `SIM_EXTRA_ARGS="-vrdev.rideTest 1" ./sim.sh /tmp/ride.png` + log `[simride]`. Look for: the camera snaps UP onto the vehicle (higher eye height) instead of staying on the ground.

- [ ] **Hold-to-eat mechanic.** `SIM_EXTRA_ARGS="-vrdev.eatTest 1" ./sim.sh` then grep the log for `[eattest]`. Look for: the golden-apple stack count DROPS by 1 after the hold (mechanic works); the hand-at-mouth geometry is device-only.

---

## 7. HUD

- [ ] **Hearts / hunger / breath.** Default `./sim.sh` draws the stat rows. Look for: 10 hearts + 10 hunger drumsticks, correct icons, positioned bottom-center; breath bubbles when applicable.

- [ ] **XP bar.** `-vrdev.fakeXp 1` (default) stubs level 7 @ 60%. Look for: the green XP bar 60% filled with "7". For the REAL packet path use `-vrdev.realHud 1` (level "12").

- [ ] **Armor statbar.** `SIM_EXTRA_ARGS="-vrdev.realHud 1" ./sim.sh`. Look for: the armor row (16 half-icons, 20/... ) above the health, from the real HUDADD packet (#108).

- [ ] **Boss bar + potion effect.** `-vrdev.fakeHud 1` (default). Look for: the Ender Dragon boss bar at top and a potion-effect indicator.

- [ ] **Hotbar (head-locked) + selection.** Default run. Look for: the hotbar row with the selected cell highlighted; cycle with the X/O buttons if a controller is present (`[hotbar]` in log).

- [ ] **Wrist hotbar + wield count + per-slot wear.** `-vrdev.fakeWield 1` (default) draws the wrist ring with cells, a "64" count on the wield, and varied wear bars across the first cells (#106, #158, #57, #66). Look for: the ring anchored to the hand, wear bars at different fills, the count legible.

---

## What the sim CANNOT judge (do NOT rely on it here)

- **True VR scale / comfort / depth.** The sim renders a 2D framebuffer; the wield/HUD/mob sizes give a rough read but the actual felt scale, stereo depth, and comfort are device-only. (The chest-size bug was visible as a *relative* scale error, but final calibration is on-device.)
- **Passthrough translucency against an EMPTY background.** Where the game frame is transparent, the sim paints its checkerboard passthrough stand-in (brown/white squares), which differs from the device's skybox/black. Alpha drawn *against opaque game geometry* IS judgeable (see the glass test); alpha with nothing behind it can mislead.
- **Controller feel / gestures.** PSVR2 Sense controller input, haptics, grip/trigger feel, hand tracking, and gesture-driven actions (right-click to open a chest, hand-at-mouth eating) are not deliverable headless.
- **Mouse / keyboard input.** `GCMouse` / `GCKeyboard` events are not delivered to the sim (the sim also reports a phantom `GCController`). Anything gated on real HID input can't be exercised; use the scripted `-vrdev.*` aids instead.
- **Head-tracking / re-anchoring nuance.** In the sim the device anchor is present but untracked; head-pose is faked via `-vrdev.pitch/yaw` (which move the hands with the view), so you can't frame the hands independently or test real head re-anchoring.

---

## Suggested new sim hooks (small `-vrdev.*` flags that would close a gap)

Each would make a currently-awkward or device-only check a one-line headless screenshot.

- **`-vrdev.wield <itemstring>`** — force any named item into the hand (set inventory slot 0 + wieldIndex 0, bypass fakeWield). Would make the **wielded-chest size** (and any mesh/tool/node wield) a one-flag check instead of the `fakeWield 0 + giveme` dance. Verifies: the `.mesh` wield branch at correct scale for chest/bed/any mesh node.

- **`-vrdev.openContainer <nodename>`** — place the node in front, then open its real container formspec (chest/furnace/anvil) without a right-click gesture. Verifies: real container UI layout, container inventory list, item icons inside a chest — none of which `fakeStation`'s canned spec covers.

- **`-vrdev.autoDig 1`** (or `-vrdev.dig <nodename>`) — actually dig a node in front so the server sends a real drop entity. Verifies: the full dig -> crack overlay -> node removal -> server drop pipeline and real dropped-item rendering, vs. today's animation-only `fakeSwing`.

- **`-vrdev.walk "<dir> <nodes>"`** — script a movement input for N nodes. Verifies: sneak edge-glue, sustained ladder climb, movement resistance rate, step-up — all currently blocked because the sim delivers no per-frame movement input.

- **`-vrdev.mobHurt <id>`** — inject a hurt/animation message on a spawned mob. Verifies: the damage hit-flash tint (currently untestable headless).

- **`-vrdev.spawnPlants 1` / `-vrdev.spawnNodebox 1`** — dedicated scene aids (like spawnBed/spawnGlass/spawnRails) for plantlike crops and nodebox fences/walls/buttons/torches, so those drawtypes get a reliable, re-asserting headless scene instead of hand-built `-vrdev.cmd /setblock` chains.

- **`-vrdev.isoIcon 1`** — render inventory/hotbar icons for icon-less nodes as a 3D isometric cube/mesh (desktop parity). Would let a screenshot confirm the **flattened chest icon** is fixed rather than only confirming the flat fallback is wrong.
