import XCTest
@testable import LuantiKit

/// TOSERVER_INTERACT layout (serverpackethandler.cpp handleCommand_Interact):
/// u8 action, u16 item, bytes32 PointedThing, then the PLAYERPOS block.
final class InteractPacketTests: XCTestCase {
    private struct Decoded {
        var action: Int, wield: Int, pointedType: Int
        var under: SIMD3<Int>?, above: SIMD3<Int>?
        var objectId: Int?
        var pitch: Int, yaw: Int, keys: Int
    }

    private func decode(_ d: Data) -> Decoded {
        let r = PacketReader(d)
        let action = r.u8(), wield = r.u16()
        let pt = PacketReader(r.bytes32())
        XCTAssertEqual(pt.u8(), 0, "PointedThing version")
        let type = pt.u8()
        var under: SIMD3<Int>? = nil, above: SIMD3<Int>? = nil, objectId: Int? = nil
        if type == 1 {
            under = SIMD3(pt.s16(), pt.s16(), pt.s16())
            above = SIMD3(pt.s16(), pt.s16(), pt.s16())
        } else if type == 2 {
            objectId = pt.u16()
        }
        _ = r.s32(); _ = r.s32(); _ = r.s32()   // position
        _ = r.s32(); _ = r.s32(); _ = r.s32()   // speed
        let pitch = r.s32(), yaw = r.s32()
        let keys = r.u32()
        return Decoded(action: action, wield: wield, pointedType: type, under: under, above: above, objectId: objectId, pitch: pitch, yaw: yaw, keys: keys)
    }

    func testObjectPunchCarriesTheObjectId() {
        let c = Client(name: "t", password: "")
        c.setWieldIndex(2)
        let d = decode(c.interactPacketObject(action: 0, objectId: 4242))   // punch a mob
        XCTAssertEqual(d.action, 0)
        XCTAssertEqual(d.wield, 2)
        XCTAssertEqual(d.pointedType, 2, "PointedThing type: object")
        XCTAssertEqual(d.objectId, 4242)
        XCTAssertNil(d.under)
    }

    func testPlaceCarriesNodeAndPlaceKey() {
        let c = Client(name: "t", password: "")
        c.setWieldIndex(3)
        let d = decode(c.interactPacket(action: 3, under: SIMD3(1, -2, 300), above: SIMD3(1, -1, 300)))
        XCTAssertEqual(d.action, 3)
        XCTAssertEqual(d.wield, 3)
        XCTAssertEqual(d.pointedType, 1)
        XCTAssertEqual(d.under, SIMD3(1, -2, 300))
        XCTAssertEqual(d.above, SIMD3(1, -1, 300))
        XCTAssertEqual(d.keys, 256, "place key bit")
    }

    func testDigCompleteSetsDigKey() {
        let c = Client(name: "t", password: "")
        let d = decode(c.interactPacket(action: 2, under: SIMD3(0, 0, 0), above: SIMD3(0, 1, 0)))
        XCTAssertEqual(d.keys, 128, "dig key bit")
    }

    /// Rightclick-air (buckets on open water, eating while looking at the sky):
    /// action 5 with a "nothing" pointed thing and no key bits.
    func testActivateIsPointedNothing() {
        let c = Client(name: "t", password: "")
        let d = decode(c.interactPacket(action: 5, under: nil, above: nil))
        XCTAssertEqual(d.action, 5)
        XCTAssertEqual(d.pointedType, 0)
        XCTAssertNil(d.under)
        XCTAssertEqual(d.keys, 0)
    }

    /// Raise-to-mouth eat is a HOLD: VoxeLibre ticks a ~1.6s eat delay off
    /// the held place/RMB control bit, so while placeHeld the interact carries the
    /// place bit even for an activate that otherwise has none.
    func testPlaceHeldSetsThePlaceBitOnActivate() {
        let c = Client(name: "t", password: "")
        XCTAssertEqual(decode(c.interactPacket(action: 5, under: nil, above: nil)).keys, 0)
        c.placeHeld = true
        XCTAssertEqual(decode(c.interactPacket(action: 5, under: nil, above: nil)).keys, 256,
                       "held place bit carries through the activate")
    }

    /// Sneak is control bit 6 (value 64): sent so mods see it and the server
    /// treats a rightclick as a placement. It rides both PLAYERPOS and
    /// interact packets, and combines with the held place bit.
    func testSneakSetsBit6() {
        let c = Client(name: "t", password: "")
        XCTAssertEqual(decode(c.interactPacket(action: 5, under: nil, above: nil)).keys, 0)
        c.sneakHeld = true
        XCTAssertEqual(decode(c.interactPacket(action: 5, under: nil, above: nil)).keys, 64)
        c.placeHeld = true
        XCTAssertEqual(decode(c.interactPacket(action: 5, under: nil, above: nil)).keys, 64 | 256)
    }

    /// The look angles ride along in hundredths of a degree, so a server-side
    /// raycast (VoxeLibre's bucket) follows the gaze we last set.
    func testLookAnglesInHundredthsOfDegrees() {
        let c = Client(name: "t", password: "")
        c.setPose(pos: SIMD3(0, 0, 0), yaw: .pi / 2, pitch: -.pi / 4)
        let d = decode(c.interactPacket(action: 5, under: nil, above: nil))
        XCTAssertEqual(d.yaw, 9000)
        XCTAssertEqual(d.pitch, -4500)
    }
}
