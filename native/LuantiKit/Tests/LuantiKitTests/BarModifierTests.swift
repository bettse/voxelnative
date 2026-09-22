import XCTest
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LuantiKit

/// The bar-building texture modifiers (#122): [lowpart, [verticalframe,
/// [transform, [resize, as VoxeLibre's boss bars and XP bar use them.
/// Semantics mirror imagesource.cpp. Images are 8 px so the 8 px canvas is 1:1.
final class BarModifierTests: XCTestCase {
    private func png(_ w: Int, _ h: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> Data {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { px[i*4] = r; px[i*4+1] = g; px[i*4+2] = b; px[i*4+3] = 255 }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let out = NSMutableData()
        let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, ctx.makeImage()!, nil); CGImageDestinationFinalize(dst)
        return out as Data
    }
    private func media() -> MediaManager {
        let m = MediaManager(send: { _, _ in })
        m.storeForTesting("red.png", png(8, 8, 255, 0, 0))
        m.storeForTesting("blue.png", png(8, 8, 0, 0, 255))
        return m
    }
    private func render(_ spec: String, canvas: Int = 8) -> (px: [UInt8], uv: SIMD2<Float>) {
        try! XCTUnwrap(TextureAtlas.evaluateModifiedFit(spec, media: media(), canvas: canvas))
    }
    private func rgb(_ px: [UInt8], _ x: Int, _ y: Int, canvas: Int = 8) -> (Int, Int, Int) {
        let j = (y * canvas + x) * 4
        return (Int(px[j]), Int(px[j+1]), Int(px[j+2]))
    }

    func testLowpartOverlaysOnlyTheBottomPercent() {
        let r = render("red.png^[lowpart:50:blue.png")
        XCTAssertEqual(rgb(r.px, 4, 1).0, 255)   // top half untouched: red
        XCTAssertEqual(rgb(r.px, 4, 6).2, 255)   // bottom half: blue
        XCTAssertEqual(rgb(r.px, 4, 6).0, 0)
    }

    func testVerticalFramePicksOneFrameOfAStrip() {
        // A 8x16 strip: red on top, blue below (built with [combine).
        let strip = "[combine:8x16:0,0=red.png:0,8=blue.png"
        let top = render(strip + "^[verticalframe:2:0")
        let bottom = render(strip + "^[verticalframe:2:1")
        XCTAssertEqual(top.uv, SIMD2(1, 1))       // 8x8 result fills the canvas
        XCTAssertEqual(rgb(top.px, 4, 4).0, 255)
        XCTAssertEqual(rgb(bottom.px, 4, 4).2, 255)
    }

    func testTransformR270TurnsABottomFillIntoALeftFill() {
        // Bottom half blue, then rotate clockwise: the fill should sit on the left.
        let r = render("red.png^[lowpart:50:blue.png^[transformR270")
        XCTAssertEqual(rgb(r.px, 1, 4).2, 255)   // left: blue
        XCTAssertEqual(rgb(r.px, 6, 4).0, 255)   // right: red
        // R90 (counter-clockwise) puts it on the right instead.
        let l = render("red.png^[lowpart:50:blue.png^[transformR90")
        XCTAssertEqual(rgb(l.px, 6, 4).2, 255)
        XCTAssertEqual(rgb(l.px, 1, 4).0, 255)
    }

    func testTransformFlipsAndDigits() {
        let fy = render("red.png^[lowpart:50:blue.png^[transformFY")   // bottom fill -> top
        XCTAssertEqual(rgb(fy.px, 4, 1).2, 255)
        let d3 = render("red.png^[lowpart:50:blue.png^[transform3")    // 3 == R270
        XCTAssertEqual(rgb(d3.px, 1, 4).2, 255)
    }

    func testResizeChangesTheAspect() {
        let r = render("red.png^[resize:16x4")                   // 4:1 bar
        XCTAssertEqual(r.uv.x, 1, accuracy: 1e-6)                // fitted to canvas width
        XCTAssertEqual(r.uv.y, 0.25, accuracy: 1e-6)             // a quarter as tall
        XCTAssertEqual(rgb(r.px, 0, 0).0, 255)
    }

    func testGroupedBarRecipeFillsFromTheLeft() {
        // The shape of the mcl_bossbars / XP recipe: fill from the bottom inside
        // a group, rotate clockwise, then resize into a wide bar.
        let r = render("(red.png^[lowpart:50:blue.png^[transformR270)^[resize:16x4")
        XCTAssertEqual(r.uv.y, 0.25, accuracy: 1e-6)             // 16x4 fitted to the 8 px canvas -> 8x2
        XCTAssertEqual(rgb(r.px, 1, 0).2, 255)                   // left: filled (blue)
        XCTAssertEqual(rgb(r.px, 6, 0).0, 255)                   // right: empty (red)
    }
}
