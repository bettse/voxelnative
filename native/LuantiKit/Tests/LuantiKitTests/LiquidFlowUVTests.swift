import XCTest
import simd
@testable import LuantiKit

/// Flowing-liquid top-surface UV rotation, mirroring the engine's
/// drawLiquidTop: the animated water texture should run in the flow direction
/// derived from the four corner heights.
final class LiquidFlowUVTests: XCTestCase {
    private func approx(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ eps: Float = 1e-4) -> Bool {
        abs(a.x - b.x) < eps && abs(a.y - b.y) < eps
    }

    func testLevelSurfaceDefaultsToPlusX() {
        // A flat top (all corners equal) has no gradient, so the direction falls
        // back to +X and the UVs are left unrotated.
        let dir = WorldMesher.liquidFlowDir(h00: 1, h10: 1, h01: 1, h11: 1)
        XCTAssertTrue(approx(dir, SIMD2(1, 0)))
        let t = SIMD2<Float>(0.25, 0.75)
        XCTAssertTrue(approx(WorldMesher.flowRotUV(t, dir), t))
    }

    func testSlopeTowardsPlusZ() {
        // Higher at low Z (h00,h10) than high Z (h01,h11): liquid slopes down
        // toward +Z, so the direction is +Z with no X component.
        let dir = WorldMesher.liquidFlowDir(h00: 1.0, h10: 1.0, h01: 0.5, h11: 0.5)
        XCTAssertTrue(approx(dir, SIMD2(0, 1)), "got \(dir)")
    }

    func testSlopeTowardsPlusX() {
        // Higher at low X (h00,h01) than high X (h10,h11): slopes down toward +X.
        let dir = WorldMesher.liquidFlowDir(h00: 1.0, h10: 0.5, h01: 1.0, h11: 0.5)
        XCTAssertTrue(approx(dir, SIMD2(1, 0)), "got \(dir)")
    }

    func testDirIsUnitLength() {
        let dir = WorldMesher.liquidFlowDir(h00: 1.0, h10: 0.9, h01: 0.6, h11: 0.4)
        XCTAssertEqual((dir.x * dir.x + dir.y * dir.y).squareRoot(), 1, accuracy: 1e-4)
    }

    func testRotationIsRigidAboutCentre() {
        // The centre UV is fixed and a 90-degree flow (+Z) maps the X axis to Y,
        // matching a quarter turn of the texture.
        let dir = SIMD2<Float>(0, 1)   // pure +Z
        XCTAssertTrue(approx(WorldMesher.flowRotUV(SIMD2(0.5, 0.5), dir), SIMD2(0.5, 0.5)))
        // (1,0.5) is +0.5 along X from centre; a +Z turn sends it to +0.5 along Y.
        XCTAssertTrue(approx(WorldMesher.flowRotUV(SIMD2(1.0, 0.5), dir), SIMD2(0.5, 1.0)))
    }

    /// The per-cell translate keeps the rotated texture continuous: a
    /// point on the shared edge of two neighbouring cells must land on the same
    /// texel (UVs equal modulo 1) whichever cell emits it, for any flow angle.
    func testTranslateMakesNeighbouringCellsSeamless() {
        // Flowing tops use flowBaseUV: u = local z, v = local x.
        func cellUV(_ g: SIMD3<Int>, lx: Float, lz: Float, _ dir: SIMD2<Float>) -> SIMD2<Float> {
            WorldMesher.flowRotUV(WorldMesher.flowBaseUV(SIMD3(lx, 1, lz)), dir) + WorldMesher.flowTranslateUV(g, dir)
        }
        func sameTexel(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool {
            let d = a - b
            return abs(d.x - d.x.rounded()) < 1e-3 && abs(d.y - d.y.rounded()) < 1e-3
        }
        let dirs: [SIMD2<Float>] = [SIMD2(1, 0), SIMD2(0, 1), simd_normalize(SIMD2(1, 0.5)), simd_normalize(SIMD2(-0.3, -1))]
        let g = SIMD3<Int>(37, 4, -12)
        for dir in dirs {
            // +X neighbour shares the x=1 edge of g with its own x=0 edge.
            let a = cellUV(g, lx: 1, lz: 0.3, dir)
            let b = cellUV(g &+ SIMD3(1, 0, 0), lx: 0, lz: 0.3, dir)
            XCTAssertTrue(sameTexel(a, b), "x edge dir=\(dir) a=\(a) b=\(b)")
            // +Z neighbour shares the z=1 edge.
            let c = cellUV(g, lx: 0.7, lz: 1, dir)
            let d = cellUV(g &+ SIMD3(0, 0, 1), lx: 0.7, lz: 0, dir)
            XCTAssertTrue(sameTexel(c, d), "z edge dir=\(dir) c=\(c) d=\(d)")
        }
    }

    /// The animated strip scrolls toward +v. On the surface, +v must point the
    /// way the liquid flows, for each axis: the old u = z, v = 1 - x layout
    /// sent every flow along X uphill (lava "flowing backwards").
    func testScrollDirectionRunsDownhill() {
        func surfaceDirOfTexV(_ dir: SIMD2<Float>) -> SIMD2<Float> {
            // Which world (x, z) direction a step of +v in texture space lands on:
            // sample the UV at the cell centre and at centre + small world offsets.
            let c = WorldMesher.flowRotUV(WorldMesher.flowBaseUV(SIMD3(0.5, 1, 0.5)), dir)
            let px = WorldMesher.flowRotUV(WorldMesher.flowBaseUV(SIMD3(0.6, 1, 0.5)), dir) - c   // +x step
            let pz = WorldMesher.flowRotUV(WorldMesher.flowBaseUV(SIMD3(0.5, 1, 0.6)), dir) - c   // +z step
            // Solve for the world step whose UV delta is (0, +0.1): project.
            return simd_normalize(SIMD2(px.y, pz.y))
        }
        let cases: [(h: (Float, Float, Float, Float), flow: SIMD2<Float>)] = [
            ((1, 0.5, 1, 0.5), SIMD2(1, 0)),    // x0 side high: flows +X
            ((0.5, 1, 0.5, 1), SIMD2(-1, 0)),   // flows -X
            ((1, 1, 0.5, 0.5), SIMD2(0, 1)),    // z0 side high: flows +Z
            ((0.5, 0.5, 1, 1), SIMD2(0, -1)),   // flows -Z
        ]
        for (h, flow) in cases {
            let dir = WorldMesher.liquidFlowDir(h00: h.0, h10: h.1, h01: h.2, h11: h.3)
            XCTAssertTrue(approx(dir, flow), "flow dir \(dir) expected \(flow)")
            let s = surfaceDirOfTexV(dir)
            XCTAssertTrue(approx(s, flow), "texture +v runs along \(s), flow is \(flow)")
        }
    }
}
