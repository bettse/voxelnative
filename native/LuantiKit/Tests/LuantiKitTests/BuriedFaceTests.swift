import XCTest
import simd
@testable import LuantiKit

/// Nodebox faces lying flat against another box of the same node are not
/// drawn (they z-fought the covering face in our double-sided pass).
final class BuriedFaceTests: XCTestCase {
    private func box(_ a: [Float]) -> NodeRegistry.Box { NodeRegistry.Box(min: SIMD3(a[0], a[1], a[2]), max: SIMD3(a[3], a[4], a[5])) }

    func testFenceRailEndInsidePostIsBuried() {
        let post = box([-2/16, -0.5, -2/16, 2/16, 0.5, 2/16])
        let rail = box([-1/16, 4/16, -0.5, 1/16, 7/16, -2/16])   // ends at the post's -z face
        let all = [post, rail]
        XCTAssertTrue(WorldMesher.buriedFace(rail, SIMD3(0, 0, 1), among: all, index: 1), "rail end facing into the post")
        XCTAssertFalse(WorldMesher.buriedFace(rail, SIMD3(0, 0, -1), among: all, index: 1), "rail's outer end at the node edge")
        XCTAssertFalse(WorldMesher.buriedFace(rail, SIMD3(0, 1, 0), among: all, index: 1), "rail top")
        XCTAssertFalse(WorldMesher.buriedFace(post, SIMD3(0, 0, -1), among: all, index: 0), "post face is bigger than the rail end")
    }

    func testCactusSpikePlaneIsNotBuried() {
        // A zero-thickness plane wider than the body face: neither buries the other.
        let body = box([-7/16, -0.5, -7/16, 7/16, 0.5, 7/16])
        let spike = box([-0.5, -0.5, -7/16, 0.5, 0.5, -7/16])
        let all = [body, spike]
        XCTAssertFalse(WorldMesher.buriedFace(spike, SIMD3(0, 0, 1), among: all, index: 1))
        XCTAssertFalse(WorldMesher.buriedFace(body, SIMD3(0, 0, -1), among: all, index: 0), "a flat plane covers nothing")
    }

    func testDuplicateFaceKeepsTheFirst() {
        let a = box([-0.5, -0.5, 0, 0.5, 0.5, 0.25]), b = box([-0.5, -0.5, 0, 0.5, 0.5, 0.25])
        XCTAssertFalse(WorldMesher.buriedFace(a, SIMD3(0, 0, -1), among: [a, b], index: 0))
        XCTAssertTrue(WorldMesher.buriedFace(b, SIMD3(0, 0, -1), among: [a, b], index: 1))
    }

    func testStairRiserUnderTreadIsBuried() {
        // Luanti-style stair: a bottom slab plus a half-width upper box resting on it.
        let slab = box([-0.5, -0.5, -0.5, 0.5, 0, 0.5])
        let step = box([-0.5, 0, 0, 0.5, 0.5, 0.5])
        XCTAssertTrue(WorldMesher.buriedFace(step, SIMD3(0, -1, 0), among: [slab, step], index: 1), "step's bottom sits on the slab")
        XCTAssertFalse(WorldMesher.buriedFace(slab, SIMD3(0, 1, 0), among: [slab, step], index: 0), "slab top is only half covered")
    }
}
