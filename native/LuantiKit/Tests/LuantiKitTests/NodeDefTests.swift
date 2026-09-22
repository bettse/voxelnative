import XCTest
import simd
@testable import LuantiKit

/// Builds a real TOCLIENT_NODEDEF payload (matching Luanti's ContentFeatures
/// wire format) and runs it through NodeRegistry, so the recent parse fixes are
/// regression-tested end to end:
///  - node_box corners are in BS units and must be divided by BS (the door bug)
///  - a "connected" node_box has 15 box-lists that must all be consumed or the
///    stream drifts into the sounds
///  - the "dug" sound is captured for local break audio
final class NodeDefTests: XCTestCase {

    // MARK: tests

    /// buildable_to (#178): grass/snow are replaceable so a placed block lands in
    /// them; solid nodes are not. Air (id 0) defaults true.
    func testBuildableToFlagParsed() {
        let grass = NodeFixtures.node(name: "t:tallgrass", drawtype: 0, dugSound: "", walkable: false, buildableTo: true) { w in w.u8(6).u8(0) }
        let stone = NodeFixtures.node(name: "t:stone", drawtype: 0, dugSound: "") { w in w.u8(6).u8(0) }
        let reg = NodeRegistry()
        reg.parseNodeDef(NodeFixtures.nodedefPayload([(1, grass), (2, stone)]))
        XCTAssertTrue(reg.isBuildableTo(reg.id(for: "t:tallgrass")!))
        XCTAssertFalse(reg.isBuildableTo(reg.id(for: "t:stone")!))
        XCTAssertTrue(reg.isBuildableTo(0), "air is replaceable")
    }

    /// climbable (#209): ladders (walkable) and vines (not walkable) carry the
    /// flag; plain nodes don't. Drives ascend/descend + fall-arrest physics.
    func testClimbableFlagParsed() {
        let ladder = NodeFixtures.node(name: "t:ladder", drawtype: 0, dugSound: "", walkable: true, climbable: true) { w in w.u8(6).u8(0) }
        let vine = NodeFixtures.node(name: "t:vine", drawtype: 0, dugSound: "", walkable: false, climbable: true) { w in w.u8(6).u8(0) }
        let stone = NodeFixtures.node(name: "t:stone", drawtype: 0, dugSound: "") { w in w.u8(6).u8(0) }
        let reg = NodeRegistry()
        reg.parseNodeDef(NodeFixtures.nodedefPayload([(1, ladder), (2, vine), (3, stone)]))
        XCTAssertTrue(reg.isClimbable(reg.id(for: "t:ladder")!))
        XCTAssertTrue(reg.isClimbable(reg.id(for: "t:vine")!))
        XCTAssertFalse(reg.isClimbable(reg.id(for: "t:stone")!))
    }

    /// move_resistance / liquid_viscosity feed the movement slowdown (#211):
    /// water viscosity 1, lava 7, cobweb 14 (via move_resistance), plain 0. The
    /// registry keeps the larger of the two fields.
    func testMoveResistanceParsed() {
        let water = NodeFixtures.node(name: "t:water", drawtype: 0, dugSound: "", viscosity: 1) { w in w.u8(6).u8(0) }
        let lava = NodeFixtures.node(name: "t:lava", drawtype: 0, dugSound: "", viscosity: 7) { w in w.u8(6).u8(0) }
        let web = NodeFixtures.node(name: "t:cobweb", drawtype: 0, dugSound: "", walkable: false, moveResistance: 14) { w in w.u8(6).u8(0) }
        let stone = NodeFixtures.node(name: "t:stone", drawtype: 0, dugSound: "") { w in w.u8(6).u8(0) }
        let reg = NodeRegistry()
        reg.parseNodeDef(NodeFixtures.nodedefPayload([(1, water), (2, lava), (3, web), (4, stone)]))
        XCTAssertEqual(reg.moveResistance(reg.id(for: "t:water")!), 1)
        XCTAssertEqual(reg.moveResistance(reg.id(for: "t:lava")!), 7)
        XCTAssertEqual(reg.moveResistance(reg.id(for: "t:cobweb")!), 14)
        XCTAssertEqual(reg.moveResistance(reg.id(for: "t:stone")!), 0)
    }

