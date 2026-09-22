import XCTest
import simd
@testable import LuantiKit

/// Small pure helpers that the mesher / per-block remesh / texture pipeline
/// depend on.
final class HelpersTests: XCTestCase {
    // blockPos must floor toward negative infinity (not truncate), or the
    // per-block mesh cache keys a node into the wrong 16-cube near x/z < 0.
    func testBlockPosFloors() {
        XCTAssertEqual(WorldMap.blockPos(SIMD3(0, 0, 0)), SIMD3(0, 0, 0))
        XCTAssertEqual(WorldMap.blockPos(SIMD3(15, 15, 15)), SIMD3(0, 0, 0))
        XCTAssertEqual(WorldMap.blockPos(SIMD3(16, 0, 0)), SIMD3(1, 0, 0))
        XCTAssertEqual(WorldMap.blockPos(SIMD3(-1, -1, -1)), SIMD3(-1, -1, -1))
        XCTAssertEqual(WorldMap.blockPos(SIMD3(-16, 0, 0)), SIMD3(-1, 0, 0))
        XCTAssertEqual(WorldMap.blockPos(SIMD3(-17, 0, 0)), SIMD3(-2, 0, 0))
    }

    func testNodeIndexRange() {
        XCTAssertEqual(WorldMap.index(0, 0, 0), 0)
        XCTAssertEqual(WorldMap.index(15, 15, 15), 4095)   // last cell in a 16^3 block
        // Distinct cells map to distinct indices.
        XCTAssertNotEqual(WorldMap.index(1, 0, 0), WorldMap.index(0, 1, 0))
    }

    // imageNames extracts every .png referenced by a tile modifier string, so the
    // media layer downloads a door's base texture even when it carries ^transforms.
    func testImageNamesFromModifiers() {
        XCTAssertEqual(NodeRegistry.imageNames("grass.png"), ["grass.png"])
        XCTAssertEqual(NodeRegistry.imageNames("a.png^[transformFX"), ["a.png"])
        XCTAssertEqual(NodeRegistry.imageNames("(a.png^b.png)^[colorize:#ff0000:128"), ["a.png", "b.png"])
        XCTAssertEqual(NodeRegistry.imageNames("blank.png^mcl_noise.png"), ["blank.png", "mcl_noise.png"])
        XCTAssertTrue(NodeRegistry.imageNames("[combine:16x16").isEmpty)   // no real file
    }

    func testParseHexColor() {
        XCTAssertEqual(TextureAtlas.parseHexColor("#ff8000")!, [255, 128, 0])
        XCTAssertEqual(TextureAtlas.parseHexColor("00ff00")!, [0, 255, 0])
        XCTAssertNil(TextureAtlas.parseHexColor("xyz"))
    }
}

extension HelpersTests {
    func testStripEscapesRemovesTranslationAndColor() {
        // \x1b(T@domain)Dirt\x1bE  ->  Dirt
        let s = "\u{1b}(T@mcl_core)Dirt\u{1b}E"
        XCTAssertEqual(ItemRegistry.stripEscapes(s), "Dirt")
        // color escape then text
        let c = "\u{1b}(c@#ff0000)Red Sand\u{1b}(c@#ffffff)"
        XCTAssertEqual(ItemRegistry.stripEscapes(c), "Red Sand")
        // plain text is untouched
        XCTAssertEqual(ItemRegistry.stripEscapes("Cobblestone"), "Cobblestone")
    }
}
