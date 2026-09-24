import XCTest
import CryptoKit
@testable import LuantiKit

/// Runtime media + batched particles: SPAWN_PARTICLE_BATCH framing,
/// MEDIA_PUSH bookkeeping in MediaManager, and the HAVE_MEDIA ack. Wire
/// layouts mirror clientpackethandler.cpp / particles.cpp / client.cpp.
final class RuntimeMediaTests: XCTestCase {

    /// A serialized ParticleParameters prefix (pos in BS units), optionally
    /// followed by tail bytes we don't parse (vertical, animation, glow, ...).
    private func particleBlob(x: Float, tex: String, tail: Int = 0, accY: Float = 0) -> Data {
        let w = PacketWriter()
        w.f32(x).f32(20).f32(30)            // pos
        w.f32(0).f32(0).f32(0)              // vel
        w.f32(0).f32(accY).f32(0)           // acc (BS units)
        w.f32(1.5).f32(2)                   // expiration, size
        w.u8(0).string32(tex)               // collisiondetection, texture
        for _ in 0..<tail { w.u8(7) }
        return w.data
    }

    func testParticleBatchSpawnsEachBlob() {
        let c = Client(name: "t", password: "")
        var got: [(pos: SIMD3<Float>, acc: SIMD3<Float>, tex: String)] = []
        c.onSpawnParticle = { pos, _, acc, _, _, tex, _, _ in got.append((pos, acc, tex)) }
        let inner = PacketWriter()
        inner.bytes32(particleBlob(x: 10, tex: "a.png", tail: 9, accY: -98))   // tail must not desync the next blob
        inner.bytes32(particleBlob(x: 40, tex: "b.png"))
        let comp = try! XCTUnwrap(Zstd.compress(inner.data))
        c.handleSpawnParticleBatch(PacketWriter().bytes32(comp).data)

        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got[0].pos.x, 10.5, accuracy: 1e-5)  // node units + 0.5 grid shift (no /BS: particles.cpp keeps nodes)
        XCTAssertEqual(got[0].acc.y, -98, accuracy: 1e-5)   // the server's gravity as sent, not a hardcoded one
        XCTAssertEqual(got[0].tex, "a.png")
        XCTAssertEqual(got[1].pos.x, 40.5, accuracy: 1e-5)
        XCTAssertEqual(got[1].acc.y, 0, accuracy: 1e-5)     // a floating particle stays put
        XCTAssertEqual(got[1].tex, "b.png")
    }

    func testCorruptParticleBatchIsIgnored() {
        let c = Client(name: "t", password: "")
        var n = 0
        c.onSpawnParticle = { _, _, _, _, _, _, _, _ in n += 1 }
        c.handleSpawnParticleBatch(PacketWriter().bytes32(Data([1, 2, 3])).data)   // not zstd
        c.handleSpawnParticleBatch(Data([0, 0]))                                     // truncated
        XCTAssertEqual(n, 0)
    }

    func testPushedMediaIsAckedOnceItLands() {
        let m = MediaManager(send: { _, _ in })
        var acked: [(String, [Int])] = []
        m.onPushedReady = { acked.append(($0, $1)) }

        // A fresh sha1 every run: MediaManager caches downloads on disk by sha1,
        // and a hit from a previous run would (correctly) ack straight away.
        let sha = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        m.push(name: "skin.png", sha1Hex: sha, token: 77)
        XCTAssertTrue(m.announced.contains("skin.png"))
        XCTAssertEqual(m.pendingPushTokens("skin.png"), [77])
        m.push(name: "skin.png", sha1Hex: sha, token: 78)   // a second push for the same file merges
        XCTAssertTrue(acked.isEmpty)

        // The file arrives by TOCLIENT_MEDIA (raw bytes; not zstd, which parseMedia tolerates).
        let p = PacketWriter().u16(1).u16(0).u32(1).string16("skin.png").bytes32(Data([9, 9, 9]))
        m.parseMedia(p.data)
        XCTAssertEqual(m.bytes("skin.png"), Data([9, 9, 9]))
        XCTAssertEqual(acked.count, 1)
        XCTAssertEqual(acked.first?.0, "skin.png")
        XCTAssertEqual(acked.first?.1, [77, 78])
        XCTAssertEqual(m.pendingPushTokens("skin.png"), [])
    }

    /// Announce packet (proto >= 48): bytes32 zstd(string16_array names), then
    /// a 20-byte sha1 per name, then string16 remote urls.
    private func announce(_ files: [(String, String)]) -> Data {
        let names = PacketWriter().u32(files.count)
        for (n, _) in files { names.u16(n.utf8.count) }
        for (n, _) in files { names.raw(Data(n.utf8)) }
        let w = PacketWriter().bytes32(Zstd.compress(names.data)!)
        for (_, hex) in files {
            var raw = Data()
            var i = hex.startIndex
            while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); raw.append(UInt8(hex[i..<j], radix: 16)!); i = j }
            w.raw(raw)
        }
        w.string16("")
        return w.data
    }
    private func freshSha() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + "00000000" }

    /// VoxeLibre dynamic_add_media()s its skin base textures on join, and they
    /// are in the announce list too. A push for a file that's already in flight
    /// must NOT re-request it: the server refuses a second request for the same
    /// name and the download stalled forever (cold cache = colour-block world).
    func testSameHashPushMergesIntoTheInflightRequest() {
        var requests: [Data] = []
        let m = MediaManager(send: { op, d in if op == Op.toserverRequestMedia { requests.append(d) } })
        var acked: [(String, [Int])] = []
        m.onPushedReady = { acked.append(($0, $1)) }
        var complete = 0
        m.onComplete = { complete += 1 }
        let sha = freshSha()
        m.parseAnnounce(announce([("skin.png", sha), ("other.png", freshSha())]))
        m.request(["skin.png", "other.png"])
        XCTAssertEqual(requests.count, 1)

        m.push(name: "skin.png", sha1Hex: sha, token: 5)      // identical content, still downloading
        XCTAssertEqual(requests.count, 1, "an identical push must not send a second REQUEST_MEDIA")
        XCTAssertEqual(m.pendingPushTokens("skin.png"), [5])

        let p = PacketWriter().u16(1).u16(0).u32(2)
            .string16("skin.png").bytes32(Data([1])).string16("other.png").bytes32(Data([2]))
        m.parseMedia(p.data)
        XCTAssertEqual(acked.map { $0.0 }, ["skin.png"])
        XCTAssertEqual(complete, 1, "download finishes once every requested file has landed")

        // A push for bytes we already hold acks immediately, no fetch.
        m.push(name: "skin.png", sha1Hex: sha, token: 6)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(acked.last?.1, [6])
    }

    /// The last bunch of a reply is all the server will send: a name it skipped
    /// (unknown, or "requested before") must not keep onComplete from firing.
    func testSkippedFileInLastBunchDoesNotStallTheDownload() {
        let m = MediaManager(send: { _, _ in })
        var complete = 0
        m.onComplete = { complete += 1 }
        m.parseAnnounce(announce([("a.png", freshSha()), ("b.png", freshSha())]))
        m.request(["a.png", "b.png"])
        // bunch 0/2 carries a.png; bunch 1/2 is empty and b.png never comes.
        m.parseMedia(PacketWriter().u16(2).u16(0).u32(1).string16("a.png").bytes32(Data([1])).data)
        XCTAssertEqual(complete, 0)
        m.parseMedia(PacketWriter().u16(2).u16(1).u32(0).data)
        XCTAssertEqual(complete, 1)
        XCTAssertTrue(m.has("a.png")); XCTAssertFalse(m.has("b.png"))
    }

    /// The server's reply usually ends with an EMPTY bunch (it opens a new one
    /// once the byte budget is hit, even after the last file). The next batch
    /// must not be requested until that bunch lands, or its "last bunch" would
    /// be read against the next batch and wrongly skip all of it.
    func testTrailingEmptyBunchDoesNotSkipTheNextBatch() {
        var requests = 0
        let m = MediaManager(send: { op, _ in if op == Op.toserverRequestMedia { requests += 1 } })
        var complete = 0
        m.onComplete = { complete += 1 }
        // 129 files: batch 1 = 128, batch 2 = 1.
        let names = (0..<129).map { "f\($0).png" }
        m.parseAnnounce(announce(names.map { ($0, freshSha()) }))
        m.request(Set(names))
        XCTAssertEqual(requests, 1)
        // Reply 1: bunch 0/2 carries every file of the batch, bunch 1/2 is empty.
        let batch1 = m.outstandingForTesting
        XCTAssertEqual(batch1.count, 128)
        let w = PacketWriter().u16(2).u16(0).u32(128)
        for n in batch1 { w.string16(n).bytes32(Data([1])) }
        m.parseMedia(w.data)
        XCTAssertEqual(requests, 1, "still one reply in flight: wait for its last bunch")
        m.request(["f128.png", "f5.png"])   // the session asking for more in that gap must not jump the queue
        XCTAssertEqual(requests, 1)
        m.parseMedia(PacketWriter().u16(2).u16(1).u32(0).data)
        XCTAssertEqual(requests, 2, "batch 2 goes out once reply 1 is fully in")
        let missing = names.filter { !m.has($0) }
        XCTAssertEqual(missing.count, 1)
        m.parseMedia(PacketWriter().u16(1).u16(0).u32(1).string16(missing[0]).bytes32(Data([2])).data)
        XCTAssertEqual(complete, 1)
        XCTAssertTrue(names.allSatisfy { m.has($0) })
    }

    /// A name still queued in `pending` must not be queued again by a later
    /// request() (the HUD re-requests its icons every tick): the duplicate went
    /// out in a second batch and the server refused it as "requested before".
    func testQueuedNameIsNotRequestedTwice() {
        var batches: [Data] = []
        let m = MediaManager(send: { op, d in if op == Op.toserverRequestMedia { batches.append(d) } })
        let names = (0..<130).map { "q\($0).png" }
        m.parseAnnounce(announce(names.map { ($0, freshSha()) }))
        m.request(Set(names))                 // 128 in flight, 2 pending
        m.request(["q0.png", "q129.png", "q128.png"])
        // Finish batch 1 (one bunch carrying all 128), then batch 2 must hold exactly the 2 leftovers.
        let w = PacketWriter().u16(1).u16(0).u32(128)
        for n in m.outstandingForTesting { w.string16(n).bytes32(Data([1])) }
        m.parseMedia(w.data)
        XCTAssertEqual(batches.count, 2)
        let r = PacketReader(batches[1]); let n = r.u16()
        var second: [String] = []
        for _ in 0..<n { second.append(r.string16()) }
        XCTAssertEqual(n, 2, "batch 2 = the two names that didn't fit, each once: \(second)")
    }

    func testHaveMediaPacketLayout() {
        XCTAssertEqual(Array(Client.haveMediaPacket([77, 5])), [2, 0, 0, 0, 77, 0, 0, 0, 5])
    }

    func testMediaPushModernRegistersFetchAndToken() {
        let c = Client(name: "t", password: "")
        c.protoVer = 40
        let hash = Data(repeating: 0xAB, count: 20)
        c.handleMediaPush(PacketWriter().bytes16(hash).string16("cape.png").u8(1).u32(9).data)
        XCTAssertTrue(c.media.announced.contains("cape.png"))
        XCTAssertEqual(c.media.pendingPushTokens("cape.png"), [9])
        XCTAssertFalse(c.media.has("cape.png"))            // not until TOCLIENT_MEDIA delivers it
    }

    func testMediaPushLegacyInlineVerifiesTheHash() {
        let c = Client(name: "t", password: "")
        c.protoVer = 39
        let file = Data([1, 2, 3, 4, 5])
        let good = Data(Insecure.SHA1.hash(data: file))
        c.handleMediaPush(PacketWriter().bytes16(good).string16("ok.png").u8(0).bytes32(file).data)
        XCTAssertEqual(c.media.bytes("ok.png"), file)

        var bad = good; bad[0] ^= 0xFF
        c.handleMediaPush(PacketWriter().bytes16(bad).string16("bad.png").u8(0).bytes32(file).data)
        XCTAssertFalse(c.media.has("bad.png"))
    }

    func testMediaPushRejectsPathLikeNames() {
        let c = Client(name: "t", password: "")
        c.protoVer = 40
        let hash = Data(repeating: 1, count: 20)
        for name in ["../x.png", "a/b.png", "", "sp ace.png"] {
            c.handleMediaPush(PacketWriter().bytes16(hash).string16(name).u8(1).u32(1).data)
            XCTAssertFalse(c.media.announced.contains(name), name)
        }
        XCTAssertTrue(Client.isSafeMediaName("mob_skin-v2.png"))
    }
}
