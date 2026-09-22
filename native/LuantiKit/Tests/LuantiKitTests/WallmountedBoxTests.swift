import XCTest
import simd
@testable import LuantiKit

/// A type="wallmounted" node_box has 3 boxes (wall_top, wall_bottom, wall_side);
/// exactly one is drawn per the wallmounted param2, not all three (#212, the
/// button plus-clump). Verifies the selection + that walls rotate about Y only.
final class WallmountedBoxTests: XCTestCase {
    private func box(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> NodeRegistry.Box { NodeRegistry.Box(min: lo, max: hi) }

    func testSelectsOneBoxByParam2() {
        let top = box(SIMD3(-0.1, 0.4, -0.1), SIMD3(0.1, 0.5, 0.1))
        let bottom = box(SIMD3(-0.1, -0.5, -0.1), SIMD3(0.1, -0.4, 0.1))
        let side = box(SIMD3(-0.1, -0.1, 0.3), SIMD3(0.1, 0.1, 0.5))
        let boxes = [top, bottom, side]
        // floor (0) -> wall_bottom, ceiling (1) -> wall_top.
        XCTAssertEqual(WorldMesher.wallmountedBox(boxes, param2: 0).count, 1)
        XCTAssertEqual(WorldMesher.wallmountedBox(boxes, param2: 0)[0].min.y, bottom.min.y, accuracy: 1e-6)
        XCTAssertEqual(WorldMesher.wallmountedBox(boxes, param2: 1)[0].max.y, top.max.y, accuracy: 1e-6)
        // walls (2..5) -> a single side box.
        for p2: UInt8 in [2, 3, 4, 5] {
            XCTAssertEqual(WorldMesher.wallmountedBox(boxes, param2: p2).count, 1, "wall p2=\(p2) is one box")
        }
    }

    func testWallRotationIsYOnly() {
        // A side box spanning y 0..0.2 stays y 0..0.2 through every wall rotation
        // (a pure Y turn moves x/z, never y).
        let side = box(SIMD3(-0.1, 0, 0.3), SIMD3(0.1, 0.2, 0.5))
        let boxes = [side, side, side]
        for p2: UInt8 in [2, 3, 4, 5] {
            let r = WorldMesher.wallmountedBox(boxes, param2: p2)[0]
            XCTAssertEqual(r.min.y, 0, accuracy: 1e-6, "p2=\(p2) y-min preserved")
            XCTAssertEqual(r.max.y, 0.2, accuracy: 1e-6, "p2=\(p2) y-max preserved")
        }
        // The engine's transformNodeBox: x- (3) is the unrotated wall_side,
        // x+ (2) is turned 180, so the same box lands at -z.
        let r3 = WorldMesher.wallmountedBox(boxes, param2: 3)[0]
        XCTAssertEqual(r3.min.z, 0.3, accuracy: 1e-6)
        XCTAssertEqual(r3.max.z, 0.5, accuracy: 1e-6)
        let r2 = WorldMesher.wallmountedBox(boxes, param2: 2)[0]
        XCTAssertEqual(r2.min.z, -0.5, accuracy: 1e-6)
        XCTAssertEqual(r2.max.z, -0.3, accuracy: 1e-6)
    }
}
