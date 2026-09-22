# Formspecs, HUD, texture modifiers, and model formats

Written 2026-09-09 from `repos/luanti/doc/lua_api.md`, `builtin/game/`,
`irr/src/CB3DMeshFileLoader.cpp`, and a survey of the installed VoxeLibre
0.91.2 Lua and model files. Companion to `luanti-protocol.md` (wire formats)
and `godot-visionos.md` (platform).

The point of this file: size the "everything that is not blocks" work, and
pin down the subset VoxeLibre actually needs so the client doesn't implement
the whole Luanti UI stack.

## 1. Formspecs

A formspec is a string of `element[args;args]` blocks the server sends;
the client draws a window and sends back named field values. The client
needs a parser, a layout engine, and a renderer for the element subset
below, plus the reply packets INVENTORY_FIELDS / NODEMETA_FIELDS.

### 1.1 What VoxeLibre uses (occurrences across its Lua)

| element | uses | needed for |
|---|---|---|
| `list` | 148 | every inventory slot grid |
| `listring` | 120 | shift-click transfer between lists |
| `label` | 102 | titles |
| `image` | 86 | slot backgrounds, decorations, tabs |
| `tooltip` | 52 | hover text on buttons |
| `size` | 47 | window size |
| `image_button` | 44 | tabs, recipe book, arrows |
| `button` | 32 | plain buttons |
| `formspec_version` | 26 | VoxeLibre sends version 6 (real coordinates) |
| `box` | 19 | coloured rectangles |
| `style_type`, `style` | 28 | button skins from the prepend |
| `textarea` | 13 | books, signs |
| `table` | 12 | lists (awards, credits) |
| `button_exit` | 12 | close |
| `item_image` | 11 | icons |
| `background`, `background9`, `bgcolor` | 14 | window chrome |
| `field` | 7 | text input (anvil rename, sign) |
| `scrollbar`, `scroll_container`, `scrollbaroptions` | 13 | creative inventory, recipe book |
| `model` | 6 | player preview in inventory |
| `item_image_button` | 5 | tab icons |
| `container` | 3 | offset groups |
| `textlist`, `tabheader`, `checkbox`, `hypertext`, `field_close_on_enter`, `field_enter_after_edit`, `set_focus`, `no_prepend`, `padding`, `listcolors` | few | long tail |

Not used: `dropdown`, `pwdfield`, `animated_image`, `button_url`, `vertlabel`,
`tablecolumns` trees. Skip those.

### 1.2 The prepend every form gets

VoxeLibre sets a formspec prepend on join (`mcl_formspec_prepend`):

```
listcolors[#9990;#FFF7;#FFF0;#000;#FFF]
style_type[image_button;border=false;bgimg=mcl_inventory_button9.png;bgimg_pressed=mcl_inventory_button9_pressed.png;bgimg_middle=2,2]
style_type[button;border=false;bgimg=mcl_inventory_button9.png;bgimg_pressed=mcl_inventory_button9_pressed.png;bgimg_middle=2,2]
style_type[field;textcolor=#323232]
style_type[label;textcolor=#323232]
style_type[textarea;textcolor=#323232]
style_type[checkbox;textcolor=#323232]
bgcolor[#00000000;true]
background9[1,1;1,1;mcl_base_textures_background9.png;true;7]
```

So the client must support `style_type` with `bgimg`, `bgimg_pressed`,
`bgimg_middle` (9-slice), `border=false`, `textcolor`, and `background9`
with `auto_clip` and a `middle` value. That is what makes it look like
Minecraft instead of Luanti.

### 1.3 Real coordinates (formspec version 2+)

VoxeLibre uses `formspec_version[6]`, so everything is in the "real
coordinate" system: one unit is one inventory slot, no hidden padding.
`list[...]` draws slots of size 1 with 0.25 spacing by default (so slot
pitch 1.25). Labels are positioned by the centre of their text.
`size[W,H]` is the window size in those units; the engine scales the window
to fit the screen. In VR, pick a fixed metres-per-unit (about 0.04 m per
unit gives a 12-unit inventory a 0.5 m wide panel) and place the panel in
front of the player.

