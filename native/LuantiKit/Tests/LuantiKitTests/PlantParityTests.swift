import XCTest
import simd
@testable import LuantiKit

/// Parity review 2026-09-23: tall rooted plants tile their texture per node,
/// and wallmounted plantlike nodes (amethyst buds) turn onto walls/ceilings,
/// both as content_mapblock.cpp drawPlantlikeQuad does.
final class PlantParityTests: XCTestCase {
    private func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { simd_length(a - b) < 1e-4 }

    func testTallPlantTilesOncePerNode() {
        // 2.5 nodes of kelp: segments [1.5,2.5], [0.5,1.5], [0,0.5], two quads each.
        let q = WorldMesher.plantQuadsTallTiled(2.5)
        XCTAssertEqual(q.count, 6)
        // Top segment: full texture (V 1 at the bottom edge, 0 at the top).
        XCTAssertEqual(q[0].1[0].y, 1, accuracy: 1e-5)
        XCTAssertEqual(q[0].1[2].y, 0, accuracy: 1e-5)
        XCTAssertEqual(q[0].0[2].y, 2.5, accuracy: 1e-5)   // top corner at the plant's top
        // Bottom half-node: only the top half of the texture, V 0..0.5.
        XCTAssertEqual(q[4].1[0].y, 0.5, accuracy: 1e-5)
        XCTAssertEqual(q[4].0[0].y, 0, accuracy: 1e-5)
        XCTAssertEqual(q[4].0[2].y, 0.5, accuracy: 1e-5)
        // Every V stays in 0...1, so the clamped sampler never smears.
        for (_, uv) in q { for t in uv { XCTAssert(t.y >= 0 && t.y <= 1) } }
    }

    func testWallmountedPlantRotation() {
        let base = SIMD3<Float>(0.5, 0, 0.5)          // bottom centre of a floor plant
        XCTAssert(near(WorldMesher.wallmountedPlant(base, 1), base))                         // YN: floor, unchanged
        XCTAssert(near(WorldMesher.wallmountedPlant(base, 0), SIMD3(0.5, 1, 0.5)))           // YP: hangs from the ceiling
        XCTAssert(near(WorldMesher.wallmountedPlant(base, 2), SIMD3(1, 0.5, 0.5)))           // XP: grows out of the +X wall
        XCTAssert(near(WorldMesher.wallmountedPlant(base, 3), SIMD3(0, 0.5, 0.5)))           // XN
        XCTAssert(near(WorldMesher.wallmountedPlant(base, 4), SIMD3(0.5, 0.5, 1)))           // ZP
        XCTAssert(near(WorldMesher.wallmountedPlant(base, 5), SIMD3(0.5, 0.5, 0)))           // ZN
    }
}
