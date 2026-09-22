import XCTest
import simd
@testable import LuantiKit

/// blockPos was floor(a/16.0); it's now a >> 4 (arithmetic shift) for speed since
/// it's the hottest primitive. Lock the equivalence, especially across the
/// negative boundary where naive integer division would round the wrong way.
final class BlockPosTests: XCTestCase {
    func testShiftMatchesFloorDivideAcrossZero() {
        for a in -80...80 {
            let floorDiv = Int((Double(a) / 16.0).rounded(.down))
            XCTAssertEqual(a >> 4, floorDiv, "a=\(a)")
        }
    }

    func testBlockPosOfKnownNodes() {
        XCTAssertEqual(WorldMap.blockPos(SIMD3(0, 0, 0)), SIMD3(0, 0, 0))
        XCTAssertEqual(WorldMap.blockPos(SIMD3(15, 15, 15)), SIMD3(0, 0, 0))
        XCTAssertEqual(WorldMap.blockPos(SIMD3(16, 16, 16)), SIMD3(1, 1, 1))
        XCTAssertEqual(WorldMap.blockPos(SIMD3(-1, -1, -1)), SIMD3(-1, -1, -1))
        XCTAssertEqual(WorldMap.blockPos(SIMD3(-16, -16, -16)), SIMD3(-1, -1, -1))
        XCTAssertEqual(WorldMap.blockPos(SIMD3(-17, 0, -17)), SIMD3(-2, 0, -2))
    }

    /// The in-block index masks with & 15, so a node and its block coord agree:
    /// blockPos * 16 + (p & 15) reconstructs the node.
    func testBlockAndLocalIndexAgree() {
        for p in [SIMD3(5, -3, 200), SIMD3(-1, -16, -33), SIMD3(16, 31, -48)] {
            let bp = WorldMap.blockPos(p)
            XCTAssertEqual(bp &* 16 &+ SIMD3(p.x & 15, p.y & 15, p.z & 15), p, "p=\(p)")
        }
    }
}
