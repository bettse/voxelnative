import XCTest
import simd
@testable import LuantiKit

/// WorldMesher geometry rules: faces between two cubes are dropped, the edge
/// against an unloaded block stays closed (no peeking into the void), and
/// non-cube drawtypes get their reversed twin quads because the renderer
/// back-face culls the opaque world.
final class WorldMesherTests: XCTestCase {
    private let mid = SIMD3(8, 8, 8)   // well inside block (0,0,0)

    private func registry() -> (NodeRegistry, stone: UInt16, plant: UInt16) {
        let stone = NodeFixtures.node(name: "test:stone", drawtype: 0, dugSound: "") { w in w.u8(6).u8(0) }
        let plant = NodeFixtures.node(name: "test:grass", drawtype: 5, dugSound: "", walkable: false) { w in w.u8(6).u8(0) }
        let reg = NodeRegistry()
        reg.parseNodeDef(NodeFixtures.nodedefPayload([(1, stone), (2, plant)]))
        return (reg, reg.id(for: "test:stone")!, reg.id(for: "test:grass")!)
    }

    private func mesh(_ map: WorldMap, _ reg: NodeRegistry) -> WorldMesher.Mesh {
        do { let o = WorldMesher.build(map, atlas: TextureAtlas(), nodes: reg).opaque; return (o.vertices, o.solid + o.cutout) }
    }
    private func quads(_ m: WorldMesher.Mesh) -> Int { m.vertices.count / 9 / 4 }

    func testLightSourceCubeSkipsFaceShading() {
        // A light_source cube (glowstone) draws all six faces at shade 1.0;
        // a plain cube keeps the engine's directional shades (top 1, sides < 1).
        let lit = NodeFixtures.node(name: "test:glow", drawtype: 0, dugSound: "", lightSource: 14) { w in w.u8(6).u8(0) }
        let plain = NodeFixtures.node(name: "test:stone", drawtype: 0, dugSound: "") { w in w.u8(6).u8(0) }
        let reg = NodeRegistry()
        reg.parseNodeDef(NodeFixtures.nodedefPayload([(1, lit), (2, plain)]))
        func shades(_ name: String) -> [Float] {
            let map = WorldMap(); map.setNode(mid, param0: reg.id(for: name)!)
            let v = WorldMesher.build(map, atlas: TextureAtlas(), nodes: reg).opaque.vertices
            var out: [Float] = []
            for q in stride(from: 0, to: v.count, by: 36) { out.append(v[q + 6]) }   // shade is float 6 of 9
            return out
        }
        XCTAssertEqual(shades("test:glow"), [Float](repeating: 1.0, count: 6), "glowstone faces all unshaded")
        XCTAssertTrue(shades("test:stone").contains { $0 < 0.9 }, "stone keeps directional shading")
    }

    func testLoneCubeHasSixFaces() {
        let (reg, stone, _) = registry()
        let map = WorldMap()
        map.setNode(mid, param0: stone)
        let m = mesh(map, reg)
        XCTAssertEqual(quads(m), 6)
        XCTAssertEqual(m.indices.count, 6 * 6, "one triangle pair per face, no twins for a cube")
    }

    func testSharedFaceBetweenCubesIsDropped() {
        let (reg, stone, _) = registry()
        let map = WorldMap()
        map.setNode(mid, param0: stone)
        map.setNode(mid &+ SIMD3(1, 0, 0), param0: stone)
        XCTAssertEqual(quads(mesh(map, reg)), 10, "12 faces minus the 2 that touch")
    }

    func testFaceAgainstUnloadedBlockStaysClosed() {
        let (reg, stone, _) = registry()
        let map = WorldMap()
        map.setNode(SIMD3(0, 8, 8), param0: stone)   // x-1 lies in a block that was never streamed
        XCTAssertEqual(quads(mesh(map, reg)), 5)
    }

    // Plants are two-sided, but that's the renderer's cull mode on the cutout
    // pass now, not a reversed twin per quad in the index stream.
    func testPlantQuadsHaveNoReversedTwin() {
        let (reg, _, plant) = registry()
        let map = WorldMap()
        map.setNode(mid, param0: plant)
        let m = mesh(map, reg)
        let q = quads(m)
        XCTAssertGreaterThan(q, 0)
        XCTAssertEqual(m.indices.count, q * 6, "one winding per quad")
    }

    // The per-block world render draws each mapblock's buffer on its own,
    // so a subset mesh (only: [bpos]) must return indices LOCAL to that block's
    // vertex array (0-based), never global offsets into a concatenated world.
    func testSubsetMeshHasBlockLocalIndices() {
        let (reg, stone, _) = registry()
        let map = WorldMap()
        map.setNode(SIMD3(8, 8, 8), param0: stone)            // block (0,0,0)
        map.setNode(SIMD3(24, 8, 8), param0: stone)           // block (1,0,0), not adjacent
        for bp in [SIMD3(0, 0, 0), SIMD3(1, 0, 0)] {
            let o = WorldMesher.build(map, atlas: TextureAtlas(), nodes: reg, only: [bp]).opaque
            let verts = o.vertices.count / 9
            XCTAssertEqual(verts, 24, "a lone cube in block \(bp) is 6 faces")
            for idx in o.solid + o.cutout {
                XCTAssertLessThan(Int(idx), verts, "index must be local to this block's vertices")
            }
        }
    }

    func testMeshVerticesLandOnTheNodeCell() {
        let (reg, stone, _) = registry()
        let map = WorldMap()
        map.setNode(mid, param0: stone)
        let m = mesh(map, reg)
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for v in stride(from: 0, to: m.vertices.count, by: 9) {
            let p = SIMD3(m.vertices[v], m.vertices[v + 1], m.vertices[v + 2])
            lo = simd_min(lo, p); hi = simd_max(hi, p)
        }
        XCTAssertEqual(lo, SIMD3(8, 8, 8), "our grid puts node g on [g, g+1]")
        XCTAssertEqual(hi, SIMD3(9, 9, 9))
    }
}
