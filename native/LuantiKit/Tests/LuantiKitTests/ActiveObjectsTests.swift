import XCTest
import simd
@testable import LuantiKit

/// AO command handling (#100): PUNCHED hp/flash/death, STOP_ANIMATION, and the
/// ObjectProperties tail (nametag, damage_texture_modifier). Wire layouts here
/// mirror GenericCAO::processMessage and ObjectProperties::serialize.
final class ActiveObjectsTests: XCTestCase {

    /// TOCLIENT_ACTIVE_OBJECT_REMOVE_ADD with one added object and no messages.
    private func addPacket(id: Int, name: String = "mob", isPlayer: Bool = false, hp: Int) -> Data {
        let initData = PacketWriter()
        initData.u8(1).string16(name).u8(isPlayer ? 1 : 0).u16(id)
            .f32(0).f32(0).f32(0)          // position
            .f32(0).f32(0).f32(0)          // rotation
            .u16(hp).u8(0)                 // hp, then zero initial messages
        let w = PacketWriter()
        w.u16(0).u16(1).u16(id).u8(0).bytes32(initData.data)
        return w.data
    }

    private func removePacket(ids: [Int]) -> Data {
        let w = PacketWriter()
        w.u16(ids.count); for id in ids { w.u16(id) }
        w.u16(0)   // no adds
        return w.data
    }

    /// One TOCLIENT_ACTIVE_OBJECT_MESSAGES entry: (u16 id, bytes16 body).
    private func msg(_ id: Int, _ body: PacketWriter) -> Data {
        let w = PacketWriter()
        w.u16(id).bytes16(body.data)
        return w.data
    }

    private func punch(_ ao: ActiveObjects, _ id: Int, resultHp: Int) {
        ao.handleMessages(msg(id, PacketWriter().u8(4).u16(resultHp)))   // AO_CMD_PUNCHED
    }

    /// AO_CMD_SET_PHYSICS_OVERRIDE (content_cao.cpp): 3 f32, 3 legacy u8, then
    /// the 5.8 (7 f32) and 5.9 (3 f32) tails. speed_crouch is the 2nd of the
    /// 5.8 tail, speed_walk the last of the 5.9 tail; both default to 1 when
    /// a server sends the short form.
    func testPhysicsOverrideParsesCrouchAndWalkMultipliers() {
        let ao = ActiveObjects()
        ao.localPlayerName = "me"
        ao.handleRemoveAdd(addPacket(id: 3, name: "me", isPlayer: true, hp: 20))
        var got: [Float] = []
        ao.onLocalPhysicsOverride = { s, j, g, c, w in got = [s, j, g, c, w] }
        let full = PacketWriter().u8(9).f32(1.3).f32(1).f32(1).u8(0).u8(0).u8(0)
            .f32(1).f32(1.5).f32(1).f32(1).f32(1).f32(1).f32(1)    // 5.8 tail: speed_crouch = 1.5
            .f32(1).f32(1).f32(0.8)                                // 5.9 tail: speed_walk = 0.8
        ao.handleMessages(msg(3, full))
        XCTAssertEqual(got, [1.3, 1, 1, 1.5, 0.8])
        let short = PacketWriter().u8(9).f32(0).f32(0).f32(1).u8(0).u8(0).u8(0)   // bed freeze, old layout
        ao.handleMessages(msg(3, short))
        XCTAssertEqual(got, [0, 0, 1, 1, 1])
    }