Example, the survival inventory (from `mcl_inventory/survival.lua`):

```
formspec_version[6]
size[11.75,10.9]
image[x,y;1,1;mcl_formspec_itemslot.png] ... (one per slot, via get_itemslot_bg_v4)
list[current_player;main;0.375,5.575;9,3;9]
list[current_player;main;0.375,9.525;9,1;]
list[current_player;armor;0.375,0.375;1,1;1]  (x4 rows)
image[1.57,0.343;3.62,4.85;mcl_inventory_background9.png;2]
list[current_player;offhand;5.375,4.125;1,1]
label[6.61,0.5;Crafting]
list[current_player;craft;6.625,0.875;2,2]
image[9.125,1.5;1,1;crafting_formspec_arrow.png]
list[current_player;craftpreview;10.375,1.5;1,1;]
style_type[image;noclip=true] + tab images/buttons above the window
```

### 1.4 Interaction model to implement

- `list` slots: click = pick up / put down the cursor stack, right-click =
  take half / put one, shift-click = move to next list in the `listring`.
  Each results in a TOSERVER_INVENTORY_ACTION `Move` or `Drop` (protocol
  notes section 12). The server echoes the new inventory.
- `craftpreview` is read-only; the server fills it. Taking from it crafts.
- Buttons send INVENTORY_FIELDS with `{name = "true"}` plus all field
  values; `button_exit` also closes and sends `quit = "true"`.
- Closing a form (Escape/menu) sends `{quit = "true"}`.
- The death screen is a formspec named `__builtin:death`:
  `size[11,5.5,true] bgcolor[#320000b4;true] label[...;You died]
  button_exit[4,3;3,0.5;btn_respawn;Respawn]`. Reply with
  INVENTORY_FIELDS formname `__builtin:death`, fields
  `btn_respawn=true`, `quit=true`.
- Node forms (chest, furnace) are SHOW_FORMSPEC with `context` lists that
  resolve to `nodemeta:x,y,z`; reply with NODEMETA_FIELDS for their buttons.

VR rendering plan: parse the formspec into a widget tree, render to a
SubViewport with Godot Control nodes (TextureRect, Button, Label, GridContainer
of slot buttons), show it on a quad in front of the player, and drive it with
the controller ray as a virtual mouse (`Viewport.push_input`). That reuses
Godot's UI toolkit instead of writing a layout engine.

## 2. HUD

Builtin server Lua adds for every client (since protocol 46 these come as
normal HUD elements, not hard-coded):

- `hotbar` (type 12), `statbar` health (hearts) and breath, `minimap`.

VoxeLibre adds (occurrences): `image` 23, `text` 18, `statbar` 1,
`image_waypoint` 1. That covers hunger/armor/XP bars (image + text in
`vl_hudbars`), boss bars, wielded item name, titles, and the compass/death
waypoint.

Fields per element (HUDADD packet, protocol notes section 8): `type`,
`position` (0..1 screen fraction), `scale`, `text` (texture or string),
`number` (count or colour), `item`, `direction`, `alignment`, `offset`
(pixels), `world_pos`, `size`, `z_index`, `text2`, `style`.

VR plan: draw the HUD to a SubViewport at a fixed virtual resolution (say
1280x720) and show it on a curved quad attached to the camera at 2 to 3
metres, or on a wrist panel. `world_pos` waypoints become 3D labels. The
hotbar needs the inventory `main` list and wield index; selection changes
send PLAYERITEM.

## 3. Texture modifiers

Node and item textures are strings like
`mcl_core_stone.png^[colorize:#ff0000:60`. The client must evaluate them
into images at atlas build time. Full grammar is in `lua_api.md` under
"Texture modifiers"; the subset VoxeLibre uses (occurrences in Lua, plus
whatever the engine itself generates):

