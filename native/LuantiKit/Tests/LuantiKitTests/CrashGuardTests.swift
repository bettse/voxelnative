import XCTest
@testable import LuantiKit

/// Truncated or malformed packets from a buggy / version-mismatched server must
/// be dropped, not crash the client, mirroring the engine's own tolerance in
/// its deserialize paths. These lock in the code-review crash guards (WorldMap
/// block decode, ANNOUNCE_MEDIA).
final class CrashGuardTests: XCTestCase {
    private let n = WorldMap.NODES_PER_BLOCK

    /// A BLOCKDATA stream that ends after param0 (no param1/param2) must be
    /// dropped: storing it would leave 0-length param arrays that the next
    /// light/param2/mesh read indexes up to 4095 into (a crash).
    func testBlockTruncatedAfterParam0IsDropped() {
        let inner = PacketWriter()
        inner.u8(0x02)                 // flags (not-air)
        inner.u16(0xFFFF)              // lighting_complete
        inner.u8(2).u8(2)              // content_width, params_width
        for _ in 0..<n { inner.u16(42) }   // param0 only, then the stream ends
        let w = PacketWriter()
        w.s16(1).s16(2).s16(3)
        w.raw(Zstd.compress(inner.data)!)
        w.u8(2)                        // serializeNetworkSpecific

        let world = WorldMap()
        XCTAssertNil(world.decodeBlockData(w.data), "a block missing param1/param2 is rejected")
        // Nothing was stored, so the node stays unloaded (not a garbage read).
        XCTAssertEqual(world.nodeId(SIMD3(16, 32, 48)), WorldMap.CONTENT_IGNORE)
    }

    /// A full, well-formed block still decodes (guards don't reject valid data).
    func testCompleteBlockStillDecodes() {
        let inner = PacketWriter()
        inner.u8(0x02); inner.u16(0xFFFF); inner.u8(2).u8(2)
        for _ in 0..<n { inner.u16(42) }
        for _ in 0..<n { inner.u8(0) }     // param1
        for _ in 0..<n { inner.u8(0) }     // param2
        inner.raw(Data([0]))               // NodeMetadataList version 0 = none
        let w = PacketWriter()
        w.s16(0).s16(0).s16(0)
        w.raw(Zstd.compress(inner.data)!)
        w.u8(2)
        let world = WorldMap()
        XCTAssertEqual(world.decodeBlockData(w.data), .zero)
        XCTAssertEqual(world.nodeId(.zero), 42)
    }

    /// ANNOUNCE_MEDIA declaring an enormous name count must not be trusted into a
    /// multi-GB reserveCapacity: the count can't exceed half the decompressed
    /// buffer (each name needs at least its 2-byte length), so it's clamped and
    /// the announce is dropped rather than crashing.
    func testAnnounceMediaHugeCountIsClamped() {
        let names = PacketWriter()
        names.u32(0x40000000)          // ~1 billion names, in a 4-byte buffer
        let payload = PacketWriter()
        payload.bytes32(Zstd.compress(names.data)!)   // no sha1s / urls follow
        let m = MediaManager(send: { _, _ in })
        m.parseAnnounce(payload.data)   // must return, not allocate 8GB / crash
        XCTAssertTrue(m.announced.isEmpty, "a bogus announce registers no media")
    }

    /// The x position (BS*1000) the client would send, decoded out of an INTERACT
    /// packet's trailing PLAYERPOS block.
    private func sentPosX(_ c: Client) -> Int {
        let r = PacketReader(c.interactPacket(action: 5, under: nil, above: nil))
        _ = r.u8(); _ = r.u16(); _ = r.bytes32()   // action, wield, PointedThing
        return r.s32()                              // position.x
    }

    /// A MOVE_PLAYER carrying a non-finite coord must be dropped, not stored:
    /// otherwise Int(spawn.x * 1000) traps when the next PLAYERPOS is built.
    func testMovePlayerNonFiniteCoordIsDropped() {
        let c = Client(name: "t", password: "")
        let valid = PacketWriter()
        valid.f32(100).f32(200).f32(-300).f32(0).f32(0)   // x=100 BS -> 10 nodes
        c.handleMovePlayer(valid.data)
        let good = sentPosX(c)
        XCTAssertEqual(good, 10_000, "valid spawn is applied (10 nodes * 1000)")

        // Now a NaN x: dropped, so the last good spawn stays, and building the
        // pos packet doesn't trap.
        let bad = PacketWriter()
        bad.f32(.nan).f32(0).f32(0).f32(0).f32(0)
        c.handleMovePlayer(bad.data)
        XCTAssertEqual(sentPosX(c), good, "the NaN MOVE_PLAYER left spawn untouched")

        // ...and an infinite one, same story.
        let inf = PacketWriter()
        inf.f32(.infinity).f32(0).f32(0).f32(0).f32(0)
        c.handleMovePlayer(inf.data)
        XCTAssertEqual(sentPosX(c), good, "the Inf MOVE_PLAYER left spawn untouched")
    }

    /// A well-formed announce of one file still parses (the clamp isn't too tight).
    func testAnnounceMediaValidStillParses() {
        let names = PacketWriter()
        names.u32(1)                   // one name
        let nm = Data("a.png".utf8)
        names.u16(nm.count); names.raw(nm)
        let payload = PacketWriter()
        payload.bytes32(Zstd.compress(names.data)!)
        payload.raw(Data(repeating: 0xAB, count: 20))   // its 20-byte sha1
        let m = MediaManager(send: { _, _ in })
        m.parseAnnounce(payload.data)
        XCTAssertEqual(m.announced, ["a.png"])
    }
}
