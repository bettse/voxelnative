import XCTest
@testable import LuantiKit

/// Client-side relight on node changes (#278). The engine relights locally in
/// Map::addNodeAndUpdate and the server does not resend relit blocks to the
/// placer, so a placed torch must light its surroundings on our side.
final class RelightTests: XCTestCase {
    private func registry() -> NodeRegistry {
        let r = NodeRegistry()
        let stone = NodeFixtures.node(name: "t:stone", drawtype: 0, dugSound: "", lightPropagates: false) { w in w.u8(6).u8(0) }
        let torch = NodeFixtures.node(name: "t:torch", drawtype: 7, dugSound: "", walkable: false, lightSource: 12) { w in w.u8(6).u8(0) }
        r.parseNodeDef(NodeFixtures.nodedefPayload([(id: 1, blob: stone), (id: 2, blob: torch)]))
        return r
    }
    private func map(_ r: NodeRegistry) -> WorldMap {
        let m = WorldMap()
        // An air-filled block (setNode into an unloaded block starts as air, light 0).
        m.setNode(SIMD3(0, 0, 0), param0: WorldMap.CONTENT_AIR)
        m.lightInfo = r.lightInfo()
        return m
    }
    private func night(_ m: WorldMap, _ p: SIMD3<Int>) -> Int { Int(m.nodeLight(p) >> 4) }

    func testTorchLightsItsSurroundingsAndRemovalDarkensThem() {
        let r = registry(); let m = map(r)
        let torch = r.id(for: "t:torch")!
        var relit = Set<SIMD3<Int>>()
        m.onRelit = { relit.formUnion($0) }
        m.setNode(SIMD3(8, 8, 8), param0: torch)
        XCTAssertEqual(night(m, SIMD3(8, 8, 8)), 12)
        XCTAssertEqual(night(m, SIMD3(9, 8, 8)), 11)
        XCTAssertEqual(night(m, SIMD3(8, 8, 11)), 9)
        XCTAssertEqual(night(m, SIMD3(8, 8, 8 + 12)), 0, "falls off to nothing 12 nodes away")
        XCTAssertTrue(relit.contains(SIMD3(0, 0, 0)), "the block was reported for remesh")
        m.removeNode(SIMD3(8, 8, 8))
        XCTAssertEqual(night(m, SIMD3(8, 8, 8)), 0)
        XCTAssertEqual(night(m, SIMD3(9, 8, 8)), 0, "unlit again after the torch is dug")
    }

    /// Placing an opaque node in an unlit area changes no light value, so no
    /// block is copied and nothing is reported for remesh (perf review: every
    /// setNode used to dirty 7 blocks and cancel the remesh coalesce).
    func testNoLightChangeReportsNothing() {
        let r = registry(); let m = map(r)
        var fired = 0
        m.onRelit = { _ in fired += 1 }
        m.setNode(SIMD3(4, 4, 4), param0: r.id(for: "t:stone")!)
        XCTAssertEqual(fired, 0)
    }

    /// A light-14 torch relight in an open 3x3x3-block volume must stay well
    /// under a tick (it runs inline on ADDNODE; the old version spent 8-15 ms
    /// in dictionary probes).
    func testTorchRelightIsFast() {
        let r = registry(); let m = map(r)
        for x in -1...1 { for y in -1...1 { for z in -1...1 where !(x == 0 && y == 0 && z == 0) {
            m.setNode(SIMD3(x * 16, y * 16, z * 16), param0: WorldMap.CONTENT_AIR)
        } } }
        let torch = r.id(for: "t:torch")!
        let t0 = Date()
        for i in 0..<10 { m.setNode(SIMD3(8, 8, 8), param0: torch); m.removeNode(SIMD3(8, 8, 8)); _ = i }
        let perOp = Date().timeIntervalSince(t0) / 20
        print("[relight-bench] \(perOp * 1000) ms per place/dig")
        // ~5 ms in a debug build since light_source lights BOTH banks (#323):
        // in this all-dark volume that is two full spreads per op. Release is
        // 5-10x faster, so it is still a fraction of a tick on device.
        XCTAssertLessThan(perOp, 0.008, "a torch relight should take well under a tick (debug build)")
    }

