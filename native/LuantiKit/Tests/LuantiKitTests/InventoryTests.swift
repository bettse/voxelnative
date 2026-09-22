import XCTest
@testable import LuantiKit

/// TOCLIENT_INVENTORY text -> lists, the way the inventory panel reads them.
final class InventoryTests: XCTestCase {
    func testParsesAllListsAndKeepsOnKeepList() {
        let c = Client(name: "t", password: "")
        c.parseInventoryText("""
        List main 4
        Width 0
        Item mcl_core:stone 12
        Empty
        Item mcl_tools:pick_wood 1 200
        Item "mcl_core:dirt"
        EndInventoryList
        List craft 4
        Width 2
        Empty
        Empty
        Empty
        Empty
        EndInventoryList
        EndInventory
        """)
        let main = c.inventory["main"]!
        XCTAssertEqual(main.count, 4)
        XCTAssertEqual(main[0]?.name, "mcl_core:stone"); XCTAssertEqual(main[0]?.count, 12)
        XCTAssertNil(main[1])
        XCTAssertEqual(main[2]?.name, "mcl_tools:pick_wood"); XCTAssertEqual(main[2]?.wear, 200)
        XCTAssertEqual(main[3]?.name, "mcl_core:dirt"); XCTAssertEqual(main[3]?.count, 1)
        XCTAssertEqual(c.inventory["craft"]?.count, 4)
        XCTAssertEqual(c.hotbar[0], "mcl_core:stone")

        // A later packet that only KeepLists main must not wipe it.
        c.parseInventoryText("""
        KeepList main
        List craft 1
        Width 1
        Item mcl_core:cobble 3
        EndInventoryList
        EndInventory
        """)
        XCTAssertEqual(c.inventory["main"]?.count, 4)
        XCTAssertEqual(c.inventory["craft"]?.first??.name, "mcl_core:cobble")
    }
}
