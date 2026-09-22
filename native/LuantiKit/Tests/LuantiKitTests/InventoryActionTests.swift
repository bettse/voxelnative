import XCTest
@testable import LuantiKit

/// The InventoryAction strings we send, checked against inventorymanager.cpp's
/// parsers (IMoveAction/IDropAction/ICraftAction). A wrong field order here
/// silently moves the wrong stack or eats an item, so pin the exact format.
final class InventoryActionTests: XCTestCase {
    func testMoveFieldOrder() {
        let s = Client.moveAction(count: 5,
                                  from: Client.InvRef("current_player", "main", 3),
                                  to: Client.InvRef("current_player", "craft", 1))
        // Move <count> <from_inv> <from_list> <from_i> <to_inv> <to_list> <to_i>
        XCTAssertEqual(s, "Move 5 current_player main 3 current_player craft 1")
    }

    func testMoveAcrossInventories() {
        let s = Client.moveAction(count: 0,
                                  from: Client.InvRef("nodemeta:1,-2,3", "main", 0),
                                  to: Client.InvRef("current_player", "main", 8))
        XCTAssertEqual(s, "Move 0 nodemeta:1,-2,3 main 0 current_player main 8", "count 0 = whole stack")
    }

    func testMoveSomewhereZeroCountBecomesWholeStack() {
        // The engine's MoveSomewhere loop runs while count > 0, so 0 would move
        // nothing (unlike Move, where 0 = whole stack). Our "0 = all" maps to a
        // count bigger than any stack; the server clamps it to the slot.
        let s = Client.moveSomewhereAction(count: 0,
            from: Client.InvRef("nodemeta:1,2,3", "main", 0), toLoc: "current_player", toList: "main")
        XCTAssertEqual(s, "MoveSomewhere 9999 nodemeta:1,2,3 main 0 current_player main")
    }

    func testMoveSomewhereHasNoDestIndex() {
        let s = Client.moveSomewhereAction(count: 2,
                                           from: Client.InvRef("current_player", "craft", 3),
                                           toLoc: "current_player", toList: "main")
        // MoveSomewhere <count> <from_inv> <from_list> <from_i> <to_inv> <to_list>
        XCTAssertEqual(s, "MoveSomewhere 2 current_player craft 3 current_player main")
        // 7 tokens: verb + count + from(3) + toLoc + toList. A plain Move would
        // add an 8th (the destination index); MoveSomewhere omits it.
        XCTAssertEqual(s.split(separator: " ").count, 7, "no trailing destination index")
    }

    func testDropFieldOrder() {
        let s = Client.dropAction(count: 7, from: Client.InvRef("current_player", "main", 4))
        XCTAssertEqual(s, "Drop 7 current_player main 4")
    }

    func testCraftFieldOrder() {
        XCTAssertEqual(Client.craftAction(count: 1, craftLoc: "current_player"),
                       "Craft 1 current_player")
        XCTAssertEqual(Client.craftAction(count: 0, craftLoc: "detached:creative"),
                       "Craft 0 detached:creative")
    }
}
