import Foundation
import simd

/// Voxel mesher over a streamed WorldMap, the counterpart of the engine's
/// MapBlockMesh / content_mapblock.cpp drawtype builders. Emits only faces
/// between a solid node and air, interleaved as [x,y,z, u,v, layer, shade, light, tint]
/// (9 floats, stride 36) for the texture-array shader. Layer comes from the
/// TextureAtlas (real tile texture, or a fallback colour layer); shade is a
/// per-face directional term; light is node light; tint is packed RGB.
public enum WorldMesher {
    // normal, 4 CCW corners (unit cube), the Luanti tile index for this face,
    // and a directional shade.
    private struct Face { let n: SIMD3<Int>; let c: [SIMD3<Float>]; let tile: Int; let shade: Float }
    private static let faces: [Face] = [
        Face(n: SIMD3(0, 1, 0),  c: [SIMD3(0,1,0), SIMD3(0,1,1), SIMD3(1,1,1), SIMD3(1,1,0)], tile: 0, shade: 1.00), // +Y top
        Face(n: SIMD3(0,-1, 0),  c: [SIMD3(0,0,1), SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(1,0,1)], tile: 1, shade: 0.447), // -Y bottom (mesh.cpp applyFacesShading)
        Face(n: SIMD3(0, 0, 1),  c: [SIMD3(0,0,1), SIMD3(1,0,1), SIMD3(1,1,1), SIMD3(0,1,1)], tile: 4, shade: 0.837), // +Z
        Face(n: SIMD3(0, 0,-1),  c: [SIMD3(1,0,0), SIMD3(0,0,0), SIMD3(0,1,0), SIMD3(1,1,0)], tile: 5, shade: 0.837), // -Z
        Face(n: SIMD3(1, 0, 0),  c: [SIMD3(1,0,1), SIMD3(1,0,0), SIMD3(1,1,0), SIMD3(1,1,1)], tile: 2, shade: 0.671), // +X
        Face(n: SIMD3(-1,0, 0),  c: [SIMD3(0,0,0), SIMD3(0,0,1), SIMD3(0,1,1), SIMD3(0,1,0)], tile: 3, shade: 0.671), // -X
    ]
    // UV per corner (top-left texture origin).
    private static let uv: [SIMD2<Float>] = [SIMD2(0,1), SIMD2(1,1), SIMD2(1,0), SIMD2(0,0)]

    // UV for a point on a nodebox face, in node-local 0..1 coords. Derived from
    // the cube face UVs above so a full-extent box textures identically to a
    // cube, and a partial box (slab, stair step) samples the matching sub-rect.
    private static func boxUV(_ n: SIMD3<Int>, _ p: SIMD3<Float>) -> SIMD2<Float> {
        if n.y > 0 { return SIMD2(p.z, 1 - p.x) }        // +Y top
        if n.y < 0 { return SIMD2(1 - p.z, 1 - p.x) }    // -Y bottom
        if n.z > 0 { return SIMD2(p.x, 1 - p.y) }        // +Z
        if n.z < 0 { return SIMD2(1 - p.x, 1 - p.y) }    // -Z
        if n.x > 0 { return SIMD2(1 - p.z, 1 - p.y) }    // +X
        return SIMD2(p.z, 1 - p.y)                       // -X
    }

    // Plantlike quads, ported from the engine's drawPlantlikeQuad/drawPlantlike
    // (content_mapblock.cpp): one quad is a vertical rectangle `scale` nodes
    // wide (visual_scale, centred on the node) and scale*height tall from the
    // node floor, turned about the node's vertical axis by `rotDeg`, with the
    // meshoptions styles built from 2-4 such quads. The old cross ran corner
    // to corner, which made every plant 1.41 wide and stretched its texture.
    // Corner order matches `uv`: bottom-left, bottom-right, top-right, top-left.
    static func plantQuad(rotDeg: Float, scale: Float, height: Float,
                          offsetZ: Float = 0, topOnly: Bool = false,
                          offset: SIMD3<Float> = .zero) -> [SIMD3<Float>] {
        let hw = 0.5 * scale, top = scale * height
        var v = [SIMD3<Float>(-hw, 0, 0), SIMD3(hw, 0, 0), SIMD3(hw, top, 0), SIMD3(-hw, top, 0)]
        for i in 0..<4 where !topOnly || i >= 2 { v[i].z += offsetZ }   // engine offsets the top pair for HASH2
        let r = rotDeg * .pi / 180, c = cos(r), sn = sin(r)
        return v.map { p in SIMD3(0.5 + p.x * c - p.z * sn, p.y, 0.5 + p.x * sn + p.z * c) + offset }
    }

    /// The engine's PLANT_STYLE_* quad sets (meshoptions style 0-4): rotation
    /// degrees, Z offset in nodes, and whether only the top edge is offset.
    private static let plantStyles: [[(rot: Float, off: Float, topOnly: Bool)]] = [
        [(46, 0, false), (-44, 0, false)],                                          // 0 cross "x"
        [(91, 0, false), (1, 0, false)],                                            // 1 cross2 "+"
        [(121, 0, false), (241, 0, false), (1, 0, false)],                          // 2 star "*"
        [(1, 0.25, false), (91, 0.25, false), (181, 0.25, false), (271, 0.25, false)],  // 3 hash "#"
        [(1, -0.5, true), (91, -0.5, true), (181, -0.5, true), (271, -0.5, true)],  // 4 hash2 "#" leaning out
    ]

    /// The engine's PseudoRandom (noise.h): the LCG the mesher seeds from the
    /// node position for meshoptions random offsets, so plants land where
    /// desktop puts them.
    private struct PseudoRandom {
        var next: UInt32
        init(seed: UInt32) { next = seed }
        mutating func draw() -> UInt32 {
            next = next &* 1103515245 &+ 12345
            return (next / 65536) % 32768
        }
    }

    /// Crossed plantlike quads rising `height` nodes from the node floor (the
    /// texture stretches over the whole height, like Luanti). Rooted plants with
    /// leveled param2 (kelp) grow param2/16 nodes tall.
    static func plantQuadsTall(_ height: Float, scale: Float = 1) -> [[SIMD3<Float>]] {
        [plantQuad(rotDeg: 46, scale: scale, height: height), plantQuad(rotDeg: -44, scale: scale, height: height)]
    }

    // Firelike (NDT_FIRELIKE): flames lean outward on the floor and climb any
    // adjacent solid wall. Ported from Luanti's drawFirelikeNode/drawFirelikeQuad
    // (content_mapblock.cpp). Neighbour indices follow D6D: 0 +Z, 1 +Y, 2 +X,
    // 3 -Z, 4 -Y, 5 -X. The exact rotation sense under the Z-mirror wants a
    // device glance, same as rails.
    static let fireDirs: [SIMD3<Int>] = [SIMD3(0,0,1), SIMD3(0,1,0), SIMD3(1,0,0),
                                         SIMD3(0,0,-1), SIMD3(0,-1,0), SIMD3(-1,0,0)]

    /// One flame quad: a node-tall quad tilted out by `opening` degrees, pushed
    /// out `offsetH` and up `offsetV`, then turned to face `rotation`. Returned in
    /// node-local 0..1 coords. offsets/scale in node units (Luanti's BS = 1 here).
    static func firelikeQuad(rotation: Float, opening: Float, offsetH: Float, offsetV: Float = 0) -> [SIMD3<Float>] {
        let s: Float = 0.5
        let corners: [SIMD3<Float>] = [SIMD3(-s, s, 0), SIMD3(s, s, 0), SIMD3(s, -s, 0), SIMD3(-s, -s, 0)]
        let oa = opening * .pi / 180, c1 = cos(oa), s1 = sin(oa)
        let rr = rotation * .pi / 180, c2 = cos(rr), s2 = sin(rr)
        return corners.map { p in
            let y1 = p.y * c1 - p.z * s1          // rotateYZBy(opening)
            var z = p.y * s1 + p.z * c1
            z += offsetH
            let x = p.x * c2 - z * s2              // rotateXZBy(rotation)
            let z2 = p.x * s2 + z * c2
            return SIMD3(x + 0.5, y1 + offsetV + 0.5, z2 + 0.5)   // centred -> local
        }
    }

