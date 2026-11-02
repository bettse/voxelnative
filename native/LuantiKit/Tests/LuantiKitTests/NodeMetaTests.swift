import XCTest
import simd
@testable import LuantiKit

/// TOCLIENT_NODEMETA_CHANGED parse (absolute positions): a chest's inventory
/// updates live after the block first loaded.
final class NodeMetaTests: XCTestCase {
    func testApplyNodeMetaChangedUpdatesInventory() throws {
        let w = PacketWriter()
        w.u8(2)                      // version
        w.u16(1)                     // one node
        w.s16(10).s16(20).s16(30)    // absolute pos
        w.u32(1)                     // one string var
        w.string16("formspec"); w.string32("size[9,9]"); w.u8(0)   // name/value/private
        let inv = "List main 3\nWidth 9\nItem mcl_core:stone 5\nEmpty\nItem mcl_core:dirt\nEndInventoryList\nEndInventory\n"
        w.raw(Data(inv.utf8))

        let map = WorldMap()
        let changed = map.applyNodeMetaChanged(w.data)
        XCTAssertEqual(changed, [SIMD3(10, 20, 30)])
        let main = try XCTUnwrap(map.nodeInventory(SIMD3(10, 20, 30)))
        XCTAssertEqual(main.count, 3)
        XCTAssertEqual(main[0]?.name, "mcl_core:stone"); XCTAssertEqual(main[0]?.count, 5)
        XCTAssertNil(main[1])
        XCTAssertEqual(main[2]?.name, "mcl_core:dirt")
        // The `formspec` string var is captured so a furnace (no on_rightclick)
        // can be opened client-side on rightclick.
        XCTAssertEqual(map.nodeFormspec(SIMD3(10, 20, 30)), "size[9,9]")
        XCTAssertNil(map.nodeFormspec(SIMD3(0, 0, 0)))
    }

    private func metaPacket(_ pos: SIMD3<Int>) -> Data {
        let w = PacketWriter()
        w.u8(2); w.u16(1)
        w.s16(pos.x).s16(pos.y).s16(pos.z)
        w.u32(1); w.string16("formspec"); w.string32("size[9,9]"); w.u8(0)
        w.raw(Data("List main 1\nWidth 1\nItem mcl_core:stone 5\nEndInventoryList\nEndInventory\n".utf8))
        return w.data
    }

    /// Every position in the packet is reported, not only ones seen for the
    /// first time: a smithing table's output filling in is a change to meta
    /// that arrived with the block, and the open form has to hear about it.
    func testApplyNodeMetaChangedReportsKnownPositions() {
        let map = WorldMap()
        let p = SIMD3(10, 20, 30)
        XCTAssertEqual(map.applyNodeMetaChanged(metaPacket(p)), [p])
        XCTAssertEqual(map.applyNodeMetaChanged(metaPacket(p)), [p], "second update of the same node")
    }

    /// The meta goes with the node: dig a furnace (REMOVENODE) or have the
    /// server replace it (ADDNODE without keep_metadata) and the old form and
    /// stacks must not open from the block placed in its spot.
    func testRemoveAndAddNodeClearMeta() {
        let map = WorldMap()
        let p = SIMD3(10, 20, 30)
        _ = map.applyNodeMetaChanged(metaPacket(p))
        XCTAssertNotNil(map.nodeFormspec(p))
        _ = map.decodeRemoveNode(PacketWriter().s16(p.x).s16(p.y).s16(p.z).data)
        XCTAssertNil(map.nodeFormspec(p)); XCTAssertNil(map.nodeInventory(p))

        _ = map.applyNodeMetaChanged(metaPacket(p))
        _ = map.decodeAddNode(PacketWriter().s16(p.x).s16(p.y).s16(p.z).u16(7).u8(0).u8(0).u8(0).data)
        XCTAssertNil(map.nodeFormspec(p), "ADDNODE with keep_metadata 0 clears")

        _ = map.applyNodeMetaChanged(metaPacket(p))
        _ = map.decodeAddNode(PacketWriter().s16(p.x).s16(p.y).s16(p.z).u16(7).u8(0).u8(0).u8(1).data)
        XCTAssertEqual(map.nodeFormspec(p), "size[9,9]", "swap_node keeps the meta")
    }
}
