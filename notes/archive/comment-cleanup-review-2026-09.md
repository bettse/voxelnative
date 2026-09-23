> Snapshot of a 2026-09 comment review; line numbers and symbol names predate the `debugAuto*` -> `simAuto*` rename and are not current. Kept for history only.

# Comment cleanup review

Scope: comments in `native/Sources/*.swift`, `native/LuantiKit/Sources/LuantiKit/*.swift`,
and `native/Sources/*.metal` / `*.h`. No code was changed.

## Bottom line

The comments here are, overwhelmingly, the good kind: they explain WHY, name the
gotcha (protocol quirks, the left-handed/right-handed mirror, device-vs-sim
differences, the +0.5 grid shift, reprojection ghosting), and tie fixes to issue
numbers. I did not manufacture work — there is not much to clean up. The real
finds are a handful of stale/dead items and some leftover diagnostic scaffolding.
There is **no commented-out dead code** anywhere in scope (a heuristic scan for
commented-out statements returned only prose false positives).

Findings are ranked by value: stale/misleading first, cosmetic last.

---

## 1. Stale / misleading comments (highest value)

### 1a. `debugAutoWalk` doc comment contradicts the code
`Sources/WorldSession.swift:233-240`

```
/// Auto-walk only in the simulator (no controller there) so screenshots
/// still show motion. On device, movement comes from the controller.
#if targetEnvironment(simulator)
private let debugAutoWalk = false   // stand still at spawn for stable shots
#else
private let debugAutoWalk = false
#endif
```

The doc comment says auto-walk happens in the simulator "so screenshots still
show motion," but the sim branch is set to `false` and its own inline comment says
the opposite ("stand still at spawn for stable shots"). Both `#if`/`#else`
branches are `false`, so the conditional is a no-op. Either the doc comment is
stale (auto-walk is off everywhere now) or the sim value should be `true`. As
written, the top comment misdescribes the behavior.

### 1b. "kept only until the liquid path moves over" — the liquid path already moved
`Sources/WorldSession.swift:2847`

```
/// (Superseded by collideMove; kept only until the liquid path moves over.)
private func bodyHitsSolid(...)
```

The liquid/swim path at `WorldSession.swift:604-608` already resolves horizontal
movement through `collideMove` (see its own comment there about swept collision
for swimming). `bodyHitsSolid` has no remaining callers (grep: only the
definition). So the "kept until the liquid path moves over" condition is already
met — the comment is stale and the function is now dead (see 2a).

---

## 2. Dead code the comments already flag

### 2a. `bodyHitsSolid` is unreferenced
`Sources/WorldSession.swift:2847-2867`
No callers remain (see 1b). Whole function is dead and can go.

### 2b. `appendHotbarHUD` is unreferenced
`Sources/WorldSession.swift:1649-1689` (8-line doc comment at 1649-1656 + body)
The head-locked hotbar was replaced by the wrist-anchored one, which the code even
says out loud at `WorldSession.swift:1466`:
`// Hotbar is now wrist-anchored (postHandHud / buildHandHud), not head-locked.`
`appendHotbarHUD` has no callers (its sibling stat HUDs — `appendHealthHUD`,
`appendHungerHUD`, `appendBreathHUD`, `appendArmorHUD` — are all still called at
1462-1465; this one is not). The function and its long doc comment are dead.

### 2c. `crossDist` is computed (with a raycast) and thrown away
`Sources/WorldSession.swift:1441-1445`, discarded at `1459` (`_ = crossDist`)
The comment at `1454-1458` is honest about it:
`// crossDist is still computed above for nothing here; kept only if a future
overlay wants the aim depth.` This runs a `client.world.raycast` every frame whose
only consumer is a discarded local. If no crosshair overlay is coming back soon,
delete the computation; the comment is accurate but documents dead work.

---

## 3. Leftover debug / diagnostic scaffolding

These look left behind from closed investigations. All are either simulator-only,
dev-flag-gated, or one-shot, so none is harmful in a shipping build — but they read
as abandoned debugging tagged to bugs that appear resolved. (The intentional
`-vrdev.*` aids — autoConnect, openInventory, openKeyboard, day, fakeHands,
fakeWield, noFakeHands — are documented and should stay.)

### 3a. PROBE (#115) hand-HUD blocks
- `Sources/Renderer.swift:555-563` — `vrdev.hudProbe`, a bright test quad, sim-only.
- `Sources/Renderer.swift:1388-1401` — `vrdev.hudSwap`, binds the head-locked HUD
  buffers into the hand-HUD draw to A/B the two paths, sim-only.
- `Sources/Renderer.swift:616-619` and `1380-1383` — `[handhud-sim]` / `[handhud-draw]`
  `print` diagnostics, sim-only.

