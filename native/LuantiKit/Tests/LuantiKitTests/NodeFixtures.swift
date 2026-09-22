import XCTest
import simd
@testable import LuantiKit

/// Builders for a real TOCLIENT_NODEDEF payload (Luanti's ContentFeatures wire
/// format), shared by the parse, mesher and raycast tests.
enum NodeFixtures {

    /// Minimal TileDef: version 6, name, no animation, no flags.
    static func tile(_ w: PacketWriter, _ name: String, hasColor: Bool = false) {
        w.u8(6).string16(name).u8(0).u16(hasColor ? 8 : 0)   // flags: 8 = TILE_FLAG_HAS_COLOR
        if hasColor { w.u8(255).u8(255).u8(255) }
    }

    /// A TileDef with a vertical_frames animation (type 1: aspect_w, aspect_h,
    /// length seconds), for the animated-tile parse test (#137).
    static func tileAnimated(_ w: PacketWriter, _ name: String, secs: Float) {
        w.u8(6).string16(name)
        w.u8(1).u16(1).u16(1).f32(secs)   // vertical_frames, 1:1 aspect, cycle length
        w.u16(0)                          // flags
    }

    /// One aabb in BS units (Luanti serializes node_box corners * BS = *10).
    static func boxBS(_ w: PacketWriter, _ mn: SIMD3<Float>, _ mx: SIMD3<Float>) {
        for v in [mn.x, mn.y, mn.z, mx.x, mx.y, mx.z] { w.f32(v * 10.0) }
    }

    /// SoundSpec::serializeSimple: name, gain, pitch, fade.
    static func sound(_ w: PacketWriter, _ name: String) {
        w.string16(name).f32(1).f32(1).f32(0)
    }

    /// Serialize one ContentFeatures blob. `nodeBox` writes the node_box body
    /// (after version+type); `drawtype` 12 = nodebox.
    static func node(name: String, drawtype: Int, dugSound: String,
                      walkable: Bool = true, rightclickable: Bool = false, pointable: Bool = true,
                      climbable: Bool = false, viscosity: Int = 0, moveResistance: Int = 0,
                      buildableTo: Bool = false,
                      postEffect: (a: Int, r: Int, g: Int, b: Int) = (0, 0, 0, 0), shaded: Bool = false,
                      liquidAlt: (flowing: String, source: String) = ("", ""), liquidRange: Int = 0,
                      connectsTo: [Int] = [], connectSides: Int = 0, mesh: String = "", visualScale: Float = 1,
                      selectionBox: ((PacketWriter) -> Void)? = nil,
                      collisionBox: ((PacketWriter) -> Void)? = nil,
                      animTile: (name: String, secs: Float)? = nil,
                      specialTiles: [String] = [],
                      tiles: [(name: String, hasColor: Bool)]? = nil,   // 6 face tiles (default t.png x6)
                      overlays: [String] = ["", "", "", "", "", ""],    // tiles_overlay
                      alphaBlend: Bool = false,
                      footstepSound: String = "", digPrediction: String = "",
                      lightPropagates: Bool = true, lightSource: Int = 0,
                      nodeBox: (PacketWriter) -> Void) -> Data {
        let w = PacketWriter()
        w.u8(13)                       // ContentFeatures version
        w.string16(name)
        w.u16(0)                       // groups
        w.u8(0)                        // param_type
        w.u8(0)                        // param_type_2
        w.u8(drawtype)
        w.string16(mesh)               // mesh
        w.f32(visualScale)             // visual_scale
        w.u8(6)                                        // tiles
        if let a = animTile { tileAnimated(w, a.name, secs: a.secs); for _ in 1..<6 { tile(w, "t.png") } }
        else if let tiles { for t in tiles { tile(w, t.name, hasColor: t.hasColor) } }
        else { for _ in 0..<6 { tile(w, "t.png") } }
        for o in overlays { tile(w, o) }               // overlay tiles (fixed 6)
        w.u8(specialTiles.count)                       // special tile count
        for s in specialTiles { tile(w, s) }           // tiles_special
        w.u8(255)                      // alpha_legacy
        w.u8(0).u8(0).u8(0)            // color rgb
        w.string16("")                 // palette
        w.u8(0)                        // waving
        w.u8(connectSides)             // connect_sides bitmask (1 top 2 bottom 4 front 8 left 16 back 32 right)
        w.u16(connectsTo.count)        // connects_to count
        for cid in connectsTo { w.u16(cid) }
        w.u8(postEffect.a).u8(postEffect.r).u8(postEffect.g).u8(postEffect.b)   // post_effect argb
        w.u8(0)                        // leveled
        w.u8(lightPropagates ? 1 : 0).u8(lightPropagates ? 1 : 0).u8(lightSource)   // light_propagates, sunlight_propagates, light_source
        w.u8(1).u8(walkable ? 1 : 0).u8(pointable ? 1 : 0)   // is_ground_content, walkable, pointable
        w.u8(1).u8(climbable ? 1 : 0).u8(buildableTo ? 1 : 0).u8(rightclickable ? 1 : 0)   // diggable, climbable, buildable_to, rightclickable
        w.u32(0)                       // damage_per_second
        w.u8(0)                        // liquid_type
        w.string16(liquidAlt.flowing).string16(liquidAlt.source)   // liquid alternatives
        w.u8(viscosity).u8(0).u8(liquidRange)  // viscosity, renewable, range
        w.u8(0).u8(0)                  // drowning, floodable
        nodeBox(w)                     // node_box
        if let selectionBox { selectionBox(w) } else { w.u8(6).u8(0) }   // selection_box (default: regular)
        if let collisionBox { collisionBox(w) } else { w.u8(6).u8(0) }   // collision_box (default: regular)
        sound(w, footstepSound)        // footstep
        sound(w, "")                   // dig
        sound(w, dugSound)             // dug
        w.u8(0).u8(0)                  // legacy_facedir_simple, legacy_wallmounted
        w.string16(digPrediction).u8(0).u8(alphaBlend ? 0 : 2)   // node_dig_prediction, leveled_max, alpha (0 BLEND, 2 OPAQUE)
        w.u8(moveResistance).u8(0)     // move_resistance, liquid_move_physics
        w.u8(shaded ? 1 : 0)           // post_effect_color_shaded
        return w.data
    }

    /// Wrap node blobs into a TOCLIENT_NODEDEF payload (string32 zstd of
    /// version + count + string32(body)), matching parseNodeDef.
    static func nodedefPayload(_ nodes: [(id: Int, blob: Data)]) -> Data {
        let body = PacketWriter()
        for n in nodes { body.u16(n.id).bytes16(n.blob) }
        let inner = PacketWriter()
        inner.u8(1)                    // NodeDef version
        inner.u16(nodes.count)
        inner.bytes32(body.data)       // string32 of the per-node table
        guard let packed = Zstd.compress(inner.data) else { return Data() }
        let outer = PacketWriter()
        outer.bytes32(packed)          // string32 zstd blob
        return outer.data
    }
}
