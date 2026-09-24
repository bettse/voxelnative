import XCTest
import simd
@testable import LuantiKit

/// Stained glass (use_texture_alpha="blend"): the alpha byte parses into
/// the blended flag, and the mesher routes blended cube nodes into the
/// translucent (liquid) stream instead of the opaque one, without occluding
/// their neighbours (you see through the glass).
final class GlassMeshTests: XCTestCase {
    private let mid = SIMD3(8, 8, 8)

    private func registry(_ blobs: [(Int, Data)]) -> NodeRegistry {
        let r = NodeRegistry(); r.parseNodeDef(NodeFixtures.nodedefPayload(blobs)); return r
    }
    private func cube(_ name: String, blend: Bool = false) -> Data {
        NodeFixtures.node(name: name, drawtype: 0, dugSound: "", alphaBlend: blend) { w in w.u8(6).u8(0) }
    }
    private func build(_ map: WorldMap, _ reg: NodeRegistry) -> (opaque: Int, liquid: Int) {
        let m = WorldMesher.build(map, atlas: TextureAtlas(), nodes: reg)
        return (m.opaque.vertices.count / 9 / 4, m.liquid.vertices.count / 9 / 4)
    }

    func testAlphaByteParsesTheBlendedFlag() {
        let reg = registry([(1, cube("t:glass", blend: true)), (2, cube("t:stone"))])
        XCTAssertTrue(reg.isBlended(reg.id(for: "t:glass")!))
        XCTAssertFalse(reg.isBlended(reg.id(for: "t:stone")!), "an opaque node is not blended")
    }

    func testBlendedNodeboxGoesToTheTranslucentStream() {
        // A nether-portal-style node: nodebox (drawtype 12) + use_texture_alpha
        // "blend". Its faces must land in the alpha-blend (liquid) stream, not the
        // cutout/discard pass where the translucent purple vanishes to nothing.
        let portal = NodeFixtures.node(name: "t:portal", drawtype: 12, dugSound: "",
                                       walkable: false, alphaBlend: true) { w in
            w.u8(6).u8(1); w.u16(1)                       // node_box v6, fixed, one box
            NodeFixtures.boxBS(w, SIMD3(-0.5, -0.5, -0.1), SIMD3(0.5, 0.5, 0.1))   // thin slab
        }
        let reg = registry([(1, portal)])
        let id = reg.id(for: "t:portal")!
        XCTAssertTrue(reg.isBlended(id))
        let map = WorldMap(); map.setNode(mid, param0: id)
        let (opaque, liquid) = build(map, reg)
        XCTAssertEqual(opaque, 0, "a blended nodebox emits nothing to the opaque/cutout stream")
        XCTAssertEqual(liquid, 6, "its six box faces render in the blended pass")
    }

    func testGlassGoesToTheTranslucentStreamNotOpaque() {
        let reg = registry([(1, cube("t:glass", blend: true))])
        let map = WorldMap(); map.setNode(mid, param0: reg.id(for: "t:glass")!)
        let (opaque, liquid) = build(map, reg)
        XCTAssertEqual(opaque, 0, "no opaque geometry for glass")
        XCTAssertEqual(liquid, 6, "the six glass faces render in the blended pass")
    }

    func testGlassDoesNotOccludeAnOpaqueNeighbour() {
        // Stone next to glass: the stone keeps all 6 faces (you see it through
        // the glass), and the glass drops only its buried face.
        let reg = registry([(1, cube("t:glass", blend: true)), (2, cube("t:stone"))])
        let map = WorldMap()
        map.setNode(mid, param0: reg.id(for: "t:glass")!)
        map.setNode(mid &+ SIMD3(1, 0, 0), param0: reg.id(for: "t:stone")!)
        let (opaque, liquid) = build(map, reg)
        XCTAssertEqual(opaque, 6, "stone shows its full cube through the glass")
        XCTAssertEqual(liquid, 5, "glass drops the face buried against the stone")
    }

    func testSameGlassSharedFaceIsHidden() {
        // Two of the same glass: the shared interior face is dropped on both, so
        // each contributes 5 faces (matches Luanti's glasslike occlusion).
        let reg = registry([(1, cube("t:glass", blend: true))])
        let g = reg.id(for: "t:glass")!
        let map = WorldMap()
        map.setNode(mid, param0: g)
        map.setNode(mid &+ SIMD3(1, 0, 0), param0: g)
        let (opaque, liquid) = build(map, reg)
        XCTAssertEqual(opaque, 0)
        XCTAssertEqual(liquid, 10, "6+6 minus the two touching interior faces")
    }

    // PLAIN glass (drawtype glasslike, cutout alpha, not blended) is the common
    // window block. It used to be classed like stone and hid the neighbour's
    // face, so a wall behind a window lost its face and read as x-ray.
    private func plainGlass(_ name: String) -> Data {
        NodeFixtures.node(name: name, drawtype: 4, dugSound: "") { w in w.u8(6).u8(0) }
    }

    func testPlainGlassIsNotAnOccluder() {
        let reg = registry([(1, plainGlass("t:glass")), (2, cube("t:stone"))])
        let g = reg.id(for: "t:glass")!, st = reg.id(for: "t:stone")!
        XCTAssertTrue(reg.isGlasslike(g)); XCTAssertFalse(reg.occludes(g))
        XCTAssertTrue(reg.occludes(st))
        let map = WorldMap()
        map.setNode(mid, param0: g)
        map.setNode(mid &+ SIMD3(1, 0, 0), param0: st)
        let (opaque, liquid) = build(map, reg)
        // stone keeps 6 faces (one is seen through the glass); the glass keeps
        // 5 (its face against the stone is buried) -- both in the opaque/cutout stream.
        XCTAssertEqual(opaque, 11)
        XCTAssertEqual(liquid, 0)
    }

    func testPlainGlassCullsTheFaceSharedWithTheSameGlass() {
        let reg = registry([(1, plainGlass("t:glass"))])
        let g = reg.id(for: "t:glass")!
        let map = WorldMap()
        map.setNode(mid, param0: g)
        map.setNode(mid &+ SIMD3(1, 0, 0), param0: g)
        let (opaque, _) = build(map, reg)
        XCTAssertEqual(opaque, 10, "6+6 minus the two touching interior faces")
    }
}
