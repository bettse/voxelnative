import Foundation
import simd

/// Minimal Wavefront .obj loader for node mesh models (drawtype "mesh"):
/// positions + texcoords + triangulated faces, in the model's own coordinate
/// space. Returns a B3DLoader.Mesh so the mesher/model paths handle .obj and
/// .b3d uniformly. Normals, materials (.mtl) and groups are ignored — node
/// tiles supply the texture. UVs are flipped to a top-left origin to match the
/// atlas/image convention (OBJ texcoords are bottom-left origin).
public enum OBJLoader {
    public static func load(_ data: Data) -> B3DLoader.Mesh? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var positions: [SIMD3<Float>] = []
        var texcoords: [SIMD2<Float>] = []
        var outPos: [SIMD3<Float>] = []
        var outUV: [SIMD2<Float>] = []
        var indices: [UInt32] = []
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
                    positions.append(SIMD3(x, y, z))
                }
            case "vt":
                if f.count >= 3, let u = Float(f[1]), let v = Float(f[2]) {
                    texcoords.append(SIMD2(u, 1 - v))   // flip to top-left origin
                }
            case "f":
                // Fan-triangulate the polygon (f v0 v1 v2 [v3 ...]).
                var poly: [UInt32] = []
                for tok in f.dropFirst() { if let idx = vertexFor(tok) { poly.append(idx) } }
                guard poly.count >= 3 else { return }
                for k in 1..<(poly.count - 1) {
                    indices.append(poly[0]); indices.append(poly[k]); indices.append(poly[k + 1])
                }
            default:
                break
            }
        }
        guard !outPos.isEmpty, !indices.isEmpty else { return nil }
        var lo = outPos[0], hi = outPos[0]
        for p in outPos { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return B3DLoader.Mesh(positions: outPos, uvs: outUV, indices: indices,
                              textureName: "", minBounds: lo, maxBounds: hi)
    }
}
