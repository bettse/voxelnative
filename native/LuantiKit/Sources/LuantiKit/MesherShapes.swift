import Foundation
import simd

/// Geometry for the plantlike, firelike and raillike drawtypes, in node-local
/// 0..1 coordinates. The numbers (angles, offsets, which rail tile goes where)
/// match what a desktop Luanti client draws, so the same world looks the same;
/// the construction here is our own.
enum MesherShapes {
    /// Turn a point about the vertical axis through the origin by `deg`, in the
    /// sense that takes +X toward +Z (the world's rotation convention for
    /// param2 and meshoptions angles).
    static func turnY(_ p: SIMD3<Float>, _ deg: Float) -> SIMD3<Float> {
        let r = deg * .pi / 180, c = cos(r), s = sin(r)
        return SIMD3(p.x * c - p.z * s, p.y, p.x * s + p.z * c)
    }

    // MARK: plants

    /// One upright plant card: `scale` wide, `scale*height` tall from the floor,
    /// centred on the node's vertical axis and facing along `rotDeg`. `shift`
    /// slides the card along its facing normal (the whole card, or only its top
    /// edge when `topOnly`, which leans it). Corners: bottom-left,
    /// bottom-right, top-right, top-left.
    static func plantCard(rotDeg: Float, scale: Float, height: Float,
                          shift: Float = 0, topOnly: Bool = false,
                          offset: SIMD3<Float> = .zero) -> [SIMD3<Float>] {
        let r = rotDeg * .pi / 180
        let along = SIMD3<Float>(cos(r), 0, sin(r))     // across the card
        let normal = SIMD3<Float>(-sin(r), 0, cos(r))   // out of the card
        let centre = SIMD3<Float>(0.5, 0, 0.5) + offset
        let half = along * (0.5 * scale), up = SIMD3<Float>(0, scale * height, 0)
        let lo = centre + normal * (topOnly ? 0 : shift)
        let hi = centre + normal * shift + up
        return [lo - half, lo + half, hi + half, hi - half]
    }

    // MARK: fire

    /// A flame panel: a node-sized square standing upright, tipped back by
    /// `tilt` degrees about its bottom-to-top axis's horizontal, pushed `out`
    /// from the centre, raised by `lift`, then turned to face `yaw`.
    struct Flame { var yaw: Float; var tilt: Float; var out: Float; var lift: Float = 0 }

    static func flameCorners(_ f: Flame) -> [SIMD3<Float>] {
        let t = f.tilt * .pi / 180
        // Tilt about X: the panel's up direction swings toward +Z for positive tilt.
        let tilt = simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, cos(t), sin(t)), SIMD3(0, -sin(t), cos(t))))
        let square: [SIMD2<Float>] = [SIMD2(-0.5, 0.5), SIMD2(0.5, 0.5), SIMD2(0.5, -0.5), SIMD2(-0.5, -0.5)]
        return square.map { s in
            var p = tilt * SIMD3(s.x, s.y, 0)
            p.z += f.out
            p = turnY(p, f.yaw)
            return p + SIMD3(0.5, 0.5 + f.lift, 0.5)
        }
    }

    /// Which flame panels a fire node shows, given which neighbours it can lean
    /// on (indexed +Z, +Y, +X, -Z, -Y, -X). On a floor, or with nothing around,
    /// it's a full fire: four panels leaning in from the sides plus a centre
    /// cross. Otherwise flames only climb the walls it touches, and a ceiling
    /// with no wall makes them hang from above.
    static func flames(_ solid: [Bool]) -> [Flame] {
        let full = solid[4] || !solid.contains(true)
        let ceiling = solid[1]
        // Each side panel: the neighbour it leans on and the yaw that faces it.
        let sides: [(neighbour: Int, yaw: Float)] = [(0, 0), (5, 90), (3, 180), (2, 270)]
        var out: [Flame] = []
        for s in sides {
            if full || solid[s.neighbour] { out.append(Flame(yaw: s.yaw, tilt: -10, out: 0.4)) }
            else if ceiling { out.append(Flame(yaw: s.yaw, tilt: 70, out: 0.47, lift: 0.484)) }
        }
        if full { out += [Flame(yaw: 45, tilt: 0, out: 0), Flame(yaw: -45, tilt: 0, out: 0)] }
        return out
    }

    // MARK: rails

    /// Rail neighbour directions; a rail's connection code has bit i set when
    /// direction i holds a rail.
    static let railDirs: [SIMD3<Int>] = [SIMD3(0,0,1), SIMD3(0,0,-1), SIMD3(-1,0,0), SIMD3(1,0,0)]

    /// Direction index after a quarter turn (+X -> +Z -> -X -> -Z -> +X).
    private static func quarterTurn(_ d: Int) -> Int {
        let v = railDirs[d]
        let w = SIMD3(-v.z, 0, v.x)
        return railDirs.firstIndex(of: w)!
    }

    private static func turnSet(_ bits: Int, _ quarters: Int) -> Int {
        var out = 0
        for d in 0..<4 where bits & (1 << d) != 0 {
            var e = d
            for _ in 0..<quarters { e = quarterTurn(e) }
            out |= 1 << e
        }
        return out
    }

    /// The rail tile (0 straight, 1 curve, 2 T-junction, 3 crossing) and the
    /// turn (degrees) for a connection code. Each tile is drawn for one base
    /// set of connections at angle 0; any other set of the same shape uses the
    /// smallest quarter-turn that maps the base onto it. A lone connection, or
    /// none, lays a straight piece along its axis.
    static func railPiece(code: Int) -> (tile: Int, angle: Int) {
        let pz = 1, nz = 2, nx = 4, px = 8
        var set = code & 15
        if set == pz || set == nz { set = pz | nz }
        if set == nx || set == px { set = nx | px }
        let (tile, base): (Int, Int)
        switch set.nonzeroBitCount {
        case 0: return (0, 0)
        case 2 where set == pz | nz || set == nx | px: (tile, base) = (0, pz | nz)
        case 2: (tile, base) = (1, px | nz)
        case 3: (tile, base) = (2, px | nz | pz)
        default: return (3, 0)
        }
        for q in 0..<4 where turnSet(base, q) == set { return (tile, q * 90) }
        return (tile, 0)
    }

    /// The rail as one quad: flat just above the floor, or (sloped) rising
    /// from the floor on the -Z edge to the top of the node on the +Z edge,
    /// then turned `angle` about the node centre. Corners run (x,z) =
    /// (0,0),(0,1),(1,1),(1,0) so the shared uv table stands the tile upright.
    static func railQuad(sloped: Bool, angle: Int) -> [SIMD3<Float>] {
        let lift: Float = 1.0 / 16
        let far: Float = sloped ? 1 + lift : lift
        let q: [SIMD3<Float>] = [SIMD3(0, lift, 0), SIMD3(0, far, 1), SIMD3(1, far, 1), SIMD3(1, lift, 0)]
        guard angle % 360 != 0 else { return q }
        let mid = SIMD3<Float>(0.5, 0, 0.5)
        return q.map { turnY($0 - mid, Float(angle)) + mid }
    }

    /// The turn that makes a sloped rail climb toward neighbour direction `dir`
    /// (the unturned slope rises toward +Z).
    static func railSlopeTurn(_ dir: Int) -> Int {
        for q in 0..<4 where turnSet(1, q) == 1 << dir { return q == 3 ? -90 : q * 90 }
        return 0
    }
}