    func testDoorNodeBoxScaledFromBS() {
        // A door: full in x/y, thin in z (-0.5 .. -0.3125 node units).
        let blob = NodeFixtures.node(name: "test:door", drawtype: 12, dugSound: "door_dug") { w in
            w.u8(6).u8(1)              // NodeBox version 6, type fixed
            w.u16(1)                   // one box
            NodeFixtures.boxBS(w, SIMD3(-0.5, -0.5, -0.5), SIMD3(0.5, 0.5, -0.3125))
        }
        let reg = NodeRegistry()
        reg.parseNodeDef(NodeFixtures.nodedefPayload([(1, blob)]))

        guard let id = reg.id(for: "test:door") else { return XCTFail("node not parsed") }
        XCTAssertEqual(reg.kind(id), .nodebox)
        guard let box = reg.boxes(id)?.first else { return XCTFail("no box") }
        // Divided back to node units, and the thin z axis kept its thickness
        // (the bug clamped -0.3125 to -0.5 -> zero thickness -> invisible door).
        XCTAssertEqual(box.min.z, -0.5, accuracy: 1e-4)
        XCTAssertEqual(box.max.z, -0.3125, accuracy: 1e-4)
        XCTAssertGreaterThan(box.max.z - box.min.z, 0.1)   // real thickness
        XCTAssertEqual(box.min.x, -0.5, accuracy: 1e-4)
        XCTAssertEqual(box.max.y, 0.5, accuracy: 1e-4)
        XCTAssertEqual(reg.dugSound(id), "door_dug")
    }

    func testConnectedNodeBoxConsumesAllListsThenSound() {
        // A "connected" node_box (fences) serializes 15 box-lists; the parser
        // must consume all of them or it reads the sounds as box coordinates.
        let blob = NodeFixtures.node(name: "test:fence", drawtype: 12, dugSound: "wood_dug") { w in
            w.u8(6).u8(4)              // NodeBox version 6, type connected
            // fixed list: one post; the other 14 lists are empty.
            w.u16(1); NodeFixtures.boxBS(w, SIMD3(-0.125, -0.5, -0.125), SIMD3(0.125, 0.5, 0.125))
            for _ in 0..<14 { w.u16(0) }
        }
        let reg = NodeRegistry()
        reg.parseNodeDef(NodeFixtures.nodedefPayload([(1, blob)]))
        guard let id = reg.id(for: "test:fence") else { return XCTFail("node not parsed") }
        // If the 14 empty lists weren't consumed, the dug sound would be garbage.
        XCTAssertEqual(reg.dugSound(id), "wood_dug")
        XCTAssertEqual(reg.boxes(id)?.count, 1)
    }

    func testRegularNodeHasNoBoxButKeepsDugSound() {
        let blob = NodeFixtures.node(name: "test:stone", drawtype: 0, dugSound: "stone_dug") { w in
            w.u8(6).u8(0)              // regular node_box
        }
        let reg = NodeRegistry()
        reg.parseNodeDef(NodeFixtures.nodedefPayload([(1, blob)]))
        guard let id = reg.id(for: "test:stone") else { return XCTFail("node not parsed") }
        XCTAssertNil(reg.boxes(id))          // regular -> no nodebox geometry
        XCTAssertEqual(reg.kind(id), .cube)
        XCTAssertEqual(reg.dugSound(id), "stone_dug")
    }

    func testWalkableAndRightclickableFlags() {
        // Clover: not walkable (you pass through), not rightclickable.
        let clover = NodeFixtures.node(name: "test:clover", drawtype: 9, dugSound: "",
                          walkable: false) { w in w.u8(6).u8(0) }
        // Door: walkable + rightclickable (right-click uses it, doesn't place).
        let door = NodeFixtures.node(name: "test:door", drawtype: 12, dugSound: "",
                        rightclickable: true) { w in
            w.u8(6).u8(1); w.u16(1); NodeFixtures.boxBS(w, SIMD3(-0.5, -0.5, -0.5), SIMD3(0.5, 0.5, -0.3125))
        }
        let reg = NodeRegistry()
        reg.parseNodeDef(NodeFixtures.nodedefPayload([(1, clover), (2, door)]))
        let c = reg.id(for: "test:clover")!, d = reg.id(for: "test:door")!
        XCTAssertFalse(reg.isWalkable(c))
        XCTAssertFalse(reg.isRightclickable(c))
        XCTAssertTrue(reg.isWalkable(d))
        XCTAssertTrue(reg.isRightclickable(d))
    }

