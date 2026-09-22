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
        // can be opened client-side on rightclick (#166).
        XCTAssertEqual(map.nodeFormspec(SIMD3(10, 20, 30)), "size[9,9]")
        XCTAssertNil(map.nodeFormspec(SIMD3(0, 0, 0)))
    }
}
