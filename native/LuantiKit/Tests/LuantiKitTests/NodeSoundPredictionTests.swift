import XCTest
@testable import LuantiKit

/// Client parity: NODEDEF carries a sound_footstep and a node_dig_prediction
/// that the client used to parse-and-discard. Footstep sounds play while walking;
/// node_dig_prediction lets a dig show the right resulting node, not always air.
/// Pin that both fields survive the parse and that empty ones stay nil.
final class NodeSoundPredictionTests: XCTestCase {
    func testFootstepAndDigPredictionParsed() {
        let path = NodeFixtures.node(name: "t:grass_path", drawtype: 0, dugSound: "dug_dirt",
                                     footstepSound: "footstep_grass", digPrediction: "mcl_core:dirt") { w in w.u8(6).u8(0) }
        let stone = NodeFixtures.node(name: "t:stone", drawtype: 0, dugSound: "") { w in w.u8(6).u8(0) }
        let reg = NodeRegistry()
        reg.parseNodeDef(NodeFixtures.nodedefPayload([(1, path), (2, stone)]))

        let pid = reg.id(for: "t:grass_path")!
        XCTAssertEqual(reg.footstepSound(pid), "footstep_grass")
        XCTAssertEqual(reg.digPrediction(pid), "mcl_core:dirt")
        // No footstep set records nothing (silence). The prediction string is
        // kept verbatim: the fixture writes "", which the engine treats as
        // "predict nothing" (real servers send the "air" default for normal
        // nodes; VoxeLibre's waterlogged mangrove roots send "").
        let sid = reg.id(for: "t:stone")!
        XCTAssertNil(reg.footstepSound(sid))
        XCTAssertEqual(reg.digPrediction(sid), "")
    }
}
