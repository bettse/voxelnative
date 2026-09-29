import XCTest
@testable import LuantiKit

/// Pixel-art layers are stored at 16px and only layers with finer detail at
/// 64px; the split must be lossless for the ones it shrinks.
final class AtlasSplitTests: XCTestCase {
    private func small(_ seed: Int) -> [UInt8] {
        let n = TextureAtlas.smallTile * TextureAtlas.smallTile
        return (0..<n * 4).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed) }
    }

    func testBlownUpPixelArtCompactsLosslessly() {
        let px = small(7)
        let big = TextureAtlas.upscale(px)
        XCTAssertEqual(big.count, TextureAtlas.tile * TextureAtlas.tile * 4)
        XCTAssertEqual(TextureAtlas.compact(big), px)
        XCTAssertEqual(TextureAtlas.shrink(big), px)
    }

    func testFineDetailStaysBig() {
        var big = TextureAtlas.upscale(small(3))
        big[4] &+= 1   // one texel inside a 4x4 cell differs
        XCTAssertNil(TextureAtlas.compact(big))
    }
}
