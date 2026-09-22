import XCTest
@testable import LuantiKit

/// Generic HUD element records (#103): HUDADD captures every field, HUDCHANGE
/// updates them with the right value type per stat, HUDRM drops them. Wire
/// layouts mirror Client::handleCommand_HudAdd / HudChange (proto >= 52).
final class HudElementTests: XCTestCase {

    private func hudAdd(id: Int, type: Int, pos: SIMD2<Float>, scale: SIMD2<Float> = SIMD2(1, 1),
                        text: String = "", number: Int = 0, align: SIMD2<Float> = .zero,
                        offset: SIMD2<Float> = .zero, world: SIMD3<Float> = .zero,
                        size: SIMD2<Float> = .zero, zIndex: Int? = nil) -> Data {
        let w = PacketWriter()
        w.u32(id).u8(type).f32(pos.x).f32(pos.y).string16("n").f32(scale.x).f32(scale.y)
        w.string16(text).u32(number).u32(0).u32(0)
        w.f32(align.x).f32(align.y).f32(offset.x).f32(offset.y)
        w.f32(world.x).f32(world.y).f32(world.z)
        w.f32(size.x).f32(size.y)                 // v2f size at proto >= 52
        if let z = zIndex { w.s16(z) }            // optional tail
        return w.data
    }

    private func client() -> Client {
        let c = Client(name: "t", password: "")
        c.protoVer = 52
        return c
    }

    func testHudAddCapturesLayout() {
        let c = client()
        c.handleHudAdd(hudAdd(id: 5, type: 0, pos: SIMD2(0.5, 0), scale: SIMD2(0.375, 0.375),
                              text: "mcl_bossbars.png", align: SIMD2(0, 1), offset: SIMD2(0, 65), zIndex: -400))
        let e = try! XCTUnwrap(c.hudElements[5])
        XCTAssertEqual(e.type, 0)
        XCTAssertEqual(e.pos, SIMD2(0.5, 0))
        XCTAssertEqual(e.scale, SIMD2(0.375, 0.375))
        XCTAssertEqual(e.text, "mcl_bossbars.png")
        XCTAssertEqual(e.align, SIMD2(0, 1))
        XCTAssertEqual(e.offset, SIMD2(0, 65))
        XCTAssertEqual(e.zIndex, -400)
    }

    func testHudChangeUpdatesEachStatWithItsType() {
        let c = client()
        c.handleHudAdd(hudAdd(id: 7, type: 1, pos: .zero, text: "old", number: 1))
        func change(_ stat: Int, _ body: (PacketWriter) -> Void) {
            let w = PacketWriter().u32(7).u8(stat); body(w); c.handleHudChange(w.data)
        }
        change(0) { $0.f32(0.25).f32(0.75) }                     // pos
        change(8) { $0.f32(-52).f32(3) }                         // offset
        change(3) { $0.string16("new") }                         // text
        change(4) { $0.u32(0xFF55FF) }                           // number
        change(9) { $0.f32(1).f32(2).f32(3) }                    // world_pos
        change(11) { $0.u32((-5) & 0xFFFF_FFFF) }                // z_index, negative on the wire
        change(10) { $0.f32(50).f32(15) }                        // size (v2f at proto 52)
        let e = try! XCTUnwrap(c.hudElements[7])
        XCTAssertEqual(e.pos, SIMD2(0.25, 0.75))
        XCTAssertEqual(e.offset, SIMD2(-52, 3))
        XCTAssertEqual(e.text, "new")
        XCTAssertEqual(e.number, 0xFF55FF)
        XCTAssertEqual(e.worldPos, SIMD3(1, 2, 3))
        XCTAssertEqual(e.zIndex, -5)
        XCTAssertEqual(e.size, SIMD2(50, 15))
    }

    func testHudRmDropsTheRecord() {
        let c = client()
        c.handleHudAdd(hudAdd(id: 3, type: 4, pos: .zero, world: SIMD3(10, 20, 30)))
        XCTAssertNotNil(c.hudElements[3])
        c.handleHudRm(PacketWriter().u32(3).data)
        XCTAssertNil(c.hudElements[3])
    }

    func testChangeForUnknownIdIsIgnored() {
        let c = client()
        c.handleHudChange(PacketWriter().u32(99).u8(3).string16("x").data)
        XCTAssertNil(c.hudElements[99])
    }

    func testXpIdsAreExposedForTheGenericPathToSkip() {
        let c = client()
        c.handleHudAdd(hudAdd(id: 11, type: 1, pos: SIMD2(0.5, 1), number: 0x80FF20))   // level element
        XCTAssertEqual(c.xpHudIds, [11])
    }
}
