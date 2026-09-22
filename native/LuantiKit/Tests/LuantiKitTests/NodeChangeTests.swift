import XCTest
@testable import LuantiKit

/// TOCLIENT_ADDNODE (0x21) and TOCLIENT_REMOVENODE (0x22): the single-node
/// updates that reconcile every server-authoritative dig/place. Layout from
/// clientpackethandler.cpp: ADDNODE = v3s16 pos, MapNode (u16 param0 big-
/// endian, u8 param1, u8 param2), u8 keep_metadata; REMOVENODE = v3s16 pos.
final class NodeChangeTests: XCTestCase {
    private func addNodePayload(_ p: SIMD3<Int>, param0: Int, param1: Int, param2: Int, keepMeta: Int = 0) -> Data {
        PacketWriter().s16(p.x).s16(p.y).s16(p.z)
            .u16(param0).u8(param1).u8(param2).u8(keepMeta).data
    }

    func testAddNodeSetsParamsAndReturnsPos() {
        let w = WorldMap()
        let p = SIMD3(5, -3, 130)
        let got = w.decodeAddNode(addNodePayload(p, param0: 0x1234, param1: 0x0A, param2: 7))
        XCTAssertEqual(got, p)
        XCTAssertEqual(w.nodeId(p), 0x1234, "param0 decodes big-endian")
        XCTAssertEqual(w.nodeLight(p), 0x0A)
        XCTAssertEqual(w.nodeParam2(p), 7)
    }

    func testAddNodeIgnoresTrailingKeepMetadata() {
        // A keep_metadata byte of 1 must not shift the param reads.
        let w = WorldMap()
        _ = w.decodeAddNode(addNodePayload(SIMD3(0, 0, 0), param0: 42, param1: 0, param2: 3, keepMeta: 1))
        XCTAssertEqual(w.nodeId(SIMD3(0, 0, 0)), 42)
        XCTAssertEqual(w.nodeParam2(SIMD3(0, 0, 0)), 3)
    }

    func testRemoveNodeClearsToAir() {
        let w = WorldMap()
        let p = SIMD3(2, 4, 6)
        _ = w.decodeAddNode(addNodePayload(p, param0: 500, param1: 0, param2: 0))
        XCTAssertEqual(w.nodeId(p), 500)
        let got = w.decodeRemoveNode(PacketWriter().s16(p.x).s16(p.y).s16(p.z).data)
        XCTAssertEqual(got, p)
        XCTAssertEqual(w.nodeId(p), WorldMap.CONTENT_AIR, "removed node becomes air")
    }

    func testNegativeCoordsRoundTrip() {
        let w = WorldMap()
        let p = SIMD3(-40, -1, -42)   // s16 sign handling
        _ = w.decodeAddNode(addNodePayload(p, param0: 9, param1: 0, param2: 0))
        XCTAssertEqual(w.nodeId(p), 9)
        // A node in a different 16^3 block is still unloaded (setNode only
        // materialises the target's block).
        XCTAssertEqual(w.nodeId(SIMD3(-60, -1, -42)), WorldMap.CONTENT_IGNORE, "far block stays unloaded")
    }
}

/// Accessors the dropped-node icon fallback relies on (#129).
final class DroppedNodeFallbackTests: XCTestCase {
    func testFaceTileReturnsTopTile() {
        let stone = NodeFixtures.node(name: "test:stone", drawtype: 0, dugSound: "") { w in w.u8(6).u8(0) }
        let reg = NodeRegistry()
        reg.parseNodeDef(NodeFixtures.nodedefPayload([(1, stone)]))
        let id = reg.id(for: "test:stone")!
        XCTAssertEqual(reg.faceTile(id, 0), "t.png", "top face tile (the fixture uses t.png)")
        XCTAssertNil(reg.faceTile(9999, 0), "unknown id has no tile")
    }

    func testBaseNameStripsCountAndMeta() {
        XCTAssertEqual(ItemRegistry.baseName("mcl_core:dirt"), "mcl_core:dirt")
        XCTAssertEqual(ItemRegistry.baseName("mcl_core:dirt 5"), "mcl_core:dirt", "count dropped")
        XCTAssertEqual(ItemRegistry.baseName("mcl_tools:pick_wood 1 200"), "mcl_tools:pick_wood")
    }
}
