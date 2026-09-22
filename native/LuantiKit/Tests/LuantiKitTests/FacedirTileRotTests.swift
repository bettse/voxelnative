import XCTest
import simd
@testable import LuantiKit

/// Facedir rotates the tile as well as selecting it (mapblock_mesh dir_to_tile):
/// a sideways log's bark grain runs along the log axis. Spot-check the ported
/// rotation table and the UV rotation math.
final class FacedirTileRotTests: XCTestCase {
    func testTableMatchesEngineSpotChecks() {
        // dir_i for +X face is 1, -X is 7, +Y is 2 (see faceDirI).
        // Engine dir_to_tile rows (rotation column):
        //  facedir 1: [0,0,3,0,0,0,1,0] -> +X(1)=0, -X(7)=0, +Y(2)=3
        XCTAssertEqual(WorldMesher.facedirTileRot[1][1], 0)
        XCTAssertEqual(WorldMesher.facedirTileRot[1][2], 3)
        XCTAssertEqual(WorldMesher.facedirTileRot[1][6], 1)
        //  facedir 4 (tipped onto +Z): [0,3,0,2,0,0,2,1]
        XCTAssertEqual(WorldMesher.facedirTileRot[4][1], 3)   // +X
        XCTAssertEqual(WorldMesher.facedirTileRot[4][3], 2)   // +Z
        XCTAssertEqual(WorldMesher.facedirTileRot[4][7], 1)   // -X
        //  facedir 0 is all identity.
        XCTAssertEqual(WorldMesher.facedirTileRot[0], [0,0,0,0,0,0,0,0])
    }

    func testRotUVTurnsTheCorners() {
        let t = SIMD2<Float>(0.25, 0.75)
        XCTAssertEqual(WorldMesher.rotUV(t, 0), t)
        XCTAssertEqual(WorldMesher.rotUV(t, 1), SIMD2(0.25, 0.25))   // (1-v, u)
        XCTAssertEqual(WorldMesher.rotUV(t, 2), SIMD2(0.75, 0.25))   // (1-u, 1-v)
        XCTAssertEqual(WorldMesher.rotUV(t, 3), SIMD2(0.75, 0.75))   // (v, 1-u)
        // Four 90-degree turns return to the start.
        var q = t
        for _ in 0..<4 { q = WorldMesher.rotUV(q, 1) }
        XCTAssertEqual(q, t)
    }
}