All four are the #115 hand-HUD investigation. The hand HUD renders now, so these
are candidates to remove.

### 3b. `[door]` one-shot probe (#71)
`Sources/WorldSession.swift:1508-1524` (state var at `1553`)
Prints door/fence-gate drawtype/box/atlas layers to the device log once per
connect. Diagnostic for the door-geometry work (#71); looks done.

### 3c. `[model]` / `[mobY]` / `[mobYaw]` probes (#67)
`Sources/WorldSession.swift:1526-1550` (timer var at `1552`)
Runs every 120 ticks, forever, printing mob counts, nearest-mob Y placement, and
facing checks. This is ongoing device-log spam for the sunk-mob/facing bug (#67).
The most worth pruning of the three, since it never stops.

### 3d. `debugAutoDig`
`Sources/WorldSession.swift:231`, `860-870`
`private let debugAutoDig = false` plus its loop. Comment says "Off by default (it
chews up the world); flip to verify." This one is an honestly-labeled dev toggle,
not abandoned — fine to keep, listed only for completeness.

---

## 4. Redundant / boilerplate comments (low priority, cosmetic)

One pocket only: Apple's ARKit/Metal template comments survived in `Renderer.swift`
and clash with the house style (they restate the obvious, and two carry typos).
Representative sample, not exhaustive:

- `Sources/Renderer.swift:12` — `// The 256 byte aligned size of our uniform structure`
- `Sources/Renderer.swift:655-656` — `// Create a Metal vertex descriptor specifying how vertices will by laid out ...` (typo: "by" → "be")
- `Sources/Renderer.swift:684` — `/// Build a render state pipeline object`
- `Sources/Renderer.swift:811` — `/// Update the state of our uniform buffers before rendering`
- `Sources/Renderer.swift:819` — `/// Reset resources used in previous frame`
- `Sources/Renderer.swift:1103` — `/// Per frame updates hare` (typo: "hare" → "here")
- `Sources/Renderer.swift:1113` — `// Perform frame independent work`
- `Sources/Renderer.swift:1275` — `/// Final pass rendering code here`
- `Sources/Renderer.swift:1601` — `// Generic matrix math utility functions`
- `Sources/ShaderTypes.h:1-3` — default Xcode file header

(`Renderer.swift:826` "Remove all per drawable target resources that are older than
90 frames" is template-derived too but actually carries the useful "90 frames"
number — keep it.)

One minor TODO worth surfacing, not removing:
- `Sources/Renderer.swift:1284` — `renderEncoder.setCullMode(.none)   // TODO: .back once face winding is verified`

The many short inline comments in `GameInput.swift` (e.g. `// left grip = sprint`,
`// right O -> inventory`) look redundant at a glance but are not: they translate
the GameController API element names into the physical Sense-controller buttons and
the game action. Keep them.

---

## 5. Tricky code that lacks a comment

Very little. The genuinely subtle code is already explained — the 6d-facedir
rotation (`WorldMesher.swift`), the SRP padding (`SRP.swift`), the reverse-Z sky
depth trick (`Shaders.metal`), the b3d conjugate-quaternion gotcha
(`B3DLoader.swift:296-298`), the grid-shift invariant (`Client.swift:78-86`). No
high-value uncommented hotspots turned up. The standard matrix helpers at
`Renderer.swift:1614-1631` are uncommented, but they are the canonical
rotation/translation formulas from Apple's template and need none.

If anything, this codebase's imbalance runs the other way: a couple of dead
functions still carry full doc comments (2a, 2b), which is more misleading than a
missing comment would be.

---

## 6. Patterns worth a codebase-wide convention

1. **Issue-number tags are a strong, consistent convention** — `#57`, `#60`, `#66`,
   `#67`, `#71`, `#72`, `#78`, `#80`, `#81`, `#84`, `#86`, `#105`, `#114`, `#115`,
   and the `F1`-`F4` reconnect-fix tags all thread a fix to its reason. Worth
   keeping. The flip side: when an issue closes, its diagnostic scaffolding tends to
   linger (see #67, #71, #115 in section 3). Suggested convention: when you close an
   issue, `grep` its number and delete the probe/log scaffolding tagged with it.

2. **The `_ = field   // <name> (unused)` wire-skip annotations** in `Client.swift`,
   `ActiveObjects.swift`, and `NodeRegistry.swift` are excellent and consistent —
   they document exactly which protocol fields are being consumed-and-discarded and
   why the parse must still read them. Keep this pattern.

3. **Apple-template comment cruft is confined to `Renderer.swift` (and the
   `ShaderTypes.h` header).** A one-time sweep of that file's template-derived
   comments (section 4) would bring it in line with the rest of the codebase, which
   is written in the owner's plain-why style throughout.