    /// The flame quads for a fire node given which of its 6 neighbours are solid
    /// (indexed by D6D). Floor-backed or isolated fire draws the full flame (4
    /// leaning sides + 2 centre diagonals); otherwise flames only face solid
    /// walls, and a ceiling above makes them hang down.
    static func firelikeQuads(_ solid: [Bool]) -> [[SIMD3<Float>]] {
        let basic = solid[4] || !solid.contains(true)   // floor (-Y) or isolated
        let bottom = solid[1]                            // ceiling (+Y)
        var out: [[SIMD3<Float>]] = []
        func side(_ face: Int, _ rot: Float) {
            if basic || solid[face] { out.append(firelikeQuad(rotation: rot, opening: -10, offsetH: 0.4)) }
            else if bottom { out.append(firelikeQuad(rotation: rot, opening: 70, offsetH: 0.47, offsetV: 0.484)) }
        }
        side(0, 0); side(5, 90); side(3, 180); side(2, 270)   // +Z, -X, -Z, +X
        if basic {
            out.append(firelikeQuad(rotation: 45, opening: 0, offsetH: 0))
            out.append(firelikeQuad(rotation: -45, opening: 0, offsetH: 0))
        }
        return out
    }

    // Torchlike: a small centered crossed pair. The torch texture is centered
    // with transparent margins, so the alpha cutout carves out the stick+flame.
    // param2 wall-mounting is ignored for now (wall torches stand at center).
    private static let torchQuads: [[SIMD3<Float>]] = [
        [SIMD3(0.3,0,0.3), SIMD3(0.7,0,0.7), SIMD3(0.7,0.7,0.7), SIMD3(0.3,0.7,0.3)],
        [SIMD3(0.7,0,0.3), SIMD3(0.3,0,0.7), SIMD3(0.3,0.7,0.7), SIMD3(0.7,0.7,0.3)],
    ]

    // Raillike: a flat quad just above the floor, connecting to neighbouring
    // rails. A rail picks one of four tiles by which of its 4 horizontal
    // neighbours are rails (straight/curved/T-junction/crossing) and rotates it,
    // and slopes up when a rail sits one node higher in a direction. Ported from
    // Luanti's MapblockMeshGenerator::drawRaillikeNode (content_mapblock.cpp).
    //
    // Neighbour order = bit position: 0 +Z, 1 -Z, 2 -X, 3 +X. Same order as
    // Luanti's rail_direction so the rail_kinds table below indexes by the 4-bit
    // connection code directly.
    static let railDirs: [SIMD3<Int>] = [SIMD3(0,0,1), SIMD3(0,0,-1), SIMD3(-1,0,0), SIMD3(1,0,0)]
    private static let railSlopeAngles = [0, 180, 90, -90]
    // (tile index into faces 0..3 = straight/curved/junction/cross, Y angle deg).
    // Verbatim from Luanti's rail_kinds[16]; comment shows the set bits (+x -x -z +z).
    private static let railKinds: [(tile: Int, angle: Int)] = [
        (0,   0), // .  .  .  .
        (0,   0), // .  .  . +Z
        (0,   0), // .  . -Z  .
        (0,   0), // .  . -Z +Z
        (0,  90), // . -X  .  .
        (1, 180), // . -X  . +Z
        (1, 270), // . -X -Z  .
        (2, 180), // . -X -Z +Z
        (0,  90), // +X  .  .  .
        (1,  90), // +X  .  . +Z
        (1,   0), // +X  . -Z  .
        (2,   0), // +X  . -Z +Z
        (0,  90), // +X -X  .  .
        (2,  90), // +X -X  . +Z
        (2, 270), // +X -X -Z  .
        (3,   0), // +X -X -Z +Z
    ]

    /// Rail tile + Y rotation for a 4-bit neighbour code (bit 0 +Z, 1 -Z, 2 -X,
    /// 3 +X). A sloped rail always uses the straight tile at the slope's angle.
    static func railTileAndAngle(code: Int, sloped: Bool, slopeAngle: Int) -> (tile: Int, angle: Int) {
        sloped ? (0, slopeAngle) : railKinds[code & 15]
    }

    /// Rail slope angle for neighbour direction index 0..3 (a rail one node up in
    /// that direction makes this rail ascend toward it).
    static func railSlopeAngle(_ dir: Int) -> Int { railSlopeAngles[dir] }

    /// The rail quad in node-local 0..1 coords. Flat sits `y0` above the floor;
    /// sloped rises on the +Z edge to the node top. Rotated by `angle` about the
    /// node centre (matches Luanti's rotateXZBy). Corner order (x,z) is
    /// (0,0),(0,1),(1,1),(1,0) so the shared uv table lays the tile upright.
    static func railGeom(sloped: Bool, angle: Int) -> [SIMD3<Float>] {
        let y0: Float = 0.0625
        let hi: Float = sloped ? 1.0 + y0 : y0
        var q = [SIMD3<Float>(0, y0, 0), SIMD3(0, hi, 1), SIMD3(1, hi, 1), SIMD3(1, y0, 0)]
        if angle % 360 != 0 {
            let r = Float(angle) * .pi / 180, cs = cos(r), sn = sin(r)
            q = q.map { c in
                let x = c.x - 0.5, z = c.z - 0.5
                // Irrlicht rotateXZBy: x' = x*cos - z*sin, z' = x*sin + z*cos.
                return SIMD3(x * cs - z * sn + 0.5, c.y, x * sn + z * cs + 0.5)
            }
        }
        return q
    }

    // Signlike: a single flat quad hugging the wall the node is mounted to
    // (ladders, wall signs). wm is param2's wallmounted value (& 7):
    // 0 +Y floor, 1 -Y ceiling, 2 +X, 3 -X, 4 +Z, 5 -Z. The quad sits d off the
    // mounted face so it doesn't z-fight the wall, spanning the node in the other
    // two axes. Corners are ordered bottom-left,bottom-right,top-right,top-left so
    // the shared `uv` table lays the tile upright. Cull mode is .none, so a single
    // quad shows from both sides (you climb a ladder from the open face).
    private static func signQuad(_ wm: Int) -> [SIMD3<Float>] {
        let d: Float = 0.0625, e: Float = 0.9375
        switch wm {
        case 0:  return [SIMD3(0,e,0), SIMD3(1,e,0), SIMD3(1,e,1), SIMD3(0,e,1)]   // +Y floor (flat)
        case 1:  return [SIMD3(0,d,0), SIMD3(1,d,0), SIMD3(1,d,1), SIMD3(0,d,1)]   // -Y ceiling (flat)
        case 2:  return [SIMD3(e,0,0), SIMD3(e,0,1), SIMD3(e,1,1), SIMD3(e,1,0)]   // +X wall
        case 3:  return [SIMD3(d,0,0), SIMD3(d,0,1), SIMD3(d,1,1), SIMD3(d,1,0)]   // -X wall
        case 4:  return [SIMD3(0,0,e), SIMD3(1,0,e), SIMD3(1,1,e), SIMD3(0,1,e)]   // +Z wall
        default: return [SIMD3(0,0,d), SIMD3(1,0,d), SIMD3(1,1,d), SIMD3(0,1,d)]   // -Z wall
        }
    }

    // wallmounted param2 (0..7) -> 6d facedir, matching Luanti's
    // wallmounted_to_facedir table (directiontables.cpp).
    private static let wallmountedToFacedir: [UInt8] = [20, 0, 17, 15, 8, 6, 21, 1]

    // Resolve a node's param2 to a 6d facedir (0..23), honouring its
    // param_type_2. Mirrors MapNode::getFaceDir: facedir/colorfacedir use the
    // low 5 bits, 4dir/color4dir the low 2, wallmounted maps through the table.
    // pt2 values: 3 facedir, 4 wallmounted, 9 colorfacedir, 10 colorwallmounted,
    // 13 4dir, 14 color4dir. Anything else has no directional rotation.
    /// A type="wallmounted" node_box carries 3 boxes (wall_top, wall_bottom,
    /// wall_side); exactly ONE is drawn, chosen by the wallmounted param2, not
    /// all three (the plus-clump on buttons/floor heads, #212). Floor (0) uses
    /// wall_bottom, ceiling (1) wall_top, walls (2-5) wall_side rotated about Y
    /// to face the wall. (Wall facing may want a device spot-check; the box is
    /// centred on the origin so rotateFacedir's low 2 bits are a pure Y turn.)
    private static let wallSideFacedir: [UInt8] = [2, 0, 1, 3]
    public static func wallmountedBox(_ boxes: [NodeRegistry.Box], param2: UInt8) -> [NodeRegistry.Box] {
        guard boxes.count >= 3 else { return boxes }
        switch Int(param2 & 0x07) {
        case 1:  return [boxes[0]]                 // ceiling -> wall_top
        case 0:  return [boxes[1]]                 // floor -> wall_bottom
        default:
            // 2..5 wall -> wall_side turned to face the wall. The engine
            // (mapnode.cpp transformNodeBox) turns it 180 for x+, 0 for x-,
            // -90 for z+ and 90 for z-; in facedir low-bit terms (1 = -90,
            // 2 = 180, 3 = 90) that's this table, not (wm-2)&3.
            let fd = WorldMesher.wallSideFacedir[Int(param2 & 0x07) - 2]
            let a = rotateFacedir(boxes[2].min, fd), c = rotateFacedir(boxes[2].max, fd)
            return [NodeRegistry.Box(min: simd_min(a, c), max: simd_max(a, c))]
        }
    }

