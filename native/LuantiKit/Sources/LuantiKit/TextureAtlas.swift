import Foundation
import CoreGraphics
import ImageIO
import simd

/// Builds a texture-array atlas: one 16x16 RGBA layer per unique node tile we
/// could decode, plus dedup'd solid-colour layers for faces whose texture is
/// missing/undecodable. Produces a per-(content id, face) -> layer table for
/// the mesher and the raw layer pixels for the renderer to upload.
public final class TextureAtlas {
    // Layer edge in texels. 64, not 16, so mesh-drawtype nodes (the bed) whose
    // texture is a 64px sheet aren't crushed: a bed's top face is a ~16px region
    // of that sheet, so a 16px atlas left it ~4px of mush. Pixel-art cube tiles
    // (16px) are nearest-upscaled into the bigger layer and nearest-sampled, so
    // they look identical; only atlas memory grows (~16KB/layer). The modifier
    // path fills the layer at any size (evaluateModifiedFill) so nothing sits in
    // a corner. Raising this is the single knob for mesh-node resolution.
    public static let tile = 64

    public private(set) var layers: [[UInt8]] = []  // each tile*tile*4 RGBA
    /// A node-atlas layer that cycles frames over time (#137: lava/fire/furnace).
    public struct AnimLayer { public let layer: Int; public let frames: [[UInt8]]; public let secPerFrame: Float }
    public private(set) var animatedLayers: [AnimLayer] = []
    public private(set) var markerLayer: Int32 = 0   // plain white, for entity billboards
    public private(set) var crosshairLayer: Int32 = 0 // distinct cyan, for the aim marker
    public private(set) var healthFullLayer: Int32 = 0  // full red heart (HUD)
    public private(set) var healthHalfLayer: Int32 = 0  // half-filled heart (HUD)
    public private(set) var healthEmptyLayer: Int32 = 0 // dim/empty heart (HUD)
    public private(set) var hotbarSlotLayer: Int32 = 0   // dim cell behind a hotbar item
    public private(set) var hotbarSelectLayer: Int32 = 0 // bright border on the wield slot
    public private(set) var hungerFullLayer: Int32 = 0   // full drumstick (HUD)
    public private(set) var hungerHalfLayer: Int32 = 0   // half drumstick (HUD)
    public private(set) var hungerEmptyLayer: Int32 = 0  // dim/empty drumstick (HUD)
    public private(set) var breathFullLayer: Int32 = 0   // full air bubble (HUD, submerged)
    public private(set) var breathHalfLayer: Int32 = 0   // half bubble (HUD)
    public private(set) var breathEmptyLayer: Int32 = 0  // dim/empty bubble (HUD)
    public private(set) var armorFullLayer: Int32 = 0    // full armor icon (HUD)
    public private(set) var armorHalfLayer: Int32 = 0    // half armor icon (HUD)
    public private(set) var armorEmptyLayer: Int32 = 0   // dim/empty armor icon (HUD)
    public private(set) var xpFillLayer: Int32 = 0       // XP bar fill (XP green, HUD)
    public private(set) var xpTrackLayer: Int32 = 0      // XP bar empty track (HUD)
    private var texLayer: [String: Int] = [:]       // base texture name -> layer
    private var colorLayer: [UInt32: Int] = [:]     // packed RGB -> layer
    private var faceLayers: [UInt16: [Int32]] = [:] // content id -> 6 layer indices
    /// Content ids whose face-layer indices changed in the most recent build()
    /// vs the seeded prior atlas. Empty when a rebuild only appended new tiles,
    /// so the caller can skip the full-world remesh (perf). See build().
    public private(set) var changedFaceIds: Set<UInt16> = []
    private var paletteCache: [String: [SIMD3<Float>]] = [:] // palette image -> 256 colours
    private var nodePalette: [UInt16: [SIMD3<Float>]] = [:]   // content id -> palette colours

    /// Biome-palette colours (256) for a node, or nil if it isn't palette-tinted.
    public func paletteColors(_ id: UInt16) -> [SIMD3<Float>]? { nodePalette[id] }

    public init() {}

    public var layerCount: Int { layers.count }

    /// Carry the previous generation's layers and name->index tables into this
    /// (fresh) atlas before `build()`, so every tile that already had a number
    /// keeps it and a rebuild only APPENDS new tiles. Rebuilding from scratch
    /// renumbered every tile (dictionary order isn't stable), which is the root
    /// of a whole family of bugs: anything holding a layer index across a
    /// rebuild -- baked vertex floats, particles, icons -- then sampled whatever
    /// tile landed in that slot (snow drawing as dirt/wheat #256/#201, nether
    /// particles as blocks #202, wrong chest icons #254). The model-texture array
    /// is already append-only and never had this; this makes the node atlas
    /// match it. `dropping` names tiles whose media was re-pushed: they're
    /// evicted so build() re-evaluates their pixels (they get a fresh index,
    /// which the accompanying full remesh covers).
    public func seed(from prev: TextureAtlas, dropping: Set<String> = []) {
        layers = prev.layers
        texLayer = prev.texLayer
        for t in dropping { texLayer[t] = nil }
        colorLayer = prev.colorLayer
        keyedLayers = prev.keyedLayers
        // Carry the prior face-layer map so build() can tell which ids actually
        // changed (it overwrites every entry, but the pre-overwrite value is the
        // baseline for changedFaceIds). Without this, every id reads as changed
        // and the caller full-remeshes on every append.
        faceLayers = prev.faceLayers
        paletteCache = prev.paletteCache
        nodePalette = prev.nodePalette
    }

    /// The tile name currently at a layer index (reverse lookup), for the
    /// stale-index tripwire in DEBUG builds. Lazily built; nil for colour/HUD
    /// layers that have no tile name.
    public func nameAt(_ layer: Int) -> String? {
        texLayer.first { $0.value == layer }?.key
    }

    /// Every tile name -> index this atlas holds, for the DEBUG remap check.
    public var tileIndexSnapshot: [String: Int] { texLayer }

    /// Layer index for a content id's face (0..5). -1 if the id is unknown.
    public func layer(id: UInt16, face: Int) -> Int32 {
        guard let f = faceLayers[id], face >= 0 && face < 6 else { return 0 }
        return f[face]
    }

