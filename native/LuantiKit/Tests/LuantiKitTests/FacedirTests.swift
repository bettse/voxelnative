import XCTest
import simd
@testable import LuantiKit

/// rotateFacedir mirrors rotateMeshBy6dFacedir (client/mesh.cpp): every one
/// of the 24 facedirs must be a proper rotation (no mirror, no scale) and they
/// must all differ, or rotated nodeboxes/selection boxes end up inside out.
final class FacedirTests: XCTestCase {
    private func rot(_ fd: UInt8) -> simd_float3x3 {
        simd_float3x3(columns: (WorldMesher.rotateFacedir(SIMD3(1, 0, 0), fd),
                                WorldMesher.rotateFacedir(SIMD3(0, 1, 0), fd),
                                WorldMesher.rotateFacedir(SIMD3(0, 0, 1), fd)))
    }

    func testZeroIsIdentity() {
        XCTAssertEqual(WorldMesher.rotateFacedir(SIMD3(0.25, -0.5, 0.125), 0), SIMD3(0.25, -0.5, 0.125))
    }

    func testAll24AreDistinctProperRotations() {
        var seen: [[Float]] = []
        for fd in UInt8(0)..<24 {
            let m = rot(fd)
            XCTAssertEqual(simd_determinant(m), 1, accuracy: 1e-6, "facedir \(fd) mirrors or scales")
            let c = m.columns
            for a in [c.0, c.1, c.2] { XCTAssertEqual(simd_length(a), 1, accuracy: 1e-6) }
            let flat = [c.0.x, c.0.y, c.0.z, c.1.x, c.1.y, c.1.z, c.2.x, c.2.y, c.2.z]
            XCTAssertFalse(seen.contains(flat), "facedir \(fd) duplicates an earlier one")
            seen.append(flat)
        }
    }

    /// Facedir 1..3 spin about Y only: the up vector never moves.
    func testLowBitsKeepUp() {
        for fd in UInt8(1)...3 {
            XCTAssertEqual(WorldMesher.rotateFacedir(SIMD3(0, 1, 0), fd), SIMD3(0, 1, 0))
        }
    }

    /// meshFacedir: facedir types mask to 5 bits mod 24, 4dir to 2 bits,
    /// wallmounted goes through the table, everything else has no rotation.
    func testMeshFacedirPerParamType2() {
        XCTAssertEqual(WorldMesher.meshFacedir(0b1_0011, 3), 19)     // facedir keeps 5 bits
        XCTAssertEqual(WorldMesher.meshFacedir(0b111_0011, 9), 19)   // colorfacedir drops the colour bits
        XCTAssertEqual(WorldMesher.meshFacedir(31, 3), 7)            // 31 % 24
        XCTAssertEqual(WorldMesher.meshFacedir(0b1111, 13), 3)       // 4dir keeps 2 bits
        XCTAssertEqual(WorldMesher.meshFacedir(23, 1), 0)            // plain param2: no rotation
        // wallmounted_to_facedir (mapnode.cpp): {20, 0, 16+1, 12+3, 8, 4+2, 20+1, 0+1}
        XCTAssertEqual(WorldMesher.meshFacedir(0, 4), 20)     // y+ (ceiling)
        XCTAssertEqual(WorldMesher.meshFacedir(1, 4), 0)      // y- (floor)
        XCTAssertEqual(WorldMesher.meshFacedir(3, 4), 15)     // x-
        XCTAssertEqual(WorldMesher.meshFacedir(0xF9, 10), 0)  // colour bits ignored, dir 1
    }
}

/// cubeTile: the facedir tile permutation for plain cubes. Every facedir
/// must map the 6 world faces onto a permutation of the 6 source tiles (a
/// horizontal log shows rings on the axis ends, bark on the sides), and fd==0 is
/// the identity.
final class CubeTileTests: XCTestCase {
    func testIdentityFacedir() {
        // faces order: +Y=0, -Y=1, +Z=4, -Z=5, +X=2, -X=3 (world face -> source tile).
        XCTAssertEqual(WorldMesher.cubeTile(0, 0), 0)
        XCTAssertEqual(WorldMesher.cubeTile(1, 0), 1)
        XCTAssertEqual(WorldMesher.cubeTile(2, 0), 4)
        XCTAssertEqual(WorldMesher.cubeTile(3, 0), 5)
        XCTAssertEqual(WorldMesher.cubeTile(4, 0), 2)
        XCTAssertEqual(WorldMesher.cubeTile(5, 0), 3)
    }

    func testEveryFacedirIsAPermutation() {
        for fd: UInt8 in 0..<24 {
            let tiles = (0..<6).map { WorldMesher.cubeTile($0, fd) }
            XCTAssertEqual(Set(tiles), Set(0...5), "facedir \(fd) must permute all 6 tiles, got \(tiles)")
        }
    }

    func testSomeFacedirMovesTheTopTile() {
        // At least one facedir tips the node so the top tile (rings, tile 0) is no
        // longer on the +Y world face -- i.e. rotation actually happens.
        let moved = (1..<24).contains { WorldMesher.cubeTile(0, UInt8($0)) != 0 }
        XCTAssertTrue(moved, "no facedir moved the top tile off +Y -- permutation is a no-op")
    }
}
