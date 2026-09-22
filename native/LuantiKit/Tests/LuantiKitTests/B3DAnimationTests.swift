import XCTest
import simd
@testable import LuantiKit

/// VoxeLibre's real chest model (mcl_chests_chest.b3d): a "chest lower" node
/// holding the mesh, ANIM 0..20 @ 60 fps, and two bones ("lower", "upper")
/// with BONE weights + KEYS. mcl_chests plays open = frames 0..7, close =
/// 13..20 at speed 25.
final class B3DAnimationTests: XCTestCase {
    private func chest() throws -> B3DLoader.Mesh {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "chest", withExtension: "b3d", subdirectory: "Fixtures"))
        return try XCTUnwrap(B3DLoader.load(try Data(contentsOf: url)))
    }

    func testChestSkeletonParses() throws {
        let m = try chest()
        XCTAssertEqual(m.joints.map { $0.name }, ["chest lower", "lower", "upper"])
        XCTAssertEqual(m.joints[1].parent, 0)
        XCTAssertEqual(m.joints[2].parent, 1)
        XCTAssertEqual(m.animFrames, 20)
        XCTAssertEqual(m.animFps, 60, accuracy: 0.01)
        XCTAssertTrue(m.isAnimated)
        XCTAssertEqual(m.joints[1].keys.count, 21)              // 924 bytes / 44 per key
        XCTAssertEqual(m.joints[1].keys.first?.frame, 0)        // b3d frame 1 -> 0-based
        XCTAssertEqual(m.weights.count, m.positions.count)
        XCTAssertTrue(m.weights.allSatisfy { !$0.isEmpty })     // every vertex bound to a bone
        // Weighted vertices come from BONE chunks (joints 1/2), not the rigid fallback.
        XCTAssertTrue(m.weights.contains { $0.contains { $0.joint == 2 } })
    }

    func testLidMovesBetweenClosedAndOpen() throws {
        let m = try chest()
        let closed = m.skinnedPositions(frame: 0)
        let open = m.skinnedPositions(frame: 7)
        XCTAssertEqual(closed.count, m.positions.count)
        // Bind pose and frame 0 (closed) are the same shape; the open frame moves the lid.
        let lidVerts = m.weights.indices.filter { m.weights[$0].contains { $0.joint == 2 } }
        let baseVerts = m.weights.indices.filter { !m.weights[$0].contains { $0.joint == 2 } }
        XCTAssertFalse(lidVerts.isEmpty); XCTAssertFalse(baseVerts.isEmpty)
        let lidMoved = lidVerts.map { simd_distance(closed[$0], open[$0]) }.max() ?? 0
        let baseMoved = baseVerts.map { simd_distance(closed[$0], open[$0]) }.max() ?? 0
        XCTAssertGreaterThan(lidMoved, 0.5, "lid should swing open")
        XCTAssertLessThan(baseMoved, 0.05, "the box itself stays put")
        for p in open { XCTAssertTrue(p.x.isFinite && p.y.isFinite && p.z.isFinite) }
    }

    func testRotationKeysUseIrrlichtConjugateConvention() {
        // Irrlicht (getMatrix_transposed + row-vector transformVect) rotates by
        // the conjugate: a stored +90 deg about Y must send +X to +Z, not -Z.
        let q = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))
        let j = B3DLoader.Joint(name: "j", parent: -1, bindPos: .zero, bindScale: SIMD3(1, 1, 1),
                                bindRot: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), bindGlobalInv: matrix_identity_float4x4,
                                keys: [B3DLoader.Key(frame: 0, pos: nil, scale: nil, rot: q)])
        let m = B3DLoader.localMatrix(j, frame: 0)
        let v = m * SIMD4<Float>(1, 0, 0, 1)
        XCTAssertEqual(v.x, 0, accuracy: 1e-4)
        XCTAssertEqual(v.z, 1, accuracy: 1e-4)
    }

    /// The per-channel binary search must give exactly what the old linear
    /// scan gave, at every bracketing case: before the first key, exactly on a
    /// key, between keys, after the last key, and on a channel with a single
    /// key. Keys carry mixed channel subsets so the pos/scale/rot tracks have
    /// different frame lists (a pos-only key must not bracket rotation).
    func testBinarySearchMatchesLinearScan() {
        // Old implementation, kept verbatim as the oracle.
        func linear<T>(_ keys: [B3DLoader.Key], _ frame: Float, _ pick: (B3DLoader.Key) -> T?, _ lerp: (T, T, Float) -> T) -> T? {
            var a: (Float, T)? = nil, b: (Float, T)? = nil
            for k in keys {
                guard let v = pick(k) else { continue }
                if k.frame <= frame { a = (k.frame, v) }
                if k.frame >= frame && b == nil { b = (k.frame, v) }
            }
            guard let lo = a ?? b, let hi = b ?? a else { return nil }
            let span = hi.0 - lo.0
            let t: Float = span > 1e-6 ? max(0, min(1, (frame - lo.0) / span)) : 0
            return lerp(lo.1, hi.1, t)
        }
        typealias K = B3DLoader.Key
        let rz = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)), r1 = simd_quatf(angle: 1, axis: SIMD3(0, 0, 1))
        let keys: [K] = [
            K(frame: 2, pos: SIMD3(0, 0, 0), scale: nil, rot: rz),
            K(frame: 5, pos: SIMD3(10, 0, 0), scale: SIMD3(1, 1, 1), rot: nil),   // no rot: rot track skips this
            K(frame: 9, pos: nil, scale: SIMD3(2, 2, 2), rot: r1),                // no pos: pos track skips this
            K(frame: 14, pos: SIMD3(20, 5, 0), scale: nil, rot: nil),
        ]
        let j = B3DLoader.Joint(name: "j", parent: -1, bindPos: SIMD3(-1, -1, -1), bindScale: SIMD3(3, 3, 3),
                                bindRot: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), bindGlobalInv: matrix_identity_float4x4,
                                keys: keys)
        for frame: Float in [0, 2, 3.5, 5, 7, 9, 11, 14, 20] {
            let (p, s, r) = B3DLoader.animatedChannels(j, frame: frame)
            let ep = linear(keys, frame, { $0.pos }, { $0 + ($1 - $0) * $2 }) ?? j.bindPos
            let es = linear(keys, frame, { $0.scale }, { $0 + ($1 - $0) * $2 }) ?? j.bindScale
            let er = linear(keys, frame, { $0.rot }, { simd_slerp($0, $1, $2) }) ?? j.bindRot
            XCTAssertEqual(simd_length(p - ep), 0, accuracy: 1e-5, "pos @ \(frame)")
            XCTAssertEqual(simd_length(s - es), 0, accuracy: 1e-5, "scale @ \(frame)")
            XCTAssertEqual(simd_length(r.vector - er.vector), 0, accuracy: 1e-5, "rot @ \(frame)")
        }
        // Single-key channel and an empty joint fall back the same way too.
        let one = B3DLoader.Joint(name: "o", parent: -1, bindPos: .zero, bindScale: SIMD3(1, 1, 1),
                                  bindRot: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), bindGlobalInv: matrix_identity_float4x4,
                                  keys: [K(frame: 4, pos: SIMD3(7, 7, 7), scale: nil, rot: nil)])
        for frame: Float in [0, 4, 9] {
            XCTAssertEqual(B3DLoader.animatedChannels(one, frame: frame).0, SIMD3(7, 7, 7), "single key @ \(frame)")
        }
    }
}
