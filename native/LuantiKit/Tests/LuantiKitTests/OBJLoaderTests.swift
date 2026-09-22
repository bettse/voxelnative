import XCTest
import simd
@testable import LuantiKit

/// OBJLoader: the .obj path behind mesh-drawtype nodes (beds, lanterns) and
/// some entity models. Covers polygon fan-triangulation, the v/vt/vn face
/// token forms, 1-based and negative indices, the vt v-flip to a top-left
/// origin, and (v,vt)-pair dedup. Shapes mirror mcl_beds_bed_bottom.obj.
final class OBJLoaderTests: XCTestCase {
    private func load(_ s: String) -> B3DLoader.Mesh? {
        OBJLoader.load(Data(s.utf8))
    }

    func testQuadFaceFanTriangulates() {
        // One quad -> two triangles (6 indices), four unique verts.
        let obj = """
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        f 1 2 3 4
        """
        let m = try! XCTUnwrap(load(obj))
        XCTAssertEqual(m.positions.count, 4)
        XCTAssertEqual(m.indices.count, 6)
        XCTAssertEqual(Array(m.indices), [0, 1, 2, 0, 2, 3])
    }

    func testTexcoordVIsFlipped() {
        let obj = """
        v 0 0 0
        v 1 0 0
        v 1 1 0
        vt 0.25 0.8
        vt 0.5 0.8
        vt 0.5 0.2
        f 1/1 2/2 3/3
        """
        let m = try! XCTUnwrap(load(obj))
        XCTAssertEqual(m.uvs[0].x, 0.25, accuracy: 1e-6)
        XCTAssertEqual(m.uvs[0].y, 0.2, accuracy: 1e-6, "v flipped to a top-left origin (1 - 0.8)")
    }

    func testNegativeIndicesResolveFromTheEnd() {
        // -1 = last position defined so far. Both faces should reference the
        // same three verts.
        let obj = """
        v 0 0 0
        v 1 0 0
        v 0 1 0
        f -3 -2 -1
        """
        let m = try! XCTUnwrap(load(obj))
        XCTAssertEqual(m.positions.count, 3)
        XCTAssertEqual(m.indices.count, 3)
        XCTAssertEqual(m.positions[Int(m.indices[2])], SIMD3(0, 1, 0))
    }

    func testSameVertexUvPairIsDeduped() {
        // Two triangles sharing an edge (verts 2,3): the shared (v/vt) pairs
        // collapse, so 4 unique output verts, not 6.
        let obj = """
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        vt 0 0
        vt 1 0
        vt 1 1
        vt 0 1
        f 1/1 2/2 3/3
        f 1/1 3/3 4/4
        """
        let m = try! XCTUnwrap(load(obj))
        XCTAssertEqual(m.positions.count, 4, "shared (v,vt) pairs reused")
        XCTAssertEqual(m.indices.count, 6)
    }

    func testVNTokenFormIsAccepted() {
        // f v//vn (no texcoord) and f v/vt/vn must both parse.
        let obj = """
        v 0 0 0
        v 2 0 0
        v 0 3 0
        vt 0 0
        vn 0 0 1
        f 1//1 2//1 3//1
        """
        let m = try! XCTUnwrap(load(obj))
        XCTAssertEqual(m.indices.count, 3)
        XCTAssertEqual(m.uvs[0], SIMD2(0, 0), "no vt -> zero uv")
    }

    func testBoundsSpanTheModel() {
        let obj = """
        v -0.5 -0.3125 -0.5
        v 0.5 0.0625 0.5
        v 0.5 0.0625 -0.5
        f 1 2 3
        """
        let m = try! XCTUnwrap(load(obj))
        XCTAssertEqual(m.minBounds, SIMD3(-0.5, -0.3125, -0.5))
        XCTAssertEqual(m.maxBounds, SIMD3(0.5, 0.0625, 0.5))
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(load("# just a comment\no cube\n"))   // no geometry
    }
}
