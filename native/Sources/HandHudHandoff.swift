import Foundation
import simd
import LuantiKit

/// Session -> renderer drop-box for the hand-anchored HUD: the wielded item icon
/// (drawn on the right hand) and the hotbar strip (anchored to the left
/// wrist). Layers index the node texture atlas (same array the entity pass
/// binds); uv scales the item icon's sub-rect within its 128px layer.
struct HandHudState {
    struct Icon { var layer: Int32; var uv: SIMD2<Float>; var wear: Float = 1 }   // wear 0..1 remaining (1 = no bar)
    /// The wielded item, drawn in first person like desktop VoxeLibre: a real
    /// 3D block for node items, or the flat icon extruded into a slab for
    /// tools/craftitems.
    enum Wield {
        case block(faceLayers: [Int32])       // 6 node-atlas layers (+Y,-Y,+X,-X,+Z,-Z)
        case item(layer: Int32, uv: SIMD2<Float>)
        // A mesh-drawtype node (chest, bell, cauldron): its real b3d model,
        // textured with the node's single tile layer, so it doesn't render as a
        // flat cube with the chest texture smeared on every face.
        case mesh(model: B3DLoader.Mesh, layer: Int32)
    }
    var wield: Wield?          // currently-wielded item, or nil (empty hand)
    var digging: Bool = false  // drives the wield dig-swing animation
    // Light byte (low nibble = day/sky, high = night/torch) at the player's eye.
    // The wield item is shaded by this like desktop, instead of forced full-
    // bright: a held torch in a dark cave shouldn't glow white and read as if
    // it lights the area (our client can't do held light; it's server-baked).
    var wieldLight: Float = 255
    // For a .item wield: the icon extruded into a 3D silhouette (desktop-style
    // wieldmesh) so a tool has thickness/shape, not a flat card. nil = flat slab.
    var wieldSilhouette: B3DLoader.Mesh? = nil
    var wieldWear: Float = 1   // remaining durability 0..1 (1 = full / no bar)
    // ITEMDEF wield_scale.x, applied to item (non-block) wields like the
    // engine's wieldmesh scale: VoxeLibre tools are 1.8, shields 2, rods 1.5,
    // so they read at desktop proportions instead of toy-sized.
    var wieldScale: Float = 1
    // Wielded stack count: a baked digit layer in the MODEL texture array
    // (not the node atlas), drawn on the right hand for stackable items >1. -1 =
    // no count (single item or a tool). Items never have both a count and wear.
    var wieldCountLayer: Int32 = -1
    var wieldCountAspect: Float = 1
    var hotbar: [Icon?]        // 9 slots, nil = empty
    var wieldIndex: Int        // 0..8, highlighted slot
    // Atlas cell layers so the wrist strip matches the head-locked hotbar look.
    var slotLayer: Int32
    var selectLayer: Int32
    // Plain-white atlas layer for TINTED fills (wear bars): a tint multiplies the
    // texture, so a bar drawn on the dark slot frame came out black.
    var whiteLayer: Int32 = 0
    // Armor as a wrist gauntlet: points 0..20 and the plate atlas layers,
    // drawn as a band on the left forearm inboard of the hotbar. 0 = hidden.
    var armor: Int = 0
    var armorFullLayer: Int32 = 0
    var armorHalfLayer: Int32 = 0
    var armorEmptyLayer: Int32 = 0
    // The local player's skin in the MODEL texture array, so the right hand
    // draws as the skin's arm like desktop's first-person hand. -1 = no skin
    // yet (plain box). uv scales 0..1 onto the layer; size is the skin in px.
    var skinLayer: Int32 = -1
    var skinUV = SIMD2<Float>(1, 1)
    var skinSize = SIMD2<Float>(64, 64)
}

final class HandHudHandoff {
    private let lock = NSLock()
    private var current = HandHudState(wield: nil, hotbar: [], wieldIndex: 0,
                                       slotLayer: 0, selectLayer: 0)
    func post(_ s: HandHudState) { lock.lock(); current = s; lock.unlock() }
    func read() -> HandHudState { lock.lock(); defer { lock.unlock() }; return current }
}