    // Texture rotation (R0..R3 = 0/90/180/270) for a facedir'd cube face,
    // straight from the engine's dir_to_tile[24][8] (mapblock_mesh.cpp): a
    // sideways log's bark turns so the grain runs along the log's axis, a
    // rotated pillar's cap lines up, etc. Indexed [facedir][dir_i] where
    // dir_i = (nx + 2ny + 3nz) & 7 for the world face normal.
    static let facedirTileRot: [[UInt8]] = [
        [0, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 3, 0, 0, 0, 1, 0],
        [0, 0, 2, 0, 0, 0, 2, 0],
        [0, 0, 1, 0, 0, 0, 3, 0],
        [0, 3, 0, 2, 0, 0, 2, 1],
        [0, 3, 0, 1, 0, 1, 2, 1],
        [0, 3, 0, 0, 0, 2, 2, 1],
        [0, 3, 0, 3, 0, 3, 2, 1],
        [0, 1, 2, 2, 0, 0, 0, 3],
        [0, 1, 2, 3, 0, 3, 0, 3],
        [0, 1, 2, 0, 0, 2, 0, 3],
        [0, 1, 2, 1, 0, 1, 0, 3],
        [0, 3, 3, 1, 0, 3, 3, 3],
        [0, 2, 3, 1, 0, 3, 3, 0],
        [0, 1, 3, 1, 0, 3, 3, 1],
        [0, 0, 3, 1, 0, 3, 3, 2],
        [0, 1, 1, 3, 0, 1, 1, 1],
        [0, 2, 1, 3, 0, 1, 1, 0],
        [0, 3, 1, 3, 0, 1, 1, 3],
        [0, 0, 1, 3, 0, 1, 1, 2],
        [0, 2, 2, 2, 0, 2, 2, 2],
        [0, 2, 3, 2, 0, 2, 1, 2],
        [0, 2, 0, 2, 0, 2, 0, 2],
        [0, 2, 1, 2, 0, 2, 3, 2]
    ]
    // dir_i for our six faces (order matches `faces`): +Y -Y +Z -Z +X -X.
    static let faceDirI: [Int] = [2, 6, 3, 5, 1, 7]

    /// Rotate a tile UV by R90/180/270 (content_mapblock applies this to the
    /// cuboid tcoords). rot 0 = identity.
    @inline(__always)
    static func rotUV(_ t: SIMD2<Float>, _ rot: UInt8) -> SIMD2<Float> {
        switch rot {
        case 1: return SIMD2(1 - t.y, t.x)       // R90
        case 2: return SIMD2(1 - t.x, 1 - t.y)   // R180
        case 3: return SIMD2(t.y, 1 - t.x)       // R270
        default: return t
        }
    }

    /// Flow direction from a flowing liquid's four corner heights (our h[x][z]),
    /// matching content_mapblock.cpp drawLiquidTop: positive dx = towards +X,
    /// positive dz = towards +Z (liquid slopes down that way). Returns the unit
    /// vector, or (1,0) when the surface is level so there's a stable default.
    static func liquidFlowDir(h00: Float, h10: Float, h01: Float, h11: Float) -> SIMD2<Float> {
        let dx = (h00 + h01) - (h10 + h11)
        let dz = (h00 + h10) - (h01 + h11)
        let v = SIMD2(dx, dz)
        let len = (v.x * v.x + v.y * v.y).squareRoot()
        return len > 1e-4 ? v / len : SIMD2(1, 0)
    }

    /// Rotate a top-face UV around its centre so a flowing liquid's animated
    /// texture runs in the flow direction, as the engine does per vertex in
    /// drawLiquidTop (the X axis turns to `dir`).
    static func flowRotUV(_ t: SIMD2<Float>, _ dir: SIMD2<Float>) -> SIMD2<Float> {
        let x = t.x - 0.5, y = t.y - 0.5
        return SIMD2(dir.x * x - dir.y * y + 0.5, dir.y * x + dir.x * y + 0.5)
    }

    /// Per-cell UV offset so the rotated flow texture continues seamlessly into
    /// the next cell (drawLiquidTop's tcoord_translate). Our top face maps
    /// u = local z and v = 1 - local x, so the cell's origin in that same UV
    /// space is (g.z, -g.x); rotate it by the flow direction like the corners
    /// and keep the fraction (whole-tile shifts vanish under repeat sampling).
    static func flowTranslateUV(_ g: SIMD3<Int>, _ dir: SIMD2<Float>) -> SIMD2<Float> {
        let bx = Float(g.z), by = Float(-g.x)
        let r = SIMD2(dir.x * bx - dir.y * by, dir.y * bx + dir.x * by)
        return r - r.rounded(.down)
    }

    /// Source tile index to sample on world face `worldFace` (index into
    /// `faces`) for a plain cube under facedir `fd`: the source face whose local
    /// normal, rotated by `fd`, lands on this world face. fd==0 is the identity.
    /// Tile selection only (no per-face texture twist), which is enough for logs/
    /// pumpkins/fronts to face the right way (#225).
    public static func cubeTile(_ worldFace: Int, _ fd: UInt8) -> Int {
        let f = faces[worldFace]
        if fd == 0 { return f.tile }
        let wn = SIMD3<Float>(Float(f.n.x), Float(f.n.y), Float(f.n.z))
        for s in faces where simd_length(rotateFacedir(SIMD3<Float>(Float(s.n.x), Float(s.n.y), Float(s.n.z)), fd) - wn) < 0.1 {
            return s.tile
        }
        return f.tile
    }

    /// Directional shade for a mesh vertex normal, matching the cube face
    /// constants (mesh.cpp applyFacesShading): +Y top brightest, -Y bottom
    /// darkest, Z faces mid, X faces between. Nearest dominant axis.
    @inline(__always)
    public static func normalShade(_ n: SIMD3<Float>) -> Float {
        let ax = abs(n.x), ay = abs(n.y), az = abs(n.z)
        if ay >= ax && ay >= az { return n.y >= 0 ? 1.00 : 0.447 }
        if az >= ax { return 0.837 }
        return 0.671
    }

    public static func meshFacedir(_ p2: UInt8, _ pt2: Int) -> UInt8 {
        switch pt2 {
        case 3, 9:   return (p2 & 0x1F) % 24
        // ContentParamType2 (nodedef.h): 12 colordegrotate, 13 4dir, 14 color4dir.
        // (A previous "fix" moved 4dir to 12 on a misread enum; campfires are
        // 13 and turned either way because 13 stayed in the case.)
        case 13, 14: return p2 & 0x03
        case 4, 10:  return wallmountedToFacedir[Int(min(p2 & 0x07, 7))]
        default:     return 0
        }
    }

    // Rotate a model-space position (centred on the origin) by a 6d facedir,
    // mirroring rotateMeshBy6dFacedir (client/mesh.cpp): the low 2 bits are a
    // rotation about Y (in the XZ plane), the high bits tip the node onto
    // another axis. rotator uses Luanti's convention u' = c*u - s*v,
    // v' = s*u + c*v; the 90/180 cases collapse to exact integer swaps so
    // there's no float drift.
    @inline(__always)
    public static func rotateFacedir(_ p0: SIMD3<Float>, _ facedir: UInt8) -> SIMD3<Float> {
        var p = p0
        // Y-axis rotation (XZ plane) from the low 2 bits.
        switch facedir & 0x03 {
        case 1: p = SIMD3( p.z, p.y, -p.x)   // XZ by -90
        case 2: p = SIMD3(-p.x, p.y, -p.z)   // XZ by 180
        case 3: p = SIMD3(-p.z, p.y,  p.x)   // XZ by 90
        default: break
        }
        // Axis tip from the high bits.
        switch facedir >> 2 {
        case 1: p = SIMD3(p.x, -p.z,  p.y)   // YZ by 90  (z+)
        case 2: p = SIMD3(p.x,  p.z, -p.y)   // YZ by -90 (z-)
        case 3: p = SIMD3( p.y, -p.x, p.z)   // XY by -90 (x+)
        case 4: p = SIMD3(-p.y,  p.x, p.z)   // XY by 90  (x-)
        case 5: p = SIMD3(-p.x, -p.y, p.z)   // XY by -180
        default: break
        }
        return p
    }

    /// Tilt an entity's local vertex by `pitch` radians in the X-Y plane, applied
    /// before the horizontal yaw so a mesh whose long axis is X (an arrow shaft)
    /// tips off horizontal (#128). Exactly identity at pitch 0, so entities that
    /// never pitch (mobs) are unchanged. Sign matches Ry's u' = c*u - s*v.
    @inline(__always)
    public static func pitchLocal(_ p: SIMD3<Float>, _ pitch: Float) -> SIMD3<Float> {
        if pitch == 0 { return p }
        let c = cos(pitch), s = sin(pitch)
        return SIMD3(p.x * c - p.y * s, p.x * s + p.y * c, p.z)
    }

