import Foundation
import simd

/// Minimal Wavefront .obj loader for node mesh models (drawtype "mesh"):
/// positions + texcoords + triangulated faces, in the model's own coordinate
/// space. Returns a B3DLoader.Mesh so the mesher/model paths handle .obj and
/// .b3d uniformly. Normals and .mtl files are ignored (node tiles supply the
/// texture), but material/group changes split the faces into surfaces the way
/// Irrlicht splits mesh buffers, since surface N takes the node's tile N (a lit
/// campfire's flames, a wall lever's handle). UVs are flipped to a top-left origin to match the
/// atlas/image convention (OBJ texcoords are bottom-left origin).
public enum OBJLoader {
    public static func load(_ data: Data) -> B3DLoader.Mesh? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var positions: [SIMD3<Float>] = []
        var texcoords: [SIMD2<Float>] = []
        var outPos: [SIMD3<Float>] = []
        var outUV: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        // Irrlicht's COBJMeshFileLoader materials: a default one, then findMtl on
        // the first face after a usemtl/g line. With no .mtl every material is
        // named "", so a usemtl name never matches and always starts a new one;
        // with no usemtl yet, a group reuses its own. Empty ones are dropped.
        var mats: [(name: String, group: String, idx: [UInt32])] = [("", "", [])]
        var cur = 0, mtlName = "", grpName = "", changed = false
        // Dedup output vertices by their (posIndex, uvIndex) pair.
        var vertMap: [Int64: UInt32] = [:]

        // Resolve an OBJ index (1-based, negative = from end) against a count.
        func resolve(_ raw: Int, _ count: Int) -> Int {
            raw > 0 ? raw - 1 : count + raw
        }

        func vertexFor(_ token: Substring) -> UInt32? {
            // token is "v", "v/vt", "v//vn", or "v/vt/vn".
            let parts = token.split(separator: "/", omittingEmptySubsequences: false)
            guard let vRaw = Int(parts[0]) else { return nil }
            let pIdx = resolve(vRaw, positions.count)
            guard pIdx >= 0 && pIdx < positions.count else { return nil }
            var uvIdx = -1
            if parts.count >= 2, let tRaw = Int(parts[1]) {
                let ti = resolve(tRaw, texcoords.count)
                if ti >= 0 && ti < texcoords.count { uvIdx = ti }
            }
            let key = Int64(pIdx) << 21 | Int64(uvIdx + 1)
            if let existing = vertMap[key] { return existing }
            let out = UInt32(outPos.count)
            outPos.append(positions[pIdx])
            outUV.append(uvIdx >= 0 ? texcoords[uvIdx] : SIMD2(0, 0))
            vertMap[key] = out
            return out
        }

        text.enumerateLines { line, _ in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let tag = f.first else { return }
            switch tag {
            case "v":
                if f.count >= 4, let x = Float(f[1]), let y = Float(f[2]), let z = Float(f[3]) {
                    positions.append(SIMD3(-x, y, z))   // X negated like Irrlicht's loader (handedness)
                }
            case "vt":
                if f.count >= 3, let u = Float(f[1]), let v = Float(f[2]) {
                    texcoords.append(SIMD2(u, 1 - v))   // flip to top-left origin
                }
            case "g":
                grpName = f.count > 1 ? String(f[1]) : "default"; changed = true
            case "usemtl":
                mtlName = f.count > 1 ? String(f[1]) : ""; changed = true
            case "f":
                if changed {
                    changed = false
                    if let i = mats.firstIndex(where: { $0.name == mtlName && $0.group == grpName }) { cur = i }
                    else if !grpName.isEmpty || mats.contains(where: { $0.name == mtlName }) {
                        mats.append(("", grpName, [])); cur = mats.count - 1
                    }
                }
                // Fan-triangulate the polygon (f v0 v1 v2 [v3 ...]).
                var poly: [UInt32] = []
                for tok in f.dropFirst() { if let idx = vertexFor(tok) { poly.append(idx) } }
                guard poly.count >= 3 else { return }
                for k in 1..<(poly.count - 1) {
                    // Reversed with the X flip, as Irrlicht does, so winding stays outward.
                    mats[cur].idx.append(poly[0]); mats[cur].idx.append(poly[k + 1]); mats[cur].idx.append(poly[k])
                }
            default:
                break
            }
        }
        var surfaces: [B3DLoader.Surface] = []
        for m in mats where !m.idx.isEmpty {
            surfaces.append(B3DLoader.Surface(brush: surfaces.count, indices: m.idx))
            indices += m.idx
        }
        guard !outPos.isEmpty, !indices.isEmpty else { return nil }
        var lo = outPos[0], hi = outPos[0]
        for p in outPos { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return B3DLoader.Mesh(positions: outPos, uvs: outUV, indices: indices, surfaces: surfaces,
                              textureName: "", minBounds: lo, maxBounds: hi)
    }
}
