import XCTest
@testable import LuantiKit

/// TOSERVER_PLAYERPOS layout (networkprotocol.h): v3s32 pos*1000, v3s32
/// speed*1000, s32 pitch*100, s32 yaw*100, u32 keyPressed, u8 fov*80,
/// u8 wanted_range, u8 camera_inverted, f32 movement_speed, f32 movement_dir.
/// The client used to send a zero speed and never the jump bit (#270); mods
/// read both (get_velocity for fall/elytra checks, control.jump for mounts).
final class PlayerPosPacketTests: XCTestCase {
    private func s32(_ d: Data, _ off: Int) -> Int32 {
        Int32(bitPattern: UInt32(d[off]) << 24 | UInt32(d[off+1]) << 16 | UInt32(d[off+2]) << 8 | UInt32(d[off+3]))
    }

    func testVelocityRidesInThePacket() {
        let c = Client(name: "t", password: "")
        c.setPose(pos: SIMD3(10, 20, 30) + Client.gridShift, yaw: 0, pitch: 0, velocity: SIMD3(1.5, -9.81, 0.25))
        let d = c.playerPosBlockData()
        XCTAssertEqual(s32(d, 0), 10_000); XCTAssertEqual(s32(d, 4), 20_000); XCTAssertEqual(s32(d, 8), 30_000)
        XCTAssertEqual(s32(d, 12), 1_500)
        XCTAssertEqual(s32(d, 16), -9_810)
        XCTAssertEqual(s32(d, 20), 250)
    }

    func testControlBitsMatchLuantiLayout() {
        let c = Client(name: "t", password: "")
        XCTAssertEqual(c.heldKeys, 0)
        c.jumpHeld = true;  XCTAssertEqual(c.heldKeys, 16)
        c.sneakHeld = true; XCTAssertEqual(c.heldKeys, 16 | 64)
        c.digHeld = true;   XCTAssertEqual(c.heldKeys, 16 | 64 | 128)
        c.placeHeld = true; XCTAssertEqual(c.heldKeys, 16 | 64 | 128 | 256)
        c.moveKeys = 1 | 32; XCTAssertEqual(c.heldKeys, 1 | 16 | 32 | 64 | 128 | 256)
        // ...and the u32 lands after pos/vel/pitch/yaw (offset 32).
        let d = c.playerPosBlockData(keys: c.heldKeys)
        XCTAssertEqual(s32(d, 32), Int32(1 | 16 | 32 | 64 | 128 | 256))
    }
}