    /// NodeDefManager::nodeboxConnects (#299): a pane (connected nodebox,
    /// connects to the fence) may grow an arm toward a fence only on the
    /// faces the FENCE's connect_sides allows (front/back/left/right), never
    /// up/down; a plain stone target with no connect_sides accepts any face;
    /// two connected nodeboxes need each other in connects_to.
    func testNodeboxConnectsHonoursTargetConnectSides() {
        func connectedBox(_ w: PacketWriter) {
            w.u8(6).u8(4); w.u16(1); NodeFixtures.boxBS(w, SIMD3(-0.1, -0.5, -0.1), SIMD3(0.1, 0.5, 0.1))
            for _ in 0..<6 { w.u16(0) }; for _ in 0..<8 { w.u16(0) }
        }
        let pane = NodeFixtures.node(name: "t:pane", drawtype: 12, dugSound: "", connectsTo: [2, 3, 4]) { connectedBox($0) }
        let fence = NodeFixtures.node(name: "t:fence", drawtype: 12, dugSound: "", connectsTo: [1, 2, 3, 5], connectSides: 4 | 8 | 16 | 32) { connectedBox($0) }
        let wall = NodeFixtures.node(name: "t:wall", drawtype: 12, dugSound: "", connectsTo: [5]) { connectedBox($0) }
        let stone = NodeFixtures.node(name: "t:stone", drawtype: 0, dugSound: "") { w in w.u8(6).u8(0) }
        let sidesOnly = NodeFixtures.node(name: "t:post", drawtype: 0, dugSound: "", connectSides: 8 | 32) { w in w.u8(6).u8(0) }
        let reg = NodeRegistry()
        reg.parseNodeDef(NodeFixtures.nodedefPayload([(1, pane), (2, fence), (3, stone), (4, sidesOnly), (5, wall)]))
        // pane <-> fence: both connected nodeboxes listing each other -> arms on
        // every face (the engine ignores connect_sides between two connected boxes).
        XCTAssertTrue(reg.nodeboxConnects(from: 1, to: 2, dir: 0))
        XCTAssertTrue(reg.nodeboxConnects(from: 2, to: 1, dir: 3))
        // fence -> wall: the wall is a connected box that does NOT list the fence back.
        XCTAssertFalse(reg.nodeboxConnects(from: 2, to: 5, dir: 3))
        // pane -> plain stone: no connect_sides on the stone -> any face.
        XCTAssertTrue(reg.nodeboxConnects(from: 1, to: 3, dir: 0))
        XCTAssertTrue(reg.nodeboxConnects(from: 1, to: 3, dir: 5))
        // pane -> a post that only accepts left/right: top refused, left ok.
        XCTAssertFalse(reg.nodeboxConnects(from: 1, to: 4, dir: 0))
        XCTAssertTrue(reg.nodeboxConnects(from: 1, to: 4, dir: 3))
        // not in connects_to at all -> never.
        XCTAssertFalse(reg.nodeboxConnects(from: 1, to: 99, dir: 3))
    }