    /// Build from the node tile table and downloaded media. Safe to call again
    /// as more media arrives (layers are appended, indices stay stable).
    public func build(nodes: NodeRegistry, media: MediaManager, extraTiles: [String] = []) {
        markerLayer = Int32(layerForColor(SIMD3(1, 1, 1)))
        crosshairLayer = Int32(makeCrosshairLayer())   // white '+' cross (VoxeLibre default)
        hotbarSlotLayer = Int32(makeSlotLayer(highlight: false))
        hotbarSelectLayer = Int32(makeSlotLayer(highlight: true))
        buildHealthLayers(media: media)
        buildHungerLayers(media: media)
        buildBreathLayers(media: media)
        buildArmorLayers(media: media)
        // XP bar (#107): flat colours rather than mcl_experience_bar.png, whose
        // 5x182 strip would smear when squashed into a square tile; at HUD size
        // a flat XP-green fill on a dark track reads the same as the desktop bar.
        xpFillLayer = Int32(layerForColor(SIMD3(0.50, 1.00, 0.125)))   // 0x80FF20
        xpTrackLayer = Int32(layerForColor(SIMD3(0.10, 0.12, 0.10)))
        for t in extraTiles where !t.isEmpty { _ = layerForTile(t, media: media) }
        // Content ids whose 6 face-layer indices actually MOVED vs the seeded
        // prior atlas -- the only blocks that need re-meshing after this build.
        // The common rebuild just appends new tiles (a mob skin, an item icon)
        // and touches no existing face, so this stays empty and the caller skips
        // the full-world remesh. A colour-fallback tile that finally got its real
        // pixels (media arrived) flips an index and lands here. Reset per build.
        changedFaceIds = []
        let faceTiles = nodes.faceTilesSnapshot()   // stable copy; parse may run concurrently
        for (id, tiles) in faceTiles {
            var faces = [Int32](repeating: 0, count: 6)
            for i in 0..<6 {
                let name = tiles[i]
                if !name.isEmpty, let l = layerForTile(name, media: media) {
                    faces[i] = Int32(l)
                } else {
                    faces[i] = Int32(layerForColor(nodes.color(id)))
                }
            }
            if faceLayers[id] != faces { changedFaceIds.insert(id) }   // nil prior (first build) counts as changed
            faceLayers[id] = faces
        }
        // Animated tiles (#137): a tile flagged with a vertical-frames animation
        // and stored as a plain strip image gets its frames decoded so the
        // renderer can cycle that layer's pixels. Only plain images (no modifier)
        // are handled; lava/fire/furnace-lit are plain.
        animatedLayers = []
        for (tileName, layer) in texLayer {
            let base = NodeRegistry.imageNames(tileName).first ?? tileName
            guard let secs = nodes.animSecs(base) else { continue }   // only server-flagged animated tiles
            if tileName == base {
                // A plain strip image: decode its vertical frames directly.
                guard let data = media.store[base],
                      let frames = TextureAtlas.decodePNGFrames(data, size: TextureAtlas.tile), frames.count > 1
                else { continue }
                animatedLayers.append(AnimLayer(layer: layer, frames: frames,
                                                secPerFrame: max(0.05, secs / Float(frames.count))))
                if base.contains("lava") {
                    var s = 0, c = 0, i = 0; let f = frames[0]
                    while i + 2 < f.count { s += Int(f[i]) + Int(f[i+1]) + Int(f[i+2]); c += 3; i += 4 }
                    print("[lavaanim] tile=\(tileName) branch=strip built=\(frames.count) frame0mean=\(c>0 ? s/c : -1)"); fflush(stdout)
                }
            } else if let vf = TextureAtlas.verticalFrameParts(tileName), vf.n > 1,
                      tileName.components(separatedBy: "[verticalframe:").count == 2 {
                // A tile with exactly one `[verticalframe:N:I` pinning it to one
                // frame: lava/water (strip, maybe colour-multiplied) AND composited
                // animated blocks (a single strip inside a [combine, e.g. campfire /
                // sea pickle). Generate all N frames so it animates instead of
                // freezing on frame 0. Single verticalframe so make(i) is unambiguous.
                let parts = tileName.components(separatedBy: "^")
                let purePin = parts.count == 2 && parts[1].hasPrefix("[verticalframe:")
                var frames: [[UInt8]] = []; frames.reserveCapacity(vf.n)
                if purePin, let data = media.store[base],
                   let strip = TextureAtlas.decodePNGFrames(data, size: TextureAtlas.tile), strip.count > 1 {
                    // No trailing modifiers: decode the base strip directly, the
                    // same path source lava uses. evaluateModifiedFit's verticalframe
                    // was decoding the lava-FLOW strip near-black (#200); this fixes it.
                    frames = strip
                } else {
                    // Trailing modifiers (water multiply, cauldron [combine): must
                    // evaluate the whole chain per frame.
                    for i in 0..<vf.n {
                        guard let px = TextureAtlas.evaluateModifiedFit(vf.make(i), media: media, canvas: TextureAtlas.tile)?.px
                        else { frames = []; break }
                        frames.append(px)
                    }
                }
                if frames.count > 1 {
                    animatedLayers.append(AnimLayer(layer: layer, frames: frames,
                                                    secPerFrame: max(0.05, secs / Float(frames.count))))
                }
                // Diagnose the black/speckled lava flow (#200): did the frames
                // build, and is frame 0 actually bright? mean = avg RGB (0..255).
                if base.contains("lava") {
                    let mean = frames.first.map { f -> Int in
                        var s = 0, c = 0
                        var i = 0; while i + 2 < f.count { s += Int(f[i]) + Int(f[i+1]) + Int(f[i+2]); c += 3; i += 4 }
                        return c > 0 ? s / c : -1
                    } ?? -1
                    print("[lavaanim] tile=\(tileName) branch=vf n=\(vf.n) built=\(frames.count) frame0mean=\(mean)"); fflush(stdout)
                }
            } else if base.contains("lava") {
                // Animated lava tile that matched NEITHER branch -> stays pinned to
                // one frame (likely the black/speckled flow, #200). Surface it.
                print("[lavaanim] tile=\(tileName) branch=NONE (not animated: vf=\(TextureAtlas.verticalFrameParts(tileName)?.n ?? -1))"); fflush(stdout)
            }
        }
        // Decode biome palettes (grass/foliage) so the mesher can tint by param2.
        // Reuse the stable faceTiles snapshot (line above) instead of touching the
        // live dict, which a concurrent NODEDEF re-parse could be mutating.
        for id in faceTiles.keys {
            guard let palName = nodes.paletteName(id) else { continue }
            if let colors = paletteColors(named: palName, media: media) { nodePalette[id] = colors }
        }
    }

    /// Decode a 16x16 (256-entry) palette PNG into row-major colours.
    private func paletteColors(named spec: String, media: MediaManager) -> [SIMD3<Float>]? {
        if let c = paletteCache[spec] { return c }
        guard let first = NodeRegistry.imageNames(spec).first, let data = media.store[first],
              let px = TextureAtlas.decodePNG(data, size: 16) else { return nil }
        var colors: [SIMD3<Float>] = []; colors.reserveCapacity(256)
        for i in 0..<256 {
            let a = Float(px[i * 4 + 3])
            let inv: Float = a > 0 ? 255.0 / a : 0      // decodePNG is premultiplied
            colors.append(SIMD3(Float(px[i*4]) * inv / 255, Float(px[i*4+1]) * inv / 255, Float(px[i*4+2]) * inv / 255))
        }
        paletteCache[spec] = colors
        return colors
    }

    /// Layer for an entity texture if it's downloaded, else nil (use markerLayer).
    /// Layer for an already-built tile string (nil if not decoded).
    public func tileLayer(_ tile: String) -> Int32? { texLayer[tile].map { Int32($0) } }

    public func entityLayer(_ tile: String, media: MediaManager) -> Int32? {
        if let l = layerForTile(tile, media: media) { return Int32(l) }
        return nil
    }

