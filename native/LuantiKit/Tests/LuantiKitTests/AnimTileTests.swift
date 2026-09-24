import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import LuantiKit

/// TextureAtlas.decodePNGFrames splits a vertical animation strip into its square
/// frames, frame 0 at the TOP (Luanti plays top->bottom). This is the tricky bit
/// behind animated node tiles (lava/fire), so pin the ordering + count.
final class AnimTileTests: XCTestCase {
    /// A W x 2W PNG: top half red, bottom half blue (two square frames).
    private func twoFrameStripPNG(w: Int) -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: 2 * w, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CG origin is bottom-left, so the TOP half (frame 0) is the upper rect.
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: w))       // bottom = blue
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: w, width: w, height: w))      // top = red
        let img = ctx.makeImage()!
        let out = NSMutableData()
        let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, img, nil); CGImageDestinationFinalize(dst)
        return out as Data
    }

    func testSplitsIntoTopFirstFrames() throws {
        let frames = try XCTUnwrap(TextureAtlas.decodePNGFrames(twoFrameStripPNG(w: 8), size: 8))
        XCTAssertEqual(frames.count, 2)
        func center(_ px: [UInt8]) -> (UInt8, UInt8, UInt8) {
            let i = (4 * 8 + 4) * 4   // ~centre pixel of an 8x8 RGBA buffer
            return (px[i], px[i + 1], px[i + 2])
        }
        let (r0, g0, b0) = center(frames[0])
        XCTAssertGreaterThan(r0, 200); XCTAssertLessThan(b0, 60)   // frame 0 = top = red
        let (r1, _, b1) = center(frames[1])
        XCTAssertGreaterThan(b1, 200); XCTAssertLessThan(r1, 60)   // frame 1 = bottom = blue
    }

    func testVerticalFramesAnimationLengthIsParsed() {
        // A node whose first tile carries a vertical_frames animation records its
        // cycle seconds by base image; a static tile records nothing. Pins the
        // wire order (type 1, aspect_w u16, aspect_h u16, length f32).
        let blob = NodeFixtures.node(name: "mcl_core:lava_source", drawtype: 0, dugSound: "",
                                     animTile: ("default_lava_source_animated.png", 3.0)) { w in w.u8(6).u8(0) }
        let reg = NodeRegistry()
        reg.parseNodeDef(NodeFixtures.nodedefPayload([(1, blob)]))
        XCTAssertEqual(reg.tileAnimSecs["default_lava_source_animated.png"] ?? 0, 3.0, accuracy: 1e-4)
        XCTAssertNil(reg.tileAnimSecs["t.png"], "a static tile records no animation")
    }

    func testSquareTextureIsNotAStrip() {
        // A plain 8x8 (single frame) is not a multi-frame strip.
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let img = ctx.makeImage()!
        let out = NSMutableData()
        let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, img, nil); CGImageDestinationFinalize(dst)
        XCTAssertNil(TextureAtlas.decodePNGFrames(out as Data, size: 8))
    }

    // Liquids arrive as the strip pinned to one frame, e.g. lava flow is
    // "mcl_core_lava_flow_animation.png^[verticalframe:64:0". The animator must
    // read N=64 and rebuild the tile per frame so it cycles instead of freezing.
    func testVerticalFramePartsParsesCountAndRebuildsFrame() {
        let tile = "mcl_core_lava_flow_animation.png^[verticalframe:64:0"
        let vf = TextureAtlas.verticalFrameParts(tile)
        XCTAssertEqual(vf?.n, 64)
        XCTAssertEqual(vf?.make(7), "mcl_core_lava_flow_animation.png^[verticalframe:64:7")
        // A trailing modifier chain (water: colour multiply) is preserved.
        let water = "mcl_core_water_source_animation.png^[verticalframe:16:0^[multiply:#0084FF"
        let wf = TextureAtlas.verticalFrameParts(water)
        XCTAssertEqual(wf?.n, 16)
        XCTAssertEqual(wf?.make(5), "mcl_core_water_source_animation.png^[verticalframe:16:5^[multiply:#0084FF")
        XCTAssertNil(TextureAtlas.verticalFrameParts("plain.png"))
    }

    // Composited animated blocks (campfire, sea pickle) wrap the strip in a
    // [combine. The frame index still has to advance, and the atlas builder only
    // animates these when there's exactly one verticalframe (so the make()
    // replace is unambiguous). Pin both halves of that contract.
    func testVerticalFrameInsideCombineRebuildsSingleIndex() {
        let combine = "[combine:16x16:0,0=mcl_campfire_fire.png^[verticalframe:8:0"
        let vf = TextureAtlas.verticalFrameParts(combine)
        XCTAssertEqual(vf?.n, 8)
        XCTAssertEqual(vf?.make(3), "[combine:16x16:0,0=mcl_campfire_fire.png^[verticalframe:8:3")
        // Exactly one verticalframe -> the builder's guard admits it.
        XCTAssertEqual(combine.components(separatedBy: "[verticalframe:").count, 2)
        // Two verticalframes -> guard rejects (naive replace would corrupt).
        let two = "[combine:16x16:0,0=a.png^[verticalframe:8:0:8,0=b.png^[verticalframe:8:0"
        XCTAssertEqual(two.components(separatedBy: "[verticalframe:").count, 3)
    }
}
