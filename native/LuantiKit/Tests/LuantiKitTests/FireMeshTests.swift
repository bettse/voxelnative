import XCTest
import simd
@testable import LuantiKit

/// Firelike (drawtype 14) quad selection, ported from Luanti's drawFirelikeNode.
/// Neighbour flags are D6D-indexed: 0 +Z, 1 +Y, 2 +X, 3 -Z, 4 -Y, 5 -X. The
/// exact on-screen rotation sense under the Z-mirror still wants a device glance.
final class FireMeshTests: XCTestCase {
    private func none() -> [Bool] { [Bool](repeating: false, count: 6) }

    func testIsolatedFireDrawsTheFullFlame() {
        // No neighbours: basic fire = 4 leaning sides + 2 centre diagonals.
        XCTAssertEqual(WorldMesher.firelikeQuads(none()).count, 6)
    }

    func testFireOnAFloorDrawsTheFullFlame() {
        var s = none(); s[4] = true          // -Y solid (floor below)
        XCTAssertEqual(WorldMesher.firelikeQuads(s).count, 6)
    }

    func testFireOnASingleWallDrawsJustThatFace() {
        // A wall on +Z, no floor, not isolated: only the +Z-facing flame, no
        // centre diagonals (basic is false).
        var s = none(); s[0] = true          // +Z solid
        XCTAssertEqual(WorldMesher.firelikeQuads(s).count, 1)
    }

    func testFireUnderACeilingHangsFromEachSide() {
        // Ceiling only (+Y), no floor, no walls: four hanging quads, no centre.
        var s = none(); s[1] = true          // +Y solid
        XCTAssertEqual(WorldMesher.firelikeQuads(s).count, 4)
    }

    func testTwoWallsDrawTwoFaces() {
        var s = none(); s[0] = true; s[2] = true   // +Z and +X walls, no floor
        XCTAssertEqual(WorldMesher.firelikeQuads(s).count, 2)
    }

    func testEachQuadHasFourCornersInTheNodeFootprint() {
        for q in WorldMesher.firelikeQuads(none()) {
            XCTAssertEqual(q.count, 4)
            // Leaning/centre flames stay within a generous box around the node.
            for c in q {
                XCTAssertGreaterThan(c.x, -1.0); XCTAssertLessThan(c.x, 2.0)
                XCTAssertGreaterThan(c.y, -1.0); XCTAssertLessThan(c.y, 2.0)
                XCTAssertGreaterThan(c.z, -1.0); XCTAssertLessThan(c.z, 2.0)
            }
        }
    }

    func testRotationTurnsTheQuad() {
        // The same quad at 0 and 90 degrees occupies different footprints.
        let a = WorldMesher.firelikeQuad(rotation: 0, opening: -10, offsetH: 0.4)
        let b = WorldMesher.firelikeQuad(rotation: 90, opening: -10, offsetH: 0.4)
        XCTAssertGreaterThan(abs(a[0].x - b[0].x) + abs(a[0].z - b[0].z), 0.3)
    }
}
