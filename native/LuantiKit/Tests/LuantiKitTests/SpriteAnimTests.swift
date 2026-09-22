import XCTest
@testable import LuantiKit

/// Sprite sheets (#125): spritediv/basepos from ObjectProperties, AO_CMD_SET_SPRITE
/// animation stepping like GenericCAO, and the "^[sheet:" cell texture the
/// billboard draws. Layouts mirror ObjectProperties::serialize and processMessage.
final class SpriteAnimTests: XCTestCase {
    private func addPacket(id: Int) -> Data {
        let initData = PacketWriter()
        initData.u8(1).string16("mcl_experience:orb").u8(0).u16(id)
            .f32(0).f32(0).f32(0).f32(0).f32(0).f32(0).u16(1).u8(0)
        let w = PacketWriter()
        w.u16(0).u16(1).u16(id).u8(0).bytes32(initData.data)
        return w.data
    }
    private func msg(_ id: Int, _ body: PacketWriter) -> Data {
        let w = PacketWriter(); w.u16(id).bytes16(body.data); return w.data
    }
    /// SET_PROPERTIES up to the mesh field, with a sprite visual and a 1 x rows sheet.
    private func props(visual: String, tex: String, rows: Int, base: (Int, Int)) -> PacketWriter {
        let p = PacketWriter()
        p.u8(0).u8(4).u16(20).u8(1).f32(0)
        for _ in 0..<12 { p.f32(0) }
        p.u8(1).string16(visual).f32(0.4).f32(0.4).f32(0.4).u16(1).string16(tex)
        p.s16(1).s16(rows).s16(base.0).s16(base.1).u8(1).u8(1).f32(0).string16("")
        return p
    }
    private func setSprite(_ base: (Int, Int), frames: Int, len: Float) -> PacketWriter {
        PacketWriter().u8(3).s16(base.0).s16(base.1).u16(frames).f32(len).u8(0)
    }

    func testSheetCellFromPropertiesBaseposWraps() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 4))
        ao.handleMessages(msg(4, props(visual: "sprite", tex: "orb.png", rows: 14, base: (1, 15))))
        let e = try! XCTUnwrap(ao.entity(4))
        XCTAssertEqual(e.spriteDiv, SIMD2(1, 14))
        // VoxeLibre's orb asks for column 1 of a 1-column sheet and row 15 of 14:
        // GL repeat wrapped both, so do we.
        XCTAssertEqual(e.spriteCellTexture, "orb.png^[sheet:1x14:0,1")
        XCTAssertTrue(ao.tiles.contains("orb.png^[sheet:1x14:0,1"), "cell offered to the atlas")
    }

    func testPlainTextureIsNotASheet() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 4))
        ao.handleMessages(msg(4, props(visual: "sprite", tex: "arrow.png", rows: 1, base: (0, 0))))
        XCTAssertNil(ao.entity(4)?.spriteCellTexture)
        XCTAssertTrue(ao.tiles.contains("arrow.png"))
    }

    func testSetSpriteAnimatesDownTheColumnAndLoops() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 4))
        ao.handleMessages(msg(4, props(visual: "upright_sprite", tex: "flame.png", rows: 8, base: (0, 0))))
        ao.handleMessages(msg(4, setSprite((0, 0), frames: 8, len: 0.125)))
        XCTAssertEqual(ao.entity(4)?.spriteCellTexture, "flame.png^[sheet:1x8:0,0")
        for f in 0..<8 { XCTAssertTrue(ao.tiles.contains("flame.png^[sheet:1x8:0,\(f)"), "frame \(f) registered") }
        ao.step(0.13)                                            // one frame length passed
        XCTAssertEqual(ao.entity(4)?.spriteFrame, 1)
        for _ in 0..<7 { ao.step(0.125) }                        // ... through the end
        XCTAssertEqual(ao.entity(4)?.spriteFrame, 0, "wraps to the first frame")
    }

    func testSetSpriteRestartsFromItsBasepos() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 4))
        ao.handleMessages(msg(4, props(visual: "sprite", tex: "orb.png", rows: 14, base: (0, 0))))
        ao.handleMessages(msg(4, setSprite((0, 5), frames: 14, len: 0.05)))
        ao.step(0.06)
        XCTAssertEqual(ao.entity(4)?.spriteCellTexture, "orb.png^[sheet:1x14:0,6")
    }
}
