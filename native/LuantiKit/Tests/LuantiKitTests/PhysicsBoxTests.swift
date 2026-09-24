import XCTest
@testable import LuantiKit

/// Physics boxes follow MapNode::getCollisionBoxes: node_box / collision_box
/// apply to ANY drawtype, not just the boxy ones. A signlike ladder
/// with a wallmounted plate must not collide as a full cube.
final class PhysicsBoxTests: XCTestCase {
    private func registry(_ blobs: [(Int, Data)]) -> NodeRegistry {
        let r = NodeRegistry(); r.parseNodeDef(NodeFixtures.nodedefPayload(blobs)); return r
    }

    func testSignlikeLadderKeepsWallmountedPlateForPhysics() {
        // mcl_core:ladder: drawtype signlike (9), walkable + climbable, node_box
        // wallmounted with wall_side = {-0.5,-0.5,-0.5, -7/16,0.5,0.5}.
        let ladder = NodeFixtures.node(name: "t:ladder", drawtype: 9, dugSound: "", climbable: true) { w in
            w.u8(6).u8(2)   // NodeBox version 6, type wallmounted: top, bottom, side
            NodeFixtures.boxBS(w, SIMD3(-0.5, 0.4375, -0.5), SIMD3(0.5, 0.5, 0.5))
            NodeFixtures.boxBS(w, SIMD3(-0.5, -0.5, -0.5), SIMD3(0.5, -0.4375, 0.5))
            NodeFixtures.boxBS(w, SIMD3(-0.5, -0.5, -0.5), SIMD3(-0.4375, 0.5, 0.5))
        }
        let reg = registry([(1, ladder)])
        let id = reg.id(for: "t:ladder")!
        XCTAssertNotEqual(reg.kind(id), .nodebox, "signlike keeps its drawtype for rendering")
        XCTAssertTrue(reg.isWallmountedBox(id))
        let boxes = reg.boxes(id)
        XCTAssertEqual(boxes?.count, 3)
        // Wall on the -X side (param2 = 3, the wallmounted table's wall entry with
        // no rotation) picks the side plate, 1/16 thick.
        let picked = WorldMesher.wallmountedBox(boxes!, param2: 2)
        XCTAssertEqual(picked.count, 1)
        XCTAssertEqual(picked[0].max.x - picked[0].min.x, 0.0625, accuracy: 1e-5)
        XCTAssertNil(reg.collisionBoxesFor(id))
    }

    func testMeshNodeCollisionBoxIsStored() {
        // A mesh chest (drawtype 7) with a 14/16 collision_box.
        let chest = NodeFixtures.node(name: "t:chest", drawtype: 7, dugSound: "", collisionBox: { w in
            w.u8(6).u8(1); w.u16(1)
            NodeFixtures.boxBS(w, SIMD3(-0.4375, -0.5, -0.4375), SIMD3(0.4375, 0.375, 0.4375))
        }) { w in w.u8(6).u8(0) }
        let reg = registry([(1, chest)])
        let id = reg.id(for: "t:chest")!
        XCTAssertEqual(reg.collisionBoxesFor(id)?.count, 1)
        XCTAssertNil(reg.boxes(id), "regular node_box stores nothing")
    }
}
