import XCTest
@testable import LuantiKit

/// plantlike_rooted (drawtype 17: kelp, coral, sea pickle, seagrass) renders as a
/// solid base cube plus a plant grown from special_tiles[0]. The parser must
/// capture that special tile and mark the node .rooted, distinct from a plain
/// plantlike (drawtype 9), which has no special tile.
final class RootedNodeTests: XCTestCase {
    private func reg(_ blobs: [(Int, Data)]) -> NodeRegistry {
        let r = NodeRegistry()
        r.parseNodeDef(NodeFixtures.nodedefPayload(blobs))
        return r
    }

    func testRootedNodeCapturesSpecialTileAndKind() {
        let kelp = NodeFixtures.node(name: "mcl_ocean:kelp", drawtype: 17, dugSound: "",
                                     specialTiles: ["mcl_ocean_kelp_plant.png"]) { w in w.u8(6).u8(0) }
        let r = reg([(1, kelp)])
        XCTAssertEqual(r.kind(1), .rooted)
        XCTAssertEqual(r.specialTile(1), "mcl_ocean_kelp_plant.png")
        XCTAssertEqual(r.specialTilesSnapshot(), ["mcl_ocean_kelp_plant.png"])
    }

    func testPlainPlantlikeStaysPlantWithNoSpecialTile() {
        // drawtype 9 must not be swept into .rooted or grow a special tile.
        let grass = NodeFixtures.node(name: "mcl_flowers:tallgrass", drawtype: 9, dugSound: "") { w in w.u8(6).u8(0) }
        let r = reg([(2, grass)])
        XCTAssertEqual(r.kind(2), .plant)
        XCTAssertNil(r.specialTile(2))
        XCTAssertTrue(r.specialTilesSnapshot().isEmpty)
    }

    func testRootedWithoutSpecialTileHasNilSpecial() {
        // A malformed rooted node (no special tile) parses as .rooted but records
        // no plant tile, so the mesher just draws the base cube (no crash).
        let bare = NodeFixtures.node(name: "x:rooted_bare", drawtype: 17, dugSound: "") { w in w.u8(6).u8(0) }
        let r = reg([(3, bare)])
        XCTAssertEqual(r.kind(3), .rooted)
        XCTAssertNil(r.specialTile(3))
    }

    func testSpecialTilesSnapshotGathersEveryRootedPlant() {
        let kelp = NodeFixtures.node(name: "a", drawtype: 17, dugSound: "", specialTiles: ["kelp.png"]) { w in w.u8(6).u8(0) }
        let coral = NodeFixtures.node(name: "b", drawtype: 17, dugSound: "", specialTiles: ["coral.png"]) { w in w.u8(6).u8(0) }
        let r = reg([(1, kelp), (2, coral)])
        XCTAssertEqual(Set(r.specialTilesSnapshot()), ["kelp.png", "coral.png"])
    }

    // MARK: - leveled plant height (kelp grows tall)

    private func topY(_ quads: [[SIMD3<Float>]]) -> Float { quads.flatMap { $0.map(\.y) }.max() ?? 0 }
    private func botY(_ quads: [[SIMD3<Float>]]) -> Float { quads.flatMap { $0.map(\.y) }.min() ?? 0 }

    func testHeightOneMatchesTheSingleSegmentPlant() {
        let q = WorldMesher.plantQuadsTall(1.0)
        XCTAssertEqual(q.count, 2)
        XCTAssertEqual(botY(q), 0, accuracy: 1e-6)
        XCTAssertEqual(topY(q), 1, accuracy: 1e-6)
    }

    func testLeveledKelpStretchesToParam2Over16() {
        // A kelp with param2 = 48 (leveled) is 3 nodes tall; the plant rises from
        // the floor to y=3 while the base stays at y=0.
        let q = WorldMesher.plantQuadsTall(48.0 / 16.0)
        XCTAssertEqual(botY(q), 0, accuracy: 1e-6)
        XCTAssertEqual(topY(q), 3, accuracy: 1e-6)
    }
}
