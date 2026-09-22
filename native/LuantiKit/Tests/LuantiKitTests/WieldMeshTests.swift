import XCTest
import simd
@testable import LuantiKit

/// WieldMesh.extrudeIcon turns an item icon's alpha into a 3D silhouette (front +
/// back + side walls on transparent borders), so a wielded tool has thickness
/// and shape like desktop's wieldmesh, not a flat card.
final class WieldMeshTests: XCTestCase {
    private func faces(_ m: B3DLoader.Mesh) -> Int { m.positions.count / 4 }

    func testSinglePixelIsAClosedBox() {
        // One opaque pixel: front + back + 4 side walls = 6 quads.
        let m = WieldMesh.extrudeIcon(alpha: [true], width: 1, height: 1, thickness: 0.05)
        XCTAssertEqual(faces(m), 6)
        XCTAssertEqual(m.positions.count, 24)
        XCTAssertEqual(m.indices.count, 36)
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for p in m.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        XCTAssertEqual(lo.x, -0.5, accuracy: 1e-6); XCTAssertEqual(hi.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(lo.y, -0.5, accuracy: 1e-6); XCTAssertEqual(hi.y, 0.5, accuracy: 1e-6)
        XCTAssertEqual(lo.z, -0.05, accuracy: 1e-6); XCTAssertEqual(hi.z, 0.05, accuracy: 1e-6)
    }

    func testSharedEdgeBetweenTwoOpaquePixelsHasNoWall() {
        // Two adjacent opaque pixels: the shared vertical edge emits no wall, so
        // each pixel is front + back + 3 outer walls = 5 quads, 10 total.
        let m = WieldMesh.extrudeIcon(alpha: [true, true], width: 2, height: 1)
        XCTAssertEqual(faces(m), 10, "the shared interior edge is not walled")
    }

    func testTransparentPixelsAreSkipped() {
        // A checker leaves 2 opaque pixels, each fully bordered (4 walls) + f/b = 6.
        let m = WieldMesh.extrudeIcon(alpha: [true, false, false, true], width: 2, height: 2)
        XCTAssertEqual(faces(m), 12)
    }

    func testEmptyAlphaIsEmptyMesh() {
        XCTAssertEqual(WieldMesh.extrudeIcon(alpha: [false], width: 1, height: 1).positions.count, 0)
        XCTAssertEqual(WieldMesh.extrudeIcon(alpha: [], width: 0, height: 0).positions.count, 0)
    }

    func testRow0IsTheTopOfTheIcon() {
        // A 1-wide, 2-tall icon opaque only on row 0 (top): its geometry sits in
        // the upper half (y >= 0), confirming row 0 -> +Y.
        let m = WieldMesh.extrudeIcon(alpha: [true, false], width: 1, height: 2)
        let minY = m.positions.map(\.y).min() ?? -1
        XCTAssertEqual(minY, 0.0, accuracy: 1e-6, "top row occupies y in [0, 0.5]")
    }

    func testAlphaGridDownsamplesBySamplingCellCentres() {
        // 4x4 source, only the top-left 2x2 quadrant opaque; downsampled to a 2x2
        // grid each cell samples its centre, so only the top-left cell is opaque.
        var px = [UInt8](repeating: 0, count: 4 * 4 * 4)
        for r in 0..<2 { for c in 0..<2 { px[(r * 4 + c) * 4 + 3] = 255 } }   // TL quadrant alpha 255
        let g = WieldMesh.alphaGrid(rgba: px, width: 4, height: 4, cells: 2)
        XCTAssertEqual(g, [true, false, false, false])
    }

    func testAlphaGridHandlesNonSquareSource() {
        // 4 wide, 2 tall; left half opaque -> a 2x2 grid is opaque on the left column.
        var px = [UInt8](repeating: 0, count: 4 * 2 * 4)
        for r in 0..<2 { for c in 0..<2 { px[(r * 4 + c) * 4 + 3] = 255 } }   // left half
        let g = WieldMesh.alphaGrid(rgba: px, width: 4, height: 2, cells: 2)
        XCTAssertEqual(g, [true, false, true, false])
    }

    func testAlphaGridThresholdsOnAlphaChannel() {
        // 2x2 RGBA: opaque, transparent, opaque, transparent (alpha 255/0).
        var px = [UInt8]()
        for a in [UInt8(255), 0, 255, 0] { px.append(contentsOf: [0, 0, 0, a]) }
        let g = WieldMesh.alphaGrid(rgba: px, width: 2, height: 2, cells: 2)
        XCTAssertEqual(g, [true, false, true, false])
    }
}