    /// Rotation about the model's X axis (server rotation.x), the Y-Z plane
    /// counterpart of pitchLocal (#305).
    public static func tiltLocal(_ p: SIMD3<Float>, _ pitch: Float) -> SIMD3<Float> {
        if pitch == 0 { return p }
        let c = cos(pitch), s = sin(pitch)
        return SIMD3(p.x, p.y * c - p.z * s, p.y * s + p.z * c)
    }

    // These four run per node / per face in the inner loop. They read the
    // flat MeshSnapshot (built once per build()) instead of taking the registry
    // lock and hashing a dictionary each call -- that was ~15-20 locked lookups
    // per non-air node and dominated full remeshes (perf review #2).
    private typealias MS = NodeRegistry.MeshSnapshot
    @inline(__always)
    private static func renderKind(_ id: UInt16, _ ms: MS) -> NodeRegistry.RenderKind {
        if id == WorldMap.CONTENT_AIR || id == WorldMap.CONTENT_UNKNOWN || id == WorldMap.CONTENT_IGNORE { return .skip }
        return ms.k(id)
    }
    // Whether a node hides the cube face of its neighbour.
    @inline(__always)
    private static func occludes(_ id: UInt16, _ ms: MS) -> Bool {
        if id == WorldMap.CONTENT_AIR || id == WorldMap.CONTENT_UNKNOWN { return false }
        if id == WorldMap.CONTENT_IGNORE { return true }   // unloaded edge: keep it closed
        if ms.bl(id) { return false }                      // translucent (stained glass): the face behind shows through
        return ms.occ(id)
    }

    // A nodebox face flush with the node boundary is hidden when the neighbour
    // draws a full opaque face coplanar with it: a solid cube OR leaves (allfaces
    // render an opaque boundary face too). Without this, a snow layer / carpet /
    // slab resting on such a neighbour draws its bottom face at the exact plane of
    // the neighbour's top face and the two Z-fight (snow-on-leaves #220). Leaves
    // don't count as a full occluder elsewhere (you see into a cluster), so this
    // is a separate, boundary-only test.
    @inline(__always)
    private static func occludesBoundary(_ id: UInt16, _ ms: MS) -> Bool {
        if occludes(id, ms) { return true }
        return ms.k(id) == .allfaces
    }

    public typealias Mesh = (vertices: [Float], indices: [UInt32])

    // A liquid face is hidden if its neighbour fills the cell with an opaque cube
    // (so the water behind it can't be seen) or is an unloaded edge; only surfaces
    // exposed to air/plants are drawn. `.rooted` (kelp/coral/seagrass) counts: its
    // base is a full opaque cube, so without this the adjacent water drew a face
    // coplanar with the kelp cube face and Z-fought underwater.
    @inline(__always)
    private static func occludesLiquid(_ id: UInt16, _ ms: MS) -> Bool {
        if id == WorldMap.CONTENT_AIR || id == WorldMap.CONTENT_UNKNOWN { return false }
        if id == WorldMap.CONTENT_IGNORE { return true }
        // Glasslike is solidness 0 in the engine (content_mapblock getFaceInfo),
        // so a water face against glass is NOT hidden: aquarium/window builds
        // show the water through the pane. Everything else opaque-cube-like hides it.
        if ms.gl(id) { return false }
        let k = ms.k(id)
        return k == .cube || k == .rooted
    }

