import XCTest
@testable import LuantiKit

/// VoxeLibre XP via HUD elements (#107): mcl_experience adds an "image" bar
/// (fill arrives later as a ^[lowpart:N: texture via HUDCHANGE) and a "text"
/// level element in XP green. Wire layouts mirror Client::handleCommand_HudAdd
/// / HudChange.
final class XpHudTests: XCTestCase {

    /// TOCLIENT_HUDADD: u32 id, u8 type, v2f pos, string16 name, v2f scale,
    /// string16 text, u32 number, u32 item, u32 dir, v2f align, v2f offset,
    /// v3f world_pos.
    private func hudAdd(id: Int, type: Int, text: String = "", number: Int = 0) -> Data {
        let w = PacketWriter()
        w.u32(id).u8(type).f32(0.5).f32(1).string16("").f32(1).f32(1)
        w.string16(text).u32(number).u32(0).u32(0)
        w.f32(0).f32(0).f32(0).f32(0).f32(0).f32(0).f32(0)
        return w.data
    }

    /// TOCLIENT_HUDCHANGE with stat 3 (text): u32 id, u8 stat, string16.
    private func hudText(id: Int, _ text: String) -> Data {
        PacketWriter().u32(id).u8(3).string16(text).data
    }

    private let barTex = "(mcl_experience_bar_background.png^[lowpart:42:mcl_experience_bar.png)^[resize:40x1456^[transformR270"

    func testLowpartParsesOnlyTheXpBarTexture() {
        XCTAssertEqual(Client.xpLowpart(barTex), 42)
        XCTAssertEqual(Client.xpLowpart("(mcl_experience_bar_background.png^[lowpart:100:mcl_experience_bar.png)"), 100)
        XCTAssertNil(Client.xpLowpart("some_other.png^[lowpart:42:thing.png"))   // not the XP bar
        XCTAssertNil(Client.xpLowpart("mcl_experience_bar.png"))                   // no lowpart yet
    }

    func testBarFillAndLevelFlowThroughHudPackets() {
        let c = Client(name: "t", password: "")
        var events: [(Int, Float)] = []
        c.onXp = { events.append(($0, $1)) }

        c.handleHudAdd(hudAdd(id: 10, type: 0))                         // the bar: image, no text yet
        c.handleHudAdd(hudAdd(id: 11, type: 1, text: "", number: 0x80FF20))   // the level, XP green
        XCTAssertEqual(c.xpLevel, 0)
        XCTAssertEqual(c.xpFraction, 0, accuracy: 1e-6)

        c.handleHudChange(hudText(id: 10, barTex))
        XCTAssertEqual(c.xpFraction, 0.42, accuracy: 1e-6)

        c.handleHudChange(hudText(id: 11, "7"))
        XCTAssertEqual(c.xpLevel, 7)

        c.handleHudChange(hudText(id: 11, ""))                          // back to level 0
        XCTAssertEqual(c.xpLevel, 0)
        XCTAssertEqual(events.last?.0, 0)
        XCTAssertEqual(events.last?.1 ?? -1, 0.42, accuracy: 1e-6)
    }

    func testUnrelatedTextElementsAreIgnored() {
        let c = Client(name: "t", password: "")
        c.handleHudAdd(hudAdd(id: 5, type: 1, text: "hello", number: 0xFFFFFF))   // white text, not XP
        c.handleHudAdd(hudAdd(id: 6, type: 0))
        c.handleHudChange(hudText(id: 6, "other.png^[lowpart:50:x.png"))
        c.handleHudChange(hudText(id: 5, "9"))
        XCTAssertEqual(c.xpLevel, 0)
        XCTAssertEqual(c.xpFraction, 0, accuracy: 1e-6)
    }

    func testStatbarsStillWork() {
        // The XP branch must not swallow statbar text changes (hunger icon swap).
        let c = Client(name: "t", password: "")
        var hunger = -1
        c.onHunger = { hunger = $0 }
        c.handleHudAdd(hudAdd(id: 2, type: 2, text: "hbhunger_icon.png", number: 14))
        XCTAssertEqual(hunger, 14)
        c.handleHudChange(PacketWriter().u32(2).u8(4).u32(9).data)    // stat 4 = number
        XCTAssertEqual(hunger, 9)
    }

    // hudGeneration must bump on every hudElements mutation: the renderer caches
    // its sorted view keyed on it (#249), so a missed bump would leave the HUD
    // stale. Guards against a future mutation path forgetting to increment.
    func testHudGenerationBumpsOnEveryMutation() {
        let c = Client(name: "t", password: "")
        let g0 = c.hudGeneration
        c.handleHudAdd(hudAdd(id: 20, type: 1, text: "hi", number: 0xFFFFFF))
        let g1 = c.hudGeneration
        XCTAssertGreaterThan(g1, g0, "HUDADD must bump the generation")

        c.handleHudChange(hudText(id: 20, "there"))   // modify an existing element
        let g2 = c.hudGeneration
        XCTAssertGreaterThan(g2, g1, "HUDCHANGE on a live element must bump")

        c.handleHudChange(hudText(id: 999, "nope"))   // unknown id: no element, no bump
        XCTAssertEqual(c.hudGeneration, g2, "a change to an absent element must not bump")

        c.handleHudRm(PacketWriter().u32(20).data)
        XCTAssertGreaterThan(c.hudGeneration, g2, "HUDRM must bump")
    }
}
