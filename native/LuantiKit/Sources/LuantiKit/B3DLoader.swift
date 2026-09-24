import Foundation
import simd

/// Minimal Blitz3D (.b3d) loader: geometry only, baked into model rest space
/// (bind pose, no skinning/animation yet). Enough to draw mobs as real 3D
/// models instead of flat billboards. Port of the static path of the Godot
/// client's b3d_loader.gd. Blitz3D files are little-endian.
public enum B3DLoader {
    /// One keyframe: b3d frame numbers are 1-based, stored 0-based like Irrlicht.
    public struct Key { public var frame: Float; public var pos: SIMD3<Float>?; public var scale: SIMD3<Float>?; public var rot: simd_quatf? }
    /// A NODE that matters for animation: bind transform (local + inverse of the
    /// global bind, as Irrlicht's GlobalInversedMatrix) and its keyframes.
    public struct Joint {
        public var name: String
        public var parent: Int                 // -1 = root
        public var bindPos: SIMD3<Float>
        public var bindScale: SIMD3<Float>
        public var bindRot: simd_quatf
        public var bindGlobalInv: simd_float4x4
        public var keys: [Key]
        // Per-channel tracks split out of `keys` once at load (a key may carry
        // any subset of pos/scale/rot, so each channel has its own sorted frame
        // list). animatedChannels binary-searches these instead of scanning
        // every key three times per joint per tick (perf review #5a).
        var posTrack: [(Float, SIMD3<Float>)] = []
        var sclTrack: [(Float, SIMD3<Float>)] = []
        var rotTrack: [(Float, simd_quatf)] = []
        mutating func buildTracks() {
            posTrack = keys.compactMap { k in k.pos.map { (k.frame, $0) } }
            sclTrack = keys.compactMap { k in k.scale.map { (k.frame, $0) } }
            rotTrack = keys.compactMap { k in k.rot.map { (k.frame, $0) } }
        }
    }
    public struct Mesh {
        public var positions: [SIMD3<Float>]   // model rest space
        public var uvs: [SIMD2<Float>]
        public var indices: [UInt32]           // all triangles, every surface merged
        public var surfaces: [Surface]         // per-brush triangle sets (mob materials)
        public var textureName: String         // first brush's texture (mobs use one)
        public var minBounds: SIMD3<Float>
        public var maxBounds: SIMD3<Float>
        // Skeletal animation (empty joints = static model).
        public var joints: [Joint] = []
        /// Per vertex: (joint, weight) pairs from BONE chunks; empty = the
        /// vertex stays at its bind position (Irrlicht's b3d skinning only moves
        /// weighted vertices).
        public var weights: [[(joint: Int, w: Float)]] = []
        public var animFrames: Int = 0
        public var animFps: Float = 0
        public var isAnimated: Bool { !joints.isEmpty && joints.contains { !$0.keys.isEmpty } }

        /// Skin the bind-space positions at an (Irrlicht 0-based) frame:
        /// v' = sum_j w_j * G_j(frame) * G_j(bind)^-1 * v, exactly
        /// CSkinnedMesh::skinJoint. Unweighted vertices stay put.
        public func skinnedPositions(frame: Float, overrides: [String: JointOverride] = [:]) -> [SIMD3<Float>] {
            // A skeleton with no keys still skins when a server override poses it.
            guard !joints.isEmpty, weights.count == positions.count, isAnimated || !overrides.isEmpty else { return positions }
            var global = [simd_float4x4](repeating: matrix_identity_float4x4, count: joints.count)
            var pull = global
            for (i, j) in joints.enumerated() {
                let local = B3DLoader.localMatrix(j, frame: frame, override: overrides.isEmpty ? nil : overrides[j.name])
                global[i] = j.parent >= 0 ? global[j.parent] * local : local
                pull[i] = global[i] * j.bindGlobalInv
            }
            var out = positions
            for (vi, ws) in weights.enumerated() where !ws.isEmpty {
                let p4 = SIMD4<Float>(positions[vi], 1)
                var acc = SIMD4<Float>(repeating: 0)
                var total: Float = 0
                for (j, w) in ws { acc += (pull[j] * p4) * w; total += w }
                if total > 0 { out[vi] = SIMD3(acc.x, acc.y, acc.z) / total }
            }
            return out
        }