    func testPunchedTracksHpAndFlashTimer() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 7, hp: 10))
        XCTAssertEqual(ao.entity(7)?.hp, 10)          // starting hp comes from the add packet

        punch(ao, 7, resultHp: 9)                     // 1 damage -> floored to 0.2s so it's visible (#149)
        XCTAssertEqual(ao.entity(7)?.hp, 9)
        XCTAssertEqual(ao.entity(7)?.hitFlash ?? -1, 0.20, accuracy: 1e-6)

        punch(ao, 7, resultHp: 6)                     // 3 damage -> 0.05 + 0.05*3
        XCTAssertEqual(ao.entity(7)?.hitFlash ?? -1, 0.20, accuracy: 1e-6)

        // Healing (hp goes up) must not flash.
        ao.handleRemoveAdd(addPacket(id: 8, hp: 5))
        punch(ao, 8, resultHp: 9)
        XCTAssertEqual(ao.entity(8)?.hitFlash ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(ao.entity(8)?.hp, 9)
    }

    func testKillingBlowPuffsInsteadOfFlashing() {
        // GenericCAO: hp reaching 0 makes a smoke puff, no damage flash.
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 9, hp: 4))
        punch(ao, 9, resultHp: 0)
        XCTAssertEqual(ao.entity(9)?.hitFlash ?? -1, 0, accuracy: 1e-6)
        let puffs = ao.takeDeathPuffs()
        XCTAssertEqual(puffs.count, 1)
        XCTAssertTrue(ao.takeDeathPuffs().isEmpty, "puff is consumed once")
    }

    func testTextureModCancelsFlash() {
        // A mod-issued SET_TEXTURE_MOD mid-flash resets the engine's damage timer.
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 5, hp: 10))
        punch(ao, 5, resultHp: 8)
        XCTAssertGreaterThan(ao.entity(5)?.hitFlash ?? 0, 0)
        ao.handleMessages(msg(5, PacketWriter().u8(2).string16("^[colorize:#ff6600:80")))   // burning
        XCTAssertEqual(ao.entity(5)?.hitFlash ?? -1, 0, accuracy: 1e-6)
    }

    func testPunchedFlashIsCappedAtOneSecond() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 1, hp: 100))
        punch(ao, 1, resultHp: 50)                    // 50 damage would be 2.55s uncapped
        XCTAssertEqual(ao.entity(1)?.hitFlash ?? -1, 1.0, accuracy: 1e-6)
    }

    func testStepRunsFlashDownAndClampsAtZero() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 3, hp: 10))
        punch(ao, 3, resultHp: 7)                     // 0.20s
        ao.step(0.05)
        XCTAssertEqual(ao.entity(3)?.hitFlash ?? -1, 0.15, accuracy: 1e-6)
        ao.step(1.0)
        XCTAssertEqual(ao.entity(3)?.hitFlash ?? -1, 0, accuracy: 1e-6)   // never negative
    }

    func testDeathDetachesMobFromParentAndChildren() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 1, name: "horse", hp: 5))
        ao.handleRemoveAdd(addPacket(id: 2, name: "rider", hp: 5))
        // AO_CMD_ATTACH_TO: s16 parent, string16 bone, v3f pos, v3f rot.
        ao.handleMessages(msg(2, PacketWriter().u8(8).s16(1).string16("")
            .f32(0).f32(0).f32(0).f32(0).f32(0).f32(0)))
        XCTAssertEqual(ao.entity(2)?.attachParent, 1)

        punch(ao, 1, resultHp: 0)                     // the horse dies
        XCTAssertEqual(ao.entity(1)?.hp, 0)
        XCTAssertEqual(ao.entity(2)?.attachParent, 0) // clearChildAttachments (non-player)
    }

    func testAttachToHighParentIdIsUnsigned() {
        // A parent AO id above 32767 must be read unsigned: as s16 it goes
        // negative, objects[negative] misses, and the child never follows.
        let ao = ActiveObjects()
        let parentId = 40000
        ao.handleRemoveAdd(addPacket(id: parentId, name: "boat", hp: 5))
        ao.handleRemoveAdd(addPacket(id: 7, name: "rider", hp: 5))
        ao.handleMessages(msg(7, PacketWriter().u8(8).u16(parentId).string16("")
            .f32(0).f32(0).f32(0).f32(0).f32(0).f32(0)))
        XCTAssertEqual(ao.entity(7)?.attachParent, parentId)
    }

    func testDeadPlayerKeepsItsChildrenAttached() {
        // GenericCAO only clears children for non-players (ObjectRef::l_remove
        // semantics); a dead player just drops its own parent attachment.
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 3, name: "steve", isPlayer: true, hp: 5))
        ao.handleRemoveAdd(addPacket(id: 4, name: "parrot", hp: 5))
        ao.handleMessages(msg(4, PacketWriter().u8(8).s16(3).string16("")
            .f32(0).f32(0).f32(0).f32(0).f32(0).f32(0)))
        punch(ao, 3, resultHp: 0)
        XCTAssertEqual(ao.entity(4)?.attachParent, 3)
    }

    func testStopAnimationReturnsToBindPose() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 5, hp: 5))
        // AO_CMD_SET_ANIMATION: v2f range, f32 fps, f32 blend, u8 !loop.
        ao.handleMessages(msg(5, PacketWriter().u8(6).f32(0).f32(10).f32(15).f32(0).u8(0)))
        XCTAssertNotNil(ao.entity(5)?.animRange)
        ao.handleMessages(msg(5, PacketWriter().u8(13)))                  // AO_CMD_STOP_ANIMATION
        XCTAssertNil(ao.entity(5)?.animRange)
    }

    func testPropertiesTailParsesNametagAndDamageModifier() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 9, hp: 5))
        // AO_CMD_SET_PROPERTIES body, in ObjectProperties::serialize order.
        let p = PacketWriter()
        p.u8(0)                                       // command
        p.u8(4)                                       // properties version
        p.u16(20).u8(1).f32(0)                        // hp_max, physical, (removed) weight
        for _ in 0..<12 { p.f32(0) }                  // collisionbox + selectionbox
        p.u8(1)                                       // pointable
        p.string16("mesh")
        p.f32(1).f32(1).f32(1)                        // visual_size
        p.u16(1).string16("cow.png")                  // textures
        p.s16(1).s16(1).s16(0).s16(0)                 // spritediv, initial_sprite_basepos
        p.u8(1).u8(1).f32(0)                          // is_visible, footstep, automatic_rotate
        p.string16("cow.b3d")
        p.u16(2).u32(0xFFFF_0000).u32(0xFF00_FF00)    // colors
        p.u8(1).f32(0.6).u8(0).f32(0).u8(1)           // collide, stepheight, face dir/offset, backface
        p.string16("Bessie")
        p.u32(0xFF11_2233)                            // nametag_color (ARGB8)
        p.f32(0)                                      // face-movement max rotation
        p.string16("moo").string16("")                // infotext, wield_item
        p.s8(0).u16(10).f32(1.6).f32(0)               // glow, breath_max, eye_height, zoom_fov
        p.u8(0)                                       // use_texture_alpha
        p.string16("^[brighten")                      // damage_texture_modifier
        p.u8(1).u8(1)                                 // shaded, show_on_minimap
        ao.handleMessages(msg(9, p))

        let e = ao.entity(9)
        XCTAssertEqual(e?.visual, "mesh")
        XCTAssertEqual(e?.mesh, "cow.b3d")
        XCTAssertEqual(e?.textures, ["cow.png"])
        XCTAssertEqual(e?.nametag, "Bessie")
        XCTAssertEqual(e?.nametagColor, 0xFF11_2233)
        XCTAssertEqual(e?.damageTexMod, "^[brighten")
    }

    func testShortPropertiesTailIsSafe() {
        // An older/shorter tail must not crash; missing fields just read as empty.
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 2, hp: 5))
        let p = PacketWriter()
        p.u8(0).u8(4).u16(20).u8(1).f32(0)
        for _ in 0..<12 { p.f32(0) }
        p.u8(1).string16("sprite").f32(1).f32(1).f32(1).u16(0)
        p.s16(1).s16(1).s16(0).s16(0).u8(1).u8(1).f32(0).string16("")   // ends right after mesh
        ao.handleMessages(msg(2, p))
        XCTAssertEqual(ao.entity(2)?.visual, "sprite")
        XCTAssertEqual(ao.entity(2)?.nametag, "")
        XCTAssertEqual(ao.entity(2)?.damageTexMod, "")
    }

    // MARK: - attach offset rotation (#139 riding, shared by passenger AO + rider)

    private func approx(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ acc: Float = 1e-5, _ msg: String = "",
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: acc, msg, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: acc, msg, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: acc, msg, file: file, line: line)
    }

    func testAttachedPositionAtZeroYawIsParentPlusOffset() {
        let p = SIMD3<Float>(10, 5, -3), off = SIMD3<Float>(1, 2, 0.5)
        approx(ActiveObjects.attachedPosition(parent: p, yaw: 0, offset: off), p + off)
    }

    func testAttachedPositionYIsNeverRotated() {
        // The vertical offset (seat height) is yaw-independent at any angle.
        for yaw: Float in [0, 0.7, .pi / 2, 2.5, .pi] {
            let r = ActiveObjects.attachedPosition(parent: .zero, yaw: yaw, offset: SIMD3(0, 1.5, 0))
            XCTAssertEqual(r.y, 1.5, accuracy: 1e-5)
            XCTAssertEqual(r.x, 0, accuracy: 1e-5)
            XCTAssertEqual(r.z, 0, accuracy: 1e-5)
        }
    }

    func testAttachedPositionRotatesForwardOffsetByYaw() {
        // A boat facing yaw = +90deg carries a seat that sits +1 on local x.
        // Convention (Z-mirrored render frame): x' = x*cos + z*sin, z' = -x*sin + z*cos.
        let r = ActiveObjects.attachedPosition(parent: .zero, yaw: .pi / 2, offset: SIMD3(1, 0, 0))
        approx(r, SIMD3(0, 0, -1))
    }

    func testStepFollowLoopUsesTheSharedHelper() {
        // Drive an attached AO through step() and confirm its resolved pos matches
        // the shared helper, so the rider (WorldSession) and passenger AOs agree.
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 1, name: "boat", hp: 10))     // parent at origin, yaw 0
        ao.handleRemoveAdd(addPacket(id: 2, name: "seat", hp: 1))      // child

        // ATTACH_TO cmd 8: s16 parent, string16 bone, v3f pos(*BS), v3f rot, u8 forceVisible.
        let bs: Float = 10.0
        let attach = PacketWriter().u8(8).s16(1).string16("")
            .f32(2 * bs).f32(1 * bs).f32(0).f32(0).f32(0).f32(0).u8(0)
        ao.handleMessages(msg(2, attach))
        approx(ao.entity(2)!.attachOffset, SIMD3(2, 1, 0), 1e-4, "offset is /BS from wire")

        ao.step(0.016)
        let parent = ao.entity(1)!
        let expected = ActiveObjects.attachedPosition(parent: parent.pos, yaw: parent.yaw,
                                                      offset: ao.entity(2)!.attachOffset)
        approx(ao.entity(2)!.pos, expected)
        XCTAssertEqual(ao.entity(2)?.attachParent, 1)
    }

    // MARK: - entity raycast (#146: punch a mob with a sword)

    func testRayAABBEntryDistance() {
        let lo = SIMD3<Float>(0, 0, 0), hi = SIMD3<Float>(1, 1, 1)
        XCTAssertEqual(ActiveObjects.rayAABB(origin: SIMD3(-2, 0.5, 0.5), dir: SIMD3(1, 0, 0), lo: lo, hi: hi) ?? -1, 2, accuracy: 1e-5)
        XCTAssertEqual(ActiveObjects.rayAABB(origin: SIMD3(0.5, 0.5, 0.5), dir: SIMD3(1, 0, 0), lo: lo, hi: hi) ?? -1, 0, accuracy: 1e-5)   // inside
        XCTAssertNil(ActiveObjects.rayAABB(origin: SIMD3(-2, 0.5, 0.5), dir: SIMD3(-1, 0, 0), lo: lo, hi: hi))   // away
        XCTAssertNil(ActiveObjects.rayAABB(origin: SIMD3(-2, 5, 0.5), dir: SIMD3(1, 0, 0), lo: lo, hi: hi))      // parallel, off to the side
    }

    func testRaycastEntityHitsTheNearestMob() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 7, name: "cow", hp: 10))       // default box: x -0.3..0.3, y 0..1.7
        let cow = ao.entity(7)!
        let c = cow.pos + (cow.cbMin + cow.cbMax) * 0.5                 // box centre (gridShift-agnostic)
        let hit = ao.raycastEntity(origin: SIMD3(c.x - 2, c.y, c.z), dir: SIMD3(1, 0, 0), maxDist: 5)
        XCTAssertEqual(hit?.id, 7)
        XCTAssertEqual(hit?.dist ?? -1, 1.7, accuracy: 1e-4)           // 2 nodes to the -x face (half-width 0.3)
        XCTAssertNil(ao.raycastEntity(origin: SIMD3(c.x - 2, c.y, c.z), dir: SIMD3(-1, 0, 0), maxDist: 5))   // aimed away
        XCTAssertNil(ao.raycastEntity(origin: SIMD3(c.x - 2, c.y, c.z), dir: SIMD3(1, 0, 0), maxDist: 1.0))  // out of reach
    }

    func testLocalPlayerIdMemoizedAndInvalidated() {
        let ao = ActiveObjects()
        ao.localPlayerName = "me"
        XCTAssertEqual(ao.localPlayerId, 0, "not seen yet")
        ao.handleRemoveAdd(addPacket(id: 7, name: "me", isPlayer: true, hp: 20))
        ao.handleRemoveAdd(addPacket(id: 8, name: "other", isPlayer: true, hp: 20))
        XCTAssertEqual(ao.localPlayerId, 7)
        XCTAssertEqual(ao.localPlayerId, 7, "cached hit still resolves us")
        // Our AO id changes (relog): the memo must not keep returning the old id.
        ao.handleRemoveAdd(removePacket(ids: [7]))
        XCTAssertEqual(ao.localPlayerId, 0)
        ao.handleRemoveAdd(addPacket(id: 12, name: "me", isPlayer: true, hp: 20))
        XCTAssertEqual(ao.localPlayerId, 12)
    }

    func testRaycastEntitySkipsTheLocalPlayer() {
        let ao = ActiveObjects()
        ao.localPlayerName = "me"
        ao.handleRemoveAdd(addPacket(id: 3, name: "me", isPlayer: true, hp: 20))
        let me = ao.entity(3)!
        let c = me.pos + (me.cbMin + me.cbMax) * 0.5
        // Aimed straight through our own box: still no hit (we skip ourselves).
        XCTAssertNil(ao.raycastEntity(origin: SIMD3(c.x - 2, c.y, c.z), dir: SIMD3(1, 0, 0), maxDist: 5), "must not punch ourselves")
    }
}

