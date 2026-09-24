import Foundation
import Metal
import LuantiKit

/// Thread-safe drop-box for the streamed world mesh. The background mesher posts
/// raw vertex/index arrays; this builds the Metal buffers ON THAT background
/// thread (MTLDevice is thread-safe) so the render thread only swaps pointers.
/// Building buffers inside the render loop used to hitch frames.
///
/// The world is kept PER MAPBLOCK: a dig/place re-meshes only the handful
/// of touched blocks and posts them as a delta, instead of re-concatenating and
/// re-uploading every loaded block's geometry into one giant buffer on every
/// edit. The renderer keeps its own block->buffers dict and draws one indexed
/// call per block per pass.
final class MeshHandoff {
    struct GPUMesh { let vertices: MTLBuffer; let indices: MTLBuffer; let indexCount: Int }
    // One block's GPU geometry: a shared opaque vertex buffer with solid+cutout
    // index streams, plus an optional liquid mesh. Any field may be nil
    // (an all-air or all-solid-interior block has no faces of that kind).
    struct BlockGPU {
        let opaqueVerts: MTLBuffer?
        let solid: (buffer: MTLBuffer, count: Int)?
        let cutout: (buffer: MTLBuffer, count: Int)?
        let liquid: GPUMesh?
    }
    // One block's raw geometry as the mesher produced it (CPU side); built into
    // a BlockGPU here on the background queue.
    struct BlockRaw {
        var ov: [Float]; var solid: [UInt32]; var cutout: [UInt32]
        var lv: [Float]; var li: [UInt32]
    }
    // A batch of changes for the renderer to fold into its block dict. `reset`
    // means "drop every block first" (the atlas grew, so every block was
    // re-meshed against new layer indices). `atlas` non-nil only when it grew,
    // so mesh + atlas swap in the same frame.
    struct Delta {
        var changed: [SIMD3<Int>: BlockGPU] = [:]
        var removed: Set<SIMD3<Int>> = []
        var reset = false
        var atlas: MTLTexture? = nil
        var animated: [TextureAtlas.AnimLayer] = []
        var hasOpaque = false   // any changed block carries solid/cutout geometry (world-ready gate)
    }

    /// Set once by the renderer at init; the mesher needs it to build buffers.
    private let deviceLock = NSLock()
    private var _device: MTLDevice?
    var device: MTLDevice? {
        get { deviceLock.lock(); defer { deviceLock.unlock() }; return _device }
        set { deviceLock.lock(); _device = newValue; deviceLock.unlock() }
    }

    private let lock = NSLock()
    private var pending = Delta()
    private var hasPending = false

    private func makeMesh(_ device: MTLDevice, _ verts: [Float], _ indices: [UInt32]) -> GPUMesh? {
        guard !indices.isEmpty, !verts.isEmpty else { return nil }
        guard let vb = device.makeBuffer(bytes: verts, length: verts.count * 4, options: [.storageModeShared]),
              let ib = device.makeBuffer(bytes: indices, length: indices.count * 4, options: [.storageModeShared])
        else { return nil }
        return GPUMesh(vertices: vb, indices: ib, indexCount: indices.count)
    }

    // The node texture array is kept and grown in place: the atlas is
    // append-only, so a rebuild usually just adds layers, and re-creating a
    // ~1400-slice array and re-uploading every slice (~23 MB) per generation
    // stalled the mesher queue behind it. Existing slices are re-uploaded only
    // when their pixels changed, detected by buffer identity: the atlas seeds
    // each build from the previous layer arrays (copy-on-write shares storage),
    // and `uploadedLayers` retains those arrays, so an unchanged layer still has
    // the same base address and a changed one had to be copied to a new one.
    // A changed slice is patched while the renderer may still be sampling the
    // old bytes; that's a one-frame tear on a tile that just got its real
    // texture, which beats a full re-upload every generation.
    private var atlasTex: MTLTexture?
    private var uploadedLayers: [[UInt8]] = []
    private static let atlasHeadroom = 64

