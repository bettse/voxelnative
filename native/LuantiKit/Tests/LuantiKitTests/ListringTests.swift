import XCTest
@testable import LuantiKit

/// Formspec listring parsing drives desktop-parity shift-click. Shift-
/// clicking a slot moves the stack to the NEXT ring entry after its source list.
final class ListringTests: XCTestCase {
    private let ctx = SIMD3<Int>(1, 2, 3)
    private var node: String { "nodemeta:1,2,3" }

    func testExplicitFurnaceRingRoutesMainToDistr() {
        // The blast furnace ring: shift-clicking from player main must land on the
        // server-side `distr` distributor, which sorts fuel vs ingredient.
        let spec = """
        list[context;src;0,0;1,1;]list[context;fuel;0,1;1,1;]list[context;dst;2,0;1,1;]\
        list[current_player;main;0,4;9,3;]\
        listring[context;dst]listring[current_player;main]\
        listring[context;distr]listring[current_player;main]\
        listring[context;src]listring[current_player;main]\
        listring[context;fuel]listring[current_player;main]
        """
        let ring = Formspec.parseListrings(spec, context: ctx)
        XCTAssertEqual(ring.count, 8)
        // First occurrence of player main is at index 1; its next is context;distr.
        let i = ring.firstIndex { $0.loc == "current_player" && $0.list == "main" }
        XCTAssertEqual(i, 1)
        let next = ring[(i! + 1) % ring.count]
        XCTAssertEqual(next.loc, node)
        XCTAssertEqual(next.list, "distr")
        // The output list `dst` rings to the player.
        let d = ring.firstIndex { $0.list == "dst" }!
        XCTAssertEqual(ring[(d + 1) % ring.count].loc, "current_player")
    }

    func testBareListringConnectsLastTwoLists() {
        // A chest: bare listring[] connects the last two list[] added -> a
        // two-entry ring that cycles chest<->player.
        let spec = "list[context;main;0,0;9,3;]list[current_player;main;0,4;9,3;]listring[]"
        let ring = Formspec.parseListrings(spec, context: ctx)
        XCTAssertEqual(ring.count, 2)
        XCTAssertEqual(ring[0].loc, node); XCTAssertEqual(ring[0].list, "main")
        XCTAssertEqual(ring[1].loc, "current_player"); XCTAssertEqual(ring[1].list, "main")
        // From player main, next wraps to the chest.
        XCTAssertEqual(ring[(1 + 1) % 2].loc, node)
    }

    func testNoListringYieldsEmptyRing() {
        let ring = Formspec.parseListrings("list[current_player;main;0,0;9,3;]", context: ctx)
        XCTAssertTrue(ring.isEmpty)
    }
}
