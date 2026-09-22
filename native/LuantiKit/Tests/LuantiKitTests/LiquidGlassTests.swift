import XCTest
import simd
@testable import LuantiKit

/// A water face against a glass pane must NOT be culled: the engine treats
/// glasslike nodes as non-occluding (solidness 0), so water behind a window
/// stays visible. occludesLiquid used to hide a liquid face against any
/// cube-kind neighbour, which swept up glass too.
final class LiquidGlassTests: XCTestCase {
    private let mid = SIMD3(8, 8, 8)

    private func registry() -> NodeRegistry {
        // A glasslike node (drawtype 4) and a water SOURCE (drawtype 2).
        let glass = NodeFixtures.node(name: "t:glass", drawtype: 4, dugSound: "", walkable: false) { w in w.u8(6).u8(0) }
        let water = NodeFixtures.node(name: "t:water", drawtype: 2, dugSound: "", walkable: false,
                                      liquidAlt: ("t:water", "t:water"), liquidRange: 7) { w in w.u8(6).u8(0) }
        let stone = NodeFixtures.node(name: "t:stone", drawtype: 0, dugSound: "") { w in w.u8(6).u8(0) }
        let r = NodeRegistry(); r.parseNodeDef(NodeFixtures.nodedefPayload([(1, glass), (2, water), (3, stone)])); return r
    }
    private func liquidQuads(_ map: WorldMap, _ reg: NodeRegistry) -> Int {
        WorldMesher.build(map, atlas: TextureAtlas(), nodes: reg).liquid.vertices.count / 9 / 4
    }

    func testWaterFaceAgainstGlassIsDrawn() {
        let reg = registry()
        let water = reg.id(for: "t:water")!, glass = reg.id(for: "t:glass")!, stone = reg.id(for: "t:stone")!
        // A single water source shows all six faces (nothing occludes it here).
        let alone = WorldMap(); alone.setNode(mid, param0: water)
        XCTAssertEqual(liquidQuads(alone, reg), 6, "lone water source draws six faces")
        // Water with glass on its +X side keeps that face (see-through window).
        let vsGlass = WorldMap(); vsGlass.setNode(mid, param0: water); vsGlass.setNode(mid &+ SIMD3(1, 0, 0), param0: glass)
        XCTAssertEqual(liquidQuads(vsGlass, reg), 6, "glass does not hide the water face")
        // Water with STONE on its +X side drops that face (solid occludes it).
        let vsStone = WorldMap(); vsStone.setNode(mid, param0: water); vsStone.setNode(mid &+ SIMD3(1, 0, 0), param0: stone)
        XCTAssertEqual(liquidQuads(vsStone, reg), 5, "solid stone hides the buried water face")
    }
}
