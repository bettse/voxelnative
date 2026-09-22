import XCTest
import simd
@testable import LuantiKit

/// Flowing-liquid top-surface UV rotation (#329), mirroring the engine's
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
}
