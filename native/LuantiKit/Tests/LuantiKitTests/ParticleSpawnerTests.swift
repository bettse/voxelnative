import XCTest
import simd
@testable import LuantiKit

/// TOCLIENT_ADD_PARTICLESPAWNER (proto >= 42 tweened format). Verifies the
/// leading tweenable ranges parse and land in our grid, and that the trailing
/// fields don't drift the amount/texture.
final class ParticleSpawnerTests: XCTestCase {
    private func tweenV3(_ w: PacketWriter, _ mn: SIMD3<Float>, _ mx: SIMD3<Float>) {
        w.u8(0).u16(0).f32(0)                                  // style, reps, beginning
        for v in [mn.x,mn.y,mn.z] { w.f32(v) }; for v in [mx.x,mx.y,mx.z] { w.f32(v) }; w.f32(0)   // start min/max/bias
        for v in [mn.x,mn.y,mn.z] { w.f32(v) }; for v in [mx.x,mx.y,mx.z] { w.f32(v) }; w.f32(0)   // end (unused)
    }
    private func tweenF(_ w: PacketWriter, _ mn: Float, _ mx: Float) {
        w.u8(0).u16(0).f32(0)
        w.f32(mn).f32(mx).f32(0)
        w.f32(mn).f32(mx).f32(0)
    }

    func testParsesRangesIntoOurGrid() {
        let w = PacketWriter()
        w.u16(50)                       // amount
        w.f32(2.0)                      // time
        tweenV3(w, SIMD3(10, 20, 30), SIMD3(10, 20, 30))   // pos (NODE units on the wire) -> + 0.5 grid shift
        tweenV3(w, SIMD3(-5, 0, 0), SIMD3(5, 0, 0))        // vel
        tweenV3(w, SIMD3(0, -98, 0), SIMD3(0, -98, 0))     // acc
        tweenF(w, 1.0, 3.0)             // exptime
        tweenF(w, 2.0, 4.0)             // size
        w.u8(0)                         // collisiondetection
        w.string32("smoke.png")         // texture
        w.u32(77)                       // server id
        w.u8(0)                         // vertical
        w.u8(1)                         // collision_removal
        w.u16(0)                        // attached id
        // (trailing animation/glow/... omitted; parser stops after attached_id)

        let c = Client(name: "t", password: "")
        var got: Client.ParticleSpawner?
        c.onAddParticleSpawner = { got = $0 }
        c.handleAddParticleSpawner(w.data)
        let sp = try! XCTUnwrap(got)
        XCTAssertEqual(sp.serverId, 77)
        XCTAssertEqual(sp.amount, 50)
        XCTAssertEqual(sp.time, 2.0, accuracy: 1e-4)
        // Node units, not BS: particles.cpp keeps positions in nodes and scales
        // by BS only to render. Dividing here shrank the weather to a tenth.
        XCTAssertEqual(sp.posMin.x, 10.5, accuracy: 1e-4)  // 10 + 0.5
        XCTAssertEqual(sp.posMin.y, 20.5, accuracy: 1e-4)
        XCTAssertEqual(sp.velMin.x, -5, accuracy: 1e-4)
        XCTAssertEqual(sp.velMax.x, 5, accuracy: 1e-4)
        XCTAssertEqual(sp.accMin.y, -98, accuracy: 1e-4)   // drives particle gravity
        XCTAssertEqual(sp.accMax.y, -98, accuracy: 1e-4)
        XCTAssertEqual(sp.expMax, 3.0, accuracy: 1e-4)
        XCTAssertEqual(sp.sizeMin, 2.0, accuracy: 1e-4)
        XCTAssertEqual(sp.texture, "smoke.png")
        XCTAssertTrue(sp.collisionRemoval)
        XCTAssertEqual(sp.attachedId, 0)
    }

