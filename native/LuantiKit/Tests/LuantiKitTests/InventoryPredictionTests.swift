import XCTest
@testable import LuantiKit

/// Client-side inventory prediction: the pure apply* helpers mirror the server's
/// Move/Drop/MoveSomewhere merge/swap/clamp rules so the panel can update
/// instantly (the server echo reconciles)..
final class InventoryPredictionTests: XCTestCase {
    typealias Stack = Client.ItemStack
    // Most items stack to 64 in VoxeLibre; a couple of overrides to exercise clamp.
    private let sm: (String) -> Int = { $0 == "mcl_core:snowball" ? 16 : 64 }

    private func stack(_ name: String, _ count: Int, _ wear: Int = 0) -> Stack { Stack(name: name, count: count, wear: wear) }

    func testMoveIntoEmpty() {
        var lists: [String: [Client.ItemStack?]] = ["main": [stack("dirt", 10), nil]]
        Client.applyMove(&lists, fromList: "main", fromIdx: 0, toList: "main", toIdx: 1, count: 0, stackMax: sm)
        XCTAssertNil(lists["main"]![0])
        XCTAssertEqual(lists["main"]![1]?.count, 10)
        XCTAssertEqual(lists["main"]![1]?.name, "dirt")
    }

    func testMovePartialIntoEmpty() {
        var lists: [String: [Client.ItemStack?]] = ["main": [stack("dirt", 10), nil]]
        Client.applyMove(&lists, fromList: "main", fromIdx: 0, toList: "main", toIdx: 1, count: 3, stackMax: sm)
        XCTAssertEqual(lists["main"]![0]?.count, 7)
        XCTAssertEqual(lists["main"]![1]?.count, 3)
    }

    func testMergeClampsToStackMax() {
        var lists: [String: [Client.ItemStack?]] = ["main": [stack("dirt", 40), stack("dirt", 50)]]
        // 40 onto 50 (max 64): 14 fit, 26 stay behind.
        Client.applyMove(&lists, fromList: "main", fromIdx: 0, toList: "main", toIdx: 1, count: 0, stackMax: sm)
        XCTAssertEqual(lists["main"]![1]?.count, 64)
        XCTAssertEqual(lists["main"]![0]?.count, 26)
    }

    func testMergeRespectsSmallStackMax() {
        var lists: [String: [Client.ItemStack?]] = ["main": [stack("mcl_core:snowball", 10), stack("mcl_core:snowball", 12)]]
        Client.applyMove(&lists, fromList: "main", fromIdx: 0, toList: "main", toIdx: 1, count: 0, stackMax: sm)
        XCTAssertEqual(lists["main"]![1]?.count, 16)   // clamped to 16
        XCTAssertEqual(lists["main"]![0]?.count, 6)
    }

    func testWholeStackSwapsDifferentItems() {
        var lists: [String: [Client.ItemStack?]] = ["main": [stack("dirt", 10), stack("cobble", 5)]]
        Client.applyMove(&lists, fromList: "main", fromIdx: 0, toList: "main", toIdx: 1, count: 0, stackMax: sm)
        XCTAssertEqual(lists["main"]![0]?.name, "cobble")
        XCTAssertEqual(lists["main"]![0]?.count, 5)
        XCTAssertEqual(lists["main"]![1]?.name, "dirt")
        XCTAssertEqual(lists["main"]![1]?.count, 10)
    }

    func testPartialMoveOntoDifferentItemSwapsWholeStacks() {
        // inventorymanager.cpp allow_swap: nothing fits, so the WHOLE stacks
        // swap even though only 3 were asked for.
        var lists: [String: [Client.ItemStack?]] = ["main": [stack("dirt", 10), stack("cobble", 5)]]
        Client.applyMove(&lists, fromList: "main", fromIdx: 0, toList: "main", toIdx: 1, count: 3, stackMax: sm)
        XCTAssertEqual(lists["main"]![0]?.name, "cobble")
        XCTAssertEqual(lists["main"]![0]?.count, 5)
        XCTAssertEqual(lists["main"]![1]?.name, "dirt")
        XCTAssertEqual(lists["main"]![1]?.count, 10)
    }