/// #149: the local player's melee hit flashes the mob immediately (client-side)
/// so feedback doesn't wait on the server's PUNCHED, which mcl_mobs doesn't
/// always send as a clean hp diff.
extension ActiveObjectsTests {
    func testFlashSetsHitTimerImmediately() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 5, hp: 10))
        ao.flash(5, seconds: 0.25)
        XCTAssertEqual(ao.entity(5)?.hitFlash ?? -1, 0.25, accuracy: 1e-6)
    }
    func testFlashNeverShortensALongerRunningFlash() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 5, hp: 10))
        ao.flash(5, seconds: 0.5)
        ao.flash(5, seconds: 0.1)   // a smaller client flash must not cut the longer one short
        XCTAssertEqual(ao.entity(5)?.hitFlash ?? -1, 0.5, accuracy: 1e-6)
    }
    func testFlashOnUnknownObjectIsANoOp() {
        let ao = ActiveObjects()
        ao.flash(999, seconds: 0.25)   // no such object: must not crash or create one
        XCTAssertNil(ao.entity(999))
    }
}

/// ObjectProperties fields that drive interaction, and the raycast honoring them:
/// the engine (GenericCAO::getSelectionBox) returns no box -> not pointable when
/// an object is non-pointable, invisible, or attached; glow self-illuminates.
extension ActiveObjectsTests {
    /// Build an AO_CMD_SET_PROPERTIES body in ObjectProperties::serialize order.
    private func propsPacket(pointable: Int = 1, isVisible: Int = 1, glow: Int = 0,
                             cbMin: SIMD3<Float> = SIMD3(-0.3, 0, -0.3), cbMax: SIMD3<Float> = SIMD3(0.3, 1.7, 0.3),
                             selMin: SIMD3<Float> = .zero, selMax: SIMD3<Float> = .zero) -> PacketWriter {
        let p = PacketWriter()
        p.u8(0).u8(4)                                  // SET_PROPERTIES, version 4
        p.u16(20).u8(1).f32(0)                         // hp_max, physical, weight (removed)
        func v(_ s: SIMD3<Float>) { p.f32(s.x).f32(s.y).f32(s.z) }
        v(cbMin); v(cbMax); v(selMin); v(selMax)
        p.u8(pointable)
        p.string16("mesh").f32(1).f32(1).f32(1)        // visual, visual_size
        p.u16(1).string16("cow.png")                   // textures
        p.s16(1).s16(1).s16(0).s16(0)                  // sprite
        p.u8(isVisible).u8(1).f32(0)                   // is_visible, footstep, automatic_rotate
        p.string16("cow.b3d")                          // mesh
        p.u16(0)                                       // colors
        p.u8(1).f32(0.6).u8(0).f32(0).u8(1)            // collide, step, faceDir, faceOffset, backface
        p.string16("").u32(0).f32(0)                   // nametag, nametag_color, max_rot
        p.string16("").string16("")                    // infotext, wield_item
        p.s8(glow).u16(10).f32(1.6).f32(0)             // glow, breath, eye, zoom
        p.u8(0)                                        // use_texture_alpha
        p.string16("")                                 // damage_texture_modifier
        return p
    }