| modifier | uses | what |
|---|---|---|
| `^` overlay | everywhere | alpha-blend B over A (not associative when both semi-transparent) |
| `[transform<t>` | 123 | rotate/flip: 0 I, 1 R90, 2 R180, 3 R270, 4 FX, 5 FXR90, 6 FY, 7 FYR90 |
| `[colorize:<color>:<ratio>` | 81 | lerp each pixel toward colour by ratio/255; `alpha` keyword uses pixel alpha |
| `[verticalframe:<t>:<n>` | 33 | crop frame n of t stacked frames |
| `[multiply:<color>` | 20 | multiply RGB |
| `[resize:<w>x<h>` | 17 | nearest-neighbour resize |
| `[hsl:<h>:<s>:<l>` | 17 | hue/sat/lightness shift |
| `[lowpart:<pct>:<tex>` | 11 | blit lower pct% of tex |
| `[makealpha:<r>,<g>,<b>` | 8 | colour key to transparent |
| `[brighten` | 6 | 50% toward white |
| `[opacity:<n>` | 5 | multiply alpha by n/255 |
| `[mask:<tex>` | 5 | bitwise AND with tex |
| `[noalpha` | 3 | alpha = 255 |
| `[invert:<rgba>` | 2 | invert channels |
| `[sheet:<w>x<h>:<x>,<y>` | 1 | tile from a sheet |
| `[combine:<w>x<h>:<x>,<y>=<tex>:...` | 1 | compose on a canvas |
| `[crack:<frames>:<n>` | engine | dig crack overlay from `crack_anylength.png`; generated by the client during digging |
| `[png:<base64>` | engine | inline PNG, used by some HUD/formspec code |
| `[inventorycube{...}` | engine | 3D cube icon for node items with no inventory_image; render in Godot instead |
| `[fill`, `[screen`, `[contrast`, `[overlay`, `[hardlight`, `[colorizehsl` | 0 | skip |

Rules that matter: grouping with `(` `)`, escaping of `^` `:` `\` inside
arguments as `\^` `\:` `\\`, and when overlaying images of different sizes
the smaller one is upscaled to the larger (nearest neighbour). Palettes
(`palette_name` + param2 colour) multiply the tile by a palette pixel;
VoxeLibre uses `color` param2 on 7 node types (beds, banners, shulkers).

Implementation: evaluate modifiers on Godot `Image` (CPU) with a cache
keyed by the full string, then pack results into the atlas. Node tiles are
almost all 16x16, so a 4096x4096 atlas holds 65k tiles; use a 2D texture
array (Texture2DArray) instead to avoid mipmap bleeding.

## 4. Models

### 4.1 Formats in VoxeLibre

| format | count | used for |
|---|---|---|
| `.b3d` | 72 | all mobs, the player (`mcl_player`), armor stands, boats, minecarts |
| `.obj` | 43 | static mesh nodes: lanterns, chests, beds, doors, etc |

Godot has no runtime loader for either. OBJ is trivial. b3d needs a real
loader with skinning and keyframe animation. Survey of the 72 b3d files:

- 63 have skeletons and animations (BONE + KEYS + ANIM chunks). 9 are static.
- Every brush uses at most **one texture**. Vertex flags are either
  `normals present` or nothing; **no vertex colours**, one UV set of 2
  components. That removes most of the format's corner cases.
- Chunk counts across all files: NODE 977, MESH 122, VRTS 122, TRIS 144,
  BONE 841, KEYS 841, ANIM 101, BRUS 58.

### 4.2 b3d format (from `CB3DMeshFileLoader.cpp`)

All values little-endian. File is a tree of chunks: `char[4] tag, s32
size, body[size]`. Strings are NUL-terminated.

```
BB3D  s32 version, then child chunks TEXS, BRUS, NODE
TEXS  repeated { string name, s32 flags, s32 blend, f32 x_pos, y_pos, x_scale, y_scale, angle }
      flags bit1 (0x2) alpha-mapped, bit2 (0x4) masked, bit 65536 secondary UV
BRUS  s32 n_texs, then repeated { string name, f32 r,g,b,a, f32 shininess, s32 blend, s32 fx,
      s32 texture_id[n_texs] (-1 = none) }
      fx & 16 = no backface culling, fx & 32 = force vertex alpha
NODE  string name, f32 pos[3], f32 scale[3], f32 rot[4] as (w, x, y, z), then children:
      NODE (child bone/node), MESH, BONE, KEYS, ANIM
