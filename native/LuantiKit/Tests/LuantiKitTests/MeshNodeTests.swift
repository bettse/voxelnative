import XCTest
import simd
@testable import LuantiKit

/// Mesh-drawtype nodes (beds, lanterns, chains): the .obj is authored in
/// node-unit space centred on the origin, so the mesher maps a vertex with
/// p * visual_scale + 0.5 into the node's [g, g+1] cell and rotates the whole
/// model by facedir (content_mapblock rotateMeshBy6dFacedir). Regression guard
/// for the bed/lantern look, mirroring the convention verified against
/// mcl_beds_bed_bottom.obj (bounds x,z in [-0.5, 0.5], y in [-0.5, 0.0625]).
final class MeshNodeTests: XCTestCase {
    // #164: opaque is now (vertices, solid, cutout); tests want one index list.
    private func combined(_ o: (vertices: [Float], solid: [UInt32], cutout: [UInt32])) -> WorldMesher.Mesh { (o.vertices, o.solid + o.cutout) }
    private func meshNode(id: Int, name: String, file: String, vscale: Float = 1) -> NodeRegistry {
        let blob = NodeFixtures.node(name: name, drawtype: 16, dugSound: "", mesh: file, visualScale: vscale) { w in
            w.u8(6).u8(0)   // node_box: version 6, regular (unused for mesh)
        }
        let reg = NodeRegistry()
        reg.parseNodeDef(NodeFixtures.nodedefPayload([(id, blob)]))
        return reg
    }
    /// A single triangle whose corners are the extremes of a bed-shaped model.
    private func bedTri() -> B3DLoader.Mesh {
        B3DLoader.Mesh(positions: [SIMD3(-0.5, -0.5, -0.5), SIMD3(0.5, 0.0625, -0.5), SIMD3(0.5, -0.5, 0.5)],
                       uvs: [.zero, .zero, .zero], indices: [0, 1, 2], textureName: "bed.png",
                       minBounds: SIMD3(-0.5, -0.5, -0.5), maxBounds: SIMD3(0.5, 0.0625, 0.5))
    }
    private func verts(_ m: WorldMesher.Mesh) -> [SIMD3<Float>] {
        stride(from: 0, to: m.vertices.count, by: 9).map { SIMD3(m.vertices[$0], m.vertices[$0+1], m.vertices[$0+2]) }
    }

    func testMeshNodePlacedInItsCell() {
        let reg = meshNode(id: 1, name: "mcl_beds:bed_bottom", file: "mcl_beds_bed_bottom.obj")
        let mid = reg.id(for: "mcl_beds:bed_bottom")!
        let map = WorldMap()
        map.setNode(SIMD3(3, 4, 5), param0: mid)
        let m = combined(WorldMesher.build(map, atlas: TextureAtlas(), nodes: reg, models: [mid: bedTri()]).opaque)
        let vs = verts(m)
        XCTAssertEqual(vs.count, 3)
        // p * 1 + 0.5 + base: x in [3,4], the low bed top at y = 4 + (0.0625+0.5) = 4.5625.
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for p in vs { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        XCTAssertEqual(simd_distance(lo, SIMD3(3, 4, 5)), 0, accuracy: 1e-5)
        XCTAssertEqual(hi.y, 4.5625, accuracy: 1e-5, "the bed is low, not a full cube")
        XCTAssertEqual(hi.x, 4, accuracy: 1e-5)
    }

    func testVisualScaleShrinksTheModel() {
        let reg = meshNode(id: 1, name: "n", file: "m.obj", vscale: 0.5)
        let mid = reg.id(for: "n")!
        let map = WorldMap()
        map.setNode(SIMD3(0, 0, 0), param0: mid)
        let m = combined(WorldMesher.build(map, atlas: TextureAtlas(), nodes: reg, models: [mid: bedTri()]).opaque)
        // With vscale 0.5 the [-0.5,0.5] model spans [0.25, 0.75] around the cell centre.
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for p in verts(m) { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        XCTAssertEqual(lo.x, 0.25, accuracy: 1e-5)
        XCTAssertEqual(hi.x, 0.75, accuracy: 1e-5)
    }

    func testFacedirRotatesTheWholeModel() {
        let reg = meshNode(id: 1, name: "n", file: "m.obj")
        let mid = reg.id(for: "n")!
        // paramType2 defaults to 0 in the fixture, so meshFacedir returns 0
        // regardless of param2. Drive the rotation directly to prove the mesher
        // uses rotateFacedir: facedir 0 vs a manual rotate of the same corner.
        let corner = SIMD3<Float>(0.5, 0.0625, -0.5)
        let rotated = WorldMesher.rotateFacedir(corner, 1)   // XZ by -90 -> (z, y, -x)
        XCTAssertEqual(simd_distance(rotated, SIMD3(-0.5, 0.0625, -0.5)), 0, accuracy: 1e-5)
    }

    func testMissingModelEmitsNothing() {
        // No cube fallback for a mesh node whose .obj hasn't downloaded yet.
        let reg = meshNode(id: 1, name: "n", file: "m.obj")
        let mid = reg.id(for: "n")!
        let map = WorldMap()
        map.setNode(SIMD3(0, 5, 0), param0: mid)
        let m = combined(WorldMesher.build(map, atlas: TextureAtlas(), nodes: reg, models: [:]).opaque)
        XCTAssertEqual(m.vertices.count, 0, "an unloaded mesh node draws nothing, not a cube")
    }
}