    func testOpaqueNodeBlocksLightAndRemovingItLetsItThrough() {
        let r = registry(); let m = map(r)
        let torch = r.id(for: "t:torch")!, stone = r.id(for: "t:stone")!
        m.setNode(SIMD3(8, 8, 8), param0: torch)
        // A stone next to the torch: it holds no light itself, and the cell
        // beyond it is lit only around the corner (path of 4 -> 12 - 4 = 8).
        m.setNode(SIMD3(9, 8, 8), param0: stone)
        XCTAssertEqual(night(m, SIMD3(9, 8, 8)), 0)
        XCTAssertEqual(night(m, SIMD3(10, 8, 8)), 8)
        m.removeNode(SIMD3(9, 8, 8))
        XCTAssertEqual(night(m, SIMD3(9, 8, 8)), 11)
        XCTAssertEqual(night(m, SIMD3(10, 8, 8)), 10, "straight path again once the stone is gone")
    }

    func testDiggingUpIntoSunlightFillsTheShaft() {
        let r = registry(); let m = WorldMap()
        let stone = r.id(for: "t:stone")!
        // Build without relighting: stone everywhere below y=15, a dark 1-wide
        // shaft at (8, 0..13, 8) capped by stone at y=14, full daylight at y=15.
        for x in 0..<16 { for y in 0..<15 { for z in 0..<16 { m.setNode(SIMD3(x, y, z), param0: stone) } } }
        for y in 0..<14 { m.setNode(SIMD3(8, y, 8), param0: WorldMap.CONTENT_AIR) }
        for x in 0..<16 { for z in 0..<16 { m.setNode(SIMD3(x, 15, z), param0: WorldMap.CONTENT_AIR, param1: 0x0F) } }
        m.lightInfo = r.lightInfo()
        XCTAssertEqual(Int(m.nodeLight(SIMD3(8, 10, 8)) & 0x0F), 0)
        // Dig the cap: 15 pours straight down the shaft, the stone walls stay dark.
        m.removeNode(SIMD3(8, 14, 8))
        XCTAssertEqual(Int(m.nodeLight(SIMD3(8, 14, 8)) & 0x0F), 15)
        XCTAssertEqual(Int(m.nodeLight(SIMD3(8, 10, 8)) & 0x0F), 15, "sunlight keeps 15 going straight down")
        XCTAssertEqual(Int(m.nodeLight(SIMD3(8, 0, 8)) & 0x0F), 15)
        XCTAssertEqual(Int(m.nodeLight(SIMD3(9, 10, 8)) & 0x0F), 0, "opaque wall holds no light")
        // Put the cap back: the shaft goes dark again.
        m.setNode(SIMD3(8, 14, 8), param0: stone)
        XCTAssertEqual(Int(m.nodeLight(SIMD3(8, 10, 8)) & 0x0F), 0)
    }

    /// Snow piling up in daylight (#367): VoxeLibre's ABM set_node()s a snow
    /// layer (light-propagating, sunlight-propagating) onto sunlit ground. The
    /// ADDNODE param1 is whatever the server had; the layer and its neighbours
    /// must end up in full daylight, not a dark cell the smooth lighting would
    /// average into a streak.
    func testSnowLayerLandingInSunlightStaysLit() {
        let r = NodeRegistry()
        let stone = NodeFixtures.node(name: "t:stone", drawtype: 0, dugSound: "", lightPropagates: false) { w in w.u8(6).u8(0) }
        let snow = NodeFixtures.node(name: "t:snow", drawtype: 7, dugSound: "", walkable: false) { w in w.u8(6).u8(0) }
        r.parseNodeDef(NodeFixtures.nodedefPayload([(id: 1, blob: stone), (id: 2, blob: snow)]))
        let m = WorldMap()
        // Ground at y=0..3, open sky (day 15) above.
        for x in 0..<16 { for z in 0..<16 {
            for y in 0..<4 { m.setNode(SIMD3(x, y, z), param0: r.id(for: "t:stone")!) }
            for y in 4..<16 { m.setNode(SIMD3(x, y, z), param0: WorldMap.CONTENT_AIR, param1: 0x0F) }
        } }
        m.lightInfo = r.lightInfo()
        for given: UInt8 in [0x00, 0x0F] {
            m.setNode(SIMD3(8, 4, 8), param0: r.id(for: "t:snow")!, param1: given)
            XCTAssertEqual(Int(m.nodeLight(SIMD3(8, 4, 8)) & 0x0F), 15, "the layer itself (ADDNODE param1 \(given))")
            XCTAssertEqual(Int(m.nodeLight(SIMD3(9, 4, 8)) & 0x0F), 15, "air beside it")
            XCTAssertEqual(Int(m.nodeLight(SIMD3(8, 5, 8)) & 0x0F), 15, "air above it")
            m.removeNode(SIMD3(8, 4, 8))
        }
    }
}
