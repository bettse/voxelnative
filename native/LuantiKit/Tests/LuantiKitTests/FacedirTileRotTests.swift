import XCTest
import simd
@testable import LuantiKit

/// Facedir turns the tile as well as selecting it: a sideways log's bark
/// grain runs along the log axis. Spot-check the derived turns against what a
/// desktop client shows, and the UV rotation math.
final class FacedirTileRotTests: XCTestCase {
    // WorldMesher face order: +Y -Y +Z -Z +X -X.
    func testTurnsMatchDesktopSpotChecks() {
        // facedir 1 (turned about Y): top turns 3, bottom 1, sides unturned.
        XCTAssertEqual(WorldMesher.tileTurns[1][4], 0)   // +X
        XCTAssertEqual(WorldMesher.tileTurns[1][0], 3)   // +Y
        XCTAssertEqual(WorldMesher.tileTurns[1][1], 1)   // -Y
        // facedir 4 (tipped onto +Z).
        XCTAssertEqual(WorldMesher.tileTurns[4][4], 3)   // +X
        XCTAssertEqual(WorldMesher.tileTurns[4][2], 2)   // +Z
        XCTAssertEqual(WorldMesher.tileTurns[4][5], 1)   // -X
        // facedir 0 is all identity.
        XCTAssertEqual(WorldMesher.tileTurns[0], [0, 0, 0, 0, 0, 0])
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
