import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LuantiKit

/// Per-pixel texture modifiers: [multiply, [hsl, [brighten,
/// [makealpha, [noalpha, [opacity, [invert, [mask, [sheet. Formulas from
/// imagesource.cpp; checked on both the native path (evaluateModifiedFit)
/// and the 16 px node-tile path.
final class PixelModifierTests: XCTestCase {
    /// A w x h straight-alpha PNG from a per-pixel closure, top rows first.
    private func png(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> Data {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let (r, g, b, a) = f(x, y), j = (y * w + x) * 4
            // CG wants premultiplied bytes in; straight in, straight out at 0/255 alpha.
            px[j] = UInt8(Int(r) * Int(a) / 255); px[j+1] = UInt8(Int(g) * Int(a) / 255); px[j+2] = UInt8(Int(b) * Int(a) / 255); px[j+3] = a
        } }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let out = NSMutableData()
        let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, ctx.makeImage()!, nil); CGImageDestinationFinalize(dst)
        return out as Data
    }
    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) -> Data { png(8, 8) { _, _ in (r, g, b, a) } }

    private func media() -> MediaManager {
        let m = MediaManager(send: { _, _ in })
        m.storeForTesting("red.png", solid(255, 0, 0))
        m.storeForTesting("black.png", solid(0, 0, 0))
        m.storeForTesting("clear.png", solid(0, 0, 0, 0))
        m.storeForTesting("halfmask.png", png(8, 8) { x, _ in x < 4 ? (255, 255, 255, 255) : (0, 0, 0, 0) })
        m.storeForTesting("lr.png", png(8, 8) { x, _ in x < 4 ? (255, 0, 0, 255) : (0, 0, 255, 255) })
        m.storeForTesting("tb.png", png(8, 8) { _, y in y < 4 ? (255, 0, 0, 255) : (0, 0, 255, 255) })
        return m
    }
    private func native(_ spec: String, canvas: Int = 8) -> (px: [UInt8], uv: SIMD2<Float>) {
        try! XCTUnwrap(TextureAtlas.evaluateModifiedFit(spec, media: media(), canvas: canvas))
    }
    private func at(_ px: [UInt8], _ x: Int, _ y: Int, w: Int = 8) -> (r: Int, g: Int, b: Int, a: Int) {
        let j = (y * w + x) * 4
        return (Int(px[j]), Int(px[j+1]), Int(px[j+2]), Int(px[j+3]))
    }

    func testMultiplyScalesEachChannel() {
        let p = at(native("red.png^[multiply:#80ff40").px, 3, 3)
        XCTAssertEqual(p.r, 128, accuracy: 1); XCTAssertEqual(p.g, 0); XCTAssertEqual(p.a, 255)
    }

    func testBrightenIsHalfwayToWhite() {
        let k = at(native("black.png^[brighten").px, 1, 1)
        XCTAssertEqual(k.r, 127, accuracy: 1); XCTAssertEqual(k.g, 127, accuracy: 1)
        let r = at(native("red.png^[brighten").px, 1, 1)
        XCTAssertEqual(r.r, 255); XCTAssertEqual(r.b, 127, accuracy: 1)
    }

    func testMakealphaClearsOneColourOnly() {
        XCTAssertEqual(at(native("red.png^[makealpha:255,0,0").px, 2, 2).a, 0)
        XCTAssertEqual(at(native("red.png^[makealpha:0,0,255").px, 2, 2).a, 255)
    }

    func testNoalphaMakesTransparentOpaqueBlack() {
        let p = at(native("clear.png^[noalpha").px, 2, 2)
        XCTAssertEqual(p.a, 255); XCTAssertEqual(p.r, 0)
        // VoxeLibre's beacon beam: blank.png^[noalpha^[colorize:#b8bab9 -> a grey.
        // No ratio + a full-alpha colour = full colorize, so the black
        // becomes exactly #b8bab9, not a half-blend.
        let q = at(native("clear.png^[noalpha^[colorize:#b8bab9").px, 2, 2)
        XCTAssertEqual(q.a, 255); XCTAssertEqual(q.r, 0xb8, accuracy: 2)
    }

    func testOpacityScalesAlphaAndPremultipliedColour() {
        let p = at(native("red.png^[opacity:128").px, 2, 2)
        XCTAssertEqual(p.a, 128, accuracy: 1); XCTAssertEqual(p.r, 128, accuracy: 1)
    }

    func testInvertFlipsOnlyTheNamedChannels() {
        let p = at(native("red.png^[invert:rgb").px, 2, 2)
        XCTAssertEqual(p.r, 0); XCTAssertEqual(p.g, 255); XCTAssertEqual(p.b, 255); XCTAssertEqual(p.a, 255)
        XCTAssertEqual(at(native("red.png^[invert:g").px, 2, 2).r, 255)
    }

    func testHslShiftsHueAndLightness() {
        let g = at(native("red.png^[hsl:120").px, 2, 2)          // red -> green
        XCTAssertEqual(g.r, 0, accuracy: 2); XCTAssertEqual(g.g, 255, accuracy: 2)
        let pink = at(native("red.png^[hsl:0:0:50").px, 2, 2)    // +50% lightness: L 50 -> 75
        XCTAssertEqual(pink.r, 255); XCTAssertEqual(pink.g, 128, accuracy: 2)
        let dark = at(native("red.png^[hsl:0:-100:0").px, 2, 2)  // fully desaturated
        XCTAssertEqual(dark.r, dark.g, accuracy: 1)
    }

    func testMaskKeepsOnlyWhereTheMaskIsWhite() {
        let px = native("red.png^[mask:halfmask.png").px
        XCTAssertEqual(at(px, 1, 4).r, 255); XCTAssertEqual(at(px, 1, 4).a, 255)
        XCTAssertEqual(at(px, 6, 4).a, 0)
    }

    func testSheetCropsOneTile() {
        let s = native("lr.png^[sheet:2x1:1,0")   // right half of a left-red/right-blue image
        XCTAssertEqual(s.uv, SIMD2(0.5, 1))       // 4x8 on an 8 canvas
        XCTAssertEqual(at(s.px, 1, 1).b, 255); XCTAssertEqual(at(s.px, 1, 1).r, 0)
    }

    /// The node-tile path runs the same ops at the atlas tile size (plus [sheet
    /// via the native path). Sampled proportionally so it holds at any tile size.
    func testNodeTilePathAppliesTheSameOps() {
        let atlas = TextureAtlas(), m = media()
        let t = TextureAtlas.tile
        let mult = try! XCTUnwrap(atlas.evaluateTileForTesting("red.png^[multiply:#808080", media: m))
        XCTAssertEqual(at(mult, t / 3, t / 3, w: t).r, 128, accuracy: 1)
        let masked = try! XCTUnwrap(atlas.evaluateTileForTesting("red.png^[mask:halfmask.png", media: m))
        XCTAssertEqual(at(masked, t / 8, t / 2, w: t).a, 255)          // left half opaque
        XCTAssertEqual(at(masked, t - t / 8, t / 2, w: t).a, 0)        // right half masked out
        let sheet = try! XCTUnwrap(atlas.evaluateTileForTesting("lr.png^[sheet:2x1:1,0", media: m))
        XCTAssertEqual(at(sheet, t / 8, t / 8, w: t).b, 255)           // right crop = all blue
    }

    // the 16 px node-tile path used to drop [transform/[resize/[verticalframe/
    // [lowpart, so it now routes those through the native compositor. Sample
    // proportionally so it holds at any tile size.
    func testNodeTileHonorsVerticalframe() {
        let atlas = TextureAtlas(), m = media()
        let t = TextureAtlas.tile
        // tb.png is red-top / blue-bottom; frame 1 of 2 is the bottom -> all blue.
        let f = try! XCTUnwrap(atlas.evaluateTileForTesting("tb.png^[verticalframe:2:1", media: m))
        XCTAssertEqual(at(f, t / 2, t / 4, w: t).b, 255)
        XCTAssertEqual(at(f, t / 2, t / 4, w: t).r, 0)
    }
    func testNodeTileHonorsTransformFlipX() {
        let atlas = TextureAtlas(), m = media()
        let t = TextureAtlas.tile
        // lr.png is red-left / blue-right; FX (flip X) swaps them.
        let f = try! XCTUnwrap(atlas.evaluateTileForTesting("lr.png^[transformFX", media: m))
        XCTAssertEqual(at(f, t / 8, t / 2, w: t).b, 255)          // left is now blue
        XCTAssertEqual(at(f, t - t / 8, t / 2, w: t).r, 255)      // right is now red
    }
    func testNodeTileHonorsResize() {
        let atlas = TextureAtlas(), m = media()
        let t = TextureAtlas.tile
        let f = try! XCTUnwrap(atlas.evaluateTileForTesting("red.png^[resize:16x16", media: m))
        XCTAssertEqual(at(f, t / 2, t / 2, w: t).r, 255)         // still red after rescale
    }
    // colorize with the ratio omitted uses the colour's own alpha, not 128.
    func testColorizeOmittedRatioUsesColorAlpha() {
        // Opaque colour (alpha 255) -> full colorize: opaque red becomes blue.
        let full = at(native("red.png^[colorize:#0000ff").px, 2, 2)
        XCTAssertEqual(full.b, 255); XCTAssertEqual(full.r, 0, accuracy: 1)
        // Half-alpha colour -> ~half blend: red toward blue = purple.
        let half = at(native("red.png^[colorize:#0000ff80").px, 2, 2)
        XCTAssertEqual(half.r, 128, accuracy: 4); XCTAssertEqual(half.b, 128, accuracy: 4)
    }
}