    func testConnectedNodeBoxKeepsArmsAndConnectsTo() {
        // A fence (id 5) that connects to id 9, with a distinct box in the
        // front-connect arm so we can tell the arms were kept in order.
        let fence = NodeFixtures.node(name: "test:fence", drawtype: 12, dugSound: "wood_dug",
                         connectsTo: [9]) { w in
            w.u8(6).u8(4)                                  // version, connected
            w.u16(1); NodeFixtures.boxBS(w, SIMD3(-0.125, -0.5, -0.125), SIMD3(0.125, 0.5, 0.125))  // fixed post
            w.u16(0)                                       // connect_top: empty
            w.u16(0)                                       // connect_bottom: empty
            w.u16(1); NodeFixtures.boxBS(w, SIMD3(-0.1, 0.2, -0.5), SIMD3(0.1, 0.4, 0.0))            // connect_front: a rail
            w.u16(0)                                       // connect_left
            w.u16(0)                                       // connect_back
            w.u16(0)                                       // connect_right
            for _ in 0..<8 { w.u16(0) }                    // 6 disconnected_* + disconnected + disconnected_sides
        }
        let reg = NodeRegistry()
        reg.parseNodeDef(NodeFixtures.nodedefPayload([(5, fence)]))
        let id = reg.id(for: "test:fence")!
        XCTAssertEqual(reg.connectsToSet(id), [9])
        guard let arms = reg.connectArms(id) else { return XCTFail("no connect arms") }
        XCTAssertEqual(arms.count, 6)
        XCTAssertTrue(arms[0].isEmpty)                     // top empty
        XCTAssertEqual(arms[2].count, 1)                   // front has the rail
        XCTAssertEqual(reg.boxes(id)?.count, 1)            // fixed post kept
        XCTAssertEqual(reg.dugSound(id), "wood_dug")       // stream didn't drift
    }

    func testCollisionBoxKeptSeparateFromNodeBox() {
        // A fence draws a 1.0-tall post (node_box) but collides as a 1.5-tall
        // post (collision_box), so you can't jump it (#214). Both must be kept.
        let fence = NodeFixtures.node(name: "test:fence", drawtype: 12, dugSound: "wood_dug",
                         connectsTo: [9],
                         collisionBox: { w in
            w.u8(6).u8(4)                                  // version, connected
            w.u16(1); NodeFixtures.boxBS(w, SIMD3(-0.125, -0.5, -0.125), SIMD3(0.125, 1.0, 0.125))   // taller post
            w.u16(0); w.u16(0)                            // connect_top/bottom empty
            w.u16(1); NodeFixtures.boxBS(w, SIMD3(-0.1, 0.2, -0.5), SIMD3(0.1, 0.9, 0.0))            // front rail (tall)
            for _ in 0..<11 { w.u16(0) }                  // left/back/right + 8 disconnected lists
        }) { w in
            w.u8(6).u8(4)                                  // node_box: connected, 0.5-high post
            w.u16(1); NodeFixtures.boxBS(w, SIMD3(-0.125, -0.5, -0.125), SIMD3(0.125, 0.5, 0.125))
            for _ in 0..<14 { w.u16(0) }
        }
        let reg = NodeRegistry()
        reg.parseNodeDef(NodeFixtures.nodedefPayload([(5, fence)]))
        let id = reg.id(for: "test:fence")!
        // Visual node_box: post to +0.5 (1.0 tall).
        XCTAssertEqual(reg.boxes(id)?.first?.max.y ?? 0, 0.5, accuracy: 1e-4)
        // collision_box: post to +1.0 (1.5 tall) -- kept apart, taller.
        XCTAssertEqual(reg.collisionBoxesFor(id)?.first?.max.y ?? 0, 1.0, accuracy: 1e-4)
        XCTAssertEqual(reg.collisionConnectArms(id)?.count, 6)   // arms parsed from collision_box
        XCTAssertEqual(reg.collisionConnectArms(id)?[2].count, 1) // front rail present
        XCTAssertEqual(reg.dugSound(id), "wood_dug")             // stream didn't drift
    }

