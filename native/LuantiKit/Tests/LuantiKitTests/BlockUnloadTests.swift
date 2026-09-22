import XCTest
@testable import LuantiKit

/// Client-side mapblock unloading (#97): WorldMap.expire mirrors the engine's
/// Map::timerUpdate (usage timer + timeout + hard limit), and the evicted
/// positions go out as TOSERVER_DELETEDBLOCKS batched at 255 per packet.
final class BlockUnloadTests: XCTestCase {

    /// Create a mapblock by predicting one node at its origin (setNode makes
    /// the block if it isn't loaded).
    private func addBlock(_ w: WorldMap, _ bp: SIMD3<Int>) {
        w.setNode(bp &* 16, param0: 1)
        XCTAssertNotNil(w.blocks[bp])
    }

    func testFarBlocksAgeOutAndNearOnesDoNot() {
        let w = WorldMap()
        let a = SIMD3(0, 0, 0), b = SIMD3(20, 0, 0)   // b is 20 blocks away, past radius 12
        addBlock(w, a); addBlock(w, b)

        XCTAssertEqual(w.expire(dt: 100, near: a), [])         // under the 600 s timeout
        XCTAssertEqual(w.expire(dt: 501, near: a), [b])        // 601 s unused -> gone
        XCTAssertNotNil(w.blocks[a])
        XCTAssertNil(w.blocks[b])
    }

    // purgeFarBlocks (dimension change / long teleport) uses expire(dt: 1,
    // timeout: 0): out-of-range blocks age past the zero deadline in one call so
    // the place you left doesn't hang in the void, while in-range blocks (usage
    // reset to 0) survive. This is the invariant the transition fix relies on.
    func testTimeoutZeroPurgesFarKeepsNearInOneCall() {
        let w = WorldMap()
        let near = SIMD3(0, 0, 0), far = SIMD3(20, 0, 0)   // far is past radius 12
        addBlock(w, near); addBlock(w, far)
        let gone = w.expire(dt: 1, near: near, radius: 12, timeout: 0)
        XCTAssertEqual(gone, [far])
        XCTAssertNotNil(w.blocks[near])
        XCTAssertNil(w.blocks[far])
    }

    func testUsageResetsWhenThePlayerComesBack() {
        let w = WorldMap()
        let a = SIMD3(0, 0, 0), b = SIMD3(20, 0, 0)
        addBlock(w, a); addBlock(w, b)

        XCTAssertEqual(w.expire(dt: 500, near: a), [])         // b: 500
        XCTAssertEqual(w.expire(dt: 1, near: b), [])           // b reset to 0; a now far: 1
        XCTAssertEqual(w.expire(dt: 599, near: b), [])         // b 599, a 600 (not > 600 yet)
        XCTAssertEqual(w.expire(dt: 1, near: b), [a])          // a 601 -> gone, b 600 stays
        XCTAssertNotNil(w.blocks[b])
    }

    func testHardLimitEvictsLongestUnusedFirst() {
        let w = WorldMap()
        let old = [SIMD3(30, 0, 0), SIMD3(31, 0, 0), SIMD3(32, 0, 0)]
        for p in old { addBlock(w, p) }
        XCTAssertEqual(w.expire(dt: 10, near: .zero, timeout: 1e9), [])   // old batch: usage 10
        let new = [SIMD3(40, 0, 0), SIMD3(41, 0, 0)]
        for p in new { addBlock(w, p) }

        // 5 loaded, limit 3 -> the two oldest go, both from the first batch.
        let gone = w.expire(dt: 1, near: .zero, timeout: 1e9, limit: 3)
        XCTAssertEqual(gone.count, 2)
        XCTAssertTrue(Set(gone).isSubset(of: Set(old)))
        XCTAssertEqual(w.blocks.count, 3)
        for p in new { XCTAssertNotNil(w.blocks[p]) }
    }

    func testHardLimitNeverEvictsBlocksInUse() {
        // Everything is within radius (usage 0), so even over the limit nothing
        // goes: evicting in-use blocks would just make the server resend them.
        let w = WorldMap()
        for x in 0..<4 { addBlock(w, SIMD3(x, 0, 0)) }
        XCTAssertEqual(w.expire(dt: 1, near: .zero, timeout: 1e9, limit: 2), [])
        XCTAssertEqual(w.blocks.count, 4)
    }

    func testDeletedBlocksPacketsBatchAt255() {
        let positions = (0..<300).map { SIMD3($0, 0, -$0) }
        let packets = Client.deletedBlocksPackets(positions)
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0].count, 1 + 6 * 255)
        XCTAssertEqual(packets[1].count, 1 + 6 * 45)

        let r0 = PacketReader(packets[0])
        XCTAssertEqual(r0.u8(), 255)
        XCTAssertEqual(r0.s16(), 0); XCTAssertEqual(r0.s16(), 0); XCTAssertEqual(r0.s16(), 0)

        let r1 = PacketReader(packets[1])
        XCTAssertEqual(r1.u8(), 45)
        XCTAssertEqual(r1.s16(), 255); XCTAssertEqual(r1.s16(), 0); XCTAssertEqual(r1.s16(), -255)
        XCTAssertFalse(r1.overrun)
    }

    func testNothingEvictedSendsNoPackets() {
        XCTAssertEqual(Client.deletedBlocksPackets([]), [])
    }
}
