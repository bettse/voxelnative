import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LuantiKit

/// The node atlas is APPEND-ONLY across rebuilds: a tile's layer index, once
/// assigned, never changes for the life of the session. Rebuilding from an
/// empty atlas used to renumber every tile (dictionary order isn't stable),
/// and anything holding an index across the swap -- baked vertex floats,
/// particles, icons -- sampled whatever tile landed in that slot. That one
/// root cause was behind snow drawing as dirt/wheat, nether
/// particles as blocks and wrong chest icons. rebuildAtlas now
/// seeds each new atlas from the previous one; this locks that invariant in
/// at the unit level (the DEBUG tripwire in rebuildAtlas covers it at runtime).
final class AtlasAppendOnlyTests: XCTestCase {
    private func png(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Data {
        let w = 16, h = 16
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) { px[i*4] = r; px[i*4+1] = g; px[i*4+2] = b }
        let cs = CGColorSpaceCreateDeviceRGB()
        let cg: CGImage = px.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        let out = NSMutableData()
        let d = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
        return out as Data
    }

    /// A registry with one cube whose faces are all `tile`; NodeFixtures
    /// hardcodes t.png so we use extraTiles for the named tiles instead.
    private func registry() -> NodeRegistry {
        let r = NodeRegistry()
        let blob = NodeFixtures.node(name: "test:stone", drawtype: 0, dugSound: "") { w in w.u8(6).u8(0) }
        r.parseNodeDef(NodeFixtures.nodedefPayload([(id: 1, blob: blob)]))
        return r
    }

    func testRebuildKeepsEveryPriorIndexAndOnlyAppends() {
        let nodes = registry()
        let media = MediaManager(send: { _, _ in })
        media.storeForTesting("t.png", png(1, 1, 1))
        for i in 0..<20 { media.storeForTesting("a\(i).png", png(UInt8(i), 0, 0)) }

        // Generation 1: twenty extra tiles.
        let a1 = TextureAtlas()
        a1.build(nodes: nodes, media: media, extraTiles: (0..<20).map { "a\($0).png" })
        let gen1 = a1.tileIndexSnapshot
        XCTAssertEqual(gen1.count, 21, "t.png + 20 extras")   // node face tile + extras

        // Generation 2: seeded from 1, ten NEW tiles appended.
        for i in 0..<10 { media.storeForTesting("b\(i).png", png(0, UInt8(i), 0)) }
        let a2 = TextureAtlas()
        a2.seed(from: a1)
        a2.build(nodes: nodes, media: media,
                 extraTiles: (0..<20).map { "a\($0).png" } + (0..<10).map { "b\($0).png" })

        // Every prior tile keeps its exact index.
        for (name, idx) in gen1 {
            XCTAssertEqual(a2.tileLayer(name).map(Int.init), idx, "\(name) moved on rebuild")
        }
        // New tiles landed strictly after the old ones (append, not interleave).
        let maxOld = gen1.values.max()!
        for i in 0..<10 {
            let idx = a2.tileLayer("b\(i).png").map(Int.init)
            XCTAssertNotNil(idx); XCTAssertGreaterThan(idx!, maxOld, "b\(i).png should be appended")
        }
        XCTAssertGreaterThan(a2.layerCount, a1.layerCount)
        // And the prior layers' pixels are byte-identical (seed copies them).
        for (name, idx) in gen1 { XCTAssertEqual(a2.layers[idx], a1.layers[idx], "\(name) pixels changed") }
        // No node face moved, so the caller can skip the full remesh.
        XCTAssertTrue(a2.changedFaceIds.isEmpty, "append-only rebuild must not flag face changes")
    }

    func testNodeFaceIndexChangeIsReportedAndDroppedTileRebakes() {
        let nodes = registry()
        let media = MediaManager(send: { _, _ in })
        // Gen 1: the node's t.png is MISSING, so its faces fall back to a colour layer.
        let a1 = TextureAtlas()
        a1.build(nodes: nodes, media: media)
        XCTAssertTrue(a1.changedFaceIds.contains(1), "first build reports every face as new")
        XCTAssertNil(a1.tileLayer("t.png"))

        // Gen 2: t.png arrives. The face index moves from the colour fallback to
        // the real tile, and ONLY that id is reported changed.
        media.storeForTesting("t.png", png(9, 9, 9))
        let a2 = TextureAtlas(); a2.seed(from: a1); a2.build(nodes: nodes, media: media)
        XCTAssertEqual(a2.changedFaceIds, [1])
        let tIdx = a2.tileLayer("t.png"); XCTAssertNotNil(tIdx)

        // Gen 3: nothing new. No face changes, t.png keeps its index.
        let a3 = TextureAtlas(); a3.seed(from: a2); a3.build(nodes: nodes, media: media)
        XCTAssertTrue(a3.changedFaceIds.isEmpty)
        XCTAssertEqual(a3.tileLayer("t.png"), tIdx)

        // Gen 4: t.png was re-pushed (MEDIA_PUSH). Dropping it from the seed makes
        // build() re-evaluate the pixels; it gets a fresh index and the face is
        // reported changed so the accompanying full remesh covers it.
        media.storeForTesting("t.png", png(200, 200, 200))
        let a4 = TextureAtlas(); a4.seed(from: a3, dropping: ["t.png"]); a4.build(nodes: nodes, media: media)
        XCTAssertEqual(a4.changedFaceIds, [1])
        let newIdx = a4.tileLayer("t.png"); XCTAssertNotNil(newIdx)
        XCTAssertNotEqual(newIdx, tIdx, "re-pushed tile must get a fresh layer, not overwrite the old one")
        XCTAssertEqual(a4.layers[Int(newIdx!)][0], 200, "fresh layer holds the re-pushed pixels")
    }
}