    /// Mesh the world (or, with `only`, just those mapblocks) into opaque +
    /// liquid buffers. Neighbour nodes are always read from the full `world`, so
    /// a subset mesh still culls border faces correctly against loaded
    /// neighbours; the caller re-meshes a changed block's neighbours too so a
    /// newly exposed/covered border face is picked up.
    public static func build<W: WorldView>(_ world: W, atlas: TextureAtlas, nodes: NodeRegistry,
                                           origin: SIMD3<Float> = .zero,
                                           scale: Float = 1.0,
                                           models: [UInt16: B3DLoader.Mesh] = [:],
                                           only: Set<SIMD3<Int>>? = nil)
                                           -> (opaque: (vertices: [Float], solid: [UInt32], cutout: [UInt32]), liquid: Mesh) {
        // One locked pass to snapshot the per-id tables the inner loop reads;
        // the helpers below then index flat arrays instead of hashing under
        // the registry lock per node/face (perf review #2).
        let ms = nodes.meshSnapshot()
        var ov: [Float] = [], oi: [UInt32] = [], si: [UInt32] = []
        var lv: [Float] = [], li: [UInt32] = []
        // One flowing-liquid corner scratch for the whole mesh, reused across
        // every liquid node/face (was reallocated per liquid node). Safe because
        // each `corners = fcorners` binding is dead before the next mutation, so
        // no copy-on-write copy is triggered (#189).
        var fcorners = [SIMD3<Float>](repeating: .zero, count: 4)
        var ftopUV = [SIMD2<Float>](repeating: .zero, count: 4)   // flowing-liquid top UV scratch, reused per top face (#329)
        ov.reserveCapacity(only == nil ? (1 << 16) : 4096)   // single-block meshes stay small
        // #164: opaque faces split into si (solid NDT_NORMAL cubes -> early-Z, no
        // discard) and oi (everything with possible alpha holes -> discard pass).
        // Both index the shared ov vertex buffer.
        var emitSolid = false

        // Block-pointer cache (#181): node lookups cluster within one 16^3 block
        // (a node and its 6 neighbours), so hold the last block and skip the dict
        // hash + getter on every call. Snapshot `blocks` once (COW, read-only mesh).
        // Returns exactly what WorldMap.nodeId/nodeLight/nodeParam2 would.
        let blockSnap = world.blocks
        var cacheBP = SIMD3(Int.min, Int.min, Int.min)
        var cacheBlk: WorldMap.MapBlock? = nil
        @inline(__always) func cBlock(_ p: SIMD3<Int>) -> WorldMap.MapBlock? {
            let bp = SIMD3(p.x >> 4, p.y >> 4, p.z >> 4)
            if bp != cacheBP { cacheBP = bp; cacheBlk = blockSnap[bp] }
            return cacheBlk
        }
        @inline(__always) func cNodeId(_ p: SIMD3<Int>) -> UInt16 {
            guard let b = cBlock(p) else { return WorldMap.CONTENT_IGNORE }
            return b.param0[WorldMap.index(p.x & 15, p.y & 15, p.z & 15)]
        }
        @inline(__always) func cNodeLight(_ p: SIMD3<Int>) -> UInt8 {
            guard let b = cBlock(p) else { return 0x0F }   // unloaded reads as full daylight
            return b.param1[WorldMap.index(p.x & 15, p.y & 15, p.z & 15)]
        }
        @inline(__always) func cNodeParam2(_ p: SIMD3<Int>) -> UInt8 {
            guard let b = cBlock(p) else { return 0 }
            return b.param2[WorldMap.index(p.x & 15, p.y & 15, p.z & 15)]
        }
        // Smooth lighting with ambient occlusion for one corner of a cube face
        // (mapblock_mesh.cpp getSmoothLightSolid): average the light of the four
        // nodes that share the corner on the face's outer side (the neighbour
        // plus the three beside it along the face plane), skipping opaque ones,
        // and darken by how many of the four are opaque (Luanti's ao_gamma 1.8
        // table). Returns the packed day + night*16 value for the vertex (#273).
        let aoAmount: [Float] = [1, 0.85, 0.68, 0.46, 0.46]
        func smoothLight(np: SIMD3<Int>, normal: SIMD3<Int>, corner: SIMD3<Float>) -> Float {
            var o1 = SIMD3<Int>(0, 0, 0), o2 = SIMD3<Int>(0, 0, 0)
            if normal.x != 0 {
                o1.y = corner.y < 0.5 ? -1 : 1; o2.z = corner.z < 0.5 ? -1 : 1
            } else if normal.y != 0 {
                o1.x = corner.x < 0.5 ? -1 : 1; o2.z = corner.z < 0.5 ? -1 : 1
            } else {
                o1.x = corner.x < 0.5 ? -1 : 1; o2.y = corner.y < 0.5 ? -1 : 1
            }
            var day: Float = 0, night: Float = 0, count = 0, ao = 0
            for sp in [np, np &+ o1, np &+ o2, np &+ o1 &+ o2] {
                let id = cNodeId(sp)
                if id == WorldMap.CONTENT_IGNORE { continue }
                if id != WorldMap.CONTENT_AIR, ms.occ(id) { ao += 1; continue }
                let l = cNodeLight(sp)
                day += Float(l & 0x0F); night += Float(l >> 4); count += 1
            }
            if count == 0 {
                let l = cNodeLight(np); day = Float(l & 0x0F); night = Float(l >> 4); count = 1
            }
            let k = aoAmount[min(ao, 4)]
            let d = min(15, (day / Float(count)) * k), n = min(15, (night / Float(count)) * k)
            return d + n * 16
        }
        // Smooth light for a vertex of a see-through node (plants, mesh nodes),
        // after mapblock_mesh.cpp getSmoothLightTransparent: average the eight
        // nodes around the vertex's corner (own node included), skipping opaque
        // ones, and only start darkening past four opaque like the engine's
        // light_amount table. Cached per octant, since a chest mesh has hundreds
        // of vertices but only eight corners' worth of distinct answers.
        let aoOctant: [Float] = [1, 1, 1, 1, 1, 0.85, 0.68, 0.46, 0.46]
        var octantNode = SIMD3<Int>(Int.min, 0, 0)
        var octantCache = SIMD8<Float>(repeating: -1)
        func octantLight(_ g: SIMD3<Int>, _ c: SIMD3<Float>) -> Float {
            if octantNode != g { octantNode = g; octantCache = SIMD8(repeating: -1) }
            let sx = c.x < 0.5 ? -1 : 1, sy = c.y < 0.5 ? -1 : 1, sz = c.z < 0.5 ? -1 : 1
            let key = (sx > 0 ? 1 : 0) | (sy > 0 ? 2 : 0) | (sz > 0 ? 4 : 0)
            if octantCache[key] >= 0 { return octantCache[key] }
            var day: Float = 0, night: Float = 0, count = 0, ao = 0
            for i in 0..<8 {
                let sp = SIMD3(g.x + (i & 1 != 0 ? sx : 0), g.y + (i & 2 != 0 ? sy : 0), g.z + (i & 4 != 0 ? sz : 0))
                let id = cNodeId(sp)
                if id == WorldMap.CONTENT_IGNORE { continue }
                if id != WorldMap.CONTENT_AIR, ms.occ(id) { ao += 1; continue }
                let l = cNodeLight(sp)
                day += Float(l & 0x0F); night += Float(l >> 4); count += 1
            }
            if count == 0 {
                let l = cNodeLight(g); day = Float(l & 0x0F); night = Float(l >> 4); count = 1
            }
            let k = aoOctant[min(ao, 8)]
            let v = min(15, day / Float(count) * k) + min(15, night / Float(count) * k) * 16
            octantCache[key] = v
            return v
        }

        @inline(__always)
        // The renderer back-face culls the SOLID stream (#85), which the engine
        // only does for NDT_NORMAL cubes (content_mapblock.cpp: backface_culling
        // = drawtype == NDT_NORMAL). Every other drawtype (leaves, plants,
        // glass, nodeboxes, meshes) lands in the cutout stream, which the
        // renderer draws two-sided (cull .none), so no reversed twin is needed:
        // the twin doubled the cutout triangle count for the rasteriser to
        // throw half of it away.
        // nodedef waving class for the node being emitted (1 plants, 2 leaves),
        // carried to the vertex shader as shade + 2*class: shade itself is
        // 0..1 so the shader splits them with floor(x/2) (#300). Liquids wave
        // in the liquid pass on their own and never set this.
        var waveShift: Float = 0
        // Append one 9-float vertex / one 6-index quad without a throwaway array
        // literal per call: the mesher emits tens of thousands of these per remesh
        // (fires on every dig/place/stream), so the per-quad malloc churn matters.
        func pushVert(_ a: inout [Float], _ px: Float, _ py: Float, _ pz: Float, _ u: Float, _ v: Float, _ layer: Float, _ shade: Float, _ light: Float, _ tint: Float) {
            a.append(px); a.append(py); a.append(pz); a.append(u); a.append(v); a.append(layer); a.append(shade); a.append(light); a.append(tint)
        }
        func pushQuadIdx(_ a: inout [UInt32], _ vb: UInt32) {
            a.append(vb); a.append(vb+1); a.append(vb+2); a.append(vb); a.append(vb+2); a.append(vb+3)
        }
        func emitQuad(_ corners: [SIMD3<Float>], base b: SIMD3<Int>, layer: Float, shade: Float, light: Float, liquid: Bool, tint: Float = 16777215, uvs: [SIMD2<Float>]? = nil) {
            emitQuad(corners, base: b, layer: layer, shade: shade, lights: SIMD4(repeating: light), liquid: liquid, tint: tint, uvs: uvs)
        }
        // Per-corner light (smooth lighting, #273): one packed day+night*16
        // value per vertex; the vertex shader unpacks so the banks interpolate
        // separately across the face.
        func emitQuad(_ corners: [SIMD3<Float>], base b: SIMD3<Int>, layer: Float, shade: Float, lights: SIMD4<Float>, liquid: Bool, tint: Float = 16777215, uvRot: UInt8 = 0, uvs: [SIMD2<Float>]? = nil) {
            let vb = UInt32((liquid ? lv.count : ov.count) / 9)
            for k in 0..<4 {
                let c = corners[k]
                let px = (Float(b.x) + c.x - origin.x) * scale
                let py = (Float(b.y) + c.y - origin.y) * scale
                let pz = (Float(b.z) + c.z - origin.z) * scale
                let t = uvs?[k] ?? (uvRot == 0 ? uv[k] : WorldMesher.rotUV(uv[k], uvRot))
                let light = lights[k]
                if liquid { pushVert(&lv, px, py, pz, t.x, t.y, layer, shade, light, tint) }
                else      { pushVert(&ov, px, py, pz, t.x, t.y, layer, shade + waveShift, light, tint) }
            }
            if liquid { pushQuadIdx(&li, vb) }
            else if emitSolid {
                pushQuadIdx(&si, vb)   // solid cube face: early-Z pass, one-sided, no twin
            } else {
                pushQuadIdx(&oi, vb)   // cutout stream: drawn two-sided by the renderer
            }
        }

        // Emit one nodebox AABB (node-local -0.5..0.5) as 6 textured faces into
        // the opaque mesh. UVs come from boxUV so partial boxes sample the right
        // slice of their tile. All faces are drawn (no inter-box culling).
        @inline(__always)
        func emitBox(_ box: NodeRegistry.Box, base b: SIMD3<Int>, id: UInt16, light: Float, tint: Float = 16777215, facedir: UInt8 = 0) {
            var lo = box.min + SIMD3(repeating: 0.5)   // -0.5..0.5 -> 0..1 node-local
            var hi = box.max + SIMD3(repeating: 0.5)
            // A facedir'd box (an open door) can rotate a face flush onto the
            // shared boundary with the neighbouring wall, and the flush-face cull
            // below only fires for un-rotated boxes -- so the door panel and the
            // wall face z-fought (Eric). Pull a rotated box in by a hair so its
            // faces never sit exactly coplanar with a neighbour; the gap is far
            // too small to see but breaks the depth tie.
            if facedir != 0 {
                let eps: Float = 0.0025
                lo += SIMD3(repeating: eps); hi -= SIMD3(repeating: eps)
            }
            // A blended nodebox (nether portal: translucent animated purple) must
            // go to the alpha-BLEND (liquid) stream, not the cutout/discard pass
            // where its low-alpha pixels vanish -- same routing glass cubes use
            // (shade + 2.0 marks it "blended, not water" to the liquid shader).
            // Opaque nodeboxes (doors/fences/walls) stay in the cutout stream (#177).
            let blended = ms.bl(id)
            // Cull a face that lies flush with the node's outer boundary when the
            // neighbour in that direction draws a coplanar opaque face (#220). Only
            // for an un-rotated box: a facedir'd box (doors) moves its faces off the
            // axis, so the flush/neighbour test no longer lines up -- leave those
            // drawing every face as before.
            @inline(__always) func flushBoundary(_ n: SIMD3<Int>) -> Bool {
                (n.y > 0 && hi.y >= 0.999) || (n.y < 0 && lo.y <= 0.001)
                || (n.x > 0 && hi.x >= 0.999) || (n.x < 0 && lo.x <= 0.001)
                || (n.z > 0 && hi.z >= 0.999) || (n.z < 0 && lo.z <= 0.001)
            }
            for f in faces {
                if facedir == 0, flushBoundary(f.n),
                   WorldMesher.occludesBoundary(cNodeId(b &+ f.n), ms) { continue }
                let vbase = UInt32((blended ? lv.count : ov.count) / 9)
                let layer = Float(atlas.layer(id: id, face: f.tile))
                // A light_source nodebox (sea pickle, redstone lamp) skips the
                // directional face shade so all faces read equally bright, like
                // the cube and mesh paths (content_mapblock shade_face).
                let base = ms.lit(id) ? 1.0 : f.shade
                let shade = blended ? base + 2.0 : base
                // Smooth 8-corner light + AO, like the engine's drawAutoLightedCuboid,
                // for un-rotated boxes (slabs, stairs, fences, walls, panes): each
                // corner samples the node-corner light frame so junctions darken
                // and faces gradient instead of the whole box reading one flat
                // value. Rotated boxes (doors) keep the flat node light -- their
                // faces move off-axis so the corner frame no longer lines up.
                let smooth = facedir == 0
                let np = b &+ f.n
                for corner in f.c {
                    // corner components are 0 or 1: pick lo/hi per axis.
                    var l = SIMD3<Float>(corner.x == 0 ? lo.x : hi.x,
                                         corner.y == 0 ? lo.y : hi.y,
                                         corner.z == 0 ? lo.z : hi.z)
                    let t = boxUV(f.n, l)   // UV from the un-rotated face (texture rides along)
                    let vlight = smooth ? smoothLight(np: np, normal: f.n, corner: l) : light
                    // param2 facedir rotates the box about the node centre, so a
                    // door faces the way it was placed and visibly swings when it
                    // opens (the server rotates param2). Rotate in centred space.
                    if facedir != 0 { l = WorldMesher.rotateFacedir(l - 0.5, facedir) + 0.5 }
                    let px = (Float(b.x) + l.x - origin.x) * scale
                    let py = (Float(b.y) + l.y - origin.y) * scale
                    let pz = (Float(b.z) + l.z - origin.z) * scale
                    if blended { pushVert(&lv, px, py, pz, t.x, t.y, layer, shade, vlight, tint) }
                    else       { pushVert(&ov, px, py, pz, t.x, t.y, layer, shade + waveShift, vlight, tint) }
                }
                if blended { pushQuadIdx(&li, vbase) } else { pushQuadIdx(&oi, vbase) }
            }
        }

        // Emit a mesh-drawtype node's custom model. The model is authored in
        // node-local space centred at the origin (Luanti's -0.5..0.5 cube),
        // scaled by visual_scale; shift by +0.5 to the 0..1 node-local range the
        // rest of the mesher uses, then place at the node. Textured with the
        // node's first tile (model UVs index that layer directly). param2 is
        // resolved to a 6d facedir and the model rotated about its origin (the
        // node centre), so wall-mounted lanterns and directional chains face the
        // right way, mirroring drawMeshNode's rotateMeshBy6dFacedir.
        @inline(__always)
        func emitMeshModel(_ m: B3DLoader.Mesh, base b: SIMD3<Int>, id: UInt16, p2: UInt8, light: Float, vscale: Float, tint: Float = 16777215) {
            let layer = Float(atlas.layer(id: id, face: 0))
            let vbase = UInt32(ov.count / 9)
            let pt2 = ms.p2t(id)
            let facedir = WorldMesher.meshFacedir(p2, pt2)
            // degrotate / colordegrotate (standing signs, floor heads): the
            // engine turns the mesh about Y by 1.5 * getDegRotate degrees
            // (content_mapblock.cpp drawMeshNode, mapnode.cpp getDegRotate).
            let deg: Float = pt2 == 6 ? 1.5 * Float(p2 % 240) : pt2 == 12 ? 1.5 * Float(10 * ((p2 & 0x1F) % 24)) : 0
            let rad = deg * .pi / 180, cs = cos(rad), sn = sin(rad)
            // Per-vertex normals, accumulated from the model's triangles, so a
            // mesh node (lantern, bed, chest, chain) is shaded by facing like the
            // engine's applyFacesShading -- flat shade 1.0 made them look pasted
            // on. light_source meshes keep 1.0 (they self-illuminate).
            let lit = ms.lit(id)
            var nrm = [SIMD3<Float>](repeating: .zero, count: m.positions.count)
            if !lit {
                var i = 0
                while i + 2 < m.indices.count {
                    let a = Int(m.indices[i]), bx = Int(m.indices[i+1]), c = Int(m.indices[i+2]); i += 3
                    let fn = simd_cross(m.positions[bx] - m.positions[a], m.positions[c] - m.positions[a])
                    nrm[a] += fn; nrm[bx] += fn; nrm[c] += fn
                }
            }
            for k in 0..<m.positions.count {
                var p = facedir == 0 ? m.positions[k] : WorldMesher.rotateFacedir(m.positions[k], facedir)
                if deg != 0 { p = SIMD3(p.x * cs - p.z * sn, p.y, p.x * sn + p.z * cs) }   // rotateXZBy
                let lx = p.x * vscale + 0.5, ly = p.y * vscale + 0.5, lz = p.z * vscale + 0.5
                let px = (Float(b.x) + lx - origin.x) * scale
                let py = (Float(b.y) + ly - origin.y) * scale
                let pz = (Float(b.z) + lz - origin.z) * scale
                let t = m.uvs[k]
                var shade: Float = 1.0
                if !lit, nrm[k] != .zero {
                    var n = simd_normalize(nrm[k])
                    if facedir != 0 { n = WorldMesher.rotateFacedir(n, facedir) }
                    if deg != 0 { n = SIMD3(n.x * cs - n.z * sn, n.y, n.x * sn + n.z * cs) }
                    shade = WorldMesher.normalShade(n)
                }
                // Per-vertex smooth light so a chest against a wall darkens on
                // that side; self-lit meshes (lanterns) keep their flat light.
                let vl = lit ? light : octantLight(b, SIMD3(lx, ly, lz))
                pushVert(&ov, px, py, pz, t.x, t.y, layer, shade + waveShift, vl, tint)
            }
            for i in m.indices { oi.append(vbase + i) }
        }

        // Packed biome tint (r + g*256 + b*65536) for a node/param2, or packed
        // white (16777215) when the node isn't palette-tinted.
        @inline(__always)
        func tintFor(_ id: UInt16, _ p2: UInt8) -> Float {
            guard let colors = atlas.paletteColors(id), !colors.isEmpty else { return 16777215 }
            let idx: Int
            switch ms.p2t(id) {
            case 9:     idx = Int(p2) >> 5          // colorfacedir: top 3 bits
            // colorwallmounted packs index*8 + dir (mcl_util/nodes.lua); the
            // engine indexes its 256-stretched palette by the raw byte, which
            // for the 32-entry vine palette ([combine:16x2 of the foliage
            // image) is the same as p2/8 into the first 32 foliage colours.
            case 10:    idx = Int(p2) >> 3
            case 12:    idx = Int(p2) >> 5          // colordegrotate: 3 bits of palette index
            case 14:    idx = Int(p2) >> 2          // color4dir
            default:    idx = Int(p2)               // color (8): full byte
            }
            let c = colors[min(max(idx, 0), colors.count - 1)]
            // Unused palette slots are black; tinting by them turns the node
            // black. Treat near-black as "no tint" so it keeps its texture.
            if c.x + c.y + c.z < 0.06 { return 16777215 }
            let r = min(255, max(0, Int(c.x * 255 + 0.5)))
            let g = min(255, max(0, Int(c.y * 255 + 0.5)))
            let bl = min(255, max(0, Int(c.z * 255 + 0.5)))
            return Float(r + g * 256 + bl * 65536)
        }

        // MapblockMeshGenerator::getCornerLevel, in 0..1 node space: the top
        // corner (cx,cz) of liquid node g looks at the 4 cells around that
        // corner. Same-family liquid above any of them, or a source among them,
        // pins the corner to the top; flowing cells average their param2 level
        // (scaled by liquid_range); two or more air cells drop the corner to
        // just above the floor, which is what makes a flow's edge slope down.
        func liquidCorner(_ g: SIMD3<Int>, _ cx: Int, _ cz: Int, family: (source: UInt16, flowing: UInt16)) -> Float {
            let range = nodes.liquidRange(family.flowing)
            var sum: Float = 0, cnt = 0, air = 0
            for dz in 0..<2 { for dx in 0..<2 {
                let cell = SIMD3(g.x + cx - 1 + dx, g.y, g.z + cz - 1 + dz)
                let cid = cNodeId(cell)
                if cid == WorldMap.CONTENT_IGNORE { continue }
                let above = cNodeId(SIMD3(cell.x, cell.y + 1, cell.z))
                if above == family.source || above == family.flowing { return 1.0 }
                if cid == family.source { return 1.0 }
                if cid == family.flowing {
                    var level = Int(cNodeParam2(cell) & 0x07)
                    level = level <= 8 - range ? 0 : level - (8 - range)
                    sum += (Float(level) + 0.5) / Float(range); cnt += 1
                } else if cid == WorldMap.CONTENT_AIR {
                    air += 1
                }
            } }
            if air >= 2 { return 0.02 }
            if cnt > 0 { return sum / Float(cnt) }
            return 0.5
        }

        let blockList: [(SIMD3<Int>, WorldMap.MapBlock)] = only.map { keys in
            keys.compactMap { k in world.blocks[k].map { (k, $0) } }
        } ?? Array(world.blocks)
        for (bpos, block) in blockList {
            let base = SIMD3(bpos.x * 16, bpos.y * 16, bpos.z * 16)
            for ly in 0..<16 { for lz in 0..<16 { for lx in 0..<16 {
                let nodeIdx = WorldMap.index(lx, ly, lz)
                let id = block.param0[nodeIdx]
                let g = SIMD3(base.x + lx, base.y + ly, base.z + lz)
                if renderKind(id, ms) == .skip { continue }
                let tint = tintFor(id, block.param2[nodeIdx])   // biome palette colour
                if nodes.isLiquid(id) {
                    // Source stays a full cube; flowing liquid lowers its top
                    // corners to the level in param2 for a sloped surface.
                    let flowing = nodes.drawtype(id) == 3
                    // Lava is flagged to the liquid shader by a negative shade,
                    // so it renders opaque/glowing instead of translucent blue.
                    let lava = nodes.isLava(id)
                    let fam = nodes.liquidFamily(id) ?? (source: id, flowing: id)
                    let h00 = flowing ? liquidCorner(g, 0, 0, family: fam) : 1
                    let h10 = flowing ? liquidCorner(g, 1, 0, family: fam) : 1
                    let h01 = flowing ? liquidCorner(g, 0, 1, family: fam) : 1
                    let h11 = flowing ? liquidCorner(g, 1, 1, family: fam) : 1
                    for f in faces {
                        let np = SIMD3(g.x + f.n.x, g.y + f.n.y, g.z + f.n.z)
                        if occludesLiquid(cNodeId(np), ms) { continue }
                        let layer = Float(atlas.layer(id: id, face: f.tile))
                        let light = Float(cNodeLight(np))
                        // Drop each top corner (y==1) to its computed height; the
                        // bottom corners (y==0) stay put, so tops slope and side
                        // faces become trapezoids down to the node floor. Reuse a
                        // scratch array instead of f.c.map (no per-face alloc).
                        let corners: [SIMD3<Float>]
                        if flowing {
                            for k in 0..<4 {
                                let c = f.c[k]
                                if c.y > 0.5 {
                                    let hh = c.x < 0.5 ? (c.z < 0.5 ? h00 : h01) : (c.z < 0.5 ? h10 : h11)
                                    fcorners[k] = SIMD3(c.x, hh, c.z)
                                } else { fcorners[k] = c }
                            }
                            corners = fcorners
                        } else { corners = f.c }
                        // Turn the flowing top texture so its animation runs downhill,
                        // like drawLiquidTop: rotate each top-face UV by the flow
                        // direction derived from the corner heights (#329).
                        var topUVs: [SIMD2<Float>]? = nil
                        if flowing, f.n.y > 0 {
                            let dir = WorldMesher.liquidFlowDir(h00: h00, h10: h10, h01: h01, h11: h11)
                            let tr = WorldMesher.flowTranslateUV(g, dir)
                            for k in 0..<4 { ftopUV[k] = WorldMesher.flowRotUV(WorldMesher.uv[k], dir) + tr }
                            topUVs = ftopUV   // dead before the next top face mutates it (no COW copy)
                        }
                        emitQuad(corners, base: g, layer: layer, shade: lava ? -f.shade : f.shade,
                                 light: light, liquid: true, tint: tint, uvs: topUVs)
                    }
                    continue
                }
                let rk = renderKind(id, ms)
                waveShift = Float(nodes.waving(id)) * 2
                // Solid = a fully-opaque cube face (no alpha holes, back-face
                // culled): route to the early-Z pass. Blended (glass, goes to the
                // liquid pass anyway) and clip cubes stay in the discard pass (#164).
                emitSolid = rk == .cube && !ms.bl(id) && !ms.cl(id)
                switch rk {
                case .plant:
                    let layer = Float(atlas.layer(id: id, face: 0))
                    let light = Float(world.nodeLightLit(g))
                    // drawPlantlike: visual_scale sizes the quad; meshoptions
                    // (paramtype2 7) picks the style (VoxeLibre crops use 3, "#"),
                    // 0x10 scales by sqrt 2, 0x08 jitters X/Z, 0x20 sinks the quad
                    // a little; degrotate (6) / colordegrotate (12) turn the cross.
                    var s = nodes.visualScale(id)
                    var style = 0
                    var rot: Float = 0
                    var off = SIMD3<Float>.zero
                    var randomY = false
                    let p2 = block.param2[nodeIdx]
                    switch ms.p2t(id) {
                    case 7:
                        style = min(Int(p2 & 0x07), 4)
                        if p2 & 0x10 != 0 { s *= 1.41421 }
                        if p2 & 0x08 != 0 {
                            var rng = PseudoRandom(seed: UInt32(truncatingIfNeeded: g.x << 8 | g.z | g.y << 16))
                            off.x = Float(rng.draw() % 16) / 16 * 0.29 - 0.145
                            off.z = Float(rng.draw() % 16) / 16 * 0.29 - 0.145
                        }
                        randomY = p2 & 0x20 != 0
                    case 6:  rot = 1.5 * Float(p2 % 240)
                    case 12: rot = 1.5 * Float(10 * ((p2 & 0x1F) % 24))
                    default: break
                    }
                    for (qi, q) in WorldMesher.plantStyles[style].enumerated() {
                        var o = off
                        if randomY {
                            var yrng = PseudoRandom(seed: UInt32(truncatingIfNeeded: qi | g.x << 16 | g.z << 8 | g.y << 24))
                            o.y = -Float(yrng.draw() % 16) / 16 * 0.125
                        }
                        let quad = WorldMesher.plantQuad(rotDeg: q.rot + rot, scale: s, height: 1, offsetZ: q.off, topOnly: q.topOnly, offset: o)
                        // Smooth light per corner (engine blendLightColor on plants):
                        // the base of a flower in a shaded corner goes dark while its
                        // top still catches the sky. Glowing plants stay flat.
                        let lights = ms.lit(id) ? SIMD4(repeating: light)
                            : SIMD4(octantLight(g, quad[0]), octantLight(g, quad[1]), octantLight(g, quad[2]), octantLight(g, quad[3]))
                        emitQuad(quad, base: g, layer: layer, shade: 1.0, lights: lights, liquid: false, tint: tint)
                    }
                case .rooted:
                    // plantlike_rooted (kelp, coral, sea pickle, seagrass): a solid
                    // base cube plus a plantlike plant from special_tiles[0] grown
                    // one node up (Luanti drawPlantlikeRootedNode). Multi-segment
                    // height from leveled param2 is a follow-up; this draws one.
                    emitSolid = true                         // base is a normal opaque cube
                    for f in faces {
                        let np = SIMD3(g.x + f.n.x, g.y + f.n.y, g.z + f.n.z)
                        if occludes(cNodeId(np), ms) { continue }
                        let layer = Float(atlas.layer(id: id, face: f.tile))
                        let light = Float(cNodeLight(np))
                        emitQuad(f.c, base: g, layer: layer, shade: f.shade, light: light, liquid: false, tint: tint)
                    }
                    if let sp = nodes.specialTile(id), let sl = atlas.tileLayer(sp) {
                        emitSolid = false                    // plant has alpha: cutout stream
                        let up = SIMD3(g.x, g.y + 1, g.z)
                        let light = Float(world.nodeLightLit(up))
                        // Leveled param2 (5) sets the plant height = param2/16 nodes
                        // (kelp grows tall); other rooted plants are a single node.
                        // param2 0 falls back to 1 so a plant is never invisible.
                        let raw = Float(block.param2[nodeIdx]) / 16.0
                        let h = ms.p2t(id) == 5 && raw > 0 ? raw : 1.0
                        for q in WorldMesher.plantQuadsTall(h, scale: nodes.visualScale(id)) { emitQuad(q, base: up, layer: Float(sl), shade: 1.0, light: light, liquid: false, tint: tint) }
                    }
                case .torch:
                    let layer = Float(atlas.layer(id: id, face: 0))
                    let light = Float(world.nodeLightLit(g))
                    for q in torchQuads { emitQuad(q, base: g, layer: layer, shade: 1.0, light: light, liquid: false) }
                case .fire:
                    let layer = Float(atlas.layer(id: id, face: 0))
                    let light = Float(world.nodeLightLit(g))
                    // A neighbour is a surface fire leans on: anything not air,
                    // not unloaded, and not more of this fire (matches Luanti).
                    var solid = [Bool](repeating: false, count: 6)
                    for (i, d) in WorldMesher.fireDirs.enumerated() {
                        let nid = cNodeId(SIMD3(g.x + d.x, g.y + d.y, g.z + d.z))
                        solid[i] = nid != WorldMap.CONTENT_AIR && nid != WorldMap.CONTENT_IGNORE && nid != id
                    }
                    for q in WorldMesher.firelikeQuads(solid) { emitQuad(q, base: g, layer: layer, shade: 1.0, light: light, liquid: false, tint: tint) }
                case .rail:
                    let light = Float(world.nodeLightLit(g))
                    // A neighbour connects if it's the same node or any raillike.
                    func isRail(_ np: SIMD3<Int>) -> Bool {
                        let nid = cNodeId(np)
                        return nid == id || renderKind(nid, ms) == .rail
                    }
                    var code = 0, sloped = false, slopeAngle = 0
                    for (dir, d) in WorldMesher.railDirs.enumerated() {
                        let up = SIMD3(g.x + d.x, g.y + 1, g.z + d.z)
                        let level = SIMD3(g.x + d.x, g.y, g.z + d.z)
                        let down = SIMD3(g.x + d.x, g.y - 1, g.z + d.z)
                        if isRail(up) { sloped = true; slopeAngle = WorldMesher.railSlopeAngle(dir) }
                        if isRail(up) || isRail(level) || isRail(down) { code |= 1 << dir }
                    }
                    let (tileIdx, angle) = WorldMesher.railTileAndAngle(code: code, sloped: sloped, slopeAngle: slopeAngle)
                    let layer = Float(atlas.layer(id: id, face: tileIdx))
                    emitQuad(WorldMesher.railGeom(sloped: sloped, angle: angle), base: g, layer: layer, shade: 1.0, light: light, liquid: false)
                case .sign:
                    let wm = Int(block.param2[nodeIdx]) & 0x07
                    let layer = Float(atlas.layer(id: id, face: 0))
                    let light = Float(world.nodeLightLit(g))
                    emitQuad(signQuad(wm), base: g, layer: layer, shade: 1.0, light: light, liquid: false, tint: tint)
                case .nodebox:
                    let light = Float(world.nodeLightLit(g))
                    if let boxes = nodes.boxes(id), !boxes.isEmpty {
                        if nodes.isWallmountedBox(id) {
                            // Wallmounted node_box: draw only the one box the
                            // param2 selects (buttons/heads), not all three (#212).
                            for box in WorldMesher.wallmountedBox(boxes, param2: block.param2[nodeIdx]) {
                                emitBox(box, base: g, id: id, light: light, tint: tint, facedir: 0)
                            }
                        } else {
                        let fd = WorldMesher.meshFacedir(block.param2[nodeIdx], ms.p2t(id))
                        for box in boxes { emitBox(box, base: g, id: id, light: light, tint: tint, facedir: fd) }
                        // Connected nodeboxes (fences/walls/panes): add each arm
                        // whose neighbour is in this node's connects_to set. Arm
                        // order: top,bottom,front,left,back,right (+Y,-Y,-Z,-X,+Z,+X).
                        if let arms = nodes.connectArms(id) {
                            let dirs = [SIMD3(0,1,0), SIMD3(0,-1,0), SIMD3(0,0,-1),
                                        SIMD3(-1,0,0), SIMD3(0,0,1), SIMD3(1,0,0)]
                            for (di, off) in dirs.enumerated() where di < arms.count {
                                let np = SIMD3(g.x + off.x, g.y + off.y, g.z + off.z)
                                // nodeboxConnects: mutual connects_to between two
                                // connected nodeboxes, and the target's
                                // connect_sides gate for anything else (#299).
                                if nodes.nodeboxConnects(from: id, to: cNodeId(np), dir: di) {
                                    for box in arms[di] { emitBox(box, base: g, id: id, light: light, tint: tint, facedir: fd) }
                                }
                            }
                        }
                        }   // end non-wallmounted branch
                    } else {
                        // No usable boxes: fall back to a full cube.
                        for f in faces {
                            let np = SIMD3(g.x + f.n.x, g.y + f.n.y, g.z + f.n.z)
                            if occludes(cNodeId(np), ms) { continue }
                            let layer = Float(atlas.layer(id: id, face: f.tile))
                            emitQuad(f.c, base: g, layer: layer, shade: f.shade,
                                     light: Float(cNodeLight(np)), liquid: false, tint: tint)
                        }
                    }
                case .mesh:
                    // Custom .obj/.b3d model. If the file hasn't loaded yet,
                    // draw nothing and pick it up on a later remesh (no cube
                    // fallback — a cube would misrepresent a lantern/chain).
                    if let m = models[id] {
                        let light = Float(world.nodeLightLit(g))
                        emitMeshModel(m, base: g, id: id, p2: block.param2[nodeIdx], light: light, vscale: nodes.visualScale(id), tint: tint)
                    }
                case .cube, .allfaces:
                    // allfaces (leaves) mesh like cubes but don't occlude each
                    // other, so faces into non-leaf neighbours (air, glass) stay.
                    // BUT the face between two of the SAME leaf is culled: two
                    // coplanar cull-none faces at the same depth z-fight (#204).
                    // This matches "fast leaves"; you still see into a cluster at
                    // its air-facing edges.
                    // Stained glass (use_texture_alpha="blend") draws in the
                    // translucent pass with its texture's own alpha, flagged by a
                    // shade offset of +2 (like lava's negative shade). A face
                    // between two of the SAME glass is hidden, matching Luanti.
                    let glass = ms.bl(id)
                    // facedir/4dir tile permutation for a plain cube: pick the
                    // SOURCE tile whose local normal, rotated by param2, lands on
                    // this world face -- so a horizontal log shows rings on the
                    // axis ends and bark on the sides, carved pumpkins/furnace/
                    // dispenser fronts face the placed way (#225). allfaces/leaves
                    // don't use facedir. Tile selection only (no texture twist).
                    let fd = rk == .cube ? WorldMesher.meshFacedir(block.param2[nodeIdx], ms.p2t(id)) : 0
                    let overlays = ms.ov(id)       // lock-free (folded into the snapshot)
                    let ownColor = ms.kc(id)
                    for (fi, f) in faces.enumerated() {
                        let np = SIMD3(g.x + f.n.x, g.y + f.n.y, g.z + f.n.z)
                        let nid = cNodeId(np)
                        if occludes(nid, ms) { continue }
                        if nid == id, glass || rk == .allfaces || ms.gl(id) { continue }   // same glass/leaf: cull shared face (#204, #265)
                        let srcTile = WorldMesher.cubeTile(fi, fd)
                        // Facedir also ROTATES the tile (not just picks it), so
                        // log grain / pillar caps line up (mapblock_mesh dir_to_tile).
                        let uvRot = fd == 0 ? 0 : WorldMesher.facedirTileRot[Int(fd)][WorldMesher.faceDirI[fi]]
                        let layer = Float(atlas.layer(id: id, face: srcTile))
                        let lights = SIMD4<Float>(smoothLight(np: np, normal: f.n, corner: f.c[0]),
                                                  smoothLight(np: np, normal: f.n, corner: f.c[1]),
                                                  smoothLight(np: np, normal: f.n, corner: f.c[2]),
                                                  smoothLight(np: np, normal: f.n, corner: f.c[3]))
                        // light_source cubes (glowstone, sea lantern, shroomlight,
                        // jack o'lantern) skip the directional face shade so all
                        // six faces read equally bright (content_mapblock shade_face).
                        let faceShade = ms.lit(id) ? 1.0 : f.shade
                        // A tile with its own colour (grass-block dirt sides are
                        // color="white") skips the palette tint; the tint goes on
                        // the overlay instead (mapblock_mesh.cpp: tint only when
                        // !tile.has_color).
                        let faceTint = (ownColor?[srcTile] ?? false) ? 16777215 : tint
                        if glass {
                            emitQuad(f.c, base: g, layer: layer, shade: faceShade + 2.0, lights: lights, liquid: true, tint: faceTint, uvRot: uvRot)
                        } else {
                            emitQuad(f.c, base: g, layer: layer, shade: faceShade, lights: lights, liquid: false, tint: faceTint, uvRot: uvRot)
                        }
                        // tiles_overlay: the engine's second layer on the same
                        // face (the grass fringe over dirt). Drawn as a cutout
                        // quad a hair outside the face so it wins the depth test
                        // without a polygon offset, tinted by the palette.
                        if let overlays {
                            let name = overlays[srcTile]
                            if !name.isEmpty, let ol = atlas.tileLayer(name) {
                                let lift: Float = 0.003
                                let oc = f.c.map { $0 + SIMD3<Float>(Float(f.n.x), Float(f.n.y), Float(f.n.z)) * lift }
                                let wasSolid = emitSolid; emitSolid = false
                                emitQuad(oc, base: g, layer: Float(ol), shade: faceShade, lights: lights, liquid: false, tint: tint)
                                emitSolid = wasSolid
                            }
                        }
                    }
                case .skip: break
                }
            }}}
        }
        return ((ov, si, oi), (lv, li))
    }
}
