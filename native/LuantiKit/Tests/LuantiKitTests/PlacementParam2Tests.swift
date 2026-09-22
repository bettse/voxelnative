import XCTest
import simd
@testable import LuantiKit

/// Client-side placement param2 prediction (#178), matching Luanti game.cpp
/// nodePlacement, so oriented nodes appear facing right without a round-trip.
final class PlacementParam2Tests: XCTestCase {
    // facedir (pt2 3) / 4dir (12): the node faces the player. Luanti:
    // |dx|>|dz| -> dx<0?3:1 ; else dz<0?2:0.
    func testFacedirFacesPlayer() {
        let node = SIMD3(10, 5, 10)
        // Player to the -X of the node (dx = node-player > 0) -> 1
        XCTAssertEqual(WorldMap.placementParam2(pt2: 3, nodepos: node, neighborpos: node &- SIMD3(0,1,0), playerpos: SIMD3(4, 5, 10)), 1)
        // Player to the +X (dx < 0) -> 3
        XCTAssertEqual(WorldMap.placementParam2(pt2: 3, nodepos: node, neighborpos: node &- SIMD3(0,1,0), playerpos: SIMD3(16, 5, 10)), 3)
        // Player to the -Z (dz > 0) -> 0
        XCTAssertEqual(WorldMap.placementParam2(pt2: 13, nodepos: node, neighborpos: node, playerpos: SIMD3(10, 5, 4)), 0)
        // Player to the +Z (dz < 0) -> 2
        XCTAssertEqual(WorldMap.placementParam2(pt2: 13, nodepos: node, neighborpos: node, playerpos: SIMD3(10, 5, 16)), 2)
    }

    // wallmounted (pt2 4): mounts to the face you pointed at. dir = node - neighbor.
    // |dy| dominant -> dy<0?1:0 ; |dx| -> dx<0?3:2 ; else dz<0?5:4.
    func testWallmountedMountsToPointedFace() {
        let node = SIMD3(10, 5, 10)
        // Placed on top of the neighbor below (dir.y = +1) -> floor mount 0
        XCTAssertEqual(WorldMap.placementParam2(pt2: 4, nodepos: node, neighborpos: node &- SIMD3(0,1,0), playerpos: SIMD3(0,0,0)), 0)
        // Placed under the neighbor above (dir.y = -1) -> ceiling mount 1
        XCTAssertEqual(WorldMap.placementParam2(pt2: 4, nodepos: node, neighborpos: node &+ SIMD3(0,1,0), playerpos: SIMD3(0,0,0)), 1)
        // Against the neighbor at -X (dir.x = +1) -> 2
        XCTAssertEqual(WorldMap.placementParam2(pt2: 10, nodepos: node, neighborpos: node &- SIMD3(1,0,0), playerpos: SIMD3(0,0,0)), 2)
        // Against the neighbor at +X (dir.x = -1) -> 3
        XCTAssertEqual(WorldMap.placementParam2(pt2: 4, nodepos: node, neighborpos: node &+ SIMD3(1,0,0), playerpos: SIMD3(0,0,0)), 3)
        // Against the neighbor at -Z (dir.z = +1) -> 4
        XCTAssertEqual(WorldMap.placementParam2(pt2: 4, nodepos: node, neighborpos: node &- SIMD3(0,0,1), playerpos: SIMD3(0,0,0)), 4)
    }

    func testUnorientedNodeGetsZero() {
        let node = SIMD3(1, 1, 1)
        XCTAssertEqual(WorldMap.placementParam2(pt2: 0, nodepos: node, neighborpos: node, playerpos: SIMD3(9, 1, 1)), 0)
    }
}