    func testWaterIsUnpointableWithShadedPostEffect() {
        // Water: not pointable (ray passes through to the chest below) and a
        // post_effect_color the client paints over the view, light-shaded.
        let water = NodeFixtures.node(name: "test:water", drawtype: 2, dugSound: "", walkable: false,
                         pointable: false, postEffect: (a: 209, r: 3, g: 60, b: 92), shaded: true) { w in w.u8(6).u8(0) }
        let stone = NodeFixtures.node(name: "test:stone", drawtype: 0, dugSound: "") { w in w.u8(6).u8(0) }
        let reg = NodeRegistry()
        reg.parseNodeDef(NodeFixtures.nodedefPayload([(1, water), (2, stone)]))
        let wid = reg.id(for: "test:water")!, sid = reg.id(for: "test:stone")!
        XCTAssertFalse(reg.isPointable(wid))
        XCTAssertTrue(reg.isPointable(sid))
        XCTAssertNil(reg.postEffect(sid))
        guard let fx = reg.postEffect(wid) else { return XCTFail("no post effect") }
        XCTAssertEqual(fx.color.w, 209.0 / 255.0, accuracy: 1e-4)
        XCTAssertEqual(fx.color.y, 60.0 / 255.0, accuracy: 1e-4)
        XCTAssertTrue(fx.shaded)

        // And the raycast really skips it: ray straight down through water onto stone.
        let map = WorldMap()
        map.setNode(SIMD3(0, 5, 0), param0: wid)
        map.setNode(SIMD3(0, 4, 0), param0: wid)
        map.setNode(SIMD3(0, 3, 0), param0: sid)
        let hit = map.raycast(origin: SIMD3(0.5, 6.5, 0.5), dir: SIMD3(0, -1, 0), maxDist: 5, pointable: reg.isPointable)
        XCTAssertEqual(hit?.under, SIMD3(0, 3, 0))
        XCTAssertEqual(hit?.above, SIMD3(0, 4, 0))
    }

    func testLiquidFamilyAndRange() {
        let src = NodeFixtures.node(name: "test:water_source", drawtype: 2, dugSound: "", walkable: false,
                       liquidAlt: ("test:water_flowing", "test:water_source"), liquidRange: 7) { w in w.u8(6).u8(0) }
        let flow = NodeFixtures.node(name: "test:water_flowing", drawtype: 3, dugSound: "", walkable: false,
                        liquidAlt: ("test:water_flowing", "test:water_source"), liquidRange: 7) { w in w.u8(6).u8(0) }
        let reg = NodeRegistry()
        reg.parseNodeDef(NodeFixtures.nodedefPayload([(1, src), (2, flow)]))
        let s = reg.id(for: "test:water_source")!, f = reg.id(for: "test:water_flowing")!
        XCTAssertEqual(reg.liquidRange(f), 7)
        XCTAssertEqual(reg.liquidFamily(f)?.source, s)
        XCTAssertEqual(reg.liquidFamily(s)?.flowing, f)
        XCTAssertTrue(reg.isLiquid(f))
    }

    func testRaycastHitsSlabOnlyWhereItsBoxIs() {
        // A bottom half-slab at (0,3,0); the ray walks the full-cube grid but the
        // node only counts where its box is.
        let map = WorldMap()
        let slab: UInt16 = 7, stone: UInt16 = 8
        map.setNode(SIMD3(0, 3, 0), param0: slab)
        map.setNode(SIMD3(0, 3, -3), param0: stone)
        let boxes: (SIMD3<Int>, UInt16) -> [(lo: SIMD3<Float>, hi: SIMD3<Float>)]? = { _, id in
            id == slab ? [(SIMD3(0, 0, 0), SIMD3(1, 0.5, 1))] : nil
        }
        // Straight down onto the slab: hit, and "above" is the node over it.
        let down = map.raycast(origin: SIMD3(0.5, 6.5, 0.5), dir: SIMD3(0, -1, 0), maxDist: 6, boxes: boxes)
        XCTAssertEqual(down?.under, SIMD3(0, 3, 0)); XCTAssertEqual(down?.above, SIMD3(0, 4, 0))
        // Horizontal ray through the empty top half of the slab node passes
        // through and hits the stone behind it (a full cube).
        let across = map.raycast(origin: SIMD3(0.5, 3.75, 2.5), dir: SIMD3(0, 0, -1), maxDist: 8, boxes: boxes)
        XCTAssertEqual(across?.under, SIMD3(0, 3, -3)); XCTAssertEqual(across?.above, SIMD3(0, 3, -2))
        // Same ray through the lower half hits the slab's +Z face.
        let low = map.raycast(origin: SIMD3(0.5, 3.25, 2.5), dir: SIMD3(0, 0, -1), maxDist: 8, boxes: boxes)
        XCTAssertEqual(low?.under, SIMD3(0, 3, 0)); XCTAssertEqual(low?.above, SIMD3(0, 3, 1))
    }
}
