import XCTest
@testable import LuantiKit

/// VoxeLibre's ominous (raid captain) banner is a base plus seven
/// `((base^[colorize:C:225)^[mask:pattern])` layers. A stray paren once made the
/// masks silently skip and the whole banner came out black, so compose it from
/// the installed game's real PNGs and check it stays bright. Skips when the game
/// isn't installed on this Mac.
final class BannerCompositeTests: XCTestCase {
    func testOminousBannerComposite() throws {
        let dir = NSString(string: "~/Library/Application Support/minetest/games/mineclone2/textures").expandingTildeInPath
        let fm = FileManager.default
        try XCTSkipUnless(fm.fileExists(atPath: dir + "/mcl_banners_banner_base.png"), "VoxeLibre textures not installed")
        let m = MediaManager(send: { _, _ in })
        let layers: [(String, String)] = [("rhombus", "#114C56"), ("stripe_bottom", "#5B5B5B"), ("stripe_center", "#303030"),
                                          ("stripe_middle", "#000000"), ("half_horizontal", "#5B5B5B"), ("circle", "#5B5B5B"), ("border", "#000000")]
        var files = ["mcl_banners_banner_base.png", "mcl_banners_base_inverted.png", "mcl_banners_base.png"]
        files += layers.map { "mcl_banners_\($0.0).png" }
        for f in files {
            guard let d = fm.contents(atPath: dir + "/" + f) else { XCTFail("missing \(f)"); return }
            m.storeForTesting(f, d)
        }
        var spec = "(mcl_banners_banner_base.png^[mask:mcl_banners_base_inverted.png)^((mcl_banners_banner_base.png^[colorize:#C8C8C8:225)^[mask:mcl_banners_base.png)"
        for (p, c) in layers { spec += "^((mcl_banners_banner_base.png^[colorize:\(c):225)^[mask:mcl_banners_\(p).png)" }
        for canvas in [64, 256] {
            guard let r = TextureAtlas.evaluateModifiedFit(spec, media: m, canvas: canvas) else { XCTFail("no composite at \(canvas)"); return }
            var sum = 0, n = 0, opaque = 0
            for i in stride(from: 0, to: r.px.count, by: 4) where r.px[i+3] > 0 {
                sum += Int(r.px[i]) + Int(r.px[i+1]) + Int(r.px[i+2]); n += 3; opaque += 1
            }
            XCTAssertGreaterThan(opaque, 0)
            XCTAssertGreaterThan(n > 0 ? sum / n : 0, 60, "the composite came out nearly black at canvas \(canvas)")
        }
    }

    /// The banner PREVIEW item icon (crafting guide output of a pattern recipe)
    /// is a [combine whose entries are escaped texture strings. Compose the
    /// real one and check it is not blank.
    func testBannerPreviewIconIsNotBlank() throws {
        let dir = NSString(string: "~/Library/Application Support/minetest/games/mineclone2/textures").expandingTildeInPath
        let fm = FileManager.default
        try XCTSkipUnless(fm.fileExists(atPath: dir + "/mcl_banners_item_base.png"), "VoxeLibre textures not installed")
        let m = MediaManager(send: { _, _ in })
        for f in ["mcl_banners_item_base.png", "mcl_banners_item_overlay.png", "mcl_banners_bricks.png"] {
            guard let d = fm.contents(atPath: dir + "/" + f) else { XCTFail("missing \(f)"); return }
            m.storeForTesting(f, d)
        }
        // mcl_banners/init.lua: base and layer escaped with \^ and \: inside the combine.
        let base = "mcl_banners_item_base.png\\^(mcl_banners_item_overlay.png\\^[colorize\\:#CCCCCC)\\^[resize\\:32x32"
        let layer = "(([combine\\:20x40\\:-2,-2=mcl_banners_bricks.png\\^[resize\\:16x24\\^[colorize\\:#B02E26\\:0.6))"
        let spec = "[combine:32x32:0,0=" + base + ":8,4=" + layer
        let r = try XCTUnwrap(TextureAtlas.evaluateModifiedFit(spec, media: m, canvas: 32))
        var opaque = 0, reddish = 0
        for i in stride(from: 0, to: r.px.count, by: 4) where r.px[i+3] > 0 {
            opaque += 1
            if r.px[i] > r.px[i+2] + 30 { reddish += 1 }
        }
        XCTAssertGreaterThan(opaque, 200, "the preview icon came out blank")
        XCTAssertGreaterThan(reddish, 10, "the colorized pattern layer is missing")
    }
}
