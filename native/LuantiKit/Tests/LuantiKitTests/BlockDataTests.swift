import XCTest
@testable import LuantiKit

/// TOCLIENT_BLOCKDATA decode: the foundation of the whole world. Builds the
/// exact wire payload the server sends (mapblock.cpp MapBlock::serialize v29+:
/// s16 block pos, then a zstd frame of [flags u8, lighting u16, content_width
/// u8, params_width u8, param0 bulk, param1 bulk, param2 bulk, node metadata],
/// then one serializeNetworkSpecific version byte), and checks it round-trips.
final class BlockDataTests: XCTestCase {
    private let n = WorldMap.NODES_PER_BLOCK

    /// Assemble a payload from a per-node params closure. contentWidth 2 writes
    /// param0 big-endian; 1 writes a single byte.
    private func payload(bpos: SIMD3<Int>, contentWidth: Int = 2,
                         node: (Int) -> (p0: Int, p1: Int, p2: Int),
                         meta: Data = Data([0]),   // NodeMetadataList version 0 = none
                         trailer: Int = 2) -> Data {
        let inner = PacketWriter()
        inner.u8(0x02)          // flags (not-air)
        inner.u16(0xFFFF)       // lighting_complete
        inner.u8(contentWidth).u8(2)   // content_width, params_width
        for i in 0..<n {
            let v = node(i).p0
            if contentWidth == 2 { inner.u16(v) } else { inner.u8(v) }
        }
        for i in 0..<n { inner.u8(node(i).p1) }
        for i in 0..<n { inner.u8(node(i).p2) }
        inner.raw(meta)
        let w = PacketWriter()
        w.s16(bpos.x).s16(bpos.y).s16(bpos.z)
        w.raw(Zstd.compress(inner.data)!)
        w.u8(trailer)           // serializeNetworkSpecific (dropped on decode)
        return w.data
    }

    func testRoundTripContentWidth2() {
        let world = WorldMap()
        // Node 0 = id 300; node index(1,2,3) = id 4660 (0x1234) with light 0xAB, param2 7.
        let target = WorldMap.index(1, 2, 3)
        let got = world.decodeBlockData(payload(bpos: SIMD3(2, -1, 4)) { i in
            if i == 0 { return (300, 0, 0) }
            if i == target { return (0x1234, 0xAB, 7) }
            return (Int(WorldMap.CONTENT_AIR), 0x0F, 0)
        })
        XCTAssertEqual(got, SIMD3(2, -1, 4))
        // The block lives at bpos*16; sample within it.
        XCTAssertEqual(world.nodeId(SIMD3(32, -16, 64)), 300)             // node 0
        XCTAssertEqual(world.nodeId(SIMD3(32 + 1, -16 + 2, 64 + 3)), 0x1234)
        XCTAssertEqual(world.nodeLight(SIMD3(33, -14, 67)), 0xAB)
        XCTAssertEqual(world.nodeParam2(SIMD3(33, -14, 67)), 7)
    }

    func testRoundTripContentWidth1() {
        let world = WorldMap()
        let got = world.decodeBlockData(payload(bpos: .zero, contentWidth: 1) { i in
            i == 5 ? (42, 3, 1) : (0, 0, 0)
        })
        XCTAssertEqual(got, .zero)
        XCTAssertEqual(world.nodeId(SIMD3(5, 0, 0)), 42, "single-byte content ids decode too")
    }

    func testBigEndianParam0() {
        // 0x0102 must decode as 258, not 0x0201 - guards the byte order.
        let world = WorldMap()
        _ = world.decodeBlockData(payload(bpos: .zero) { i in i == 0 ? (0x0102, 0, 0) : (0, 0, 0) })
        XCTAssertEqual(world.nodeId(.zero), 258)
    }

    func testNodeMetadataAfterBulkIsParsed() {
        // A chest at node 0 with a "main" list of one stack. Inventory text is
        // the format Inventory::serialize writes, terminated by EndInventory.
        let inv = "List main 1\nWidth 0\nItem default:dirt 5\nEndInventory\n"
        let m = PacketWriter()
        m.u8(2)                 // NodeMetadataList version 2
        m.u16(1)                // one node
        m.u16(0)                // packed pos 0 -> node (0,0,0)
        m.u32(0)                // zero string vars
        m.raw(Data(inv.utf8))
        let world = WorldMap()
        _ = world.decodeBlockData(payload(bpos: .zero, node: { _ in (5, 0, 0) }, meta: m.data))
        let main = world.nodeInventory(.zero, list: "main")
        XCTAssertNotNil(main, "chest inventory parsed from the block's node metadata")
        XCTAssertEqual(main?.first??.name, "default:dirt")
        XCTAssertEqual(main?.first??.count, 5)
    }

    func testGarbagePayloadReturnsNilNotCrash() {
        XCTAssertNil(WorldMap().decodeBlockData(Data([0, 0, 0, 0, 0, 0, 9, 9, 9])))
    }
}