    /// Build (or grow) the node texture array from raw layers (sRGB), on the
    /// mesher thread. Returns the texture to post; nil if nothing to draw.
    private func makeAtlas(_ device: MTLDevice, _ layersIn: [[UInt8]]) -> MTLTexture? {
        guard !layersIn.isEmpty else { return nil }
        // 2048 slices is the hard cap; a longer array aborts inside Metal.
        // Truncate (later tiles draw as whatever slice the sampler clamps to)
        // rather than take the whole app down.
        var layers = layersIn
        if layers.count > WorldSession.maxTextureLayers {
            print("[tex] node atlas has \(layers.count) layers, truncating to \(WorldSession.maxTextureLayers)"); fflush(stdout)
            layers.removeLast(layers.count - WorldSession.maxTextureLayers)
        }
        // Must match the canvas the atlas bakes into (TextureAtlas.tile).
        let edge = TextureAtlas.tile, need = edge * edge * 4
        var tex: MTLTexture
        var reused = false
        if let t = atlasTex, t.arrayLength >= layers.count {
            tex = t; reused = true
        } else {
            let d = MTLTextureDescriptor()
            d.textureType = .type2DArray
            d.pixelFormat = .rgba8Unorm_srgb
            d.width = edge; d.height = edge
            d.arrayLength = min(WorldSession.maxTextureLayers,
                                (layers.count + Self.atlasHeadroom - 1) / Self.atlasHeadroom * Self.atlasHeadroom + Self.atlasHeadroom)
            d.mipmapLevelCount = TileMips.levelCount(edge: edge)   // trilinear minification (see worldSampler)
            d.usage = .shaderRead
            guard let t = device.makeTexture(descriptor: d) else { return nil }
            tex = t
            uploadedLayers.removeAll(keepingCapacity: true)
        }
        @inline(__always) func sameStorage(_ a: [UInt8], _ b: [UInt8]) -> Bool {
            a.count == b.count && a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in pa.baseAddress == pb.baseAddress } }
        }
        var uploaded = 0
        for (i, px) in layers.enumerated() where px.count == need {
            if reused, i < uploadedLayers.count, sameStorage(uploadedLayers[i], px) { continue }
            TileMips.upload(tex, slice: i, px: px, edge: edge)
            uploaded += 1
        }
        print("[tex] node atlas \(reused ? "grown" : "created") \(layers.count)/\(tex.arrayLength) slices, uploaded \(uploaded)"); fflush(stdout)
        atlasTex = tex
        uploadedLayers = layers
        return tex
    }

    /// Called on the mesher's background queue. Builds one GPU buffer set per
    /// changed block and coalesces into the pending delta (so two remeshes
    /// between two renders don't lose the first's changes). `atlasLayers` non-nil
    /// only when the atlas grew. Returns false if no device yet (keep dirty).
    @discardableResult
    func postDelta(changed: [SIMD3<Int>: BlockRaw], removed: [SIMD3<Int>], reset: Bool,
                   atlasLayers: [[UInt8]]? = nil, animated: [TextureAtlas.AnimLayer] = []) -> Bool {
        guard let device = device else { return false }
        func idxBuf(_ a: [UInt32]) -> (buffer: MTLBuffer, count: Int)? {
            guard !a.isEmpty, let b = device.makeBuffer(bytes: a, length: a.count * 4, options: [.storageModeShared]) else { return nil }
            return (b, a.count)
        }
        var built: [SIMD3<Int>: BlockGPU] = [:]
        built.reserveCapacity(changed.count)
        var anyOpaque = false
        for (bp, r) in changed {
            let ov: MTLBuffer? = r.ov.isEmpty ? nil
                : device.makeBuffer(bytes: r.ov, length: r.ov.count * 4, options: [.storageModeShared])
            let solid = idxBuf(r.solid), cutout = idxBuf(r.cutout)
            if solid != nil || cutout != nil { anyOpaque = true }
            built[bp] = BlockGPU(opaqueVerts: ov, solid: solid, cutout: cutout,
                                 liquid: makeMesh(device, r.lv, r.li))
        }
        let a = atlasLayers.flatMap { makeAtlas(device, $0) }
        lock.lock()
        if reset { pending = Delta(); pending.reset = true }
        for bp in removed { pending.changed[bp] = nil; if !pending.reset { pending.removed.insert(bp) } }
        for (bp, g) in built { pending.changed[bp] = g; pending.removed.remove(bp) }
        if anyOpaque { pending.hasOpaque = true }
        if let a = a { pending.atlas = a; pending.animated = animated }
        hasPending = true
        lock.unlock()
        return true
    }

    func take() -> Delta? {
        lock.lock(); defer { lock.unlock() }
        guard hasPending else { return nil }
        let p = pending; pending = Delta(); hasPending = false; return p
    }
}

