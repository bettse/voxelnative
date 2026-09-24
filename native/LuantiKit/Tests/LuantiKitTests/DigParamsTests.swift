import XCTest
@testable import LuantiKit

/// DigParams.digTime is Luanti's getDigParams (tool.cpp) minus wear: how long a
/// tool takes to break a node from the node's groups and the tool's groupcaps.
/// This is the gameplay rule behind the hold-to-dig timer, so pin its branches.
final class DigParamsTests: XCTestCase {
    private func caps(_ g: [String: ItemRegistry.GroupCap]) -> ItemRegistry.ToolCaps {
        ItemRegistry.ToolCaps(fullPunchInterval: 1, maxDropLevel: 0, groupCaps: g)
    }

    func testDigImmediateInstantAndFixedWithoutATool() {
        // Flowers/torches: dig_immediate 3 = instant, 2 = a fixed 0.5s, bare hand.
        XCTAssertEqual(DigParams.digTime(groups: ["dig_immediate": 3], caps: nil), 0)
        XCTAssertEqual(DigParams.digTime(groups: ["dig_immediate": 2], caps: nil), 0.5)
    }

    func testUndiggableWithoutMatchingCapsIsNil() {
        // Bare hand on stone (cracky) with no tool: can't dig -> nil.
        XCTAssertNil(DigParams.digTime(groups: ["cracky": 3], caps: nil))
        // A tool that shares no group with the node also can't dig it.
        let pick = caps(["cracky": .init(uses: 100, maxLevel: 1, times: [3: 1.2])])
        XCTAssertNil(DigParams.digTime(groups: ["crumbly": 3], caps: pick))
    }

    /// game.cpp handleDigging: the wielded tool first, and when its caps say
    /// "not diggable" the HAND is tried. VoxeLibre tools carry one dig group
    /// each (a pickaxe only pickaxey), so a pickaxe on dirt (handy+shovely)
    /// must come back nil here and the caller falls through to the hand.
    func testVoxeLibrePickaxeOnDirtIsNilAndHandDigsIt() throws {
        let pick = caps(["pickaxey": .init(uses: 100, maxLevel: 3, times: [1: 1.0])])
        let hand = caps(["handy": .init(uses: 0, maxLevel: 1, times: [1: 0.75]), "shovely": .init(uses: 0, maxLevel: 1, times: [1: 0.75])])
        let dirt = ["handy": 1, "shovely": 1]
        XCTAssertNil(DigParams.params(groups: dirt, caps: pick))
        let r = try XCTUnwrap(DigParams.params(groups: dirt, caps: hand))
        XCTAssertEqual(r.time, 0.75, accuracy: 1e-6)
        XCTAssertTrue(r.group == "handy" || r.group == "shovely", "the winning group names the __group dig sound")
    }

    func testMatchingGroupReturnsItsRatingTime() throws {
        // Node cracky=2, tool times[2]=1.0, equal level: straight lookup.
        let pick = caps(["cracky": .init(uses: 100, maxLevel: 2, times: [1: 2.0, 2: 1.0, 3: 0.5])])
        XCTAssertEqual(try XCTUnwrap(DigParams.digTime(groups: ["cracky": 2, "level": 2], caps: pick)), 1.0, accuracy: 1e-6)
    }

    func testHigherToolLevelSpeedsItUp() throws {
        // levelDiff > 1 divides the time (a stronger tool on a weak node).
        let pick = caps(["cracky": .init(uses: 100, maxLevel: 2, times: [2: 1.0])])
        // level 0 -> levelDiff 2 -> 1.0 / 2 = 0.5
        XCTAssertEqual(try XCTUnwrap(DigParams.digTime(groups: ["cracky": 2], caps: pick)), 0.5, accuracy: 1e-6)
        // level 1 -> levelDiff 1 (not > 1) -> unchanged 1.0
        XCTAssertEqual(try XCTUnwrap(DigParams.digTime(groups: ["cracky": 2, "level": 1], caps: pick)), 1.0, accuracy: 1e-6)
    }

    func testNodeLevelAboveToolMaxLevelIsNil() {
        // Node level 3 above the tool's maxLevel 2: that group is skipped -> nil.
        let pick = caps(["cracky": .init(uses: 100, maxLevel: 2, times: [1: 1.0])])
        XCTAssertNil(DigParams.digTime(groups: ["cracky": 1, "level": 3], caps: pick))
    }

    func testBestTimeAcrossGroups() throws {
        // A node in two dig groups takes the faster of the tool's matching times.
        let tool = caps([
            "cracky":  .init(uses: 100, maxLevel: 3, times: [2: 1.5]),
            "crumbly": .init(uses: 100, maxLevel: 3, times: [2: 0.4]),
        ])
        // level 2 (levelDiff 1, no speed-up division) isolates the min-time pick.
        XCTAssertEqual(try XCTUnwrap(DigParams.digTime(groups: ["cracky": 2, "crumbly": 2, "level": 2], caps: tool)), 0.4, accuracy: 1e-6)
    }
}
