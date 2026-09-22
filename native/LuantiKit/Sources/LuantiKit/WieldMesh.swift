import Foundation
import simd

/// Builds a 3D "extruded silhouette" mesh from a flat item icon's alpha, the way
/// desktop Luanti wields tools/craftitems (wieldmesh.cpp): every opaque pixel
/// becomes a front + back face, and a side wall wherever it borders a
/// transparent pixel (or the edge), so a pickaxe held in first person has real
/// thickness and shape instead of reading as a flat card.
public enum WieldMesh {
    /// `alpha` is row-major, `width`*`height`, true = opaque. The mesh is in
    /// item-local space: X,Y span [-0.5, 0.5] (row 0 is the TOP of the icon),
    /// Z is +-`thickness`. UVs address the whole icon in [0,1] with a top-left
    /// origin, so the caller scales them onto the icon's atlas sub-rect the same
    /// way the flat slab did. Empty alpha -> an empty mesh.
    public static func extrudeIcon(alpha: [Bool], width w: Int, height h: Int,
                                   thickness: Float = 0.06) -> B3DLoader.Mesh {
        var pos: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = [], idx: [UInt32] = []
        guard w > 0, h > 0, alpha.count == w * h else {
            return B3DLoader.Mesh(positions: [], uvs: [], indices: [], textureName: "",
                                  minBounds: .zero, maxBounds: .zero)
        }
        func op(_ c: Int, _ r: Int) -> Bool { c >= 0 && c < w && r >= 0 && r < h && alpha[r * w + c] }
        let t = thickness
        // One quad: 4 corners (CCW seen from its outward side) + 4 uvs.
        func quad(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>,
                  _ u0: SIMD2<Float>, _ u1: SIMD2<Float>, _ u2: SIMD2<Float>, _ u3: SIMD2<Float>) {
            let b = UInt32(pos.count)
            pos.append(contentsOf: [p0, p1, p2, p3]); uv.append(contentsOf: [u0, u1, u2, u3])
            idx.append(contentsOf: [b, b + 1, b + 2, b, b + 2, b + 3])
        }
        for r in 0..<h { for c in 0..<w where alpha[r * w + c] {
            let x0 = Float(c) / Float(w) - 0.5, x1 = Float(c + 1) / Float(w) - 0.5
            // Row 0 is the top of the icon -> highest Y.
            let y1 = 0.5 - Float(r) / Float(h), y0 = 0.5 - Float(r + 1) / Float(h)
            let u0 = Float(c) / Float(w), u1 = Float(c + 1) / Float(w)
            let v0 = Float(r) / Float(h), v1 = Float(r + 1) / Float(h)   // top-left origin
            let uTL = SIMD2(u0, v0), uTR = SIMD2(u1, v0), uBR = SIMD2(u1, v1), uBL = SIMD2(u0, v1)
            // Front (+Z): bottom-left, bottom-right, top-right, top-left.
            quad(SIMD3(x0, y0, t), SIMD3(x1, y0, t), SIMD3(x1, y1, t), SIMD3(x0, y1, t),
                 uBL, uBR, uTR, uTL)
            // Back (-Z): reversed winding.
            quad(SIMD3(x1, y0, -t), SIMD3(x0, y0, -t), SIMD3(x0, y1, -t), SIMD3(x1, y1, -t),
                 uBR, uBL, uTL, uTR)
            // Side walls only where the neighbour is transparent/off-icon. Walls
            // take the cell's own uv so they carry the item's edge colour.
            if !op(c - 1, r) { quad(SIMD3(x0, y0, -t), SIMD3(x0, y0, t), SIMD3(x0, y1, t), SIMD3(x0, y1, -t), uBL, uBL, uTL, uTL) }
            if !op(c + 1, r) { quad(SIMD3(x1, y0, t), SIMD3(x1, y0, -t), SIMD3(x1, y1, -t), SIMD3(x1, y1, t), uBR, uBR, uTR, uTR) }
            if !op(c, r - 1) { quad(SIMD3(x0, y1, t), SIMD3(x1, y1, t), SIMD3(x1, y1, -t), SIMD3(x0, y1, -t), uTL, uTR, uTR, uTL) }   // r-1 is up (top edge)
            if !op(c, r + 1) { quad(SIMD3(x0, y0, -t), SIMD3(x1, y0, -t), SIMD3(x1, y0, t), SIMD3(x0, y0, t), uBL, uBR, uBR, uBL) }
        } }
        return B3DLoader.Mesh(positions: pos, uvs: uv, indices: idx, textureName: "",
                              minBounds: SIMD3(-0.5, -0.5, -t), maxBounds: SIMD3(0.5, 0.5, t))
    }

    /// Reduce an RGBA icon (row-major, `w`*`h`, 4 bytes/px) to an opacity grid at
    /// `cells`x`cells`, sampling each cell's centre. A pixel counts as opaque when
    /// its alpha is over `threshold`. Downsampling keeps the extruded mesh small
    /// (a 16x16 grid is plenty for a wield item) regardless of source resolution.
    public static func alphaGrid(rgba: [UInt8], width w: Int, height h: Int,
                                 cells: Int = 16, threshold: UInt8 = 128) -> [Bool] {
        guard w > 0, h > 0, rgba.count >= w * h * 4, cells > 0 else { return [] }
        var out = [Bool](repeating: false, count: cells * cells)
        for r in 0..<cells { for c in 0..<cells {
            let sx = min(w - 1, (c * w + w / 2) / cells)
            let sy = min(h - 1, (r * h + h / 2) / cells)
            out[r * cells + c] = rgba[(sy * w + sx) * 4 + 3] >= threshold
        } }
        return out
    }
}
