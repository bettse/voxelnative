import XCTest
import simd
@testable import LuantiKit

/// The bed (mcl_beds) is a mesh-drawtype node whose model is authored low
/// (mattress top ~0.56 of a node, legs to the floor), NOT a full cube. This
/// loads the REAL mcl_beds_bed_bottom.obj through OBJLoader and the mesher and
/// checks it renders as that low box, and that two adjacent halves sit flush at
/// the same height (the foot/head "flat halves" concern, #131). The synthetic
/// MeshNodeTests cover the transform math; this guards the real asset.
final class BedMeshTests: XCTestCase {
    // #164: opaque is now (vertices, solid, cutout); tests want one index list.
    private func combined(_ o: (vertices: [Float], solid: [UInt32], cutout: [UInt32])) -> WorldMesher.Mesh { (o.vertices, o.solid + o.cutout) }
    private func bedMesh() throws -> B3DLoader.Mesh {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "mcl_beds_bed_bottom",
                                                  withExtension: "obj", subdirectory: "Fixtures"))
        return try XCTUnwrap(OBJLoader.load(try Data(contentsOf: url)))
    }

    private func bedReg(id: Int) -> NodeRegistry {
        // drawtype 16 = mesh; node_box regular (unused for mesh).
        let blob = NodeFixtures.node(name: "mcl_beds:bed_red_bottom", drawtype: 16,
                                     dugSound: "", mesh: "mcl_beds_bed_bottom.obj") { w in w.u8(6).u8(0) }
        let reg = NodeRegistry()
        reg.parseNodeDef(NodeFixtures.nodedefPayload([(id, blob)]))
        return reg
    }

    private func bounds(_ m: WorldMesher.Mesh) -> (lo: SIMD3<Float>, hi: SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for i in stride(from: 0, to: m.vertices.count, by: 9) {
            let p = SIMD3(m.vertices[i], m.vertices[i + 1], m.vertices[i + 2])
            lo = simd_min(lo, p); hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    func testRealBedObjIsLow() throws {
        let m = try bedMesh()
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for p in m.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        // Authored in node-unit space: full footprint, low profile.
        XCTAssertEqual(lo.x, -0.5, accuracy: 1e-4); XCTAssertEqual(hi.x, 0.5, accuracy: 1e-4)
        XCTAssertEqual(lo.z, -0.5, accuracy: 1e-4); XCTAssertEqual(hi.z, 0.5, accuracy: 1e-4)
        XCTAssertEqual(lo.y, -0.5, accuracy: 1e-4)
        XCTAssertEqual(hi.y, 0.0625, accuracy: 1e-4, "mattress top well below the node top")
    }

    func testMeshedBedIsAFlatLowBoxNotACube() throws {
        let reg = bedReg(id: 1)
        let mid = reg.id(for: "mcl_beds:bed_red_bottom")!
        let map = WorldMap()
        map.setNode(SIMD3(2, 7, 3), param0: mid)
        let mesh = combined(WorldMesher.build(map, atlas: TextureAtlas(), nodes: reg, models: [mid: try bedMesh()]).opaque)
        let b = bounds(mesh)
        // p * 1 + 0.5 + base: footprint fills [2,3]x[3,4], top at 7 + 0.5625.
        XCTAssertEqual(b.lo.y, 7.0, accuracy: 1e-4)
        XCTAssertEqual(b.hi.y, 7.5625, accuracy: 1e-4, "the bed is a low box, not a full 1.0 cube")
        XCTAssertLessThan(b.hi.y - b.lo.y, 0.6, "bed height stays under ~0.56 of a node")
    }

    func testBedSelectionBoxIsLowNotAFullCube() {
        // The bed is a mesh node with a fixed, low selection_box (top at 0.06).
        // The pointed-node highlight outlines selectionBoxes(id); if that came
        // back nil the outline would fall back to a full cube and read as a tall
        // box around the low bed. Prove the low box survives the nodedef parse.
        let blob = NodeFixtures.node(name: "mcl_beds:bed_red_bottom", drawtype: 16, dugSound: "",
                                     mesh: "mcl_beds_bed_bottom.obj",
                                     selectionBox: { w in
            w.u8(6).u8(1)                       // NodeBox version 6, type 1 = fixed
            w.u16(1)                            // one box
            NodeFixtures.boxBS(w, SIMD3(-0.5, -0.5, -0.5), SIMD3(0.5, 0.06, 0.5))
        }) { w in w.u8(6).u8(0) }               // node_box: regular
        let reg = NodeRegistry()
        reg.parseNodeDef(NodeFixtures.nodedefPayload([(1, blob)]))
        let mid = reg.id(for: "mcl_beds:bed_red_bottom")!
        let boxes = reg.selectionBoxes(mid)
        XCTAssertEqual(boxes?.count, 1, "the low selection_box is parsed, not dropped")
        XCTAssertEqual(boxes?.first?.max.y ?? 1, 0.06, accuracy: 1e-3, "highlight box top stays low")
        XCTAssertEqual(boxes?.first?.min.y ?? 0, -0.5, accuracy: 1e-3)
    }

    func testTwoHalvesSitFlushAtTheSameHeight() throws {
        // Foot and head are adjacent nodes; both meshes are authored the same
        // low height, so the pair reads as one continuous flat bed (no step).
        let reg = bedReg(id: 1)
        let mid = reg.id(for: "mcl_beds:bed_red_bottom")!
        let map = WorldMap()
        map.setNode(SIMD3(0, 0, 0), param0: mid)
        map.setNode(SIMD3(0, 0, 1), param0: mid)   // the abutting half
        let mesh = combined(WorldMesher.build(map, atlas: TextureAtlas(), nodes: reg, models: [mid: try bedMesh()]).opaque)
        let b = bounds(mesh)
        XCTAssertEqual(b.lo.z, 0.0, accuracy: 1e-4)
        XCTAssertEqual(b.hi.z, 2.0, accuracy: 1e-4, "two node footprints span z [0,2] with no gap")
        XCTAssertEqual(b.hi.y, 0.5625, accuracy: 1e-4, "both halves top out at the same low height")
    }
}