    /// A white '+' crosshair on transparent, as one atlas layer. Arms don't
    /// reach the centre (classic centre gap). Premultiplied white; the fragment
    /// alpha-cutout drops the transparent surround so only the cross shows.
    private func makeCrosshairLayer() -> Int {
        let n = TextureAtlas.tile, mid = n / 2
        var px = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n { for x in 0..<n {
            let vArm = abs(x - mid) <= 1 && ((y >= 2 && y <= mid - 2) || (y >= mid + 2 && y <= n - 3))
            let hArm = abs(y - mid) <= 1 && ((x >= 2 && x <= mid - 2) || (x >= mid + 2 && x <= n - 3))
            if vArm || hArm { let i = (y * n + x) * 4; px[i] = 255; px[i+1] = 255; px[i+2] = 255; px[i+3] = 255 }
        }}
        return rawLayer("crosshair", px)
    }

    /// A hotbar cell as one atlas layer. Non-highlight: a dim solid square (the
    /// slot background the item icon sits on). Highlight: a thick bright border
    /// with a transparent centre, drawn over the selected (wield) slot so the
    /// icon and cell below still show through. Fully opaque pixels only (the HUD
    /// billboard fragment alpha-cutouts, so semi-transparent pixels would drop).
    private func makeSlotLayer(highlight: Bool) -> Int {
        let n = TextureAtlas.tile
        var px = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n { for x in 0..<n {
            let i = (y * n + x) * 4
            let outer = x == 0 || y == 0 || x == n - 1 || y == n - 1
            let inner = x <= 1 || y <= 1 || x >= n - 2 || y >= n - 2
            if highlight {
                if inner { px[i] = 255; px[i+1] = 224; px[i+2] = 92; px[i+3] = 255 }   // gold frame
            } else if outer {
                px[i] = 96; px[i+1] = 96; px[i+2] = 104; px[i+3] = 255                 // lighter edge
            } else {
                px[i] = 34; px[i+1] = 34; px[i+2] = 42; px[i+3] = 255                  // dim fill
            }
        } }
        return rawLayer(highlight ? "slotSel" : "slotBg", px)
    }