/// Mip chain for one premultiplied RGBA node tile (64 -> 32 -> ... -> 1),
/// built on the CPU so a slice can be uploaded level by level and the atlas
/// keeps its append-only, grow-in-place upload path (no blit encoder, no
/// generateMipmaps over the whole array each time it grows).
enum TileMips {
    static func levelCount(edge: Int) -> Int { Int(log2(Double(edge))) + 1 }

    /// Levels 1..n for a `edge` x `edge` tile (level 0 is `px` itself).
    /// Premultiplied colour averages correctly with a plain box filter. For
    /// cutout tiles (leaves, plants: some texels above the 0.5 alpha test,
    /// some below) each level is rescaled so the same FRACTION of texels
    /// passes the test as at level 0, or foliage thins to nothing a few
    /// nodes out. rgb scales with alpha so the un-premultiplied colour the
    /// shader sees is unchanged.
    static func chain(_ px: [UInt8], edge: Int) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var cur = px, e = edge
        var cover0 = 0
        for i in stride(from: 3, to: px.count, by: 4) where px[i] >= 128 { cover0 += 1 }
        let coverage = Double(cover0) / Double(edge * edge)
        let preserve = coverage > 0 && coverage < 1
        while e > 1 {
            let ne = e / 2
            var next = [UInt8](repeating: 0, count: ne * ne * 4)
            for y in 0..<ne {
                for x in 0..<ne {
                    let a = ((2 * y) * e + 2 * x) * 4, b = a + 4, c = a + e * 4, d = c + 4
                    let o = (y * ne + x) * 4
                    for k in 0..<4 {
                        next[o + k] = UInt8((Int(cur[a + k]) + Int(cur[b + k]) + Int(cur[c + k]) + Int(cur[d + k]) + 2) / 4)
                    }
                }
            }
            if preserve {
                // Smallest scale in [1, 4] that restores the level-0 coverage
                // (bisection over 6 steps: the tile is at most 32x32 here).
                let want = Int((coverage * Double(ne * ne)).rounded())
                func passing(_ scale: Double) -> Int {
                    var n = 0
                    for i in stride(from: 3, to: next.count, by: 4) where Double(next[i]) * scale >= 128 { n += 1 }
                    return n
                }
                if passing(1) < want {
                    var lo = 1.0, hi = 4.0
                    for _ in 0..<6 {
                        let mid = (lo + hi) / 2
                        if passing(mid) >= want { hi = mid } else { lo = mid }
                    }
                    for i in 0..<next.count { next[i] = UInt8(min(255, Double(next[i]) * hi)) }
                }
            }
            out.append(next)
            cur = next; e = ne
        }
        return out
    }

    /// Upload level 0 plus its chain into one slice of a 2D array texture.
    static func upload(_ tex: MTLTexture, slice: Int, px: [UInt8], edge: Int) {
        var e = edge
        px.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            tex.replace(region: MTLRegionMake2D(0, 0, e, e), mipmapLevel: 0, slice: slice, withBytes: base,
                        bytesPerRow: e * 4, bytesPerImage: e * e * 4)
        }
        guard tex.mipmapLevelCount > 1 else { return }
        for (l, mip) in chain(px, edge: edge).enumerated() {
            e /= 2
            mip.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                tex.replace(region: MTLRegionMake2D(0, 0, e, e), mipmapLevel: l + 1, slice: slice, withBytes: base,
                            bytesPerRow: e * 4, bytesPerImage: e * e * 4)
            }
        }
    }
}
