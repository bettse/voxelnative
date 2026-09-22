import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
@testable import LuantiKit

/// tiles_overlay + per-tile colour (content_mapblock / mapblock_mesh parity):
/// a grass block's dirt sides carry color="white" (no palette tint on the
/// base) and a tinted grass-fringe overlay drawn as a second quad.
final class OverlayTileTests: XCTestCase {
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

    func testGrassBlockSidesGetAnOverlayQuadAndKeepTheirOwnColour() {
        let side = (name: "dirt.png", hasColor: true)
        let blob = NodeFixtures.node(name: "test:grass_block", drawtype: 0, dugSound: "",
                                     tiles: [("top.png", false), ("dirt.png", false), side, side, side, side],
                                     overlays: ["", "", "fringe.png", "fringe.png", "fringe.png", "fringe.png"]) { w in w.u8(6).u8(0) }
        let reg = NodeRegistry()
        reg.parseNodeDef(NodeFixtures.nodedefPayload([(1, blob)]))
        let id = reg.id(for: "test:grass_block")!
        XCTAssertEqual(reg.overlayTiles(id)?[2], "fringe.png")
        XCTAssertEqual(reg.faceColorOverrides(id), [false, false, true, true, true, true])
        XCTAssertEqual(Set(reg.overlayTilesSnapshot()), ["fringe.png"])

        let media = MediaManager(send: { _, _ in })
        for n in ["top.png", "dirt.png", "fringe.png"] { media.storeForTesting(n, png(1, 2, 3)) }
        let atlas = TextureAtlas()
        atlas.build(nodes: reg, media: media, extraTiles: reg.overlayTilesSnapshot())
        let fringe = atlas.tileLayer("fringe.png")
        XCTAssertNotNil(fringe)

        let map = WorldMap()
        map.setNode(SIMD3(8, 8, 8), param0: id)
        let o = WorldMesher.build(map, atlas: atlas, nodes: reg).opaque
        let quads = o.vertices.count / 9 / 4
        XCTAssertEqual(quads, 10, "6 faces + 4 side overlays")
        XCTAssertEqual(o.cutout.count, 4 * 6, "the overlays go to the cutout stream")
        // Overlay quads sample the fringe layer and sit a hair outside the face.
        var overlayQuads = 0
        for q in 0..<quads {
            let layer = o.vertices[q * 36 + 5]
            if Int32(layer) == fringe {
                overlayQuads += 1
                let x = o.vertices[q * 36]
                XCTAssertTrue(abs(x - 8) < 0.01 || abs(x - 9) < 0.01 || x < 8 || x > 9, "lifted off the face")
            }
        }
        XCTAssertEqual(overlayQuads, 4)
    }
}