MESH  s32 brush_id, then VRTS and TRIS chunks
VRTS  s32 flags (1 normals, 2 rgba), s32 tex_coord_sets, s32 tex_coord_set_size, then per vertex:
      f32 x,y,z [, nx,ny,nz] [, r,g,b,a], f32 uv[sets][size]
TRIS  s32 brush_id, then repeated s32 v0, v1, v2  (indices into this MESH's VRTS, 0-based)
BONE  repeated { s32 vertex_id, f32 weight }   (vertex_id relative to the MESH under the same NODE tree)
KEYS  s32 flags (1 position, 2 scale, 4 rotation), then repeated { s32 frame (1-based),
      [f32 pos[3]] [f32 scale[3]] [f32 rot[4] as (w,x,y,z)] }
ANIM  s32 flags, s32 frames, f32 fps   (ignored by Luanti)
```

Semantics the engine applies:

- NODE TRS is local to the parent; global = parent_global * local.
  Vertices in a MESH are transformed by the owning node's global matrix at
  load time, so the rest pose is baked into vertex positions.
- Each NODE with KEYS or BONE is a joint. Weights from BONE chunks attach
  to that joint; a vertex can have weights from several joints. Skinning
  matrix per joint = animated_global * inverse(rest_global).
- Animation frames are the KEYS frame numbers minus 1 (0-based). Position
  and scale keys are linearly interpolated, rotation keys slerped. Joints
  with no key at a frame keep their rest transform.
- Triangles from TRIS with the same brush go into one surface; the brush's
  texture index selects the texture. In Luanti the entity's `textures`
  list replaces brush textures by **material index order**, so surface i
  uses `textures[i]`. Same for mesh nodes: `tiles[i]` maps to material i.
- When normals are absent the loader computes smooth normals from faces.
- Coordinates are Blitz3D's left-handed system, same as Irrlicht. Convert
  to Godot the same way as world coordinates (negate Z) and reverse
  triangle winding.

Server-driven animation (AO_CMD_SET_ANIMATION) gives a frame range, fps,
blend time and loop flag per entity. Example from `mobs_mc:zombie`: walk 0
to 39 at 25 fps, stand 40 to 49, punch 50 to 59. Player model
(`mcl_player`) ranges like stand 0..79, walk 168..187, mine 189..198,
walk+mine 200..219 at 30 fps.

Godot mapping: build an `ArrayMesh` with one surface per brush, a
`Skeleton3D` with one bone per joint, `ARRAY_BONES` and `ARRAY_WEIGHTS`
(4 weights per vertex, normalise), and one `Animation` with position,
rotation and scale tracks per bone at the b3d keyframes. Playing a range
[a, b] at fps f = seek to a/f and play until b/f. The loader is about 400
lines of GDScript; test it on all 72 files and compare against Luanti.

### 4.3 OBJ

Luanti's loader reads `v`, `vt`, `vn`, `f` (with `v/vt/vn` indices), and
`usemtl` starts a new surface; `mtllib` is parsed but textures come from
the node's `tiles` by surface order. Negative indices allowed. Faces can
be polygons; triangulate as a fan. Roughly 100 lines.

### 4.4 Other entity visuals

`wielditem` and `item` (dropped items): render the item's inventory image
as a thin extruded sprite, or the node cube for node items.
`upright_sprite` (two-sided billboard, used by name tags and some
projectiles) and `cube` (sixed textured cube) are easy. `node` visual
draws a node mesh.

## 5. Sizing summary for the "not blocks" work

| piece | scope | effort feel |
|---|---|---|
| Texture modifier evaluator | 16 modifiers plus grouping/escaping | days |
| Atlas / texture array builder | trivial once modifiers work | day |
| OBJ loader | tiny | half day |
| b3d loader with skinning + animation | medium, well specified, good corpus | week |
| Formspec parser + Control renderer + input | 25 elements, styling, listring, slot drag logic | 1 to 2 weeks |
| HUD renderer | 4 element types plus hotbar | days |
| Inventory action plumbing | Move/Drop/Craft strings and echo handling | days |

None of this blocks the first milestone (walk around the world, dig, place
with the hotbar). Formspecs can wait until crafting is wanted.
