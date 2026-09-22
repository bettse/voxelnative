import XCTest
import simd
@testable import LuantiKit

/// Raillike connection logic: which of the 4 rail tiles (straight/curved/
/// junction/cross) and what rotation a rail picks from its neighbours, ported
/// from Luanti's rail_kinds table. Neighbour bits: 0 +Z, 1 -Z, 2 -X, 3 +X.
/// The table is orientation-critical, so pin every one of the 16 codes; the
/// exact on-screen rotation sense under the client's Z-mirror still wants a
/// device glance (same caveat as arrow/riding yaw-sign).
final class RailMeshTests: XCTestCase {
    private func ta(_ code: Int) -> (Int, Int) {
        let r = WorldMesher.railTileAndAngle(code: code, sloped: false, slopeAngle: 0)
        return (r.tile, r.angle)
    }

    func testFullRailKindsTableMatchesLuanti() {
        let expected: [(Int, Int)] = [
            (0,   0), (0,   0), (0,   0), (0,   0),
            (0,  90), (1, 180), (1, 270), (2, 180),
            (0,  90), (1,  90), (1,   0), (2,   0),
            (0,  90), (2,  90), (2, 270), (3,   0),
        ]
        for code in 0..<16 {
            let (t, a) = ta(code)
            XCTAssertEqual(t, expected[code].0, "tile for code \(code)")
            XCTAssertEqual(a, expected[code].1, "angle for code \(code)")
        }
    }

    func testIsolatedRailIsStraight() {
        XCTAssertEqual(ta(0).0, 0)   // no neighbours -> straight tile
    }

    func testStraightRunsUseTheStraightTile() {
        // +Z and -Z (a north-south run) = bits 0|1 = code 3, straight, angle 0.
        XCTAssertEqual(ta(0b0011).0, 0); XCTAssertEqual(ta(0b0011).1, 0)
        // +X and -X (east-west) = bits 3|2 = code 12, straight rotated 90.
        XCTAssertEqual(ta(0b1100).0, 0); XCTAssertEqual(ta(0b1100).1, 90)
    }

    func testCornerUsesTheCurvedTile() {
        // +X (bit3) and +Z (bit0) meeting = code 9 -> curved.
        XCTAssertEqual(ta(0b1001).0, 1)
    }

    func testThreeWayIsAJunction() {
        // +X, -X, +Z = bits 3,2,0 = code 13 -> junction (tile 2).
        XCTAssertEqual(ta(0b1101).0, 2)
    }

    func testAllFourIsACrossing() {
        XCTAssertEqual(ta(0b1111).0, 3); XCTAssertEqual(ta(0b1111).1, 0)   // code 15 -> cross tile
    }

    func testSlopeOverridesToStraightAtSlopeAngle() {
        // Even a corner code becomes the straight tile when the rail ascends.
        let r = WorldMesher.railTileAndAngle(code: 0b1001, sloped: true, slopeAngle: 90)
        XCTAssertEqual(r.tile, 0)
        XCTAssertEqual(r.angle, 90)
    }

    func testSlopeAnglesPerDirection() {
        XCTAssertEqual(WorldMesher.railSlopeAngle(0), 0)     // ascends toward +Z
        XCTAssertEqual(WorldMesher.railSlopeAngle(1), 180)   // -Z
        XCTAssertEqual(WorldMesher.railSlopeAngle(2), 90)    // -X
        XCTAssertEqual(WorldMesher.railSlopeAngle(3), -90)   // +X
    }

    func testFlatGeomMatchesThePriorStraightQuad() {
        // The angle-0 flat rail must be pixel-identical to the old railQuad so
        // straight rails (already verified on device) don't move.
        let q = WorldMesher.railGeom(sloped: false, angle: 0)
        let want: [SIMD3<Float>] = [SIMD3(0,0.0625,0), SIMD3(0,0.0625,1), SIMD3(1,0.0625,1), SIMD3(1,0.0625,0)]
        XCTAssertEqual(q.count, 4)
        for i in 0..<4 {
            XCTAssertEqual(q[i].x, want[i].x, accuracy: 1e-5)
            XCTAssertEqual(q[i].y, want[i].y, accuracy: 1e-5)
            XCTAssertEqual(q[i].z, want[i].z, accuracy: 1e-5)
        }
    }

    func testSlopedGeomRaisesThePlusZEdge() {
        let q = WorldMesher.railGeom(sloped: true, angle: 0)
        // corners at z=1 (indices 1,2) are near the node top; z=0 corners stay low.
        XCTAssertGreaterThan(q[1].y, 1.0); XCTAssertGreaterThan(q[2].y, 1.0)
        XCTAssertLessThan(q[0].y, 0.5); XCTAssertLessThan(q[3].y, 0.5)
    }

    func testRotation90IsAQuarterTurnAboutCentre() {
        let q = WorldMesher.railGeom(sloped: false, angle: 90)
        // Every corner stays on the node footprint (0..1) and off the x=0/z=0
        // base position: a 90 deg turn about (0.5,0.5) maps (0,0)->(0,1)-ish.
        for c in q {
            XCTAssertGreaterThanOrEqual(c.x, -1e-4); XCTAssertLessThanOrEqual(c.x, 1 + 1e-4)
            XCTAssertGreaterThanOrEqual(c.z, -1e-4); XCTAssertLessThanOrEqual(c.z, 1 + 1e-4)
        }
        // Rotation actually moved the corners (90 deg about centre sends the
        // x=0 base edge across to x=1).
        let flat = WorldMesher.railGeom(sloped: false, angle: 0)
        XCTAssertGreaterThan(abs(q[0].x - flat[0].x), 0.4)
    }
}