    func testSpawnerLookTailParses() {
        // animation (vertical frames 1x8 over 1.6 s), glow 14, node= source.
        let w = PacketWriter()
        w.u16(10).f32(0)
        tweenV3(w, .zero, .zero); tweenV3(w, .zero, .zero); tweenV3(w, .zero, .zero)
        tweenF(w, 1, 1); tweenF(w, 1, 1)
        w.u8(0).string32("mcl_particles_smoke_anim.png").u32(5).u8(1).u8(0).u16(0)
        w.u8(1).u16(1).u16(8).f32(1.6)   // TileAnimation vertical frames
        w.u8(14)                          // glow
        w.u8(0)                           // object_collision
        w.u16(123).u8(0).u8(2)            // node param0/param2/tile
        let c = Client(name: "t", password: "")
        var got: Client.ParticleSpawner?
        c.onAddParticleSpawner = { got = $0 }
        c.handleAddParticleSpawner(w.data)
        let sp = try! XCTUnwrap(got)
        XCTAssertTrue(sp.look.vertical)
        XCTAssertEqual(sp.look.animType, 1)
        XCTAssertEqual(sp.look.animA, 1); XCTAssertEqual(sp.look.animB, 8)
        XCTAssertEqual(sp.look.animLength, 1.6, accuracy: 1e-5)
        XCTAssertEqual(sp.look.glow, 14)
        XCTAssertEqual(sp.look.nodeId, 123); XCTAssertEqual(sp.look.nodeTile, 2)
    }

    func testSpawnerTweenEndsAndRadiusParse() {
        let w = PacketWriter()
        w.u16(4).f32(3)
        // pos start 0..0 -> end 5..5; vel/acc constant; exptime 1..1 -> 2..2; size 1 -> 3
        func tweenV3E(_ mn: SIMD3<Float>, _ mx: SIMD3<Float>, _ emn: SIMD3<Float>, _ emx: SIMD3<Float>) {
            w.u8(0).u16(0).f32(0)
            for v in [mn.x,mn.y,mn.z] { w.f32(v) }; for v in [mx.x,mx.y,mx.z] { w.f32(v) }; w.f32(0)
            for v in [emn.x,emn.y,emn.z] { w.f32(v) }; for v in [emx.x,emx.y,emx.z] { w.f32(v) }; w.f32(0)
        }
        func tweenFE(_ mn: Float, _ mx: Float, _ emn: Float, _ emx: Float) {
            w.u8(0).u16(0).f32(0); w.f32(mn).f32(mx).f32(0); w.f32(emn).f32(emx).f32(0)
        }
        tweenV3E(.zero, .zero, SIMD3(5, 5, 5), SIMD3(5, 5, 5))
        tweenV3(w, .zero, .zero); tweenV3(w, .zero, .zero)
        tweenFE(1, 1, 2, 2); tweenFE(1, 1, 3, 3)
        w.u8(0).string32("cloud.png").u32(9).u8(0).u8(0).u16(0)
        w.u8(0).u8(0).u8(0)              // animation none, glow, object_collision
        w.u16(0).u8(0).u8(0)             // node
        // 5.6+ tail: texture tweens, drag, jitter, bounce, attractor none, radius
        w.u8(0)                                              // flags
        w.u8(0).u16(0).f32(0).f32(1).f32(0.2)                // alpha 1 -> 0.2
        w.u8(0).u16(0).f32(0).f32(1).f32(1).f32(2).f32(2)    // scale 1 -> 2
        tweenV3(w, SIMD3(0.5, 0.5, 0.5), SIMD3(0.5, 0.5, 0.5))   // drag
        tweenV3(w, .zero, .zero)                                  // jitter
        tweenF(w, 0, 0)                                           // bounce
        w.u8(0)                                                   // attractor none
        tweenV3(w, SIMD3(2, 1, 2), SIMD3(2, 1, 2))               // radius
        let c = Client(name: "t", password: "")
        var got: Client.ParticleSpawner?
        c.onAddParticleSpawner = { got = $0 }
        c.handleAddParticleSpawner(w.data)
        let sp = try! XCTUnwrap(got)
        XCTAssertEqual(sp.posMinEnd?.x ?? -1, 5.5, accuracy: 1e-4)   // + grid shift
        XCTAssertEqual(sp.expMaxEnd ?? -1, 2, accuracy: 1e-4)
        XCTAssertEqual(sp.sizeMinEnd ?? -1, 3, accuracy: 1e-4)
        XCTAssertEqual(sp.radiusMax.x, 2, accuracy: 1e-4)
        XCTAssertEqual(sp.radiusMax.y, 1, accuracy: 1e-4)
        XCTAssertEqual(sp.look.drag.x, 0.5, accuracy: 1e-4)
        XCTAssertEqual(sp.look.alphaEnd, 0.2, accuracy: 1e-4)
        XCTAssertEqual(sp.look.scaleEnd.x, 2, accuracy: 1e-4)
    }

