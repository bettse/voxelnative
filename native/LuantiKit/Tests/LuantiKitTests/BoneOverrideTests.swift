import XCTest
import simd
@testable import LuantiKit

/// AO_CMD_SET_BONE_POSITION: parse, interpolation state, and how an
/// override lands in the skinned pose. Rotation convention follows Irrlicht's
/// quaternion::set(euler) feeding the same transposed-matrix path as b3d keys.
final class BoneOverrideTests: XCTestCase {
    private func addPacket(id: Int) -> Data {
        let initData = PacketWriter()
        initData.u8(1).string16("mob").u8(0).u16(id)
            .f32(0).f32(0).f32(0).f32(0).f32(0).f32(0).u16(10).u8(0)
        let w = PacketWriter()
        w.u16(0).u16(1).u16(id).u8(0).bytes32(initData.data)
        return w.data
    }
    private func boneMsg(_ id: Int, bone: String, pos: SIMD3<Float>, rotDeg: SIMD3<Float>,
                         scale: SIMD3<Float> = SIMD3(1, 1, 1), interp: Float = 0, flags: Int = 3) -> Data {
        let b = PacketWriter().u8(7).string16(bone)
            .f32(pos.x).f32(pos.y).f32(pos.z).f32(rotDeg.x).f32(rotDeg.y).f32(rotDeg.z)
            .f32(scale.x).f32(scale.y).f32(scale.z).f32(interp).f32(interp).f32(interp).u8(flags)
        let w = PacketWriter(); w.u16(id).bytes16(b.data); return w.data
    }

    func testParseStoresAbsoluteFlagsAndUnits() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 5))
        ao.handleMessages(boneMsg(5, bone: "head.control", pos: SIMD3(0, 3.72, -0.472), rotDeg: SIMD3(0, 90, 0), flags: 3))
        let ov = try! XCTUnwrap(ao.entity(5)?.boneOverrides["head.control"])
        XCTAssertEqual(ov.pos, SIMD3(0, 3.72, -0.472), "model units, no BS scaling")
        XCTAssertTrue(ov.absPos); XCTAssertTrue(ov.absRot); XCTAssertFalse(ov.absScale)
        XCTAssertEqual(ov.rot.vector.y, sin(Float.pi / 4), accuracy: 1e-5)
        XCTAssertEqual(ov.rot.real, cos(Float.pi / 4), accuracy: 1e-5)
        XCTAssertEqual(ov.posDur, 0, "first send never interpolates")
    }

    func testLegacyShortMessageIsAbsolutePosAndRot() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 5))
        let b = PacketWriter().u8(7).string16("Head").f32(0).f32(6.3).f32(0).f32(-40).f32(0).f32(0)
        let w = PacketWriter(); w.u16(5).bytes16(b.data)
        ao.handleMessages(w.data)
        let ov = try! XCTUnwrap(ao.entity(5)?.boneOverrides["Head"])
        XCTAssertTrue(ov.absPos && ov.absRot)
    }

    func testResendInterpolatesFromThePreviousTarget() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 5))
        ao.handleMessages(boneMsg(5, bone: "h", pos: SIMD3(0, 0, 0), rotDeg: .zero, interp: 0.1))
        ao.handleMessages(boneMsg(5, bone: "h", pos: SIMD3(0, 10, 0), rotDeg: .zero, interp: 0.1))
        ao.step(0.05)                                            // halfway through 0.1 s
        let mid = try! XCTUnwrap(ao.entity(5)?.boneOverrides["h"]?.current().pos)
        XCTAssertEqual(mid.y, 5, accuracy: 0.01)
        ao.step(0.1)
        XCTAssertEqual(ao.entity(5)?.boneOverrides["h"]?.current().pos?.y ?? -1, 10, accuracy: 1e-5)
    }

    func testFinishedIdentityOverrideIsDropped() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 5))
        ao.handleMessages(boneMsg(5, bone: "h", pos: .zero, rotDeg: .zero, flags: 0))   // relative zero = no-op
        ao.step(0.01)
        XCTAssertNil(ao.entity(5)?.boneOverrides["h"])
        ao.handleMessages(boneMsg(5, bone: "h", pos: .zero, rotDeg: .zero, flags: 1))   // absolute pos: keep
        ao.step(0.01)
        XCTAssertNotNil(ao.entity(5)?.boneOverrides["h"])
    }

    // MARK: skinning

    private func oneBoneMesh(keyRot: simd_quatf? = nil) -> B3DLoader.Mesh {
        let j = B3DLoader.Joint(name: "head", parent: -1, bindPos: .zero, bindScale: SIMD3(1, 1, 1),
                                bindRot: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), bindGlobalInv: matrix_identity_float4x4,
                                keys: keyRot.map { [B3DLoader.Key(frame: 0, pos: nil, scale: nil, rot: $0)] } ?? [])
        var m = B3DLoader.Mesh(positions: [SIMD3(1, 0, 0)], uvs: [.zero], indices: [0, 0, 0], textureName: "",
                               minBounds: .zero, maxBounds: SIMD3(1, 0, 0))
        m.joints = [j]; m.weights = [[(0, 1)]]
        return m
    }

    func testAbsoluteRotationMatchesAnEquivalentKey() {
        let q = B3DLoader.irrQuat(euler: SIMD3(0, .pi / 2, 0))
        let keyed = oneBoneMesh(keyRot: q).skinnedPositions(frame: 0)[0]
        var o = B3DLoader.JointOverride(); o.rot = q; o.absRot = true
        let overridden = oneBoneMesh().skinnedPositions(frame: 0, overrides: ["head": o])[0]
        XCTAssertEqual(simd_distance(keyed, overridden), 0, accuracy: 1e-5)
        XCTAssertEqual(abs(overridden.z), 1, accuracy: 1e-5, "x axis swung into z by a 90 degree yaw")
    }

    func testRelativeZeroLeavesTheAnimationAlone() {
        let q = B3DLoader.irrQuat(euler: SIMD3(0.3, -0.2, 0.9))
        let plain = oneBoneMesh(keyRot: q).skinnedPositions(frame: 0)[0]
        var o = B3DLoader.JointOverride(); o.rot = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1); o.pos = .zero
        let same = oneBoneMesh(keyRot: q).skinnedPositions(frame: 0, overrides: ["head": o])[0]
        XCTAssertEqual(simd_distance(plain, same), 0, accuracy: 1e-5)
    }

    func testAbsolutePositionMovesTheBone() {
        var o = B3DLoader.JointOverride(); o.pos = SIMD3(0, 2, 0); o.absPos = true
        let p = oneBoneMesh().skinnedPositions(frame: 0, overrides: ["head": o])[0]
        XCTAssertEqual(p, SIMD3(1, 2, 0))
    }

    func testUnknownBoneIsIgnored() {
        var o = B3DLoader.JointOverride(); o.pos = SIMD3(0, 2, 0); o.absPos = true
        XCTAssertEqual(oneBoneMesh().skinnedPositions(frame: 0, overrides: ["tail": o])[0], SIMD3(1, 0, 0))
    }
}
