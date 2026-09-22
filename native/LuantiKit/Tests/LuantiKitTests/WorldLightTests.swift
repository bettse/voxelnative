import XCTest
import simd
@testable import LuantiKit

/// Client-side relighting after a node change: a dug cell should inherit its
/// neighbours' light (so a fresh hole isn't black), and a node that doesn't
/// fill its cell (door/plant) should be lit by its neighbours, not its own
/// ~0 param1. Nodes are placed mid-block so no reads spill into unloaded
/// neighbouring blocks (which report full daylight).
final class WorldLightTests: XCTestCase {
    private let c = SIMD3(8, 8, 8)

    /// Set the 6 face neighbours of `c` to a dark solid, then override the one
    /// above with a given day-light level.
    private func makeWorld(aboveDayLight: UInt8) -> WorldMap {
        let w = WorldMap()
        for d in [SIMD3(1,0,0), SIMD3(-1,0,0), SIMD3(0,1,0),
                  SIMD3(0,-1,0), SIMD3(0,0,1), SIMD3(0,0,-1)] {
            w.setNode(c &+ d, param0: 1, param1: 0)   // dark solid all around
        }
        w.setNode(c &+ SIMD3(0,1,0), param0: WorldMap.CONTENT_AIR, param1: aboveDayLight)
        return w
    }

    func testDugCellInheritsBrightestNeighbourMinusOne() {
        let w = makeWorld(aboveDayLight: 0x0F)   // daylight directly above
        w.setNode(c, param0: 1, param1: 0)       // solid, dark
        w.removeNode(c)                          // dig it
        XCTAssertEqual(w.nodeLight(c) & 0x0F, 14, "hole should light from the 15 above, minus one step")
    }

    func testDugCellStaysDarkWithNoLightAround() {
        let w = makeWorld(aboveDayLight: 0)      // nothing lit nearby
        w.setNode(c, param0: 1, param1: 0)
        w.removeNode(c)
        XCTAssertEqual(w.nodeLight(c) & 0x0F, 0, "a cave dig stays dark")
    }

    func testNonCubeNodeLitByNeighbourNotOwnParam1() {
        let w = makeWorld(aboveDayLight: 0x0F)
        w.setNode(c, param0: 5, param1: 0)       // a door leaf: own light 0
        XCTAssertEqual(w.nodeLight(c) & 0x0F, 0, "own light is dark")
        XCTAssertEqual(w.nodeLightLit(c) & 0x0F, 15, "but it's lit by the daylight neighbour")
    }
}