    func testMoveKeepsMetaAndMetaBlocksMerge() {
        let named = Client.ItemStack(name: "dirt", count: 4, wear: 0, meta: ["description": "Special"])
        var lists: [String: [Client.ItemStack?]] = ["main": [named, nil, stack("dirt", 10)]]
        // Into an empty slot: the name override rides along.
        Client.applyMove(&lists, fromList: "main", fromIdx: 0, toList: "main", toIdx: 1, count: 2, stackMax: sm)
        XCTAssertEqual(lists["main"]![1]?.customDescription, "Special")
        XCTAssertEqual(lists["main"]![0]?.customDescription, "Special")
        // Onto plain dirt: different metadata, so no merge -- a swap.
        Client.applyMove(&lists, fromList: "main", fromIdx: 1, toList: "main", toIdx: 2, count: 0, stackMax: sm)
        XCTAssertEqual(lists["main"]![2]?.count, 2)
        XCTAssertEqual(lists["main"]![2]?.customDescription, "Special")
        XCTAssertEqual(lists["main"]![1]?.count, 10)
    }

    func testMoveAcrossLists() {
        var lists: [String: [Client.ItemStack?]] = ["main": [stack("dirt", 10)], "craft": [nil]]
        Client.applyMove(&lists, fromList: "main", fromIdx: 0, toList: "craft", toIdx: 0, count: 4, stackMax: sm)
        XCTAssertEqual(lists["main"]![0]?.count, 6)
        XCTAssertEqual(lists["craft"]![0]?.count, 4)
    }

    func testDropRemoves() {
        var lists: [String: [Client.ItemStack?]] = ["main": [stack("dirt", 10)]]
        Client.applyDrop(&lists, fromList: "main", fromIdx: 0, count: 3)
        XCTAssertEqual(lists["main"]![0]?.count, 7)
        Client.applyDrop(&lists, fromList: "main", fromIdx: 0, count: 0)   // whole stack
        XCTAssertNil(lists["main"]![0])
    }

    func testMoveSomewhereFillsThenSpills() {
        // Send 30 dirt somewhere in a list that has a 60-stack (4 space) and 2 empties.
        var lists: [String: [Client.ItemStack?]] = [
            "src": [stack("dirt", 30)],
            "dst": [stack("dirt", 60), nil, nil],
        ]
        Client.applyMoveSomewhere(&lists, fromList: "src", fromIdx: 0, toList: "dst", count: 0, stackMax: sm)
        XCTAssertEqual(lists["dst"]![0]?.count, 64)   // topped up (4)
        XCTAssertEqual(lists["dst"]![1]?.count, 26)   // remaining 26 into the first empty
        XCTAssertNil(lists["src"]![0])                // source drained
    }

    func testPredictParsesMoveString() {
        let c = Client(name: "t", password: "")
        c.debugSetInventory(["main": [stack("dirt", 10), nil]])
        c.predictInventoryAction("Move 0 current_player main 0 current_player main 1")
        XCTAssertNil(c.inventory["main"]![0])
        XCTAssertEqual(c.inventory["main"]![1]?.count, 10)
    }

    func testPredictIgnoresNonPlayerLocations() {
        let c = Client(name: "t", password: "")
        c.debugSetInventory(["main": [stack("dirt", 10)]])
        // A move into a chest (nodemeta) isn't predicted (server echo owns it).
        c.predictInventoryAction("Move 0 current_player main 0 nodemeta:1,2,3 main 0")
        XCTAssertEqual(c.inventory["main"]![0]?.count, 10)   // untouched
    }

    /// A prediction the server never answers is rolled back to the server's
    /// copy 10 s later (client.cpp), and a KeepList carries the server's list,
    /// not the prediction.
    func testUnansweredPredictionRollsBack() {
        let c = Client(name: "t", password: "")
        c.parseInventoryText("List main 2\nItem dirt 10\nEmpty\nEndInventoryList\nEndInventory\n")
        c.sendInventoryAction("Move 0 current_player main 0 current_player main 1")
        XCTAssertNil(c.inventory["main"]?[0] ?? nil, "predicted move applied")
        c.poll(5)
        XCTAssertNil(c.inventory["main"]?[0] ?? nil, "still predicted before 10 s")
        c.poll(6)
        XCTAssertEqual((c.inventory["main"]?[0] ?? nil)?.count, 10, "rolled back to the server copy")
        // KeepList after a fresh prediction: the server's list, not the guess.
        c.sendInventoryAction("Move 0 current_player main 0 current_player main 1")
        c.parseInventoryText("KeepList main\nEndInventory\n")
        XCTAssertEqual((c.inventory["main"]?[0] ?? nil)?.count, 10)
    }
}
