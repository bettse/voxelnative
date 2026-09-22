import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LuantiKit

/// Texture-modifier decode regressions. The cauldron-lava tile (#207) is a
/// grouped verticalframe strip with an overlay:
///   (mcl_core_lava_source_animation.png^[verticalframe:16:0)^cauldron_top.png
/// It was suspected of decoding near-black. It doesn't: the lava frame shows
/// through the top's transparent centre. This locks that in so a future change
/// to the group / verticalframe / overlay path can't silently darken it.
final class TextureModifierTests: XCTestCase {

    /// Encode straight-alpha RGBA pixels (row 0 = top) as PNG bytes.
    private func png(_ px: [UInt8], _ w: Int, _ h: Int) -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var buf = px.enumerated().map { (i, v) -> UInt8 in   // premultiply for the context
            let a = Float(px[(i / 4) * 4 + 3]) / 255.0
            return (i % 4 == 3) ? v : UInt8((Float(v) * a).rounded())
        }
        let cg: CGImage = buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: cs, bitmapInfo: info)!
            return ctx.makeImage()!
        }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func media() -> MediaManager { MediaManager(send: { _, _ in }) }

    func testCauldronLavaTileKeepsLavaVisible() {
        let m = media()

        // 16x256 lava strip: 16 frames, all bright orange (172,27,11).
        var strip = [UInt8](repeating: 0, count: 16 * 256 * 4)
        for i in stride(from: 0, to: strip.count, by: 4) {
            strip[i] = 172; strip[i+1] = 27; strip[i+2] = 11; strip[i+3] = 255
        }
        m.storeForTesting("mcl_core_lava_source_animation.png", png(strip, 16, 256))

        // 16x16 top: opaque grey ring (border), fully transparent centre.
        var top = [UInt8](repeating: 0, count: 16 * 16 * 4)
        for y in 0..<16 { for x in 0..<16 {
            let j = (y * 16 + x) * 4
            let edge = x < 3 || x >= 13 || y < 3 || y >= 13
            if edge { top[j] = 90; top[j+1] = 90; top[j+2] = 90; top[j+3] = 255 }
        } }
        m.storeForTesting("cauldron_top.png", png(top, 16, 16))

        let tile = "(mcl_core_lava_source_animation.png^[verticalframe:16:0)^cauldron_top.png"
        guard let out = TextureAtlas.evaluateModifiedFit(tile, media: m, canvas: 16) else {
            return XCTFail("cauldron lava tile failed to decode")
        }
        // Centre (8,8) is under the top's transparent hole -> must be the lava.
        let c = (8 * 16 + 8) * 4
        let r = Int(out.px[c]), g = Int(out.px[c+1]), b = Int(out.px[c+2]), a = Int(out.px[c+3])
        XCTAssertEqual(a, 255, "centre should be opaque lava")
        XCTAssertGreaterThan(r, 120, "centre red should be bright lava, got \(r)")
        XCTAssertGreaterThan(r, g + b, "centre should read orange/red (r>g+b), got \(r),\(g),\(b)")

        // A border pixel (0,0) is under the opaque ring -> the grey top.
        let e = 0
        XCTAssertEqual(Int(out.px[e]), 90, "border should be the opaque ring colour")
    }

    /// #200: a pure `strip.png^[verticalframe:N:0` pin (flowing lava) must
    /// decode to the bright frame, not near-black. Guards the verticalframe
    /// crop on the modifier path against a regression.
    func testLavaStripVerticalFramePinIsBright() {
        let m = media()
        // 16x1024 strip, 64 frames, all bright orange.
        var strip = [UInt8](repeating: 0, count: 16 * 1024 * 4)
        for i in stride(from: 0, to: strip.count, by: 4) {
            strip[i] = 200; strip[i+1] = 60; strip[i+2] = 20; strip[i+3] = 255
        }
        m.storeForTesting("lava_flow.png", png(strip, 16, 1024))

        guard let out = TextureAtlas.evaluateModifiedFit("lava_flow.png^[verticalframe:64:0", media: m, canvas: 16) else {
            return XCTFail("lava strip pin failed to decode")
        }
        let c = (8 * 16 + 8) * 4
        XCTAssertGreaterThan(Int(out.px[c]), 150, "lava frame should be bright, got \(out.px[c])")
        XCTAssertEqual(Int(out.px[c+3]), 255, "lava frame should be opaque")
    }
}