    /// Slice crack_anylength.png (a vertical strip of square frames, stage 0 at
    /// the top) into model-texture layers: each frame at native size in the
    /// top-left of a `canvas`-square layer, plus the uv scale that reaches it.
    /// The model shader alpha-cutouts at 0.5 but crack pixels are only partly
    /// opaque, so any visible pixel is snapped to full alpha (and darkened) so
    /// the lines read solidly.
    public static func decodeCrackFrames(_ data: Data, canvas: Int) -> [(px: [UInt8], uv: SIMD2<Float>)] {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil), img.width > 0 else { return [] }
        let w = img.width, n = max(1, img.height / w)
        guard n <= 64, w <= canvas else { return [] }
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        let uv = SIMD2<Float>(Float(w) / Float(canvas), Float(w) / Float(canvas))
        var out: [(px: [UInt8], uv: SIMD2<Float>)] = []
        for f in 0..<n {
            guard let frame = img.cropping(to: CGRect(x: 0, y: f * w, width: w, height: w)),
                  let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                                      bytesPerRow: canvas * 4, space: cs, bitmapInfo: info) else { continue }
            ctx.interpolationQuality = .none
            ctx.draw(frame, in: CGRect(x: 0, y: canvas - w, width: w, height: w))   // top-left
            guard let base = ctx.data else { continue }
            var px = [UInt8](repeating: 0, count: canvas * canvas * 4)
            px.withUnsafeMutableBytes { _ = memcpy($0.baseAddress, base, canvas * canvas * 4) }
            for i in stride(from: 0, to: px.count, by: 4) {
                if px[i + 3] > 24 {
                    px[i] /= 2; px[i + 1] /= 2; px[i + 2] /= 2; px[i + 3] = 255
                } else {
                    px[i + 3] = 0
                }
            }
            out.append((px, uv))
        }
        return out
    }

    /// Decode the VoxeLibre heart icons into HUD atlas layers: full, half, and
    /// dim/empty. Each is drawn as a peripheral billboard. If the media hasn't
    /// arrived yet, fall back to flat colour layers so HP still reads (a later
    /// rebuild, once the icons download, swaps in the real hearts).
    private func buildHealthLayers(media: MediaManager) {
        let n = TextureAtlas.tile
        func icon(_ name: String) -> [UInt8]? {
            guard let d = media.bytes(name) else { return nil }
            return TextureAtlas.decodePNG(d, size: n)
        }
        let full = icon("hudbars_icon_health.png")
        let empty = icon("hudbars_bgicon_health.png")
        print("[hud] health icons decode: full=\(full != nil) empty=\(empty != nil) storeHas=\(media.has("hudbars_icon_health.png"))"); fflush(stdout)
        if let full {
            healthFullLayer = Int32(rawLayer("healthFull", full))
            // Half heart: left half of the full heart, right half the dim/empty
            // heart (or transparent if we don't have it) so it reads as "half".
            var half = full
            let right = empty ?? [UInt8](repeating: 0, count: n * n * 4)
            for y in 0..<n { for x in (n / 2)..<n {
                let i = (y * n + x) * 4
                half[i] = right[i]; half[i+1] = right[i+1]; half[i+2] = right[i+2]; half[i+3] = right[i+3]
            } }
            healthHalfLayer = Int32(rawLayer("healthHalf", half))
        } else {
            healthFullLayer = Int32(layerForColor(SIMD3(0.85, 0.06, 0.06)))
            healthHalfLayer = Int32(layerForColor(SIMD3(0.55, 0.06, 0.06)))
        }
        healthEmptyLayer = empty.map { Int32(rawLayer("healthEmpty", $0)) }
            ?? Int32(layerForColor(SIMD3(0.16, 0.05, 0.05)))
    }

    /// Decode the VoxeLibre hunger drumstick icons into HUD atlas layers: full,
    /// half, and dim/empty background, mirroring buildHealthLayers. The half
    /// drumstick is the left half of the full icon over the right half of the
    /// empty one. Flat-colour fallback (browns) until the icons download.
    private func buildHungerLayers(media: MediaManager) {
        let n = TextureAtlas.tile
        func icon(_ name: String) -> [UInt8]? {
            guard let d = media.bytes(name) else { return nil }
            return TextureAtlas.decodePNG(d, size: n)
        }
        let full = icon("hbhunger_icon.png")
        let empty = icon("hbhunger_bgicon.png")
        print("[hud] hunger icons decode: full=\(full != nil) empty=\(empty != nil) storeHas=\(media.has("hbhunger_icon.png"))"); fflush(stdout)
        if let full {
            hungerFullLayer = Int32(rawLayer("hungerFull", full))
            var half = full
            let right = empty ?? [UInt8](repeating: 0, count: n * n * 4)
            for y in 0..<n { for x in (n / 2)..<n {
                let i = (y * n + x) * 4
                half[i] = right[i]; half[i+1] = right[i+1]; half[i+2] = right[i+2]; half[i+3] = right[i+3]
            } }
            hungerHalfLayer = Int32(rawLayer("hungerHalf", half))
        } else {
            hungerFullLayer = Int32(layerForColor(SIMD3(0.62, 0.40, 0.16)))
            hungerHalfLayer = Int32(layerForColor(SIMD3(0.42, 0.27, 0.11)))
        }
        hungerEmptyLayer = empty.map { Int32(rawLayer("hungerEmpty", $0)) }
            ?? Int32(layerForColor(SIMD3(0.14, 0.09, 0.04)))
    }

    /// Air-bubble icons for the underwater breath bar, mirroring buildHungerLayers.
    private func buildBreathLayers(media: MediaManager) {
        let n = TextureAtlas.tile
        func icon(_ name: String) -> [UInt8]? {
            guard let d = media.bytes(name) else { return nil }
            return TextureAtlas.decodePNG(d, size: n)
        }
        let full = icon("hudbars_icon_breath.png")
        let empty = icon("hudbars_bgicon_breath.png")
        print("[hud] breath icons decode: full=\(full != nil) empty=\(empty != nil) storeHas=\(media.has("hudbars_icon_breath.png"))"); fflush(stdout)
        if let full {
            breathFullLayer = Int32(rawLayer("breathFull", full))
            var half = full
            let right = empty ?? [UInt8](repeating: 0, count: n * n * 4)
            for y in 0..<n { for x in (n / 2)..<n {
                let i = (y * n + x) * 4
                half[i] = right[i]; half[i+1] = right[i+1]; half[i+2] = right[i+2]; half[i+3] = right[i+3]
            } }
            breathHalfLayer = Int32(rawLayer("breathHalf", half))
        } else {
            breathFullLayer = Int32(layerForColor(SIMD3(0.45, 0.70, 1.0)))
            breathHalfLayer = Int32(layerForColor(SIMD3(0.30, 0.48, 0.72)))
        }
        breathEmptyLayer = empty.map { Int32(rawLayer("breathEmpty", $0)) }
            ?? Int32(layerForColor(SIMD3(0.10, 0.16, 0.24)))
    }

    /// Armor plate icons (mcl_hbarmor statbar), mirroring buildHungerLayers.
    private func buildArmorLayers(media: MediaManager) {
        let n = TextureAtlas.tile
        func icon(_ name: String) -> [UInt8]? {
            guard let d = media.bytes(name) else { return nil }
            return TextureAtlas.decodePNG(d, size: n)
        }
        let full = icon("hbarmor_icon.png")
        let empty = icon("hbarmor_bgicon.png")
        if let full {
            armorFullLayer = Int32(rawLayer("armorFull", full))
            var half = full
            let right = empty ?? [UInt8](repeating: 0, count: n * n * 4)
            for y in 0..<n { for x in (n / 2)..<n {
                let i = (y * n + x) * 4
                half[i] = right[i]; half[i+1] = right[i+1]; half[i+2] = right[i+2]; half[i+3] = right[i+3]
            } }
            armorHalfLayer = Int32(rawLayer("armorHalf", half))
        } else {
            armorFullLayer = Int32(layerForColor(SIMD3(0.75, 0.78, 0.82)))
            armorHalfLayer = Int32(layerForColor(SIMD3(0.50, 0.52, 0.55)))
        }
        armorEmptyLayer = empty.map { Int32(rawLayer("armorEmpty", $0)) }
            ?? Int32(layerForColor(SIMD3(0.16, 0.17, 0.19)))
    }

    // HUD/marker layers (crosshair, hotbar slots, the stat-bar icons) are rebuilt
    // every build() as media arrives. Keyed to a stable slot so a rebuild
    // OVERWRITES its layer in place instead of appending a fresh one each time,
    // which used to leak ~18 layers per rebuild. The index stays stable, which
    // is what the renderer relies on.
    private var keyedLayers: [String: Int] = [:]
    private func rawLayer(_ key: String, _ px: [UInt8]) -> Int {
        if let s = keyedLayers[key] { layers[s] = px; return s }
        let l = layers.count; layers.append(px); keyedLayers[key] = l; return l
    }

    /// The 16 px node-tile evaluator, exposed for tests only.
    func evaluateTileForTesting(_ tile: String, media: MediaManager) -> [UInt8]? { evaluate(tile, media: media) }

    private func layerForTile(_ tile: String, media: MediaManager) -> Int? {
        if let l = texLayer[tile] { return l }
        guard let px = evaluate(tile, media: media) else { return nil }
        let l = layers.count
        layers.append(px)
        texLayer[tile] = l
        return l
    }

    /// Evaluate a tile modifier string into 16x16 premultiplied RGBA. Supports
    /// the base image, '^' overlays (including '(...)' groups), and [colorize;
    /// unknown '[' transforms are skipped (base shows through).
    private func evaluate(_ tile: String, media: MediaManager) -> [UInt8]? {
        // Bracket generators ([combine/[fill, e.g. the flower-in-pot tile
        // "[combine:32x32:0,0=pot.png:0,0=flower.png") need the native
        // compositor; the simple ^-overlay path below can't build them. Render
        // at native res and downscale to the atlas tile.
        // [sheet crops a sub-tile, which only makes sense at native res too.
        // The simple ^-overlay path below can't do geometry-changing modifiers
        // ([transform/[resize/[lowpart/[verticalframe) or the bracket generators,
        // so route any tile that uses them through the native compositor, which
        // handles the full chain (#230). Node tiles are square, so fill is exact.
        if tile.contains("[combine") || tile.contains("[fill") || tile.contains("[sheet")
            || tile.contains("[transform") || tile.contains("[resize")
            || tile.contains("[lowpart") || tile.contains("[verticalframe") {
            // Fill the layer: cube UVs sample the whole layer and this path drops
            // the fit uv, so a corner-placed result would leave the rest clear.
            return TextureAtlas.evaluateModifiedFill(tile, media: media, canvas: TextureAtlas.tile)
        }
        let parts = TextureAtlas.splitTop(tile, on: "^")
        guard let first = parts.first, var acc = tokenImage(first, media: media) else { return nil }
        let n = TextureAtlas.tile * TextureAtlas.tile
        for part in parts.dropFirst() {
            if part.hasPrefix("[colorize:") { colorizeInPlace(&acc, spec: part) }
            else if part.hasPrefix("[mask:"), let m = tokenImage(String(part.dropFirst("[mask:".count)), media: media) {
                TextureAtlas.applyMask(&acc, count: n) { i in (m[i*4], m[i*4+1], m[i*4+2], m[i*4+3]) }
            }
            else if TextureAtlas.applyPixelModifier(part, px: &acc, count: n) { continue }
            else if part.hasPrefix("[") { continue }            // unsupported transform
            else if let ov = tokenImage(part, media: media) { overInPlace(&acc, ov) }
        }
        return acc
    }

    private func tokenImage(_ token: String, media: MediaManager) -> [UInt8]? {
        if token.hasPrefix("(") && token.hasSuffix(")") {
            return evaluate(String(token.dropFirst().dropLast()), media: media)
        }
        guard token.lowercased().hasSuffix(".png"), let data = media.bytes(token) else { return nil }
        return TextureAtlas.decodePNG(data, size: TextureAtlas.tile)
    }

    /// Split on `sep` only at the top nesting level (respecting () and []).
    static func splitTop(_ s: String, on sep: Character) -> [String] {
        // Only parentheses group; Luanti's '[' modifiers (^[colorize, ^[resize)
        // are prefixes with no closing ']', so counting brackets would wrongly
        // stop splitting '^' after the first one (the mcl_skins body chain bug).
        var parts: [String] = []; var cur = ""; var depth = 0
        for ch in s {
            if ch == "(" { depth += 1 }
            else if ch == ")" { depth = max(0, depth - 1) }
            if ch == sep && depth == 0 { parts.append(cur); cur = "" } else { cur.append(ch) }
        }
        parts.append(cur); return parts
    }

    /// Alpha-over: composite `over` on top of `base` (both premultiplied RGBA).
    private func overInPlace(_ base: inout [UInt8], _ over: [UInt8]) {
        let n = TextureAtlas.tile * TextureAtlas.tile
        for i in 0..<n {
            let j = i * 4
            let ia = 1.0 - Float(over[j+3]) / 255.0
            for c in 0..<4 {
                let v = Float(over[j+c]) + Float(base[j+c]) * ia
                base[j+c] = UInt8(max(0, min(255, v)))
            }
        }
    }

    /// [colorize:#RRGGBB[AA]:ratio] — blend the image toward a colour.
    private func colorizeInPlace(_ img: inout [UInt8], spec: String) {
        let f = spec.dropFirst("[colorize:".count).split(separator: ":", omittingEmptySubsequences: false)
        guard let colorStr = f.first, let c = TextureAtlas.parseColorRGBA(String(colorStr).replacingOccurrences(of: "]", with: "")) else { return }
        let rgb = [c[0], c[1], c[2]]
        let ratioTok = f.count > 1 ? f[1].replacingOccurrences(of: "]", with: "") : "alpha"   // Luanti: omitted ratio uses the colour's own alpha (#230)
        let ratio: Float = ratioTok == "alpha" ? c[3] / 255.0 : (Float(ratioTok) ?? 128) / 255.0
        let n = TextureAtlas.tile * TextureAtlas.tile
        for i in 0..<n {
            let j = i * 4
            let a = Float(img[j+3]) / 255.0
            if a <= 0 { continue }
            for c in 0..<3 {
                let straight = Float(img[j+c]) / a          // un-premultiply
                let mixed = straight * (1 - ratio) + rgb[c] * ratio
                img[j+c] = UInt8(max(0, min(255, mixed * a)))  // re-premultiply
            }
        }
    }

    static func parseHexColor(_ s: String) -> [Float]? {
        guard let c = parseColorRGBA(s) else { return nil }
        return [c[0], c[1], c[2]]
    }

    /// Luanti parseColorString: named colours, #RGB, #RGBA, #RRGGBB, #RRGGBBAA
    /// (with/without leading '#'). Returns r,g,b,a as 0..255 floats.
    static func parseColorRGBA(_ s: String) -> [Float]? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let n = namedColors[t] { return n }
        var h = t; if h.hasPrefix("#") { h.removeFirst() }
        guard h.allSatisfy({ $0.isHexDigit }) else { return nil }
        func hx(_ sub: Substring) -> Float { Float(UInt32(sub, radix: 16) ?? 0) }
        switch h.count {
        case 3, 4:   // #RGB / #RGBA -> each nibble doubled
            let a = Array(h)
            func d(_ c: Character) -> Float { let v = UInt32(String(c), radix: 16) ?? 0; return Float(v * 16 + v) }
            return [d(a[0]), d(a[1]), d(a[2]), h.count == 4 ? d(a[3]) : 255]
        case 6, 8:
            let a = Array(h)
            let r = hx(a[0...1].reduce(into: "") { $0.append($1) }[...])
            // simpler: index pairs
            func pair(_ i: Int) -> Float { hx(Substring(String(a[i]) + String(a[i+1]))) }
            _ = r
            return [pair(0), pair(2), pair(4), h.count == 8 ? pair(6) : 255]
        default: return nil
        }
    }

    private static let namedColors: [String: [Float]] = [
        "white": [255,255,255,255], "black": [0,0,0,255], "red": [255,0,0,255],
        "green": [0,128,0,255], "lime": [0,255,0,255], "blue": [0,0,255,255],
        "yellow": [255,255,0,255], "cyan": [0,255,255,255], "magenta": [255,0,255,255],
        "gray": [128,128,128,255], "grey": [128,128,128,255], "orange": [255,165,0,255],
        "brown": [165,42,42,255], "pink": [255,192,203,255], "purple": [128,0,128,255],
    ]

    private func layerForColor(_ c: SIMD3<Float>) -> Int {
        let r = UInt8(max(0, min(255, c.x * 255)))
        let g = UInt8(max(0, min(255, c.y * 255)))
        let b = UInt8(max(0, min(255, c.z * 255)))
        let key = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
        if let l = colorLayer[key] { return l }
        let n = TextureAtlas.tile * TextureAtlas.tile
        var px = [UInt8](repeating: 255, count: n * 4)
        for i in 0..<n { px[i*4] = r; px[i*4+1] = g; px[i*4+2] = b; px[i*4+3] = 255 }
        let l = layers.count
        layers.append(px)
        colorLayer[key] = l
        return l
    }

    /// Decode PNG bytes to `size`x`size` RGBA8 (nearest, top-left origin).
    /// Decode a texture at (near) native resolution into a `canvas`x`canvas`
    /// RGBA buffer, anchored top-left with aspect preserved. Returns the buffer
    /// plus the UV scale (fraction of the canvas the image occupies) so a model's
    /// 0..1 UVs can be remapped onto its sub-rect. For full-res mob skins, which
    /// don't fit the 16x16 node atlas.
    /// Evaluate a full texture-modifier string at model resolution: base image
    /// fit into `canvas`, then top-level '^' overlays (same authored dimensions,
    /// so they land on the same sub-rect), '(...)' groups, and '[colorize:'.
    /// This is the model-path twin of the 16px atlas evaluate(), so a mob skin
    /// like "horse_chestnut.png^horse_markings_white.png" composites instead of
    /// dropping the overlay (#72). Returns nil until the base PNG is downloaded.
    /// A texture at its own (native) resolution, premultiplied RGBA, top row
    /// first. The model evaluator composites at native res (so [combine offsets
    /// and mismatched overlays are exact) then fits into the square canvas once.
    struct NativeImg { var px: [UInt8]; var w: Int; var h: Int }

    public static func evaluateModifiedFit(_ tile: String, media: MediaManager, canvas: Int) -> (px: [UInt8], uv: SIMD2<Float>)? {
        // Fast path: a single plain PNG stays pixel-identical to the plain decode
        // (keeps the model path and its regression test aligned).
        if tile.lowercased().hasSuffix(".png"), !tile.contains("^"), !tile.contains("["), !tile.contains("("),
           let data = media.bytes(tile) {
            return decodePNGFit(data, canvas: canvas)
        }
        guard let img = renderNative(tile, media: media, depth: 0) else { return nil }
        return fitNative(img, canvas: canvas)
    }

    /// Like evaluateModifiedFit, but the result FILLS the whole canvas (nearest
    /// scaled to canvas x canvas) instead of sitting top-left with a uv scale.
    /// The node-tile evaluate() path drops the fit uv, so a [combine/[fill/[sheet
    /// node whose art is smaller than the atlas layer would otherwise render in a
    /// corner with the rest transparent. Node tiles are square, so a square fill
    /// is exact; this keeps them correct at any TextureAtlas.tile size (so the
    /// atlas resolution can be raised for hi-res mesh nodes like the bed).
    public static func evaluateModifiedFill(_ tile: String, media: MediaManager, canvas: Int) -> [UInt8]? {
        guard let img = renderNative(tile, media: media, depth: 0) else { return nil }
        return fillNative(img, canvas: canvas)
    }

    /// Render a full modifier string at native resolution: base ^ overlays,
    /// (...) groups, [colorize, [combine, [fill.
    private static func renderNative(_ tile: String, media: MediaManager, depth: Int) -> NativeImg? {
        guard depth < 8 else { return nil }   // Luanti-style recursion cap; stops malformed-modifier blowups
        let parts = splitTop(tile, on: "^")
        guard let first = parts.first, var base = nativeToken(first, media: media, depth: depth) else { return nil }
        for part in parts.dropFirst() {
            if part.hasPrefix("[colorize:") { colorizeFull(&base.px, spec: part, count: base.w * base.h) }
            else if part.hasPrefix("[lowpart:") { lowpartNative(&base, part, media: media, depth: depth) }
            else if part.hasPrefix("[verticalframe:") { verticalFrameNative(&base, part) }
            else if part.hasPrefix("[transform") { transformNative(&base, String(part.dropFirst("[transform".count))) }
            else if part.hasPrefix("[resize:") { resizeNative(&base, part) }
            else if part.hasPrefix("[sheet:") { sheetNative(&base, part) }
            else if part.hasPrefix("[mask:") { maskNative(&base, part, media: media, depth: depth) }
            else if applyPixelModifier(part, px: &base.px, count: base.w * base.h) { continue }
            else if let ov = nativeToken(part, media: media, depth: depth) { nativeOver(&base, ov) }   // png/(group)/combine/fill overlays
            else if part.hasPrefix("[") { continue }                 // other unsupported transform
        }
        return base
    }

    private static func nativeToken(_ token: String, media: MediaManager, depth: Int) -> NativeImg? {
        guard depth < 8 else { return nil }
        if token.hasPrefix("(") && token.hasSuffix(")") {
            return renderNative(String(token.dropFirst().dropLast()), media: media, depth: depth + 1)
        }
        if token.hasPrefix("[combine") { return combineNative(token, media: media, depth: depth + 1) }
        if token.hasPrefix("[fill") { return fillNative(token) }
        guard token.lowercased().hasSuffix(".png"), let data = media.bytes(token) else { return nil }
        return decodePNGNative(data)
    }

    /// [combine:WxH:X,Y=file:X,Y=file2 - a WxH transparent canvas with each file
    /// blitted at (X,Y) (negative offsets crop), files may be nested modifiers.
    private static func combineNative(_ token: String, media: MediaManager, depth: Int) -> NativeImg? {
        guard depth < 8 else { return nil }
        let fields = splitParens(String(token.dropFirst("[combine:".count)), on: ":")
        guard let dim = fields.first else { return nil }
        let wh = dim.split(separator: "x")
        guard wh.count == 2, let w = Int(wh[0]), let h = Int(wh[1]), w > 0, h > 0, w * h <= 1 << 20 else { return nil }
        var base = NativeImg(px: [UInt8](repeating: 0, count: w * h * 4), w: w, h: h)
        for entry in fields.dropFirst() {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let pos = entry[..<eq].split(separator: ",")
            guard pos.count == 2, let x = Int(pos[0]), let y = Int(pos[1]) else { continue }
            let file = String(entry[entry.index(after: eq)...])
            guard let img = nativeToken(file, media: media, depth: depth) else { continue }
            blitNative(&base, img, x: x, y: y)
        }
        return base
    }

    /// [fill:WxH:color  or  [fill:WxH:X,Y:color - a solid-colour block.
    private static func fillNative(_ token: String) -> NativeImg? {
        let f = splitParens(String(token.dropFirst("[fill:".count)), on: ":")
        guard let dim = f.first else { return nil }
        let wh = dim.split(separator: "x")
        guard wh.count == 2, let w = Int(wh[0]), let h = Int(wh[1]), w > 0, h > 0, w * h <= 1 << 20 else { return nil }
        let colorStr = f.count >= 3 ? f[2] : (f.count >= 2 ? f[1] : "")   // skip an optional X,Y
        guard let c = parseColorRGBA(colorStr) else { return nil }
        let rgb = [c[0], c[1], c[2]]; let a = c[3]; let af = a / 255
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {   // premultiplied
            px[i*4] = UInt8(rgb[0]*af); px[i*4+1] = UInt8(rgb[1]*af); px[i*4+2] = UInt8(rgb[2]*af); px[i*4+3] = UInt8(a)
        }
        return NativeImg(px: px, w: w, h: h)
    }

    /// Split on `sep` at top level, respecting only '(' ')' (so a nested group's
    /// ':' or ',' isn't split). Brackets are NOT treated as depth here.
    private static func splitParens(_ s: String, on sep: Character) -> [String] {
        var parts: [String] = []; var cur = ""; var depth = 0
        for ch in s {
            if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
            if ch == sep && depth == 0 { parts.append(cur); cur = "" } else { cur.append(ch) }
        }
        parts.append(cur); return parts
    }

    private static func decodePNGNative(_ data: Data) -> NativeImg? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                                  space: cs, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let bp = ctx.data else { return nil }
        var px = [UInt8](repeating: 0, count: w*h*4)
        px.withUnsafeMutableBytes { _ = memcpy($0.baseAddress, bp, w*h*4) }
        return NativeImg(px: px, w: w, h: h)   // CG bitmap orientation; all native ops share it
    }

    /// Composite `over` onto `base`, nearest-scaling `over` to base dimensions
    /// first (Luanti upscaleImagesToMatchLargest for same/greater base).
    // The bar-building modifiers (imagesource.cpp): VoxeLibre's boss bars and XP
    // bar are "(strip^[lowpart:P:strip)^[transformR270^[verticalframe:N:I^[resize:WxH".

    /// [lowpart:P:file — overlay only the bottom P% of `file` (rows above the
    /// cut are dropped, then a normal alpha-over). The percent fill of a bar.
    private static func lowpartNative(_ base: inout NativeImg, _ part: String, media: MediaManager, depth: Int) {
        let f = part.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard f.count == 3, let pct = Int(f[1]),
              var over = nativeToken(String(f[2]), media: media, depth: depth + 1) else { return }
        let cut = over.h * (100 - max(0, min(100, pct))) / 100
        for y in 0..<min(cut, over.h) {
            for x in 0..<over.w { let j = (y * over.w + x) * 4; over.px[j] = 0; over.px[j+1] = 0; over.px[j+2] = 0; over.px[j+3] = 0 }
        }
        nativeOver(&base, over)
    }

    /// [verticalframe:N:I — crop frame I (0-based, clamped) of N from a vertical strip.
    private static func verticalFrameNative(_ base: inout NativeImg, _ part: String) {
        let f = part.split(separator: ":")
        guard f.count >= 3, let n = Int(f[1]), let i0 = Int(f[2]), n > 0 else { return }
        let fh = max(1, base.h / n)
        let y0 = min(min(max(0, i0), n - 1) * fh, base.h - 1)
        let rows = min(fh, base.h - y0)
        let px = Array(base.px[(y0 * base.w * 4)..<((y0 + rows) * base.w * 4)])
        base = NativeImg(px: px, w: base.w, h: rows)
    }

    /// [transform<t> — t is a digit 0-7 or letters I / R90 / R180 / R270 / FX /
    /// FY applied left to right. R rotates counter-clockwise like the engine, so
    /// a bar filled from the bottom by [lowpart then R270'd fills from the left.
    private static func transformNative(_ base: inout NativeImg, _ spec: String) {
        var ops: [String] = []
        if let d = Int(spec), (0...7).contains(d) {
            ops = [[], ["R90"], ["R180"], ["R270"], ["FX"], ["FX", "R90"], ["FY"], ["FY", "R90"]][d]
        } else {
            var s = Substring(spec.uppercased())
            while !s.isEmpty {
                if s.hasPrefix("R180") { ops.append("R180"); s = s.dropFirst(4) }
                else if s.hasPrefix("R270") { ops.append("R270"); s = s.dropFirst(4) }
                else if s.hasPrefix("R90") { ops.append("R90"); s = s.dropFirst(3) }
                else if s.hasPrefix("FX") { ops.append("FX"); s = s.dropFirst(2) }
                else if s.hasPrefix("FY") { ops.append("FY"); s = s.dropFirst(2) }
                else if s.hasPrefix("I") { s = s.dropFirst(1) }
                else { return }
            }
        }
        for op in ops {
            let w = base.w, h = base.h
            let (nw, nh) = (op == "R90" || op == "R270") ? (h, w) : (w, h)
            var out = [UInt8](repeating: 0, count: nw * nh * 4)
            for y in 0..<nh { for x in 0..<nw {
                let sx: Int, sy: Int
                switch op {
                case "R90":  (sx, sy) = (w - 1 - y, x)           // counter-clockwise
                case "R180": (sx, sy) = (w - 1 - x, h - 1 - y)
                case "R270": (sx, sy) = (y, h - 1 - x)           // clockwise
                case "FX":   (sx, sy) = (w - 1 - x, y)
                default:     (sx, sy) = (x, h - 1 - y)           // FY
                }
                let si = (sy * w + sx) * 4, di = (y * nw + x) * 4
                out[di] = base.px[si]; out[di+1] = base.px[si+1]; out[di+2] = base.px[si+2]; out[di+3] = base.px[si+3]
            } }
            base = NativeImg(px: out, w: nw, h: nh)
        }
    }

    /// [resize:WxH — nearest-neighbour rescale to exactly W x H.
    private static func resizeNative(_ base: inout NativeImg, _ part: String) {
        let f = part.dropFirst("[resize:".count).split(separator: "x")
        guard f.count == 2, let nw = Int(f[0]), let nh = Int(f[1]),
              nw > 0, nh > 0, nw <= 4096, nh <= 4096 else { return }
        var out = [UInt8](repeating: 0, count: nw * nh * 4)
        for y in 0..<nh {
            let sy = y * base.h / nh
            for x in 0..<nw {
                let sx = x * base.w / nw
                let si = (sy * base.w + sx) * 4, di = (y * nw + x) * 4
                out[di] = base.px[si]; out[di+1] = base.px[si+1]; out[di+2] = base.px[si+2]; out[di+3] = base.px[si+3]
            }
        }
        base = NativeImg(px: out, w: nw, h: nh)
    }

    /// [sheet:WxH:X,Y: keep tile (X,Y) of a WxH tile sheet (the moon phases).
    private static func sheetNative(_ base: inout NativeImg, _ part: String) {
        guard let s = parseSheet(part) else { return }
        let tw = max(1, base.w / s.w), th = max(1, base.h / s.h)
        var out = [UInt8](repeating: 0, count: tw * th * 4)
        for y in 0..<th { for x in 0..<tw {
            let sx = s.x * tw + x, sy = s.y * th + y
            guard sx < base.w, sy < base.h else { continue }
            let sj = (sy * base.w + sx) * 4, dj = (y * tw + x) * 4
            for c in 0..<4 { out[dj+c] = base.px[sj+c] }
        } }
        base = NativeImg(px: out, w: tw, h: th)
    }

    /// [mask:file: AND the base with the (nested-modifier) mask image,
    /// stretched to the base's size like upscaleImagesToMatchLargest.
    private static func maskNative(_ base: inout NativeImg, _ part: String, media: MediaManager, depth: Int) {
        let name = String(part.replacingOccurrences(of: "]", with: "").dropFirst("[mask:".count))
        guard let m = nativeToken(name, media: media, depth: depth + 1) else { return }
        let bw = base.w, mw = m.w, mh = m.h, bh = base.h
        applyMask(&base.px, count: bw * bh) { i in
            let x = i % bw, y = i / bw
            let mx = mw == bw ? x : x * mw / bw, my = mh == bh ? y : y * mh / bh
            let j = (my * mw + mx) * 4
            return (m.px[j], m.px[j+1], m.px[j+2], m.px[j+3])
        }
    }

    private static func nativeOver(_ base: inout NativeImg, _ over: NativeImg) {
        for y in 0..<base.h { for x in 0..<base.w {
            let ox = over.w == base.w ? x : x * over.w / base.w
            let oy = over.h == base.h ? y : y * over.h / base.h
            let oj = (oy * over.w + ox) * 4, bj = (y * base.w + x) * 4
            let ia = 1.0 - Float(over.px[oj+3]) / 255.0
            for c in 0..<4 { base.px[bj+c] = UInt8(max(0, min(255, Float(over.px[oj+c]) + Float(base.px[bj+c]) * ia))) }
        } }
    }

    /// Blit `img` onto `base` at pixel (x,y) with alpha (negative x/y crop).
    /// All NativeImg buffers are top-down (row 0 = top, the CG bitmap layout),
    /// and [combine authors X,Y top-left, so no flip is needed.
    private static func blitNative(_ base: inout NativeImg, _ img: NativeImg, x: Int, y: Int) {
        for iy in 0..<img.h { for ix in 0..<img.w {
            let bx = x + ix, by = y + iy
            if bx < 0 || bx >= base.w || by < 0 || by >= base.h { continue }
            let ij = (iy * img.w + ix) * 4, bj = (by * base.w + bx) * 4
            let ia = 1.0 - Float(img.px[ij+3]) / 255.0
            for c in 0..<4 { base.px[bj+c] = UInt8(max(0, min(255, Float(img.px[ij+c]) + Float(base.px[bj+c]) * ia))) }
        } }
    }

    /// Fit a native image into a square canvas, aspect preserved, anchored
    /// top-left (matches decodePNGFit's placement + uv).
    private static func fitNative(_ img: NativeImg, canvas: Int) -> (px: [UInt8], uv: SIMD2<Float>)? {
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var buf = img.px
        let cgOpt: CGImage? = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: img.w, height: img.h, bitsPerComponent: 8,
                                      bytesPerRow: img.w * 4, space: cs, bitmapInfo: info) else { return nil }
            return ctx.makeImage()   // copies the pixels; safe once we leave the closure
        }
        guard let cg = cgOpt else { return nil }
        let s = min(Double(canvas) / Double(img.w), Double(canvas) / Double(img.h), 1.0)
        let dw = max(1, Int((Double(img.w) * s).rounded())), dh = max(1, Int((Double(img.h) * s).rounded()))
        guard let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                                  bytesPerRow: canvas * 4, space: cs, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: canvas - dh, width: dw, height: dh))   // same placement as decodePNGFit
        guard let bp = ctx.data else { return nil }
        var px = [UInt8](repeating: 0, count: canvas * canvas * 4)
        px.withUnsafeMutableBytes { _ = memcpy($0.baseAddress, bp, canvas * canvas * 4) }
        return (px, SIMD2(Float(dw) / Float(canvas), Float(dh) / Float(canvas)))
    }

    /// Nearest-scale a native render to fill exactly canvas x canvas (no aspect
    /// letterboxing). Mirrors fitNative's context setup so orientation matches.
    private static func fillNative(_ img: NativeImg, canvas: Int) -> [UInt8]? {
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var buf = img.px
        let cgOpt: CGImage? = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: img.w, height: img.h, bitsPerComponent: 8,
                                      bytesPerRow: img.w * 4, space: cs, bitmapInfo: info) else { return nil }
            return ctx.makeImage()   // copies the pixels; safe once we leave the closure
        }
        guard let cg = cgOpt,
              let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                                  bytesPerRow: canvas * 4, space: cs, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: canvas, height: canvas))   // fill the whole layer
        guard let bp = ctx.data else { return nil }
        var px = [UInt8](repeating: 0, count: canvas * canvas * 4)
        px.withUnsafeMutableBytes { _ = memcpy($0.baseAddress, bp, canvas * canvas * 4) }
        return px
    }

    private static func overFull(_ base: inout [UInt8], _ over: [UInt8], count: Int) {
        for i in 0..<count {
            let j = i * 4
            let ia = 1.0 - Float(over[j+3]) / 255.0
            for c in 0..<4 { base[j+c] = UInt8(max(0, min(255, Float(over[j+c]) + Float(base[j+c]) * ia))) }
        }
    }

    private static func colorizeFull(_ img: inout [UInt8], spec: String, count: Int) {
        let f = spec.dropFirst("[colorize:".count).split(separator: ":", omittingEmptySubsequences: false)
        guard let colorStr = f.first, let c = parseColorRGBA(String(colorStr).replacingOccurrences(of: "]", with: "")) else { return }
        let rgb = [c[0], c[1], c[2]]
        let ratioTok = f.count > 1 ? f[1].replacingOccurrences(of: "]", with: "") : "alpha"   // Luanti: omitted ratio uses the colour's own alpha (#230)
        // "alpha" ratio = use the colour's own alpha channel as the blend ratio
        // (Luanti's [colorize:#RRGGBBAA:alpha), else a 0..255 amount.
        let ratio: Float = ratioTok == "alpha" ? c[3] / 255.0 : (Float(ratioTok) ?? 128) / 255.0
        for i in 0..<count {
            let j = i * 4
            let a = Float(img[j+3]) / 255.0
            if a <= 0 { continue }
            for c in 0..<3 {
                let straight = Float(img[j+c]) / a
                img[j+c] = UInt8(max(0, min(255, (straight * (1 - ratio) + rgb[c] * ratio) * a)))
            }
        }
    }

    public static func decodePNGFit(_ data: Data, canvas: Int) -> (px: [UInt8], uv: SIMD2<Float>)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        let s = min(Double(canvas) / Double(w), Double(canvas) / Double(h), 1.0)
        let dw = max(1, Int((Double(w) * s).rounded())), dh = max(1, Int((Double(h) * s).rounded()))
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                                  bytesPerRow: canvas * 4, space: cs, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: canvas - dh, width: dw, height: dh))  // top-left
        guard let base = ctx.data else { return nil }
        var px = [UInt8](repeating: 0, count: canvas * canvas * 4)
        px.withUnsafeMutableBytes { _ = memcpy($0.baseAddress, base, canvas * canvas * 4) }
        return (px, SIMD2(Float(dw) / Float(canvas), Float(dh) / Float(canvas)))
    }

    /// Decode a vertical animation strip (height a multiple of width) into its
    /// square frames, each downscaled to size*size premultiplied RGBA, frame 0 at
    /// the top (Luanti plays top->bottom). nil if it isn't a multi-frame strip.
    /// Parse a `[verticalframe:N:I` modifier out of a tile string. Returns the
    /// frame count N and a closure that rebuilds the tile with a given frame index
    /// (leaving the rest of the modifier chain intact), so the animator can render
    /// each frame of a liquid tile that the server pinned to one frame (#137).
    static func verticalFrameParts(_ tile: String) -> (n: Int, make: (Int) -> String)? {
        guard let r = tile.range(of: "[verticalframe:") else { return nil }
        let tail = tile[r.upperBound...]                    // "N:I<rest>"
        guard let colon = tail.firstIndex(of: ":") else { return nil }
        guard let n = Int(tail[..<colon]) else { return nil }
        let afterColon = tail[tail.index(after: colon)...]  // "I<rest>"
        let iDigits = afterColon.prefix { $0.isNumber }
        guard !iDigits.isEmpty else { return nil }
        let head = String(tile[..<r.upperBound]) + String(tail[..<colon]) + ":"   // "...[verticalframe:N:"
        let rest = String(afterColon[afterColon.index(afterColon.startIndex, offsetBy: iDigits.count)...])
        return (n, { i in "\(head)\(i)\(rest)" })
    }

    public static func decodePNGFrames(_ data: Data, size: Int) -> [[UInt8]]? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        guard w > 0, h > w, h % w == 0 else { return nil }
        let n = h / w
        guard n >= 2, n <= 64 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var out: [[UInt8]] = []
        for i in 0..<n {
            guard let frame = img.cropping(to: CGRect(x: 0, y: i * w, width: w, height: w)),
                  let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: cs, bitmapInfo: info) else { return nil }
            ctx.interpolationQuality = .none
            ctx.draw(frame, in: CGRect(x: 0, y: 0, width: size, height: size))
            guard let base = ctx.data else { return nil }
            var px = [UInt8](repeating: 0, count: size * size * 4)
            px.withUnsafeMutableBytes { _ = memcpy($0.baseAddress, base, size * size * 4) }
            out.append(px)
        }
        return out
    }

    public static func decodePNG(_ data: Data, size: Int) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        // Let CGContext own its backing store, then copy the pixels out.
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: cs, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .none
        // Tiles are often taller than wide (animation strips); draw just the top
        // square frame so a still frame shows instead of a squashed strip.
        let w = img.width, h = img.height
        let frame = (h > w && w > 0) ? w : h
        let toDraw = (h != frame)
            ? (img.cropping(to: CGRect(x: 0, y: 0, width: img.width, height: frame)) ?? img)
            : img
        ctx.draw(toDraw, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let base = ctx.data else { return nil }
        var px = [UInt8](repeating: 0, count: size * size * 4)
        px.withUnsafeMutableBytes { _ = memcpy($0.baseAddress, base, size * size * 4) }
        return px
    }
}
