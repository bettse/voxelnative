import XCTest
import simd
@testable import LuantiKit

/// End-to-end mesher wiring for the drawtypes added recently (rail, fire,
/// plantlike_rooted): builds a tiny world and checks the real build() path emits
/// the geometry the pure helpers describe. Complements the pure-function tests
/// (RailMeshTests, FireMeshTests, RootedNodeTests) by exercising the neighbour
/// queries and per-drawtype switch in WorldMesher.build.
final class DrawtypeMeshTests: XCTestCase {
    private let mid = SIMD3(8, 8, 8)

    private func mesh(_ map: WorldMap, _ reg: NodeRegistry) -> WorldMesher.Mesh {
        do { let o = WorldMesher.build(map, atlas: TextureAtlas(), nodes: reg).opaque; return (o.vertices, o.solid + o.cutout) }
    }
    private func quads(_ m: WorldMesher.Mesh) -> Int { m.vertices.count / 9 / 4 }

    private func registry(_ blobs: [(Int, Data)]) -> NodeRegistry {
        let r = NodeRegistry(); r.parseNodeDef(NodeFixtures.nodedefPayload(blobs)); return r
    }
    private func node(_ name: String, _ dt: Int, special: [String] = []) -> Data {
        NodeFixtures.node(name: name, drawtype: dt, dugSound: "", walkable: dt == 0 || dt == 17,
                          specialTiles: special) { w in w.u8(6).u8(0) }
    }

    func testLoneRailEmitsOneFlatQuad() {
        let reg = registry([(1, node("t:rail", 11))])
        let map = WorldMap(); map.setNode(mid, param0: reg.id(for: "t:rail")!)
        XCTAssertEqual(quads(mesh(map, reg)), 1, "a rail is a single ground quad")
    }

    func testLoneFireDrawsTheFullFlame() {
        let reg = registry([(1, node("t:fire", 14))])
        let map = WorldMap(); map.setNode(mid, param0: reg.id(for: "t:fire")!)
        XCTAssertEqual(quads(mesh(map, reg)), 6, "isolated fire = 4 sides + 2 centre diagonals")
    }

    func testFireLeansOnlyOnASingleAdjacentWall() {
        // Fire with one solid neighbour (+X) and no floor: exactly one flame, the
        // one facing that wall. The stone contributes its own faces, so subtract a
        // stone-only baseline to isolate the fire's quad count.
        let reg = registry([(1, node("t:fire", 14)), (2, node("t:stone", 0))])
        let stone = reg.id(for: "t:stone")!, fire = reg.id(for: "t:fire")!
        let side = mid &+ SIMD3(1, 0, 0)

        let stoneOnly = WorldMap(); stoneOnly.setNode(side, param0: stone)
        let both = WorldMap(); both.setNode(mid, param0: fire); both.setNode(side, param0: stone)
        // Fire doesn't occlude the stone's faces, so the stone emits the same
        // count either way; the difference is the fire's own quads.
        XCTAssertEqual(quads(mesh(both, reg)) - quads(mesh(stoneOnly, reg)), 1, "one flame, leaning on the wall")
    }

    func testRootedNodeRendersASolidBaseNotAPlant() {
        // With no atlas tile the plant is skipped, but the base cube must still be
        // a real 6-face cube (back-face culled, no reversed twins) -- proof the
        // node is meshed as .rooted, not as a 2-quad plant.
        let reg = registry([(1, node("t:kelp", 17, special: ["kelp.png"]))])
        let map = WorldMap(); map.setNode(mid, param0: reg.id(for: "t:kelp")!)
        let m = mesh(map, reg)
        XCTAssertEqual(quads(m), 6)
        XCTAssertEqual(m.indices.count, 36, "solid base cube: one triangle pair per face, no twins")
    }

    // A thin snow-layer nodebox (full x/z, floor-hugging in y): its bottom face is
    // flush with the node boundary at y=-0.5.
    private func snowLayer() -> Data {
        NodeFixtures.node(name: "t:snow", drawtype: 12, dugSound: "") { w in
            w.u8(6).u8(1)             // NodeBox version 6, type fixed
            w.u16(1)                  // one box
            NodeFixtures.boxBS(w, SIMD3(-0.5, -0.5, -0.5), SIMD3(0.5, -0.4375, 0.5))
        }
    }

    func testSnowLayerOverAirKeepsItsBottomFace() {
        let reg = registry([(1, snowLayer())])
        let map = WorldMap(); map.setNode(mid, param0: reg.id(for: "t:snow")!)
        // Nothing below: all six faces of the thin box are drawn.
        XCTAssertEqual(quads(mesh(map, reg)), 6, "snow over air: bottom face still emitted")
    }

    func testSnowLayerOnLeavesCullsItsBottomFace() {
        // The snow-on-leaves case: a snow layer resting on leaves. The leaves draw a full
        // opaque top face at the same plane as the snow's bottom face; without the
        // boundary cull the two Z-fight. The snow's bottom (-Y) face must be culled.
        let reg = registry([(1, snowLayer()), (2, node("t:leaves", 5))])
        let snow = reg.id(for: "t:snow")!, leaves = reg.id(for: "t:leaves")!
        let below = mid &+ SIMD3(0, -1, 0)

        let leafOnly = WorldMap(); leafOnly.setNode(below, param0: leaves)
        let both = WorldMap(); both.setNode(mid, param0: snow); both.setNode(below, param0: leaves)
        // The leaves emit the same faces either way (snow doesn't occlude them),
        // so the difference is the snow's own quads: 5, not 6 (bottom culled).
        XCTAssertEqual(quads(mesh(both, reg)) - quads(mesh(leafOnly, reg)), 5, "snow-on-leaves: bottom face culled, no Z-fight")
    }
}
