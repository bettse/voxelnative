import Foundation
import simd

/// Per-frame model geometry (mob meshes already transformed into origin space,
/// same 8-float vertex layout as the world/entity mesh: x,y,z,u,v,layer,shade,light).
final class ModelHandoff {
    private let lock = NSLock()
    private var v: [Float] = []
    private var i: [UInt32] = []
    // Overlay stream: modal UI (keyboard, chat, kogane menu, inventory panel,
    // connection banner) drawn on top of the world with no depth test, so
    // nearby terrain never buries it. Same vertex layout + model texture array.
    private var ov: [Float] = []
    private var oi: [UInt32] = []
    // Translucent entity stream (use_texture_alpha mobs like slimes): drawn
    // after the opaque models, blended, without writing depth.
    private var bv: [Float] = []
    private var bi: [UInt32] = []
    // One generation per stream, bumped only when that stream's bytes change,
    // so the renderer (90Hz vs the ~62.5Hz producer) skips re-uploading
    // unchanged geometry (#163). Separate counters: a walking mob used to
    // force the open inventory panel's overlay to re-upload every tick.
    private var gen = 0, ogen = 0, bgen = 0
    func post(_ verts: [Float], _ indices: [UInt32], overlayVerts: [Float] = [], overlayIndices: [UInt32] = [],
              blendVerts: [Float] = [], blendIndices: [UInt32] = []) {
        lock.lock()
        // Only bump gen when the bytes actually changed, so the 90Hz renderer
        // skips re-uploading identical geometry on idle frames (standing still,
        // no mobs, panel closed). The elementwise compare on the tick thread is
        // far cheaper than the per-frame GPU upload it saves, and identical bytes
        // render identically -- no staleness risk (perf review #1/#5).
        // memcmp, not `!=`: Array's elementwise compare walked ~1 MB of floats
        // per tick on an idle scene (no mob moved, so nothing differed early).
        @inline(__always) func same<T>(_ a: [T], _ b: [T]) -> Bool {
            a.count == b.count && (a.isEmpty || a.withUnsafeBytes { pa in b.withUnsafeBytes { pb in
                memcmp(pa.baseAddress!, pb.baseAddress!, pa.count) == 0 } })
        }
        if !same(verts, v) || !same(indices, i) { v = verts; i = indices; gen &+= 1 }
        if !same(overlayVerts, ov) || !same(overlayIndices, oi) { ov = overlayVerts; oi = overlayIndices; ogen &+= 1 }
        if !same(blendVerts, bv) || !same(blendIndices, bi) { bv = blendVerts; bi = blendIndices; bgen &+= 1 }
        lock.unlock()
    }
    func read() -> (gen: Int, v: [Float], i: [UInt32]) { lock.lock(); defer { lock.unlock() }; return (gen, v, i) }
    func readOverlay() -> (gen: Int, v: [Float], i: [UInt32]) { lock.lock(); defer { lock.unlock() }; return (ogen, ov, oi) }
    func readBlend() -> (gen: Int, v: [Float], i: [UInt32]) { lock.lock(); defer { lock.unlock() }; return (bgen, bv, bi) }
}

/// One full-res model texture, placed into a fixed-size layer of a texture
/// array. `uvScale` maps the model's 0..1 UVs onto the sub-rect it occupies.
struct ModelTexture {
    var name: String
    var rgba: [UInt8]       // ModelTextureHandoff.size^2 * 4, sRGB
    var uvScale: SIMD2<Float>
}

/// An in-place update to one existing layer's pixels (no array reallocation).
struct ModelTexPatch { let index: Int; let rgba: [UInt8] }

/// Thread-safe drop-box for the mob/UI texture set. Rebuilding the whole
/// texture2d_array on every change was the big hitch source (#perf): a chat
/// keystroke, the HUD timer ticking each second, an XP or wield-count digit all
/// just rewrite ONE existing layer, but the old path recopied every layer and
/// made a fresh GPU array on the render thread. So distinguish a `full`
/// (re)build -- only when the layer COUNT changes (a new skin/label/count) --
/// from `patches` that the renderer writes into the existing array in place.
final class ModelTextureHandoff {
    // Layer dimension for every model-texture layer (chat, nametags, HUD text,
    // item icons, crack). 256, not 128: a full line of chat text packed into a
    // 128px square came out with ~5px glyphs that blurred when magnified in the
    // world (the load MOTD/join text); 256 doubles the glyph resolution (#175).
    static let size = 256

    private let lock = NSLock()
    private var fullPending: [ModelTexture]?
    private var patchPending: [Int: [UInt8]] = [:]   // layer index -> latest pixels
    private var _builtCount = 0                       // layers the renderer actually built (acked)

    /// The renderer reports how many layers its array actually has after a full
    /// (re)build. The producer compares this to its layer count and re-posts a
    /// full until they match, so a dropped/failed rebuild (device memory pressure)
    /// self-heals instead of leaving high-index icons sampling out of range (#254).
    func reportBuilt(_ n: Int) { lock.lock(); _builtCount = n; lock.unlock() }
    var builtCount: Int { lock.lock(); defer { lock.unlock() }; return _builtCount }

    /// Queue a full layer set. Patches queued alongside are KEPT, not folded
    /// in: the renderer grows the array in place and uploads only the layers
    /// beyond what it already holds, so a queued edit to an existing layer
    /// must still land as a patch after the grow (folding it into the full
    /// would silently drop it).
    func post(full t: [ModelTexture]) {
        lock.lock(); fullPending = t; lock.unlock()
    }
    /// In-place layer updates, applied by the renderer after any pending full.
    func post(patches: [ModelTexPatch]) {
        lock.lock(); defer { lock.unlock() }
        for p in patches { patchPending[p.index] = p.rgba }
    }
    func take() -> (full: [ModelTexture]?, patches: [ModelTexPatch]) {
        lock.lock(); defer { lock.unlock() }
        let f = fullPending; fullPending = nil
        let p = patchPending.map { ModelTexPatch(index: $0.key, rgba: $0.value) }; patchPending.removeAll()
        return (f, p)
    }
}


/// Six decoded RGBA faces of a SET_SKY "skybox" (the End), tick thread ->
/// renderer, which builds a cube texture from them. An empty post clears
/// the box (the sky went back to regular/plain) (#290).
final class SkyboxHandoff {
    static let size = 256
    private let lock = NSLock()
    private var pending: [[UInt8]]?
    private var clearPending = false
    func post(_ faces: [[UInt8]]) { lock.lock(); pending = faces; clearPending = false; lock.unlock() }
    func postClear() { lock.lock(); pending = nil; clearPending = true; lock.unlock() }
    /// nil = nothing new; .some(nil) = clear; .some(faces) = build.
    func take() -> [[UInt8]]?? {
        lock.lock(); defer { lock.unlock() }
        if let f = pending { pending = nil; return .some(f) }
        if clearPending { clearPending = false; return .some(nil) }
        return nil
    }
}