    func testPropertiesParsePointableVisibleGlowSelbox() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 9, hp: 5))
        ao.handleMessages(msg(9, propsPacket(pointable: 0, isVisible: 0, glow: -1,
                                             selMin: SIMD3(-0.2, 0.1, -0.2), selMax: SIMD3(0.2, 1.5, 0.2))))
        let e = ao.entity(9)
        XCTAssertEqual(e?.pointable, false)
        XCTAssertEqual(e?.isVisible, false)
        XCTAssertEqual(e?.glow, -1)
        XCTAssertEqual(e?.selMin.y ?? -9, 0.1, accuracy: 1e-5)
        XCTAssertEqual(e?.selMax.y ?? -9, 1.5, accuracy: 1e-5)
    }

    func testRaycastSkipsNonPointableEntity() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 7, name: "chest", hp: 1))
        ao.handleMessages(msg(7, propsPacket(pointable: 0)))
        let e = ao.entity(7)!
        let c = e.pos + (e.cbMin + e.cbMax) * 0.5
        XCTAssertNil(ao.raycastEntity(origin: SIMD3(c.x - 2, c.y, c.z), dir: SIMD3(1, 0, 0), maxDist: 5))
    }

    func testRaycastSkipsInvisibleEntity() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 7, name: "wieldview", hp: 1))
        ao.handleMessages(msg(7, propsPacket(isVisible: 0)))
        let e = ao.entity(7)!
        let c = e.pos + (e.cbMin + e.cbMax) * 0.5
        XCTAssertNil(ao.raycastEntity(origin: SIMD3(c.x - 2, c.y, c.z), dir: SIMD3(1, 0, 0), maxDist: 5))
    }

    func testRaycastSkipsAttachedEntity() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 1, name: "boat", hp: 10))
        ao.handleMessages(msg(1, propsPacket(pointable: 0)))   // parent won't be hit, isolates the child
        ao.handleRemoveAdd(addPacket(id: 2, name: "item", hp: 1))
        let e = ao.entity(2)!
        let c = e.pos + (e.cbMin + e.cbMax) * 0.5
        XCTAssertEqual(ao.raycastEntity(origin: SIMD3(c.x - 2, c.y, c.z), dir: SIMD3(1, 0, 0), maxDist: 5)?.id, 2,
                       "hittable before it's attached")
        // ATTACH_TO cmd 8: parent, bone, pos(v3f), rot(v3f), forceVisible.
        ao.handleMessages(msg(2, PacketWriter().u8(8).s16(1).string16("")
            .f32(0).f32(0).f32(0).f32(0).f32(0).f32(0).u8(0)))
        XCTAssertNil(ao.raycastEntity(origin: SIMD3(c.x - 2, c.y, c.z), dir: SIMD3(1, 0, 0), maxDist: 5),
                     "an attached child is not pointable")
    }

    func testRaycastUsesSelectionBoxNotCollisionBox() {
        let ao = ActiveObjects()
        ao.handleRemoveAdd(addPacket(id: 7, name: "mob", hp: 10))
        // Selectionbox taller than the collisionbox: a ray above the cb top hits.
        ao.handleMessages(msg(7, propsPacket(cbMin: SIMD3(-0.3, 0, -0.3), cbMax: SIMD3(0.3, 1.0, 0.3),
                                             selMin: SIMD3(-0.3, 0, -0.3), selMax: SIMD3(0.3, 2.0, 0.3))))
        let e = ao.entity(7)!
        let y = e.pos.y + 1.5   // inside selbox (0..2), above collisionbox (0..1)
        XCTAssertNotNil(ao.raycastEntity(origin: SIMD3(e.pos.x - 2, y, e.pos.z), dir: SIMD3(1, 0, 0), maxDist: 5),
                        "the taller selectionbox should be pointable up there")
    }
}

/// #283: children attached to the local player are hidden, like the engine in
/// first person (the mcl_burning fire billboard, our own wieldview item).
extension ActiveObjectsTests {
    func testEntitiesAttachedToTheLocalPlayerAreNotDrawn() {
        let ao = ActiveObjects()
        ao.localPlayerName = "me"
        ao.handleRemoveAdd(addPacket(id: 3, name: "me", isPlayer: true, hp: 20))
        ao.handleRemoveAdd(addPacket(id: 4, name: "mcl_burning:fire", hp: 1))
        ao.handleRemoveAdd(addPacket(id: 5, name: "cow", hp: 10))
        // ATTACH_TO (cmd 8): u16 parent, string16 bone, v3f pos, v3f rot
        let m = PacketWriter().u8(8).u16(3).string16("").f32(0).f32(0).f32(0).f32(0).f32(0).f32(0)
        ao.handleMessages(PacketWriter().u16(4).bytes16(m.data).data)
        let drawn = ao.snapshot().map(\.id).sorted()
        XCTAssertEqual(drawn, [5], "the fire attached to us is hidden; the cow still draws")
    }
}
