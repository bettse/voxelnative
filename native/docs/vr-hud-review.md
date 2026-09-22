# VR HUD design review — VoxeLibre on Apple Vision Pro

A design review of the heads-up display in the native visionOS/Metal client. It
covers current VR/AR HUD best practice, an inventory of what the client draws
today, and prioritized, element-by-element recommendations. This is a design
document — no code changes are proposed inline, only what to move, resize,
re-anchor, add, or remove and why.

Scope note: the AVP renders through a **fixed optical focal plane at roughly
1.3 m**. Everything below about depth, sharpness, and eye comfort keys off that
number. All sizes in the client are in node units and `PlayerState.scale` is
`1.0` (1 node = 1 meter), so node-unit sizes below are also meters, which lets us
state real angular sizes.

---

## 1. VR/AR HUD best practices (2024–2026)

**Prefer world- or body-anchored (diegetic) UI over head-locked overlays.**
A traditional HUD floating in front of the face reads like "walking around with a
phone directly in front of your eyes" — you constantly refocus between it and the
world, and it is fatiguing and immersion-breaking. VR punishes floating overlays
and rewards in-world information; guidance is to avoid strictly non-diegetic UI
in VR and to integrate information into the world or place it a few meters away
([UX Planet / Merge](https://merge.rocks/blog/vr-ar-ux-design-immersive-ux-best-practices),
[Developer Nation](https://www.developernation.net/blog/unity_virtual_reality/)).
The trade-off is real: diegetic UI costs legibility and glance speed — no single
display type wins for every kind of information, so match the technique to how
urgently the value must be read
([Diegetic vs Non-Diegetic UI](https://punchev.com/blog/diegetic-vs-non-diegetic-game-ui),
[Diegetic/Non-diegetic health interfaces in VR shooters, Springer](https://link.springer.com/chapter/10.1007/978-3-030-85613-7_1)).

**visionOS Human Interface Guidelines.** Place primary content directly ahead at
eye level, within roughly 30° above and below eye level; don't make people turn
their head or move to interact. Use the system glass materials for surfaces
(depth, translucency, environmental integration) rather than opaque custom
panels; **white text is the most legible** choice against the variable glass
background. Avoid motion that is overwhelming, jarring, or too fast, and always
keep a stationary frame of reference
([Apple HIG for visionOS, MacStories](https://www.macstories.net/news/apple-publishes-updated-human-interface-guidelines-for-visionos/),
[Designing for visionOS](https://think.design/blog/the-complete-guide-to-designing-for-visionos/),
[Apple Developer: Spatial design Q&A](https://developer.apple.com/news/?id=fi8ne6ji)).

**Comfort field of view.** Keep glanceable UI within about 60° of forward view
(80° max per side for main content, ~105° for peripheral). Vertically, ~20° up is
comfortable (60° max) and ~12° down is comfortable (40° max); reading below eye
level is easier than above
([VR design principles, Dummies](https://www.dummies.com/article/technology/programming-web-design/general-programming-web-design/virtual-reality-design-principles-starting-up-user-attention-and-comfort-zones-256440/),
[Spatial UX guide, UX Planet](https://uxplanet.org/designing-for-spatial-ux-in-ar-vr-a-beginner-to-advanced-guide-to-immersive-interface-design-c55f092deb0b)).

**Body-anchored UI works** — wrist, shoulder, or lap-height panels are a
recognized pattern, and lower placement reduces arm/neck fatigue while leaning on
spatial memory
([VR UI design best practices, arXiv 2508.09358](https://arxiv.org/pdf/2508.09358)).

**Text legibility.** Aim for a cap height of about **1.2–1.8° of visual angle**
for comfortable reading; below ~1.2° reading gets hard. Place text 1–10 m away,
ideally near 3 m, but on a fixed-focal-plane headset keep it near that plane to
limit blur and the vergence–accommodation conflict; low panel resolution makes
far text unreadable unless it is large
([VR text display guideline, ResearchGate](https://www.researchgate.net/figure/ergence-distances-elicited-throughout-our-study-as-a-guideline-for-text-display-in-VR_fig4_324664157),
[Vergence–accommodation conflict, Wiley/SID 2024](https://sid.onlinelibrary.wiley.com/doi/10.1002/jsid.1283)).

**Reticle / targeting.** A reticle drawn at a *guessed* depth double-images in
stereo. Either drive it from the eye/aim raycast so it sits at the true hit
distance, or replace it with an in-world target highlight
([Spatial UI best practices, IxDF](https://ixdf.org/literature/article/spatial-ui-design-tips-and-best-practices)).

---

## 2. Inventory of the current HUD

Three anchoring classes are in use.

### Head-locked (follows the gaze), depth-tested billboard stream
Authored in a canonical head-local frame and re-anchored to the *current* frame's
head pose at draw time (`EntityInstance.headLocal`, `Renderer.buildHudBillboards`)
— this deliberately avoids the ghosting/doubling that baking against the stale
tick pose caused. All are drawn at `light: 255` (full-bright day or night).

- **Health hearts** — lower-left column, azimuth −0.50 rad (~29° left of gaze),
  10 icons stacked top→bottom, each ~0.10 m tall at 1.7 m (≈ **3.4°**),
  full/half/empty at 2 HP each. The column is "bowed" back toward center at its
  ends (`appendHealthHUD` → `appendStatColumn`).
- **Hunger drumsticks** — mirror of hearts at azimuth +0.50 rad (~29° right).
- **Breath bubbles** — top-center row of 10, elevation +0.30 rad (~17° up),
  **only while submerged** (a nice contextual reveal), popping from the right.
- **XP bar + level** — a 12-segment shallow arc across the bottom-center at 1.7 m
  (azimuth ±0.28 rad, dipping to elevation −0.28 rad), green fill from the left;
  the level digits ride just above it in XP green. Shown only once XP exists.
- **Placement basis** — `stableFrame` gravity-stabilizes and drops head roll, and
  **caps pitch at ~55°** (`maxSin = 0.82`) so the basis can't snap through the
  pole when you look straight up/down (this is the fix for the #68 flip).

### Overlay stream (head-locked, drawn on top, no depth test)
- **Status banner** — connect/loading/notice text, 1.2 m ahead and 0.12 m below
  eye, red backdrop band (140,24,24), ~0.36 m wide; crisp filled text (#175).
- **Chat** — recent lines, at 1.3 m, stacked *above* eye level (top edge at
  +0.30, dropping downward), 9 s life with a 1 s fade, dark translucent backdrop
  per line, constant glyph height so long lines wrap instead of shrinking (#157).
  Per-line height 0.028 m at 1.3 m ≈ **1.23°** — right at the legibility floor.
- Also here: death text, the **Kogane companion** (body-anchored — offset from
  body-forward so you turn to look at it — plus a head-locked menu panel),
  entity **nametags** (#118), the on-screen **keyboard**, and the **inventory
  panel**.

### Wrist / hand-anchored (diegetic), from tracked hand poses (`Renderer.buildHandHud`)
- **Wield item** — drawn in the **right** hand (#66): a real 3D block for nodes,
  the real b3d model for mesh nodes (chest/bell), or the icon extruded to a
  silhouette/slab for tools. Has a switch "pop" and a dig-swing animation (#136).
  Eric deliberately chose hand-attached over desktop's camera-lock.
- **Wristwatch spot** — on the right wrist: the wielded **stack count** as a
  camera-facing billboard (#158, made a billboard because a flat label read
  mirrored/upside-down, #168) and a **durability wear bar** (#159, green→red;
  the bug was a tint over the dark slot coming out black, fixed with a white
  layer). Count and wear never coexist, so they share the spot.
- **Hotbar ring** — 9 cells wrapped around the **left** forearm cylinder (#57),
  radius 0.068 m, spanning ~80% of the wrist; the **selected slot rotates to the
  top** of the wrist rather than a marker moving. Per-slot wear bars (#106),
  slot frame + selection frame.
- **Armor gauntlet** — 10 plate segments on the same left forearm (#108), tighter
  radius (0.060 m) and shifted toward the elbow so it doesn't collide with the
  hotbar; hidden at 0 armor.

### World-anchored
- **Pointed-node highlight** — a black selection box on the node under the aim.
  **There is deliberately no crosshair/reticle (#48)**: the outline is the
  targeting cue, since a reticle at a guessed depth reads badly in stereo.
- **Dig-crack overlay** on the node being mined; **break particles**; mob
  **nametags** float above entities.

### Known issues flagged in comments
`#48` no crosshair by design · `#68` up/down flip (handled by the 55° pitch cap)
· `#157` constant-height chat text · `#159` wear-bar tint · `#108` armor gauntlet
· `#158`/`#168` wield count billboard vs mirrored label · `#175` crisp text
paths · `#66` wield hand-attached · `#106` per-slot wear.

---

## 3. Recommendations (prioritized)

Ordered by impact-to-effort. Each ties to comfort, legibility, or immersion.

### P1 — Unify HUD depth near the AVP focal plane (comfort, sharpness)
The head-locked stats sit at **1.7 m**, chat at **1.3 m**, and the banner at
**1.2 m**. The panel's fixed focal plane is ~1.3 m, so the 1.7 m stats sit off
the focal plane (slightly softer, more vergence–accommodation strain) and your
eyes refocus as they move between elements. **Move the peripheral stats and XP
arc to ~1.3–1.4 m** so the whole persistent HUD lives on or near the focal plane.
Low effort (one distance constant per element), clear comfort/sharpness win.

### P2 — Bump chat text to ~1.5–1.8° and move it below eye level (legibility, comfort)
Chat at **1.23°** is at the reading floor, and it currently stacks *above* eye
level, which the HIG calls the more fatiguing direction to read. Raise the
per-line height so cap height lands ~1.5–1.8°, and **anchor chat in the
lower-third** of view (top edge below the gaze) instead of above it. Keep the
9 s auto-fade — transient chat is already good practice.

### P3 — Pull hearts and hunger inboard and lower (comfort, glanceability)
Health at ~29° left and hunger at ~29° right forces a ~57° eye saccade between
the two values you check most in a survival game — near the edge of the ~60°
glance-comfort budget. **Bring both columns inboard** (toward ±15–18°) and
**down** into the comfortable lower band, ideally as a single low cluster
(hearts left, hunger right, sharing one horizontal zone) so both read in one
glance without a big dart to the corners.

### P4 — Give the head-locked stats a translucent glass backing, not full-bright (legibility + immersion)
Drawing vitals at `light: 255` keeps them readable but makes them look pasted-on,
glares in bright scenes (snow/desert) and floats untethered in dark caves — the
opposite of the HIG's glass-material guidance and the "phone in front of your
face" failure mode. Add a **subtle dark translucent backing plate** behind each
stat cluster (or per icon) for consistent contrast in any environment, and
consider dropping the icons slightly below full-bright so they sit in the scene
rather than on top of it.

### P5 — Reconsider the pitch cap's side effect on vitals (comfort/stability)
The 55° pitch cap (fix for #68) means that when you look far up (placing a block
overhead) or far down (mining at your feet), the gaze-relative stat columns stop
tracking and freeze at the cap — they can drift toward center or feel detached
from where you're looking. Consider **anchoring the persistent vitals to a
torso/body frame (yaw-follow, no pitch)** instead of gaze-relative-with-cap: they
stay put as you pitch, which is steadier and matches the "body-anchored UI"
pattern. (Keep the true-aim `centered` basis for anything that must track the aim
ray.)

### P6 — Add a depth-correct reticle *only* for ranged/placement actions (targeting)
The no-crosshair decision (#48) is sound for melee mining — the node highlight is
the cue. But it leaves ranged aiming (bow, throwing, distant placement) with no
targeting cue when you're not pointed at a pointable node in reach. The raycast
already yields a hit point, and `EntityInstance.centered` already gives a
true-aim basis. **Draw a small reticle at the raycast hit depth** — not a guessed
depth, which is exactly what #48 warns against — and show it **only** while a
ranged/placeable item is wielded. Keeps the clean look for mining, fixes aiming.

### P7 — Confirm hotbar selection without forcing a wrist raise (feedback)
The wrist ring is a good diegetic choice, but the selected slot only reads when
the left wrist is raised and rotated into view. Because the **wield item is
already shown in the right hand**, selection is implicitly confirmed by what
you're holding — good. For the empty-hand / fast-cycle case, add a **brief
head-locked flash of the selected slot (≈1.5 s, then fade)** on change, so slot
changes are confirmed without holding the wrist up.

### P8 — Add diegetic feedback for the urgent thresholds (immersion + at-a-glance safety)
Counting hearts/bubbles is slow. Layer in diegetic cues for the states you must
notice instantly: a **red damage vignette / desaturation at low health**, a
**heartbeat or edge pulse when starving**, and an **edge darken/tint as breath
runs low** (complementing the existing bubbles). These are standard, comfortable
VR techniques and reduce reliance on reading peripheral columns mid-combat.

### P9 — Check the XP arc / level for lower-field clutter (comfort)
The XP arc and green digits sit bottom-center at ~1.7 m — the same lower-field
region you look through while mining at your feet or reading the wrist. Move it to
the unified ~1.3 m depth (P1) and verify it doesn't overlap the wrist HUD or the
dig target when you look down; consider fading it out shortly after XP changes
rather than showing it persistently.

---

## 4. Alternative layouts (with trade-offs)

### A. "Wrist cockpit" — everything diegetic on the forearms
Move **all** persistent stats onto the arms: health and hunger join the hotbar
ring and armor gauntlet as bands/dials on the left forearm; wield + count + wear
stay on the right. Head space is completely clear.
- **Pros:** most immersive, fully HIG-aligned (nothing head-locked), no floating
  overlay fatigue, leverages spatial memory.
- **Cons:** health/hunger now cost a wrist raise to read — bad during combat when
  those are exactly the values you need instantly. **Mitigate** by keeping a
  diegetic health cue in view (damage vignette, P8) so the one urgent stat
  doesn't require a glance down.

### B. "Minimal head cluster + diegetic feedback" (recommended default)
Keep a small, **glass-backed, dim** vitals cluster low and slightly inboard
(P1/P3/P4) — a single bottom band rather than two far corners — and add the
diegetic threshold cues from P8. Wield/hotbar/armor stay on the wrist.
- **Pros:** best balance of glanceability and immersion; small persistent
  footprint; urgent states surface diegetically; low risk.
- **Cons:** still has some head-locked UI (not zero-overlay purist); needs the
  vignette/pulse art and threshold logic.

### C. "Contextual / transient HUD"
Nothing persistent except the wield-in-hand. Stats **fade in only when they
change or cross a threshold** (and on demand — a wrist raise or a downward
glance), then fade out.
- **Pros:** cleanest possible view, maximum immersion, minimal clutter.
- **Cons:** survival players want continuous at-a-glance health; a stat you can't
  see until it changes can be missed. Best combined with P8's always-on diegetic
  low-health cue as the safety net.

---

## 5. Quick wins vs. larger reworks

**Quick wins (constant/parameter tweaks, low risk):**
- P1 — unify HUD depth to ~1.3–1.4 m (per-element distance constants).
- P2 — raise chat glyph height to ~1.5–1.8° and move chat below eye level.
- P3 — pull hearts/hunger inboard (~±15–18°) and lower.
- P9 — re-depth the XP arc and check lower-field overlap.

**Medium (new geometry/state, moderate effort):**
- P4 — translucent glass backing plates behind head-locked stats.
- P7 — transient head-locked selected-slot flash on hotbar change.
- P6 — depth-correct reticle at raycast hit distance for ranged/placement only.

**Larger reworks (design + art + logic):**
- P5 — re-anchor vitals to a torso/body (yaw-follow) frame.
- P8 — diegetic threshold feedback (damage vignette, starving pulse, breath
  edge tint).
- Alternative layout A or C — a structural re-home of where vitals live.

---

## Sources
- [Apple publishes updated HIG for visionOS — MacStories](https://www.macstories.net/news/apple-publishes-updated-human-interface-guidelines-for-visionos/)
- [Designing for visionOS: The Complete Guide — think.design](https://think.design/blog/the-complete-guide-to-designing-for-visionos/)
- [Q&A: Spatial design for visionOS — Apple Developer](https://developer.apple.com/news/?id=fi8ne6ji)
- [Diegetic and Non-diegetic Health Interfaces in VR Shooter Games — Springer](https://link.springer.com/chapter/10.1007/978-3-030-85613-7_1)
- [Diegetic vs Non-Diegetic Game UI — Punchev](https://punchev.com/blog/diegetic-vs-non-diegetic-game-ui)
- [Immersive UX best practices — Merge](https://merge.rocks/blog/vr-ar-ux-design-immersive-ux-best-practices)
- [A New Dimension for UI: Unity for VR — Developer Nation](https://www.developernation.net/blog/unity_virtual_reality/)
- [VR design principles: comfort zones — Dummies](https://www.dummies.com/article/technology/programming-web-design/general-programming-web-design/virtual-reality-design-principles-starting-up-user-attention-and-comfort-zones-256440/)
- [Designing for Spatial UX in AR/VR — UX Planet](https://uxplanet.org/designing-for-spatial-ux-in-ar-vr-a-beginner-to-advanced-guide-to-immersive-interface-design-c55f092deb0b)
- [VR User Interface Design: Best Practices — arXiv 2508.09358](https://arxiv.org/pdf/2508.09358)
- [Spatial UI Design: Tips and Best Practices — IxDF](https://ixdf.org/literature/article/spatial-ui-design-tips-and-best-practices)
- [Text display in VR / vergence distances guideline — ResearchGate](https://www.researchgate.net/figure/ergence-distances-elicited-throughout-our-study-as-a-guideline-for-text-display-in-VR_fig4_324664157)
- [Vergence–accommodation conflict increases time to focus in AR — Wiley/SID 2024](https://sid.onlinelibrary.wiley.com/doi/10.1002/jsid.1283)