    func testOneShotParticleLookParses() {
        // ParticleParameters::deSerialize: core, then vertical/removal/animation/glow/object_collision/node.
        let w = PacketWriter()
        for _ in 0..<9 { w.f32(0) }      // pos, vel, acc
        w.f32(2).f32(1).u8(1).string32("dust.png")
        w.u8(0).u8(1)                    // vertical, collision_removal
        w.u8(2).u8(4).u8(2).f32(0.1)     // sheet 4x2, 0.1 s per frame
        w.u8(7).u8(0)                    // glow, object_collision
        w.u16(42).u8(0).u8(0)            // node
        let c = Client(name: "t", password: "")
        var got: Client.ParticleLook?
        c.onSpawnParticle = { _, _, _, _, _, _, _, look in got = look }
        c.handleSpawnParticle(w.data)
        let look = try! XCTUnwrap(got)
        XCTAssertTrue(look.collisionRemoval)
        XCTAssertEqual(look.animType, 2); XCTAssertEqual(look.animA, 4); XCTAssertEqual(look.animB, 2)
        XCTAssertEqual(look.glow, 7)
        XCTAssertEqual(look.nodeId, 42)
    }

    func testDeleteReportsId() {
        let c = Client(name: "t", password: "")
        var deleted: Int?
        c.onDeleteParticleSpawner = { deleted = $0 }
        c.handleDeleteParticleSpawner(PacketWriter().u32(123).data)
        XCTAssertEqual(deleted, 123)
    }

    func testLegacyPreProto42Layout() {
        // Pre-42: after amount+time, each parameter is just min then max (no
        // style/reps/beginning/bias/end). v3f min+max = 24B, f32 min+max = 8B.
        let w = PacketWriter()
        w.u16(20)                        // amount
        w.f32(0)                         // time (infinite)
        for v in [10,20,30,10,20,30] { w.f32(Float(v)) }   // pos min/max (BS)
        for v in [-5,0,0,5,0,0] { w.f32(Float(v)) }        // vel min/max
        for v in [0,-98,0,0,-98,0] { w.f32(Float(v)) }     // acc min/max
        w.f32(1).f32(3)                  // exptime min/max
        w.f32(2).f32(4)                  // size min/max
        w.u8(0)                          // collisiondetection
        w.string32("smoke.png")
        w.u32(9)                         // server id
        w.u8(0)                          // vertical
        w.u8(0)                          // collision_removal
        w.u16(0)                         // attached id
        let c = Client(name: "t", password: "")
        c.protoVer = 39
        var got: Client.ParticleSpawner?
        c.onAddParticleSpawner = { got = $0 }
        c.handleAddParticleSpawner(w.data)
        let sp = try! XCTUnwrap(got)
        XCTAssertEqual(sp.serverId, 9)
        XCTAssertEqual(sp.amount, 20)
        XCTAssertEqual(sp.time, 0, accuracy: 1e-4)
        XCTAssertEqual(sp.posMin.x, 10.5, accuracy: 1e-4)  // 10 + 0.5 (world-anchored, node units)
        XCTAssertEqual(sp.velMax.x, 5, accuracy: 1e-4)
        XCTAssertEqual(sp.expMax, 3.0, accuracy: 1e-4)
        XCTAssertEqual(sp.texture, "smoke.png")
    }

    /// node= unset arrives as CONTENT_IGNORE (127); only other ids are node
    /// particles (particles.cpp tests != CONTENT_IGNORE). Treating 127 as a node
    /// dropped every VoxeLibre weather flake, since IGNORE has no tiles.
    func testUnsetNodeIsNotANodeParticle() {
        var look = Client.ParticleLook()
        XCTAssertFalse(look.isNodeParticle)
        look.nodeId = 127
        XCTAssertFalse(look.isNodeParticle)
        look.nodeId = 0
        XCTAssertTrue(look.isNodeParticle)
    }
}