        /// A joint's model-space transform at a frame: the product of local
        /// matrices down its parent chain, which is what Irrlicht's joint scene
        /// node reports as its transform. Bone attachments hang off it.
        public func jointGlobalMatrix(name: String, frame: Float, overrides: [String: JointOverride] = [:]) -> simd_float4x4? {
            guard let idx = joints.firstIndex(where: { $0.name == name }) else { return nil }
            var chain: [Int] = []
            var i = idx
            while i >= 0 { chain.append(i); i = joints[i].parent }
            var m = matrix_identity_float4x4
            for j in chain.reversed() {
                m = m * B3DLoader.localMatrix(joints[j], frame: frame, override: overrides.isEmpty ? nil : overrides[joints[j].name])
            }
            return m
        }

        public init(positions: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32],
                    surfaces: [Surface] = [], textureName: String,
                    minBounds: SIMD3<Float>, maxBounds: SIMD3<Float>) {
            self.positions = positions; self.uvs = uvs; self.indices = indices
            self.surfaces = surfaces.isEmpty ? [Surface(brush: 0, indices: indices)] : surfaces
            self.textureName = textureName; self.minBounds = minBounds; self.maxBounds = maxBounds
        }
    }

    /// One material's triangles. `brush` indexes the .b3d brush list, which for
    /// Luanti mobs is also the index into the entity's `textures` array — each
    /// surface takes textures[brush], so a multi-material mob (skeleton = bones +
    /// armor + bow, cow = body + mushrooms) paints each part with its own skin.
    public struct Surface {
        public var brush: Int
        public var indices: [UInt32]
        public init(brush: Int, indices: [UInt32]) { self.brush = brush; self.indices = indices }
    }

    // Little-endian cursor over the file bytes.
    private final class Cur {
        let b: [UInt8]; var p = 0
        init(_ d: Data) { b = [UInt8](d) }
        func has(_ n: Int) -> Bool { p + n <= b.count }
        func tag() -> String {
            guard has(4) else { p = b.count; return "" }
            defer { p += 4 }
            return String(bytes: b[p..<p+4], encoding: .ascii) ?? ""
        }
        func i32() -> Int {
            guard has(4) else { p = b.count; return 0 }
            defer { p += 4 }
            let v = UInt32(b[p]) | (UInt32(b[p+1]) << 8) | (UInt32(b[p+2]) << 16) | (UInt32(b[p+3]) << 24)
            return Int(Int32(bitPattern: v))
        }
        func f32() -> Float {
            guard has(4) else { p = b.count; return 0 }
            defer { p += 4 }
            let v = UInt32(b[p]) | (UInt32(b[p+1]) << 8) | (UInt32(b[p+2]) << 16) | (UInt32(b[p+3]) << 24)
            return Float(bitPattern: v)
        }
        func str() -> String {
            var out: [UInt8] = []
            while has(1), b[p] != 0 { out.append(b[p]); p += 1 }
            if has(1) { p += 1 }   // skip NUL
            return String(bytes: out, encoding: .utf8) ?? ""
        }
    }

    private struct Vert { var p: SIMD3<Float>; var uv: SIMD2<Float> }

    /// Joint local transform at a frame: each channel interpolates its own keys
    /// (linear pos/scale, slerp rot) and falls back to the bind value when the
    /// joint has no keys for that channel.
    /// A server bone override (AO_CMD_SET_BONE_POSITION) at one instant, in
    /// the bone's local space. `absolute` channels replace the animated value;
    /// the others add to it (BoneOverride::getPosition/getRotation/getScale).
    public struct JointOverride {
        public var pos: SIMD3<Float>? = nil, rot: simd_quatf? = nil, scale: SIMD3<Float>? = nil
        public var absPos = false, absRot = false, absScale = false
        public init() {}
    }

    /// Irrlicht quaternion::set(x, y, z): Euler radians to the quaternion the
    /// engine feeds through the same transposed-matrix path as the b3d keys,
    /// so it composes with them and goes through rotationMatrix unchanged.
    public static func irrQuat(euler e: SIMD3<Float>) -> simd_quatf {
        let sr = sin(e.x * 0.5), cr = cos(e.x * 0.5)
        let sp = sin(e.y * 0.5), cp = cos(e.y * 0.5)
        let sy = sin(e.z * 0.5), cy = cos(e.z * 0.5)
        return simd_normalize(simd_quatf(ix: sr * cp * cy - cr * sp * sy,
                                         iy: cr * sp * cy + sr * cp * sy,
                                         iz: cr * cp * sy - sr * sp * cy,
                                         r:  cr * cp * cy + sr * sp * sy))
    }

    static func localMatrix(_ j: Joint, frame: Float, override o: JointOverride? = nil) -> simd_float4x4 {
        var (pos, scale, rot) = animatedChannels(j, frame: frame)
        if let o = o {
            if let p = o.pos { pos = o.absPos ? p : pos + p }
            if let s = o.scale { scale = o.absScale ? s : scale * s }
            // Irrlicht's `override * anim` is Hamilton(anim, override).
            if let r = o.rot { rot = o.absRot ? r : simd_mul(rot, r) }
        }
        return translation(pos) * rotationMatrix(rot) * scaling(scale)
    }

    static func animatedChannels(_ jIn: Joint, frame: Float) -> (SIMD3<Float>, SIMD3<Float>, simd_quatf) {
        // A Joint built by hand (tests) has keys but no tracks; derive them.
        // The loader builds them once, so this branch never runs at runtime.
        var j = jIn
        if !j.keys.isEmpty, j.posTrack.isEmpty, j.sclTrack.isEmpty, j.rotTrack.isEmpty { j.buildTracks() }
        var pos = j.bindPos, scale = j.bindScale, rot = j.bindRot
        // Each channel brackets its own keys (Irrlicht keeps position, scale
        // and rotation tracks separately), so a pos-only key doesn't snap rot.
        // Binary search the channel's sorted track for the bracketing pair:
        // lo = last key at or before `frame`, hi = first key at or after it,
        // each falling back to the other at the ends (same result the old
        // linear scan produced, without touching every key).
        @inline(__always)
        func bracket<T>(_ track: [(Float, T)], _ lerp: (T, T, Float) -> T) -> T? {
            guard !track.isEmpty else { return nil }
            // first index with frame >= target
            var l = 0, r = track.count
            while l < r { let m = (l + r) >> 1; if track[m].0 < frame { l = m + 1 } else { r = m } }
            let hiIdx = l < track.count ? l : nil
            // last index with frame <= target: hiIdx itself if exact, else the one before
            let loIdx: Int? = (hiIdx != nil && track[hiIdx!].0 == frame) ? hiIdx : (l > 0 ? l - 1 : nil)
            guard let lo = (loIdx ?? hiIdx).map({ track[$0] }), let hi = (hiIdx ?? loIdx).map({ track[$0] }) else { return nil }
            let span = hi.0 - lo.0
            let t: Float = span > 1e-6 ? max(0, min(1, (frame - lo.0) / span)) : 0
            return lerp(lo.1, hi.1, t)
        }
        if let p: SIMD3<Float> = bracket(j.posTrack, { $0 + ($1 - $0) * $2 }) { pos = p }
        if let s: SIMD3<Float> = bracket(j.sclTrack, { $0 + ($1 - $0) * $2 }) { scale = s }
        if let r: simd_quatf = bracket(j.rotTrack, { simd_slerp($0, $1, $2) }) { rot = r }
        return (pos, scale, rot)
    }

    public static func load(_ data: Data) -> Mesh? {
        let c = Cur(data)
        guard c.tag() == "BB3D" else { return nil }
        let size = c.i32(); let end = c.p + size
        _ = c.i32()   // version

        var textures: [String] = []      // TEXS names
        var brushTex: [Int] = []         // BRUS -> first texture id
        var verts: [Vert] = []
        var indices: [UInt32] = []
        var surfaces: [Surface] = []
        var joints: [Joint] = []
        var weights: [[(joint: Int, w: Float)]] = []
        var meshRanges: [(joint: Int, start: Int, end: Int, weighted: Bool)] = []   // per MESH buffer
        var verticesStart = 0            // Irrlicht's VerticesStart: BONE ids are relative to the last MESH
        var animFrames = 0
        var animFps: Float = 0

        func readTexs(_ e: Int) {
            while c.p < e {
                let name = c.str().replacingOccurrences(of: "\\", with: "/")
                _ = c.i32()                 // flags
                _ = c.i32()                 // blend
                for _ in 0..<5 { _ = c.f32() }
                textures.append(name)
            }
        }
        func readBrus(_ e: Int) {
            let nTex = c.i32()
            while c.p < e {
                _ = c.str()                 // name
                for _ in 0..<5 { _ = c.f32() }
                _ = c.i32(); _ = c.i32()
                var texId = -1
                for i in 0..<nTex { let t = c.i32(); if i == 0 { texId = t } }
                brushTex.append(texId)
            }
        }
        func readVrts(_ e: Int, _ g: simd_float4x4) {
            let flags = c.i32()
            let tcs = c.i32()
            let tcss = c.i32()
            let hasN = (flags & 1) != 0
            let hasC = (flags & 2) != 0
            while c.p < e {
                let lp = SIMD4<Float>(c.f32(), c.f32(), c.f32(), 1)
                let wp = g * lp
                if hasN { _ = c.f32(); _ = c.f32(); _ = c.f32() }
                if hasC { for _ in 0..<4 { _ = c.f32() } }
                var uv = SIMD2<Float>(0, 0)
                for si in 0..<tcs { for ci in 0..<tcss {
                    let v = c.f32()
                    if si == 0 && ci == 0 { uv.x = v } else if si == 0 && ci == 1 { uv.y = v }
                }}
                verts.append(Vert(p: SIMD3(wp.x, wp.y, wp.z), uv: uv))
                weights.append([])
            }
        }
        func readBone(_ e: Int, joint: Int) {
            while c.p + 8 <= e {
                let vid = c.i32() + verticesStart
                let w = c.f32()
                if vid >= 0, vid < weights.count, w > 0 {
                    weights[vid].append((joint, w))
                    if let r = meshRanges.indices.last(where: { meshRanges[$0].start <= vid && vid < meshRanges[$0].end }) {
                        meshRanges[r].weighted = true
                    }
                }
            }
        }
        func readKeys(_ e: Int, joint: Int) {
            let flags = c.i32()
            while c.p + 4 <= e {
                var k = Key(frame: Float(max(1, c.i32()) - 1), pos: nil, scale: nil, rot: nil)
                if flags & 1 != 0 { k.pos = SIMD3(c.f32(), c.f32(), c.f32()) }
                if flags & 2 != 0 { k.scale = SIMD3(c.f32(), c.f32(), c.f32()) }
                if flags & 4 != 0 { let w = c.f32(); k.rot = simd_quatf(ix: c.f32(), iy: c.f32(), iz: c.f32(), r: w) }
                joints[joint].keys.append(k)
            }
            joints[joint].keys.sort { $0.frame < $1.frame }
            joints[joint].buildTracks()
        }
        func readTris(_ e: Int, base: Int) {
            let brush = c.i32()   // brush id for this tri set
            var tri: [UInt32] = []
            while c.p + 12 <= e {
                let a = UInt32(base + c.i32()), b = UInt32(base + c.i32()), d = UInt32(base + c.i32())
                indices.append(a); indices.append(b); indices.append(d)
                tri.append(a); tri.append(b); tri.append(d)
            }
            surfaces.append(Surface(brush: brush, indices: tri))
        }
        func readMesh(_ e: Int, _ g: simd_float4x4, joint: Int) {
            _ = c.i32()   // brush id
            let base = verts.count
            verticesStart = base
            while c.p < e, c.has(8) {
                let t = c.tag(); let cs = c.i32(); let ce = c.p + cs
                switch t {
                case "VRTS": readVrts(ce, g)
                case "TRIS": readTris(ce, base: base)
                default: break
                }
                c.p = ce
            }
            meshRanges.append((joint, base, verts.count, false))
        }
        func readNode(_ e: Int, _ parent: simd_float4x4, parentJoint: Int) {
            let name = c.str()
            let t = SIMD3<Float>(c.f32(), c.f32(), c.f32())
            let s = SIMD3<Float>(c.f32(), c.f32(), c.f32())
            let w = c.f32()
            let q = simd_quatf(ix: c.f32(), iy: c.f32(), iz: c.f32(), r: w)
            let local = translation(t) * rotationMatrix(q) * scaling(s)
            let global = parent * local
            let jid = joints.count
            joints.append(Joint(name: name, parent: parentJoint, bindPos: t, bindScale: s, bindRot: q,
                                bindGlobalInv: global.inverse, keys: []))
            while c.p < e, c.has(8) {
                let tag = c.tag(); let cs = c.i32(); let ce = c.p + cs
                switch tag {
                case "NODE": readNode(ce, global, parentJoint: jid)
                case "MESH": readMesh(ce, global, joint: jid)
                case "BONE": readBone(ce, joint: jid)
                case "KEYS": readKeys(ce, joint: jid)
                case "ANIM": _ = c.i32(); animFrames = c.i32(); animFps = c.f32()
                default: break
                }
                c.p = ce
            }
        }

        while c.p < end, c.has(8) {
            let t = c.tag(); let cs = c.i32(); let ce = c.p + cs
            switch t {
            case "TEXS": readTexs(ce)
            case "BRUS": readBrus(ce)
            case "NODE": readNode(ce, matrix_identity_float4x4, parentJoint: -1)
            default: break
            }
            c.p = ce
        }
        guard !verts.isEmpty, !indices.isEmpty else { return nil }
        // Irrlicht's b3d path never attaches unweighted buffers to their node:
        // vertices without BONE weights stay at their baked bind position.
        _ = meshRanges

        var lo = verts[0].p, hi = verts[0].p
        for v in verts { lo = simd_min(lo, v.p); hi = simd_max(hi, v.p) }
        let tex = (brushTex.first.flatMap { $0 >= 0 && $0 < textures.count ? textures[$0] : nil }) ?? textures.first ?? ""
        var mesh = Mesh(positions: verts.map { $0.p }, uvs: verts.map { $0.uv },
                        indices: indices, surfaces: surfaces, textureName: tex,
                        minBounds: lo, maxBounds: hi)
        mesh.joints = joints; mesh.weights = weights
        mesh.animFrames = animFrames; mesh.animFps = animFps
        return mesh
    }

    /// Irrlicht builds joint matrices with quaternion::getMatrix_transposed and
    /// transforms row vectors, which rotates by the CONJUGATE of the stored
    /// quaternion. Match that or every non-180-degree key swings the wrong way.
    static func rotationMatrix(_ q: simd_quatf) -> simd_float4x4 { simd_float4x4(q.conjugate) }

    private static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        return m
    }
    private static func scaling(_ s: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.0.x = s.x; m.columns.1.y = s.y; m.columns.2.z = s.z
        return m
    }
}
