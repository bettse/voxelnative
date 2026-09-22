import Foundation
import simd

/// One entity to draw as an upright billboard. Position is node coordinates
/// (feet); width/height in nodes; layer is the atlas layer; light is param1.
struct EntityInstance {
    var pos: SIMD3<Float>
    var width: Float
    var height: Float
    var layer: Float
    var light: Float
    // Packed r + g*256 + b*65536 colour multiplier; white = untinted. Mobs go
    // red here while their PUNCHED hit-flash timer runs (#100).
    var tint: Float = 16777215
    // Head-locked HUD (crosshair, hearts, hunger, breath, hotbar): `pos` is a
    // head-LOCAL offset in a canonical frame (forward -Z, right +X, up +Y),
    // node units. The renderer places it against the current frame's head pose
    // so it doesn't lag the camera (and ghost/double under reprojection) during
    // head motion. World billboards leave this false and use `pos` as a node.
    var headLocal: Bool = false
    // Crosshair: a head-locked instance that must track the TRUE aim (full pitch),
    // not the gravity-stabilised, pitch-capped basis the peripheral HUD uses, so
    // it stays on the raycast's hit block when you look up/down.
    var centered: Bool = false
}

/// Thread-safe drop-box for the current entity list (session -> renderer).
/// Split into world billboards and head-locked HUD at post time (once, on the
/// tick thread) so the renderer doesn't re-filter the whole list twice every
/// frame at 90Hz (#186).
final class EntityHandoff {
    private let lock = NSLock()
    private var worldE: [EntityInstance] = []
    private var hudE: [EntityInstance] = []
    func post(world: [EntityInstance], hud: [EntityInstance]) {
        lock.lock(); worldE = world; hudE = hud; lock.unlock()
    }
    func read() -> (world: [EntityInstance], hud: [EntityInstance]) {
        lock.lock(); defer { lock.unlock() }; return (worldE, hudE)
    }
}
