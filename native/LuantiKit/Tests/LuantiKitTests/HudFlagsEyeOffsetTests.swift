import XCTest
@testable import LuantiKit

/// TOCLIENT_HUD_SET_FLAGS masks only the named bits; TOCLIENT_EYE_OFFSET is
/// BS units on the wire (#290).
final class HudFlagsEyeOffsetTests: XCTestCase {
    func testHudFlagsHonourMask() {
        let c = Client(name: "t", password: "")
        var seen: UInt32 = 0
        c.onHudFlags = { seen = $0 }
        // mcl_shields: hud_set_flags({wielditem = false}) -> flags 0, mask 8.
        c.handleHudSetFlags(PacketWriter().u32(0).u32(8).data)
        XCTAssertEqual(c.hudFlags & 8, 0)
        XCTAssertEqual(c.hudFlags & 1, 1, "hotbar bit untouched by a wielditem-only mask")
        XCTAssertEqual(seen, c.hudFlags)
        c.handleHudSetFlags(PacketWriter().u32(8).u32(8).data)
        XCTAssertEqual(c.hudFlags & 8, 8)
    }

    func testEyeOffsetIsBSUnits() {
        let c = Client(name: "t", password: "")
        var got = SIMD3<Float>(repeating: 99)
        c.onEyeOffset = { got = $0 }
        // mcl_beds: set_eye_offset({0,-13,0}, {0,0,0}) -> 1.3 nodes lower.
        c.handleEyeOffset(PacketWriter().f32(0).f32(-13).f32(0).f32(0).f32(0).f32(0).data)
        XCTAssertEqual(got.y, -1.3, accuracy: 1e-5)
    }

    func testFovRecordedNotApplied() {
        let c = Client(name: "t", password: "")
        // mcl_sprint: set_fov(1.1, true, 0.15) as a multiplier with a transition.
        c.handleFov(PacketWriter().f32(1.1).u8(1).f32(0.15).data)
        XCTAssertEqual(c.fovOverride.fov, 1.1, accuracy: 1e-6)
        XCTAssertTrue(c.fovOverride.isMultiplier)
        XCTAssertEqual(c.fovOverride.transition, 0.15, accuracy: 1e-6)
        // Pre-5.3 servers omit transition_time.
        c.handleFov(PacketWriter().f32(8).u8(0).data)
        XCTAssertEqual(c.fovOverride, Client.FovOverride(fov: 8, isMultiplier: false, transition: 0))
    }

    func testHudSetParamHotbar() {
        let c = Client(name: "t", password: "")
        XCTAssertEqual(c.hotbarItemCount, 9)
        // hud_set_hotbar_itemcount(7): the value string is a big-endian s32.
        c.handleHudSetParam(PacketWriter().u16(1).u16(4).u8(0).u8(0).u8(0).u8(7).data)
        XCTAssertEqual(c.hotbarItemCount, 7)
        // Out of range (0 / > 32) or wrong length is ignored, like the engine.
        c.handleHudSetParam(PacketWriter().u16(1).u16(4).u8(0).u8(0).u8(0).u8(0).data)
        c.handleHudSetParam(PacketWriter().u16(1).u16(2).u8(0).u8(3).data)
        XCTAssertEqual(c.hotbarItemCount, 7)
        c.handleHudSetParam(PacketWriter().u16(2).string16("blank.png").data)
        c.handleHudSetParam(PacketWriter().u16(3).string16("mcl_inventory_hotbar_selected.png").data)
        XCTAssertEqual(c.hotbarImage, "blank.png")
        XCTAssertEqual(c.hotbarSelectedImage, "mcl_inventory_hotbar_selected.png")
    }
}
