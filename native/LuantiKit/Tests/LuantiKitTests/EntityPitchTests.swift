import XCTest
import simd
@testable import LuantiKit

/// Entity pitch (#128): WorldMesher.pitchLocal tilts a model vertex in the X-Y
/// plane before the horizontal yaw, so an arrow (shaft along local X) tips off
/// horizontal. Must be exactly identity at pitch 0 so mobs are unaffected.
final class EntityPitchTests: XCTestCase {
    func testZeroPitchIsIdentity() {
        let p = SIMD3<Float>(0.3, -0.7, 1.25)
        XCTAssertEqual(WorldMesher.pitchLocal(p, 0), p, "mobs (pitch 0) must be byte-for-byte unchanged")
    }

    func testNinetyDegreesSwingsXShaftToY() {
        // The arrow's shaft is +X; a 90-degree pitch should point it +Y.
        let tip = WorldMesher.pitchLocal(SIMD3(1, 0, 0), .pi / 2)
        XCTAssertEqual(tip.x, 0, accuracy: 1e-6)
        XCTAssertEqual(tip.y, 1, accuracy: 1e-6)
        XCTAssertEqual(tip.z, 0, accuracy: 1e-6)
    }

    func testZAxisUntouched() {
        // Pitch is a rotation in X-Y, so the model's Z (its width) never moves.
        let r = WorldMesher.pitchLocal(SIMD3(0, 0, 2.5), 0.9)
        XCTAssertEqual(r, SIMD3(0, 0, 2.5))
    }

    func testPreservesLength() {
        let p = SIMD3<Float>(0.8, 1.6, -0.4)
        XCTAssertEqual(simd_length(WorldMesher.pitchLocal(p, 0.6)), simd_length(p), accuracy: 1e-6)
    }

    private func arrow() -> ActiveObjects {
        let ao = ActiveObjects()
        let initData = PacketWriter()
        initData.u8(1).string16("arrow").u8(0).u16(70)
            .f32(0).f32(0).f32(0).f32(0).f32(0).f32(0).u16(1).u8(0)
        ao.handleRemoveAdd(PacketWriter().u16(0).u16(1).u16(70).u8(0).bytes32(initData.data).data)
        return ao
    }

    func testParsePitchRollAndYawFromRotation() {
        // UPDATE_POSITION rotation (degrees): x -> pitch, z -> roll (where
        // vl_projectile puts a projectile's flight angle), y -> the yaw target.
        let ao = arrow()
        let body = PacketWriter().u8(1)
            .f32(0).f32(0).f32(0).f32(0).f32(0).f32(0).f32(0).f32(0).f32(0)
            .f32(30).f32(90).f32(-20)   // rotation: pitch 30, yaw 90, roll -20
            .u8(1).u8(0).f32(0.1)
        ao.handleMessages(PacketWriter().u16(70).bytes16(body.data).data)
        let e = ao.entity(70)!
        XCTAssertEqual(e.pitch, Float.pi / 6, accuracy: 1e-5)
        XCTAssertEqual(e.roll, -Float.pi / 9, accuracy: 1e-5)
        XCTAssertEqual(e.yawTarget, Float.pi / 2, accuracy: 1e-5)
        XCTAssertEqual(e.yaw, 0, accuracy: 1e-5, "facing eases in step(), it doesn't snap")
        for _ in 0..<20 { ao.step(0.05) }
        XCTAssertEqual(ao.entity(70)!.yaw, Float.pi / 2, accuracy: 1e-4)
    }

    func testYawEasesTheShortWayRound() {
        let ao = arrow()
        // 350 deg -> 10 deg is a 20 deg turn through 0, not 340 deg the other way.
        let seed = PacketWriter().u8(1)
            .f32(0).f32(0).f32(0).f32(0).f32(0).f32(0).f32(0).f32(0).f32(0)
            .f32(0).f32(350).f32(0).u8(0).u8(0).f32(0.1)   // do_interpolate=false snaps
        ao.handleMessages(PacketWriter().u16(70).bytes16(seed.data).data)
        let turn = PacketWriter().u8(1)
            .f32(0).f32(0).f32(0).f32(0).f32(0).f32(0).f32(0).f32(0).f32(0)
            .f32(0).f32(10).f32(0).u8(1).u8(0).f32(0.1)
        ao.handleMessages(PacketWriter().u16(70).bytes16(turn.data).data)
        ao.step(0.05)
        let y = ao.entity(70)!.yaw
        let wrapped = atan2(sin(y), cos(y))
        XCTAssertTrue(wrapped > -Float.pi / 18 - 1e-4 && wrapped < Float.pi / 18 + 1e-4, "yaw \(y) left the 350..10 arc")
    }

    func testAccelerationIsIntegrated() {
        // Falling item: velocity 0, acceleration -10 (BS units on the wire).
        let ao = arrow()
        let body = PacketWriter().u8(1)
            .f32(0).f32(100).f32(0)        // pos y = 10 nodes
            .f32(0).f32(0).f32(0)
            .f32(0).f32(-100).f32(0)       // acc y = -10 nodes/s^2
            .f32(0).f32(0).f32(0).u8(0).u8(0).f32(0.1)
        ao.handleMessages(PacketWriter().u16(70).bytes16(body.data).data)
        for _ in 0..<10 { ao.step(0.1) }   // 1 s
        let e = ao.entity(70)!
        XCTAssertEqual(e.vel.y, -10, accuracy: 1e-4)
        XCTAssertLessThan(e.target.y, 10.5 - 4.9, "target fell about 5 nodes in a second (0.5*a*t^2)")
    }
}
