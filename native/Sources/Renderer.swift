
import ARKit
import GameController
import CompositorServices
import LuantiKit
import QuartzCore
import ImageIO
import Metal
import MetalKit
import ModelIO
import simd
import UniformTypeIdentifiers

// Element-wise pushes for the 9-float vertex layout and quad/tri indices.
// The emitters used to build a temporary array per vertex/quad
// (`append(contentsOf: [...])`), which is a heap allocation each -- ~500-600
// per frame at 90 Hz just for the hand HUD, plus 6 per world billboard (300
// rain particles = +1800/frame). Same as WorldSession's pushV/pushQuad (#248).
@inline(__always) private func pushV9(_ a: inout [Float], _ x: Float, _ y: Float, _ z: Float,
                                       _ u: Float, _ v: Float, _ layer: Float, _ shade: Float,
                                       _ light: Float, _ tint: Float) {
    a.append(x); a.append(y); a.append(z); a.append(u); a.append(v)
    a.append(layer); a.append(shade); a.append(light); a.append(tint)
}

/// One textured quad from four corners in bottom-left, bottom-right, top-right,
/// top-left order with the standard (0,1) (1,1) (1,0) (0,0) uvs scaled by `uv`.
/// Takes the corners as arguments so the per-quad `[corners]` / `[uvs]` array
/// literals the emitters used to build (two mallocs per billboard per frame,
/// ~420 billboards at 90 Hz) are gone (perf review #310).
@inline(__always) private func pushQuadV9(_ a: inout [Float], _ bl: SIMD3<Float>, _ br: SIMD3<Float>,
                                          _ tr: SIMD3<Float>, _ tl: SIMD3<Float>, uv: SIMD2<Float> = SIMD2(1, 1),
                                          layer: Float, shade: Float, light: Float, tint: Float) {
    pushV9(&a, bl.x, bl.y, bl.z, 0, uv.y, layer, shade, light, tint)
    pushV9(&a, br.x, br.y, br.z, uv.x, uv.y, layer, shade, light, tint)
    pushV9(&a, tr.x, tr.y, tr.z, uv.x, 0, layer, shade, light, tint)
    pushV9(&a, tl.x, tl.y, tl.z, 0, 0, layer, shade, light, tint)
}
@inline(__always) private func pushQuad(_ a: inout [UInt32], _ b: UInt32) {
    a.append(b); a.append(b &+ 1); a.append(b &+ 2); a.append(b); a.append(b &+ 2); a.append(b &+ 3)
}
@inline(__always) private func pushTri(_ a: inout [UInt32], _ x: UInt32, _ y: UInt32, _ z: UInt32) {
    a.append(x); a.append(y); a.append(z)
}


// The 256 byte aligned size of our uniform structure
nonisolated let alignedUniformsSize = (MemoryLayout<Uniforms>.size + 0xFF) & -0x100
nonisolated let alignedViewProjectionArraySize = (MemoryLayout<ViewProjectionArray>.size + 0xFF) & -0x100

nonisolated let maxBuffersInFlight = 3

enum RendererError: Error {
    case badVertexDescriptor
}

extension MTLDevice {
    nonisolated var supportsMSAA: Bool {
        supports32BitMSAA && supportsTextureSampleCount(2)
    }

    nonisolated var rasterSampleCount: Int {
        supportsMSAA ? 2 : 1
    }
}

extension LayerRenderer.Clock.Instant {
    nonisolated var timeInterval: TimeInterval {
        let components = LayerRenderer.Clock.Instant.epoch.duration(to: self).components
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

final class RendererTaskExecutor: TaskExecutor {
    private let queue = DispatchQueue(label: "RenderThreadQueue", qos: .userInteractive)

    func enqueue(_ job: UnownedJob) {
        queue.async {
          job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    nonisolated func asUnownedSerialExecutor() -> UnownedTaskExecutor {
        return UnownedTaskExecutor(ordinary: self)
    }

    static var shared: RendererTaskExecutor = RendererTaskExecutor()
}

actor Renderer {

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    #if !targetEnvironment(simulator)
    let residencySets: [MTLResidencySet]
    let commandQueueResidencySet: MTLResidencySet
    #endif

    let dynamicUniformBuffer: MTLBuffer
    let pipelineState: MTLRenderPipelineState
    // #164: solid opaque blocks use a no-discard early-Z pipeline; the cutout
    // (leaves/plants/nodeboxes) portion keeps the discarding `pipelineState`.
    let worldOpaquePipelineState: MTLRenderPipelineState
    // The world is drawn PER MAPBLOCK now (#183): a dict of block -> GPU buffers
    // the mesher deltas in and out, one indexed draw per block per pass. Replaces
    // the single concatenated world/liquid buffers, so a dig re-uploads only the
    // touched blocks instead of the whole world every time.
    var worldBlocks: [SIMD3<Int>: MeshHandoff.BlockGPU] = [:]
    private let perf = PerfStats("frame")   // -vrdev.perfStats / testing mode: per-phase ms every 5 s
    // Frustum culling (perf #1): meshRef captured each frame from the render
    // state, and a reused scratch list of the block keys that pass the cull.
    private var worldMeshRef = SIMD3<Float>(0, 0, 0)
    private var worldEye = SIMD3<Float>(0, 0, 0)   // player pos in node coords, for front-to-back sort
    // Flat copy of worldBlocks for the per-frame cull: rebuilt only when the
    // block set changes (consumeHandoff), so the 90 Hz path walks a contiguous
    // array instead of a 7500-entry dictionary's bucket table, and the draw
    // passes index it instead of hashing each key three times (perf #310).
    private struct BlockEntry { let key: SIMD3<Int>; let loN: SIMD3<Float>; let gpu: MeshHandoff.BlockGPU }
    private var blockList: [BlockEntry] = []
    private var blockListDirty = true
    private var visibleBlocks: [(dist: Float, idx: Int)] = []
    // buildHandHud scratch (kept between frames, see there) + wield mesh extents.
    private var handV: [Float] = [], handIdx: [UInt32] = [], handVt: [Float] = [], handIdxt: [UInt32] = []
    private var wieldMeshExtent: [Int: Float] = [:]
    // Dev frustum-cull kill switch, read once (it's set at launch), not per frame.
    private lazy var noCull = UserDefaults.standard.bool(forKey: "vrdev.noCull")
    #if !targetEnvironment(simulator)
    // Dedicated residency set for the block buffers, rebuilt only when the block
    // set changes (not every frame) (#182/#183). One per in-flight slot so a
    // rebuild never mutates a set the GPU is still reading; a delta arms a refresh
    // countdown so every slot gets updated over the next few frames.
    var worldResidencySets: [MTLResidencySet] = []
    var worldResidencyRefresh = 0
    #endif
    let depthState: MTLDepthStencilState
    let skyPipelineState: MTLRenderPipelineState
    let skyDepthState: MTLDepthStencilState
    let underwaterPipelineState: MTLRenderPipelineState
    let underwaterDepthState: MTLDepthStencilState
    let vignettePipelineState: MTLRenderPipelineState   // diegetic low-health / low-breath edge cast (HUD P8)
    let noDepthState: MTLDepthStencilState   // always-pass, no write: HUD on top of walls
    let deathPipelineState: MTLRenderPipelineState

    let endFrameEvent: MTLSharedEvent
    var committedFrameIndex: UInt64 = 0

    var uniformBufferOffset = 0

    var uniformBufferIndex = 0

    var uniforms: UnsafeMutablePointer<Uniforms>

    var perDrawableTarget = [LayerRenderer.Drawable.Target: DrawableTarget]()

    var rotation: Float = 0

    var textureArray: MTLTexture?
    let liquidPipelineState: MTLRenderPipelineState
    let liquidDepthState: MTLDepthStencilState
    var entityVertexBuffer: MTLBuffer
    var entityIndexBuffer: MTLBuffer
    var entityIndexCount: Int = 0
    // Head-locked HUD billboards, placed per-drawable against the current head.
    var hudInstances: [EntityInstance] = []
    var hudVertexBuffer: MTLBuffer
    // Glass backing plate behind the low vitals band (HUD layout B): a blended,
    // soft-edged dark panel so the icons read in any scene. Its own pipeline
    // (blended) and buffers, built each frame with the HUD against the head pose.
    let hudGlassPipelineState: MTLRenderPipelineState
    var hudGlassVertexBuffer: MTLBuffer
    var hudGlassIndexBuffer: MTLBuffer
    var hudGlassIndexCount: Int = 0
    var hudIndexBuffer: MTLBuffer
    var hudIndexCount: Int = 0
    // Reused scratch for buildHudBillboards so the per-frame (90 fps) build stops
    // allocating fresh vertex/index arrays each call (perf review). The glass
    // panel's index list is constant.
    private var hudScratchV: [Float] = []
    private var hudScratchIdx: [UInt32] = []
    private var hudScratchGV: [Float] = []
    private static let hudGlassIdx: [UInt32] = [0, 1, 2, 0, 2, 3]
    private nonisolated(unsafe) var accessoryLogged: Set<String> = []   // one-shot [acc] pose log per chirality (#73); under accessoryLock
    // Hand-anchored HUD: wield item on the right hand (#66), hotbar on the left
    // wrist (#57). Built each frame from the tracked hand/controller poses.
    var handHudVertexBuffer: MTLBuffer
    var handHudIndexBuffer: MTLBuffer
    var handHudIndexCount: Int = 0
    // #158: the wield stack count samples the MODEL texture array (baked digits),
    // not the node atlas, so it rides its own small buffer drawn with that array.
    var handHudTextVertexBuffer: MTLBuffer
    var handHudTextIndexBuffer: MTLBuffer
    var handHudTextIndexCount: Int = 0
    // Wield animation (#136): track the wield identity to time a drop-and-pop on
    // switch, and a wall clock for the continuous dig swing.
    private var lastWieldKey: (Int, Int32) = (-1, -1)
    private var wieldSwitchTime: CFTimeInterval = -1e9
    var handVertexBuffer: MTLBuffer
    var handIndexBuffer: MTLBuffer
    var handIndexCount: Int = 0
    var modelVertexBuffer: MTLBuffer
    var modelIndexBuffer: MTLBuffer
    var modelIndexCount: Int = 0
    var overlayVertexBuffer: MTLBuffer
    var overlayIndexBuffer: MTLBuffer
    var overlayIndexCount: Int = 0
    // #163: last handoff generation consumed, so the 90Hz render loop skips
    // re-uploading the model/overlay streams the ~62.5Hz producer hasn't changed.
    private var lastModelGen = -1
    private var lastOverlayGen = -1
    var modelTextureArray: MTLTexture?
    // SET_SKY "skybox" cube (the End). A 1x1 black cube stays bound when
    // there is none so skyFragment always has a texture at its slot (#290).
    var skyboxTexture: MTLTexture?
    lazy var skyboxPlaceholder: MTLTexture? = {
        let d = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba8Unorm_srgb, size: 1, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        var px: [UInt8] = [0, 0, 0, 255]
        for f in 0..<6 { t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, slice: f, withBytes: &px, bytesPerRow: 4, bytesPerImage: 4) }
        return t
    }()
    // Cloud noise for skyFragment: the 4-octave value-noise fbm the shader used
    // to evaluate per pixel (16 hashes, ~250 ops, on 30-60% of an outdoor
    // frame) baked once into a tiling 256x256 texture and sampled once. The
    // lattice wraps at each octave (8/16/32/64 cells across), so it tiles
    // exactly; a mip chain keeps the far horizon from sparkling.
    lazy var cloudNoiseTexture: MTLTexture? = {
        let n = 256
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: n, height: n, mipmapped: true)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        func hash(_ x: Int, _ y: Int, _ k: Int) -> Float {
            var h = UInt32(truncatingIfNeeded: x) &* 374761393 &+ UInt32(truncatingIfNeeded: y) &* 668265263 &+ UInt32(k) &* 2246822519
            h = (h ^ (h >> 13)) &* 1274126177
            return Float(h ^ (h >> 16)) / Float(UInt32.max)
        }
        var px = [UInt8](repeating: 255, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                var v: Float = 0, a: Float = 0.5, cells = 8
                for k in 0..<4 {
                    let fx = Float(x) / Float(n) * Float(cells), fy = Float(y) / Float(n) * Float(cells)
                    let ix = Int(fx), iy = Int(fy)
                    var u = fx - Float(ix), w = fy - Float(iy)
                    u = u * u * (3 - 2 * u); w = w * w * (3 - 2 * w)
                    let c00 = hash(ix % cells, iy % cells, k), c10 = hash((ix + 1) % cells, iy % cells, k)
                    let c01 = hash(ix % cells, (iy + 1) % cells, k), c11 = hash((ix + 1) % cells, (iy + 1) % cells, k)
                    v += a * ((c00 * (1 - u) + c10 * u) * (1 - w) + (c01 * (1 - u) + c11 * u) * w)
                    a *= 0.5; cells *= 2
                }
                let b = UInt8(max(0, min(255, v * 255)))
                let o = (y * n + x) * 4
                px[o] = b; px[o + 1] = b; px[o + 2] = b
            }
        }
        TileMips.upload(t, slice: 0, px: px, edge: n)
        return t
    }()
    // Layers of modelTextureArray that hold real data; arrayLength is the
    // allocation (with headroom). Grows in place until it overflows.
    private var modelArrayLogical = 0
    var captureTexture: MTLTexture?   // CPU-readable copy of a frame, for screenshots
    let entityPipelineState: MTLRenderPipelineState
    let handPipelineState: MTLRenderPipelineState

    let worldTracking: WorldTrackingProvider
    let handTracking = HandTrackingProvider()   // free-hand poses (device only)
    // PSVR2 controllers: tracked as spatial accessories (hand tracking is off for
    // a hand holding a controller), giving their 6DoF pose so we can draw them.
    private var accessoryTracking: AccessoryTrackingProvider?
    private let accessoryLock = NSLock()
    private nonisolated(unsafe) var accessoryXforms: [String: simd_float4x4] = [:]
    private var arSessionRef: ARKitSession?
    private var handAuthorized = false
    static let useHandTracking = false   // Sense controllers are the only input; hands stay off
    let layerRenderer: LayerRenderer
    let appModel: AppModel

    init(_ layerRenderer: LayerRenderer, appModel: AppModel) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        self.appModel = appModel
        // Let the background mesher build Metal buffers off the render thread.
        appModel.meshHandoff.device = layerRenderer.device

        let device = self.device
        self.commandQueue = self.device.makeCommandQueue()!

        #if !targetEnvironment(simulator)
        let residencySetDesc = MTLResidencySetDescriptor()
        residencySetDesc.initialCapacity = 3 // color + depth + view projection buffer
        self.residencySets = (0...maxBuffersInFlight).map { _ in try! device.makeResidencySet(descriptor: residencySetDesc) }
        #endif

        self.endFrameEvent = device.makeSharedEvent()!
        // Start the signal value + committed frames index at
        // max buffers in flight to avoid negative values
        self.endFrameEvent.signaledValue = UInt64(maxBuffersInFlight)
        committedFrameIndex = UInt64(maxBuffersInFlight)

        let uniformBufferSize = alignedUniformsSize * maxBuffersInFlight

        self.dynamicUniformBuffer = self.device.makeBuffer(length: uniformBufferSize,
                                                           options: [MTLResourceOptions.storageModeShared])!

        self.dynamicUniformBuffer.label = "UniformBuffer"

        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents()).bindMemory(to: Uniforms.self, capacity: 1)

        let mtlVertexDescriptor = Self.buildMetalVertexDescriptor()

        do {
            pipelineState = try Self.buildRenderPipeline(device: device,
                                                         layerRenderer: layerRenderer,
                                                         mtlVertexDescriptor: mtlVertexDescriptor)
            worldOpaquePipelineState = try Self.buildRenderPipeline(device: device,
                                                         layerRenderer: layerRenderer,
                                                         mtlVertexDescriptor: mtlVertexDescriptor,
                                                         fragment: "fragmentShaderOpaque")
        } catch {
            fatalError("Unable to compile render pipeline state.  Error info: \(error)")
        }

        self.depthState = Self.buildDepthStencilState(device: device)

        do {
            skyPipelineState = try Self.buildSkyPipeline(device: device, layerRenderer: layerRenderer)
        } catch { fatalError("Unable to compile sky pipeline: \(error)") }
        let skyDepthDesc = MTLDepthStencilDescriptor()
        skyDepthDesc.depthCompareFunction = .greater  // reverse-Z: only where the world left the clear depth
        skyDepthDesc.isDepthWriteEnabled = true
        self.skyDepthState = device.makeDepthStencilState(descriptor: skyDepthDesc)!

        do {
            underwaterPipelineState = try Self.buildUnderwaterPipeline(device: device, layerRenderer: layerRenderer)
        } catch { fatalError("Unable to compile underwater pipeline: \(error)") }
        do {
            vignettePipelineState = try Self.buildTintPipeline(device: device, layerRenderer: layerRenderer,
                                                              fragment: "vignetteFragment", vertex: "vignetteVertex")
        } catch { fatalError("Unable to compile vignette pipeline: \(error)") }
        let uwDepth = MTLDepthStencilDescriptor()
        uwDepth.depthCompareFunction = .always   // tint over everything already drawn
        uwDepth.isDepthWriteEnabled = false      // colour-only blend; leave depth intact
        self.underwaterDepthState = device.makeDepthStencilState(descriptor: uwDepth)!
        let nd = MTLDepthStencilDescriptor()
        nd.depthCompareFunction = .always; nd.isDepthWriteEnabled = false
        self.noDepthState = device.makeDepthStencilState(descriptor: nd)!
        do {
            deathPipelineState = try Self.buildTintPipeline(device: device, layerRenderer: layerRenderer, fragment: "deathFragment")
        } catch { fatalError("Unable to compile death pipeline: \(error)") }

        do {
            liquidPipelineState = try Self.buildLiquidPipeline(device: device, layerRenderer: layerRenderer,
                                                               mtlVertexDescriptor: mtlVertexDescriptor)
        } catch { fatalError("Unable to compile liquid pipeline: \(error)") }
        let liqDepth = MTLDepthStencilDescriptor()
        liqDepth.depthCompareFunction = .greater   // reverse-Z, test against opaque
        liqDepth.isDepthWriteEnabled = false        // don't occlude; blend over
        self.liquidDepthState = device.makeDepthStencilState(descriptor: liqDepth)!
        do {
            entityPipelineState = try Self.buildEntityPipeline(device: device, layerRenderer: layerRenderer,
                                                               mtlVertexDescriptor: mtlVertexDescriptor)
        } catch { fatalError("Unable to compile entity pipeline: \(error)") }
        do {
            hudGlassPipelineState = try Self.buildGlassPipeline(device: device, layerRenderer: layerRenderer,
                                                               mtlVertexDescriptor: mtlVertexDescriptor)
        } catch { fatalError("Unable to compile glass pipeline: \(error)") }
        do {
            handPipelineState = try Self.buildHandPipeline(device: device, layerRenderer: layerRenderer,
                                                           mtlVertexDescriptor: mtlVertexDescriptor)
        } catch { fatalError("Unable to compile hand pipeline: \(error)") }
        entityVertexBuffer = device.makeBuffer(length: 32, options: [.storageModeShared])!
        entityIndexBuffer = device.makeBuffer(length: 4, options: [.storageModeShared])!
        hudVertexBuffer = device.makeBuffer(length: 32, options: [.storageModeShared])!
        hudGlassVertexBuffer = device.makeBuffer(length: 32, options: [.storageModeShared])!
        hudGlassIndexBuffer = device.makeBuffer(length: 4, options: [.storageModeShared])!
        hudIndexBuffer = device.makeBuffer(length: 4, options: [.storageModeShared])!
        handHudVertexBuffer = device.makeBuffer(length: 32, options: [.storageModeShared])!
        handHudTextVertexBuffer = device.makeBuffer(length: 32, options: [.storageModeShared])!
        handHudTextIndexBuffer = device.makeBuffer(length: 4, options: [.storageModeShared])!
        handHudIndexBuffer = device.makeBuffer(length: 4, options: [.storageModeShared])!
        handVertexBuffer = device.makeBuffer(length: 32, options: [.storageModeShared])!
        handIndexBuffer = device.makeBuffer(length: 4, options: [.storageModeShared])!
        modelVertexBuffer = device.makeBuffer(length: 32, options: [.storageModeShared])!
        modelIndexBuffer = device.makeBuffer(length: 4, options: [.storageModeShared])!
        overlayVertexBuffer = device.makeBuffer(length: 32, options: [.storageModeShared])!
        overlayIndexBuffer = device.makeBuffer(length: 4, options: [.storageModeShared])!

        // The streamed world starts empty; blocks arrive as deltas via
        // consumeMeshHandoff once the first chunks are meshed (sky-only until then).

        #if !targetEnvironment(simulator)
        // Add persistent resources to the command queue residency set (after all
        // resources are loaded). World block buffers live in their own per-slot
        // sets (worldResidencySets), rebuilt only on a block-set change.
        residencySetDesc.initialCapacity = 4
        let residencySet = try! self.device.makeResidencySet(descriptor: residencySetDesc)
        residencySet.addAllocations([dynamicUniformBuffer])
        residencySet.commit()
        commandQueueResidencySet = residencySet
        commandQueue.addResidencySet(residencySet)
        let worldResDesc = MTLResidencySetDescriptor()
        worldResDesc.initialCapacity = 512
        worldResidencySets = (0...maxBuffersInFlight).map { _ in try! device.makeResidencySet(descriptor: worldResDesc) }
        #endif

        worldTracking = WorldTrackingProvider()

    }

    private func startARSession(_ arSession: ARKitSession) async {
        arSessionRef = arSession
        print("[hands] HandTrackingProvider.isSupported=\(HandTrackingProvider.isSupported)"); fflush(stdout)
        // PSVR2 Sense controllers only: no hand tracking (no permission prompt,
        // and no await window for controllers to connect into before the
        // accessory observer exists).
        if Renderer.useHandTracking, HandTrackingProvider.isSupported {
            let auth = await arSession.requestAuthorization(for: [.handTracking])
            print("[hands] auth = \(String(describing: auth[.handTracking]))"); fflush(stdout)
            handAuthorized = auth[.handTracking] == .allowed
            if handAuthorized { print("[hands] hand tracking ON"); fflush(stdout) }
        }
        let accProvider = await makeAccessoryProvider()
        do {
            try await arSession.run(currentProviders(accProvider))
        } catch {
            print("[hands] ARKit run failed (\(error)); head only"); fflush(stdout)
            do { try await arSession.run([worldTracking]) }
            catch { fatalError("Failed to initialize ARSession") }
        }
        if let accProvider { consumeAccessoryUpdates(accProvider) }
        arSessionRunning = true
        // Controllers can turn on after launch; re-enumerate accessories then.
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.rebuildAccessories() }
        }
        // #73: both Sense controllers connected DURING the awaits above (the hand
        // tracking auth prompt + session start), before this observer existed, so
        // the session ran with zero accessories and no hand boxes ever showed.
        // Catch up once now.
        if accProvider == nil, !GCController.controllers().isEmpty { await rebuildAccessories() }
    }
    private var arSessionRunning = false

    private func currentProviders(_ acc: AccessoryTrackingProvider?) -> [any DataProvider] {
        var p: [any DataProvider] = [worldTracking]
        if handAuthorized { p.append(handTracking) }
        if let acc { p.append(acc) }
        return p
    }

    /// Build an AccessoryTrackingProvider from every connected spatial controller.
    private func makeAccessoryProvider() async -> AccessoryTrackingProvider? {
        var accessories: [Accessory] = []
        let all = GCController.controllers()
        print("[accessory] enumerate \(all.count) controllers; supported=\(AccessoryTrackingProvider.isSupported)"); fflush(stdout)
        for c in all {
            print("[accessory]  candidate vendor=\(c.vendorName ?? "?") cat=\(c.productCategory)"); fflush(stdout)
            do {
                let a = try await Accessory(device: c)
                accessories.append(a)
                print("[accessory]  built accessory for \(c.vendorName ?? "?")"); fflush(stdout)
            } catch {
                print("[accessory]  Accessory(device:) failed for \(c.vendorName ?? "?"): \(error)"); fflush(stdout)
            }
        }
        print("[accessory] \(accessories.count) spatial accessories"); fflush(stdout)
        guard !accessories.isEmpty else { accessoryTracking = nil; return nil }
        let p = AccessoryTrackingProvider(accessories: accessories)
        accessoryTracking = p
        return p
    }

    /// Re-run the session including any newly-connected controllers.
    private func rebuildAccessories() async {
        print("[accessory] rebuild (a controller connected)"); fflush(stdout)
        guard arSessionRunning, let arSession = arSessionRef else { return }
        let acc = await makeAccessoryProvider()
        guard let acc else { return }
        try? await arSession.run(currentProviders(acc))
        consumeAccessoryUpdates(acc)
    }

    /// Stream controller poses into accessoryXforms (keyed by handedness).
    private func consumeAccessoryUpdates(_ provider: AccessoryTrackingProvider) {
        Task { [weak self] in
            for await update in provider.anchorUpdates {
                guard let self else { return }
                let a = update.anchor
                let key = "\(a.accessory.inherentChirality)"
                self.accessoryLock.lock()
                // One-shot per key: what the accessory pose actually looks like
                // (#73: boxes/wield don't show at held controllers though acc=2).
                if !self.accessoryLogged.contains(key) {
                    self.accessoryLogged.insert(key)
                    let t = a.originFromAnchorTransform.columns.3
                    print("[acc] key=\(key) tracked=\(a.isTracked) t=(\(t.x), \(t.y), \(t.z))"); fflush(stdout)
                }
                if a.isTracked { self.accessoryXforms[key] = a.originFromAnchorTransform }
                else { self.accessoryXforms.removeValue(forKey: key) }
                self.accessoryLock.unlock()
            }
        }
    }

    /// Rebuild the two small hand boxes at the tracked controller/hand anchors.
    /// No-op in the sim (no hand tracking), so it's safe there.
    private var handLogTick = 0
    #if targetEnvironment(simulator)
    /// The simulator has no controllers and AccessoryTracking is compiled out, so
    /// accessoryXforms stays empty and the hands/wield/hotbar never render there.
    /// Publish two synthetic hand poses (immersive-origin space, the same space
    /// real accessory poses use) so those can be screenshotted and iterated in the sim
    /// without the headset. Opt out with -vrdev.noFakeHands 1. The keys contain
    /// "left"/"right" so handPose()/appendAccessoryBoxes match them.
    private func simulateHandPoses() {
        if UserDefaults.standard.bool(forKey: "vrdev.noFakeHands") { return }
        // Anchor to the head pose (the sim camera isn't at the origin), so the
        // hands sit below-forward of the actual view like real held controllers.
        let head = appModel.player.headXform()
        func hand(_ x: Float) -> simd_float4x4 {
            var local = matrix_identity_float4x4
            // Higher and closer than a real held controller: the sim eye is fixed
            // and level, so this centres the wield + wrist ring in the screenshot
            // frame instead of pushing them into the lower corners.
            local.columns.3 = SIMD4<Float>(x, -0.14, -0.32, 1)   // right/down/forward of the head
            return head * local
        }
        accessoryLock.lock()
        accessoryXforms["simLeft"]  = hand(-0.16)
        accessoryXforms["simRight"] = hand(0.16)
        accessoryLock.unlock()
    }
    #endif

    /// Extra rotation composed onto the device anchor: identity on device; in
    /// the sim an optional -vrdev.pitch / -vrdev.yaw (degrees) so a headless
    /// screenshot can look up at the sky or turn (#119). The sim's anchor is
    /// present but untracked (so a nil-fallback never fires), hence composing.
    /// Applied to both the view matrix and the HUD/hands/raycast head so they
    /// stay consistent.
    nonisolated static func simHeadOffset() -> simd_float4x4 {
        #if targetEnvironment(simulator)
        let d = UserDefaults.standard
        // -vrdev.down <deg> is the way to look down: UserDefaults reads a
        // leading-dash value ("-vrdev.pitch -45") as the next flag, so
        // negative pitches silently become 0.
        let pitch = Float(d.double(forKey: "vrdev.pitch") - d.double(forKey: "vrdev.down")) * .pi / 180
        // -vrdev.spin <deg/sec>: a continuous auto-pan on top of the static yaw,
        // so a screen recording shows a smooth turn across the world for a demo
        // clip (no controller needed). Uses monotonic uptime so it's time-based.
        let spin = d.double(forKey: "vrdev.spin")
        let yaw = Float(d.double(forKey: "vrdev.yaw")) * .pi / 180
                + (spin != 0 ? Float(ProcessInfo.processInfo.systemUptime * spin) * .pi / 180 : 0)
        if pitch == 0 && yaw == 0 { return matrix_identity_float4x4 }
        // Yaw about the world up axis, then pitch about the head's right axis;
        // +pitch tilts the forward (-Z) ray up toward +Y.
        return matrix4x4_rotation(radians: yaw, axis: SIMD3(0, 1, 0))
             * matrix4x4_rotation(radians: pitch, axis: SIMD3(1, 0, 0))
        #else
        return matrix_identity_float4x4
        #endif
    }

    private func consumeHands() {
        handIndexCount = 0
        var v: [Float] = []; var idx: [UInt32] = []
        v.reserveCapacity(512); idx.reserveCapacity(128)   // hand boxes, rebuilt per frame (perf #2)
        if HandTrackingProvider.isSupported, handTracking.state == .running {
            let anchors = handTracking.latestAnchors
            handLogTick += 1
            if handLogTick % 180 == 0 {
                print("[hands] hand L=\(anchors.leftHand?.isTracked == true) R=\(anchors.rightHand?.isTracked == true) acc=\(accessoryXforms.count)"); fflush(stdout)
            }
            for hand in [anchors.leftHand, anchors.rightHand] {
                guard let h = hand, h.isTracked else { continue }
                appendHandBox(h.originFromAnchorTransform, v: &v, idx: &idx)
            }
        }
        appendAccessoryBoxes(v: &v, idx: &idx)
        guard !v.isEmpty else { handIndexCount = 0; return }
        upload(v, into: &handVertexBuffer)
        upload(idx, into: &handIndexBuffer)
        handIndexCount = idx.count
    }

    /// Draw a box at each tracked controller (spatial accessory) pose.
    private func appendAccessoryBoxes(v: inout [Float], idx: inout [UInt32]) {
        // Draw the hand/controller box for BOTH hands, including the wielding
        // hand. Desktop hides the arm behind a first-person wield, but in VR the
        // controller IS the hand: hiding it left the wield item floating in
        // space with nothing to ground it (#66). Showing the box makes the wield
        // read as held (the item sits just above the palm; see buildHandHud).
        accessoryLock.lock(); let xs = accessoryXforms; accessoryLock.unlock()
        for (_, m) in xs {
            appendHandBox(m, v: &v, idx: &idx)
        }
    }

    /// Best pose for one hand: prefer the tracked controller (accessory, keyed by
    /// chirality), else the bare-hand anchor. nil if neither is tracked.
    // Both hand poses, resolved once per frame. handPose() is asked 4x a frame
    // at 90 Hz (wield, hotbar, armor, pointer ray) and each call took the
    // accessory lock, copied the dict and lowercased every key (perf review #7).
    private var poseFrame: UInt64 = .max
    private var poseLeft: simd_float4x4?, poseRight: simd_float4x4?
    private func resolveHandPoses(frameIndex: UInt64) {
        guard poseFrame != frameIndex else { return }
        poseFrame = frameIndex
        accessoryLock.lock(); let acc = accessoryXforms; accessoryLock.unlock()
        var l: simd_float4x4? = nil, r: simd_float4x4? = nil
        for (k, m) in acc {
            let lk = k.lowercased()
            if l == nil, lk.contains("left") { l = m }
            if r == nil, lk.contains("right") { r = m }
        }
        if (l == nil || r == nil), HandTrackingProvider.isSupported, handTracking.state == .running {
            let a = handTracking.latestAnchors
            if l == nil, let h = a.leftHand, h.isTracked { l = h.originFromAnchorTransform }
            if r == nil, let h = a.rightHand, h.isTracked { r = h.originFromAnchorTransform }
        }
        poseLeft = l; poseRight = r
    }
    private func handPose(left: Bool) -> simd_float4x4? { left ? poseLeft : poseRight }

    /// A textured quad lying flat in a hand anchor's local X/Z plane, offset in
    /// hand-local metres. Orientation is a first cut for device iteration.
    private func emitHandQuad(_ m: simd_float4x4, offset: SIMD3<Float>, size: Float,
                             layer: Int32, uv: SIMD2<Float>, into v: inout [Float], idx: inout [UInt32]) {
        let s = size * 0.5
        func xf(_ l: SIMD3<Float>) -> SIMD3<Float> { let p = m * SIMD4<Float>(offset + l, 1); return SIMD3(p.x, p.y, p.z) }
        let base = UInt32(v.count / 9)
        pushQuadV9(&v, xf(SIMD3(-s, 0, -s)), xf(SIMD3(s, 0, -s)), xf(SIMD3(s, 0, s)), xf(SIMD3(-s, 0, s)),
                   uv: uv, layer: Float(layer), shade: 1.0, light: 255, tint: 16777215)
        pushQuad(&idx, base)
    }

    /// An extruded item silhouette (desktop-style wield mesh), item-local coords
    /// in [-0.5,0.5]. Transformed by the wield anchor `m`, scaled by `size`; the
    /// mesh's 0..1 icon UVs are scaled onto the atlas layer's sub-rect (`uv`).
    private func emitHandSilhouette(_ m: simd_float4x4, mesh: B3DLoader.Mesh, size: Float,
                                    layer: Int32, uv: SIMD2<Float>, light: Float = 255,
                                    into v: inout [Float], idx: inout [UInt32]) {
        let base = UInt32(v.count / 9)
        let l = Float(layer)
        for k in 0..<mesh.positions.count {
            let p = m * SIMD4<Float>(mesh.positions[k] * size, 1)
            let t = mesh.uvs[k]
            pushV9(&v, p.x, p.y, p.z, t.x * uv.x, t.y * uv.y, l, 1.0, light, 16777215)
        }
        for i in mesh.indices { idx.append(base + i) }
    }

    /// A textured cube (block wield item) at a hand pose, one face layer each
    /// (order +Y,-Y,+X,-X,+Z,-Z, matching NodeRegistry face tiles).
    private func emitHandCube(_ m: simd_float4x4, offset: SIMD3<Float>, size: Float,
                              layers: [Int32], light: Float = 255, into v: inout [Float], idx: inout [UInt32]) {
        guard layers.count == 6 else { return }
        let h = size * 0.5
        // (normal-index -> 4 corners) in a unit cube centred at offset.
        let faces: [(l: Int, c: [SIMD3<Float>])] = [
            (0, [SIMD3(-h, h, -h), SIMD3(-h, h, h), SIMD3(h, h, h), SIMD3(h, h, -h)]),   // +Y
            (1, [SIMD3(-h, -h, h), SIMD3(-h, -h, -h), SIMD3(h, -h, -h), SIMD3(h, -h, h)]), // -Y
            (2, [SIMD3(h, -h, h), SIMD3(h, -h, -h), SIMD3(h, h, -h), SIMD3(h, h, h)]),    // +X
            (3, [SIMD3(-h, -h, -h), SIMD3(-h, -h, h), SIMD3(-h, h, h), SIMD3(-h, h, -h)]), // -X
            (4, [SIMD3(-h, -h, h), SIMD3(h, -h, h), SIMD3(h, h, h), SIMD3(-h, h, h)]),    // +Z
            (5, [SIMD3(h, -h, -h), SIMD3(-h, -h, -h), SIMD3(-h, h, -h), SIMD3(h, h, -h)]), // -Z
        ]
        func xf(_ l: SIMD3<Float>) -> SIMD3<Float> { let p = m * SIMD4<Float>(offset + l, 1); return SIMD3(p.x, p.y, p.z) }
        for f in faces {
            let base = UInt32(v.count / 9)
            pushQuadV9(&v, xf(f.c[0]), xf(f.c[1]), xf(f.c[2]), xf(f.c[3]),
                       layer: Float(layers[f.l]), shade: 1.0, light: light, tint: 16777215)
            pushQuad(&idx, base)
        }
    }

    /// A quad in a hand anchor's local space with an explicit width/height frame
    /// (for the wrist-wrapped hotbar). center/wAxis/hAxis are hand-local; wAxis
    /// and hAxis are unit directions scaled by `half`.
    private func emitHandQuadFrame(_ m: simd_float4x4, center: SIMD3<Float>,
                                   wAxis: SIMD3<Float>, hAxis: SIMD3<Float>, half: Float,
                                   layer: Int32, uv: SIMD2<Float>, into v: inout [Float], idx: inout [UInt32]) {
        let w = wAxis * half, h = hAxis * half
        func xf(_ l: SIMD3<Float>) -> SIMD3<Float> { let p = m * SIMD4<Float>(l, 1); return SIMD3(p.x, p.y, p.z) }
        let base = UInt32(v.count / 9)
        pushQuadV9(&v, xf(center - w - h), xf(center + w - h), xf(center + w + h), xf(center - w + h),
                   uv: uv, layer: Float(layer), shade: 1.0, light: 255, tint: 16777215)
        pushQuad(&idx, base)
    }

    /// A tinted rectangle in a hand frame (explicit half-width/height), for the
    /// wield durability bar. `tint` is packed r + g*256 + b*65536.
    private func emitHandRect(_ m: simd_float4x4, center: SIMD3<Float>,
                              wAxis: SIMD3<Float>, hAxis: SIMD3<Float>, halfW: Float, halfH: Float,
                              layer: Int32, tint: Float, into v: inout [Float], idx: inout [UInt32]) {
        let w = wAxis * halfW, h = hAxis * halfH
        func xf(_ l: SIMD3<Float>) -> SIMD3<Float> { let p = m * SIMD4<Float>(l, 1); return SIMD3(p.x, p.y, p.z) }
        let base = UInt32(v.count / 9)
        pushQuadV9(&v, xf(center - w - h), xf(center + w - h), xf(center + w + h), xf(center - w + h),
                   layer: Float(layer), shade: 1.0, light: 15, tint: tint)
        pushQuad(&idx, base)
    }

    /// A flat item icon extruded into a thin slab (upright, facing ±Z), the
    /// first-person "item in hand" look for tools/craftitems. Icon on the front
    /// and back; thin edges give it depth.
    private func emitHandSlab(_ m: simd_float4x4, offset: SIMD3<Float>, size: Float,
                              layer: Int32, uv: SIMD2<Float>, light: Float = 255,
                              into v: inout [Float], idx: inout [UInt32]) {
        let h = size * 0.5, d = size * 0.06        // half-size and half-depth
        let l = Float(layer)
        // Tilt so it reads like a first-person held tool (Minecraft-style): laid
        // back toward the player and rolled diagonally, so a pickaxe/axe extends
        // up-forward from the fist instead of lying flat. Tune on device.
        let pitch: Float = -0.85, roll: Float = -0.55
        let cx = cosf(pitch), sx = sinf(pitch), cz = cosf(roll), sz = sinf(roll)
        func tilt(_ p: SIMD3<Float>) -> SIMD3<Float> {   // rotZ(roll) * rotX(pitch)
            let y1 = p.y * cx - p.z * sx, z1 = p.y * sx + p.z * cx
            return SIMD3(p.x * cz - y1 * sz, p.x * sz + y1 * cz, z1)
        }
        func quad(_ c: [SIMD3<Float>], _ t: [(Float, Float)]) {
            let base = UInt32(v.count / 9)
            for k in 0..<4 {
                let p = m * SIMD4<Float>(offset + tilt(c[k]), 1)
                pushV9(&v, p.x, p.y, p.z, t[k].0 * uv.x, t[k].1 * uv.y, l, 1.0, light, 16777215)
            }
            pushQuad(&idx, base)
        }
        let full: [(Float, Float)] = [(0, 1), (1, 1), (1, 0), (0, 0)]
        // front (+Z) and back (-Z): the icon.
        quad([SIMD3(-h, -h, d), SIMD3(h, -h, d), SIMD3(h, h, d), SIMD3(-h, h, d)], full)
        quad([SIMD3(h, -h, -d), SIMD3(-h, -h, -d), SIMD3(-h, h, -d), SIMD3(h, h, -d)], full)
        // thin edges (sample the icon border so they aren't transparent).
        let edge: [(Float, Float)] = [(0, 1), (1, 1), (1, 1), (0, 1)]
        quad([SIMD3(-h, h, d), SIMD3(h, h, d), SIMD3(h, h, -d), SIMD3(-h, h, -d)], edge)   // top
        quad([SIMD3(-h, -h, -d), SIMD3(h, -h, -d), SIMD3(h, -h, d), SIMD3(-h, -h, d)], edge) // bottom
        quad([SIMD3(h, -h, d), SIMD3(h, -h, -d), SIMD3(h, h, -d), SIMD3(h, h, d)], edge)    // right
        quad([SIMD3(-h, -h, -d), SIMD3(-h, -h, d), SIMD3(-h, h, d), SIMD3(-h, h, -d)], edge) // left
    }

    /// Build the hand-anchored HUD: wield item on the right hand, hotbar strip on
    /// the left wrist. Uses the node atlas (textureArray), like the entity pass.
    private func buildHandHud() {
        handHudIndexCount = 0
        handHudTextIndexCount = 0
        let hud = appModel.handHudHandoff.read()
        // Wield + wrist hotbar + armor is ~100 quads rebuilt every frame: the
        // four scratch arrays are instance properties emptied with their
        // capacity kept, so nothing is malloced per frame (a fresh
        // reserveCapacity(4096) was a 16 KB allocation at 90 Hz, perf #310).
        handV.removeAll(keepingCapacity: true); handIdx.removeAll(keepingCapacity: true)
        handVt.removeAll(keepingCapacity: true); handIdxt.removeAll(keepingCapacity: true)
        var v = handV, idx = handIdx
        var vt = handVt, idxt = handIdxt   // count digits (model-texture array)
        handV = []; handIdx = []; handVt = []; handIdxt = []   // keep the storage uniquely owned by the locals
        defer { handV = v; handIdx = idx; handVt = vt; handIdxt = idxt }
        // Wielded item, pinned to the HEAD at a fixed lower-right offset like
        // the RIGHT hand/controller, so the item lives in your hand like a real
        // held tool (Eric chose hand-attached over desktop's camera-lock). The
        // grip transform sits the item forward-and-up of the fist with a tool
        // tilt; hand-local axes are +Y up, -Z forward (matching #66's offsets).
        // Numbers are a starting point to tune on device (the sim's fake hand is
        // not a real controller pose).
        if let w = hud.wield, let hand = handPose(left: false) {
            // Animate (#136): a quick drop-and-pop when the wield changes, and a
            // continuous swing while digging. Both ride on top of the grip so the
            // resting pose (offset/tilt/size) is unchanged.
            let now = CACurrentMediaTime()
            let key: (Int, Int32) = {
                switch w {
                case .block(let l): return (hud.wieldIndex, l.first ?? -1)
                case .item(let l, _): return (hud.wieldIndex, l)
                case .mesh(_, let l): return (hud.wieldIndex, l)
                }
            }()
            if key != lastWieldKey { lastWieldKey = key; wieldSwitchTime = now }
            var dipY: Float = 0, swing: Float = 0
            let popDur = 0.18, popAmp: Float = 0.05
            let sp = now - wieldSwitchTime
            if sp >= 0 && sp < popDur { dipY = -popAmp * Float(sin(sp / popDur * .pi)) }   // down then back
            if hud.digging { swing = 0.5 * Float(sin(now * 2 * 2 * .pi)) }                  // ~2 Hz pitch swing
            let grip = hand * matrix4x4_translation(0.0, 0.035 + dipY, -0.10)               // forward-up of the fist
                            * matrix4x4_rotation(radians: swing, axis: SIMD3(1, 0, 0))
            switch w {
            case .block(let layers):
                // Tilt to a 3D corner (top + front + side) like a held block.
                let m = grip * matrix4x4_rotation(radians: -0.5, axis: SIMD3(0, 1, 0))
                             * matrix4x4_rotation(radians: 0.4, axis: SIMD3(1, 0, 0))
                emitHandCube(m, offset: .zero, size: 0.11, layers: layers, light: hud.wieldLight, into: &v, idx: &idx)
            case .mesh(let model, let layer):
                // A mesh node (chest etc): draw the real model at the same 3/4
                // presentation angle as a held block, textured with its one tile.
                // Model coords are NOT node-local: a chest b3d spans ~+-4.4 units
                // (the node applies visual_scale ~0.1 in-world). Normalize by the
                // model's largest extent so any authored scale fits the block-size
                // wield, instead of assuming [-0.5,0.5] (which made the chest ~10x
                // too big). Empty/degenerate model -> fall back to the old size.
                // Cached: the extent scan is the same every frame for the same
                // held model. Mesh is a value type, so key on the array's
                // storage identity (its buffer pointer + count), which only
                // changes when a different model is handed off.
                let key = model.positions.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) ^ ($0.count << 40) }
                let extent: Float
                if let e = wieldMeshExtent[key] { extent = e }
                else {
                    var lo = model.positions.first ?? .zero, hi = lo
                    for p in model.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
                    extent = max(hi.x - lo.x, max(hi.y - lo.y, hi.z - lo.z))
                    if wieldMeshExtent.count > 64 { wieldMeshExtent.removeAll() }
                    wieldMeshExtent[key] = extent
                }
                let s: Float = extent > 1e-4 ? 0.12 / extent : 0.12
                let m = grip * matrix4x4_rotation(radians: -0.5, axis: SIMD3(0, 1, 0))
                             * matrix4x4_rotation(radians: 0.4, axis: SIMD3(1, 0, 0))
                emitHandSilhouette(m, mesh: model, size: s, layer: layer, uv: SIMD2(1, 1), light: hud.wieldLight, into: &v, idx: &idx)
            case .item(let layer, let uv):
                // Angle the tool up-forward out of the fist (diagonal like desktop).
                let tilt = matrix4x4_rotation(radians: -0.55, axis: SIMD3(0, 0, 1))
                         * matrix4x4_rotation(radians: -0.85, axis: SIMD3(1, 0, 0))
                if let sil = hud.wieldSilhouette {
                    emitHandSilhouette(grip * tilt, mesh: sil, size: 0.16 * hud.wieldScale, layer: layer, uv: uv, light: hud.wieldLight, into: &v, idx: &idx)
                } else {
                    emitHandSlab(grip, offset: .zero, size: 0.15 * hud.wieldScale, layer: layer, uv: uv, light: hud.wieldLight, into: &v, idx: &idx)
                }
            }
            // Count and wear both sit like a wristwatch: a small patch on top of
            // the wrist (hand-local +Y), just toward the elbow, raised off the
            // surface so it doesn't sink in. Anchored to `hand`, not `grip`, so
            // they stay on the arm instead of floating by the held item (#168).
            // A stackable item never has wear, so the two share this spot freely.
            let watchAcross = SIMD3<Float>(1, 0, 0)          // around the wrist (band width)
            let watchAlong  = SIMD3<Float>(0, 0, 1)          // toward the elbow (band length)
            let watchCenter = SIMD3<Float>(0, 0.040, 0.055)  // top of the wrist, just above the surface
            // Stack count (#158): a small camera-facing BILLBOARD at the wrist,
            // not a label lying flat on the watch face. A flat label grazed the
            // hand angle and read mirrored/upside-down (#168); a billboard is
            // always upright and legible at any hand pose (like a hotbar-cell
            // count). Anchored at the wrist world point, oriented by the head's
            // right/up so it faces you. The text pass is cull .none, so one quad
            // shows from both sides.
            if hud.wieldCountLayer >= 0 {
                let th: Float = 0.018
                let tw = th * max(0.3, hud.wieldCountAspect)
                let cw = hand * SIMD4<Float>(watchCenter, 1)
                let center = SIMD3<Float>(cw.x, cw.y, cw.z)
                let head = appModel.player.headXform()
                let hr = simd_normalize(SIMD3<Float>(head.columns.0.x, head.columns.0.y, head.columns.0.z))
                let hu = simd_normalize(SIMD3<Float>(head.columns.1.x, head.columns.1.y, head.columns.1.z))
                emitHandRect(matrix_identity_float4x4, center: center, wAxis: hr, hAxis: hu,
                             halfW: tw, halfH: th, layer: hud.wieldCountLayer, tint: 16777215, into: &vt, idx: &idxt)
            }
            // Durability (#159): a short band across the wrist, green->red by
            // remaining, filled from one end like a gauge.
            if hud.wieldWear < 0.999 {
                let rem = max(0, min(1, hud.wieldWear))
                let half: Float = 0.032                        // short watch-width band
                emitHandRect(hand, center: watchCenter, wAxis: watchAcross, hAxis: watchAlong, halfW: half, halfH: 0.010,
                             layer: hud.whiteLayer, tint: Float(20 + 20*256 + 20*65536), into: &v, idx: &idx)
                let fw = max(0.001, half * rem)                // fill from the -X end
                // Sit the fill a hair above the backdrop band; drawn coplanar they
                // Z-fought (the weird flicker on the wear bar). +Y is off the wrist.
                let fillCenter = watchCenter - watchAcross * (half - fw) + SIMD3<Float>(0, 0.0015, 0)
                emitHandRect(hand, center: fillCenter, wAxis: watchAcross, hAxis: watchAlong,
                             halfW: fw, halfH: 0.010, layer: hud.whiteLayer,
                             tint: Float(Int((1 - rem) * 255) + Int(rem * 255) * 256), into: &v, idx: &idx)
            }
        }
        // #57: hotbar wrapped AROUND the left wrist (an arc, not a flat line).
        // Cells sit on a cylinder about the forearm axis (hand-local Z), each
        // facing radially outward; width runs around the wrist, height along the
        // arm. Radius/arc are first-cut numbers to tune on device.
        if let m = handPose(left: true), !hud.hotbar.isEmpty {
            let n = hud.hotbar.count
            let cell: Float = 0.030, r: Float = 0.068
            let angStep: Float = 0.8 * 2 * .pi / Float(n)   // 9 cells span 80% of the wrist
            for i in 0..<n {
                // The selected slot always sits on top of the wrist; the others
                // wrap around from it (so selecting rotates the ring, not a marker).
                var rel = i - hud.wieldIndex
                if rel > n / 2 { rel -= n } else if rel < -(n / 2) { rel += n }
                let a = Float(rel) * angStep                        // 0 = top of wrist
                let radial = SIMD3<Float>(sin(a), cos(a), 0)        // outward from the arm
                let tangent = SIMD3<Float>(cos(a), -sin(a), 0)      // around the wrist
                let along = SIMD3<Float>(0, 0, 1)                   // along the forearm
                let base = radial * r + SIMD3<Float>(0, 0, 0.02)    // slight shift toward the elbow
                emitHandQuadFrame(m, center: base + radial * 0.000, wAxis: tangent, hAxis: along,
                                  half: cell * 0.5, layer: hud.slotLayer, uv: SIMD2(1, 1), into: &v, idx: &idx)
                if let ic = hud.hotbar[i] {
                    // -along: the cell's texture-top points toward the fingers, not
                    // the elbow, so the icon reads upright on the wrist (#57). With
                    // +along it came out upside down. The slot/select frames are
                    // symmetric so they don't care.
                    emitHandQuadFrame(m, center: base + radial * 0.001, wAxis: tangent, hAxis: -along,
                                      half: cell * 0.48, layer: ic.layer, uv: ic.uv, into: &v, idx: &idx)
                    // Per-slot wear bar along the bottom edge of the cell (green
                    // -> red by remaining), so a damaged tool reads on the ring
                    // itself, not only when wielded (#106).
                    if ic.wear < 0.999 {
                        let rem = max(0, min(1, ic.wear))
                        let bot = base + radial * 0.002 - along * (cell * 0.42)
                        let full = cell * 0.42
                        emitHandRect(m, center: bot, wAxis: tangent, hAxis: along, halfW: full, halfH: cell * 0.06,
                                     layer: hud.whiteLayer, tint: Float(20 + 20*256 + 20*65536), into: &v, idx: &idx)
                        let fw = max(0.001, full * rem)
                        emitHandRect(m, center: bot + tangent * (fw - full), wAxis: tangent, hAxis: along,
                                     halfW: fw, halfH: cell * 0.06, layer: hud.whiteLayer,
                                     tint: Float(Int((1 - rem) * 255) + Int(rem * 255) * 256), into: &v, idx: &idx)
                    }
                }
                if i == hud.wieldIndex {
                    emitHandQuadFrame(m, center: base + radial * 0.002, wAxis: tangent, hAxis: along,
                                      half: cell * 0.5, layer: hud.selectLayer, uv: SIMD2(1, 1), into: &v, idx: &idx)
                }
            }
        }
        // Armor as a wrist gauntlet (#108): a band of plate segments on the same
        // left-forearm cylinder as the hotbar, a touch tighter radius so it reads
        // as an under-layer, and shifted up-arm (toward the elbow) so it doesn't
        // collide with the hotbar. Hidden at 0 armor. filled = armor - i*2 picks
        // full/half/empty, like the peripheral stat columns.
        if let m = handPose(left: true), hud.armor > 0 {
            let n = 10
            let cell: Float = 0.024, r: Float = 0.060
            let angStep: Float = 0.7 * 2 * .pi / Float(n)   // top ~70% of the forearm
            let along = SIMD3<Float>(0, 0, 1)
            for i in 0..<n {
                let a = (Float(i) - Float(n - 1) / 2) * angStep    // centred on top of the wrist
                let radial = SIMD3<Float>(sin(a), cos(a), 0)
                let tangent = SIMD3<Float>(cos(a), -sin(a), 0)
                let base = radial * r + SIMD3<Float>(0, 0, 0.075)  // up-arm of the hotbar (which sits at 0.02)
                let filled = hud.armor - i * 2
                let layer = filled >= 2 ? hud.armorFullLayer : filled == 1 ? hud.armorHalfLayer : hud.armorEmptyLayer
                emitHandQuadFrame(m, center: base, wAxis: tangent, hAxis: along,
                                  half: cell * 0.5, layer: layer, uv: SIMD2(1, 1), into: &v, idx: &idx)
            }
        }
        if !vt.isEmpty {
            upload(vt, into: &handHudTextVertexBuffer)
            upload(idxt, into: &handHudTextIndexBuffer)
            handHudTextIndexCount = idxt.count
        }
        guard !v.isEmpty else { return }
        upload(v, into: &handHudVertexBuffer)
        upload(idx, into: &handHudIndexBuffer)
        handHudIndexCount = idx.count
    }

    /// A small flattened box (palm-ish) at a hand anchor, in world/metre space so
    /// entityVertex places it via the same viewProjection the mobs use. 9-float
    /// entity vertex layout (uv/params unused by handFragment).
    private func appendHandBox(_ m: simd_float4x4, v: inout [Float], idx: inout [UInt32]) {
        let hx: Float = 0.045, hy: Float = 0.028, hz: Float = 0.075
        let corners: [SIMD3<Float>] = [
            SIMD3(-hx,-hy,-hz), SIMD3(hx,-hy,-hz), SIMD3(hx,hy,-hz), SIMD3(-hx,hy,-hz),
            SIMD3(-hx,-hy, hz), SIMD3(hx,-hy, hz), SIMD3(hx,hy, hz), SIMD3(-hx,hy, hz)]
        let faces = [[0,1,2,3],[5,4,7,6],[4,0,3,7],[1,5,6,2],[3,2,6,7],[4,5,1,0]]
        let base = UInt32(v.count / 9)
        for c in corners {
            let w = m * SIMD4<Float>(c, 1)
            pushV9(&v, w.x, w.y, w.z, 0, 0, 0, 1, 255, 16777215)
        }
        for f in faces {
            let a = base+UInt32(f[0]), b = base+UInt32(f[1]), cc = base+UInt32(f[2]), d = base+UInt32(f[3])
            pushTri(&idx, a, b, cc); pushTri(&idx, a, cc, d)
        }
    }

    @MainActor
    static func startRenderLoop(_ layerRenderer: LayerRenderer, appModel: AppModel, arSession: ARKitSession) {
        Task(executorPreference: RendererTaskExecutor.shared) {
            let renderer = Renderer(layerRenderer, appModel: appModel)
            await renderer.startARSession(arSession)
            await renderer.renderLoop()
        }
    }

    static func buildMetalVertexDescriptor() -> MTLVertexDescriptor {
        // Create a Metal vertex descriptor specifying how vertices will be laid out for input into our render
        //   pipeline and how we'll layout our Model IO vertices

        let mtlVertexDescriptor = MTLVertexDescriptor()

        // One interleaved buffer: position (float3) then texcoord (float2), our
        // voxel mesh layout. Stride 20 bytes.
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].format = MTLVertexFormat.float3
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].offset = 0
        mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue

        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].format = MTLVertexFormat.float2  // uv
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].offset = 12
        mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue

        mtlVertexDescriptor.attributes[VertexAttribute.params.rawValue].format = MTLVertexFormat.float4  // layer, shade, light, tint
        mtlVertexDescriptor.attributes[VertexAttribute.params.rawValue].offset = 20
        mtlVertexDescriptor.attributes[VertexAttribute.params.rawValue].bufferIndex = BufferIndex.meshPositions.rawValue

        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stride = 36
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepRate = 1
        mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue].stepFunction = MTLVertexStepFunction.perVertex

        return mtlVertexDescriptor
    }

    static func buildRenderPipeline(device: MTLDevice,
                                    layerRenderer: LayerRenderer,
                                    mtlVertexDescriptor: MTLVertexDescriptor,
                                    fragment: String = "fragmentShader") throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: "vertexShader")
        let fragmentFunction = library?.makeFunction(name: fragment)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor
        pipelineDescriptor.rasterSampleCount = device.rasterSampleCount

        pipelineDescriptor.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        pipelineDescriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat

        pipelineDescriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    static func buildSkyPipeline(device: MTLDevice, layerRenderer: LayerRenderer) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "SkyPipeline"
        desc.vertexFunction = library?.makeFunction(name: "skyVertex")
        desc.fragmentFunction = library?.makeFunction(name: "skyFragment")
        desc.rasterSampleCount = device.rasterSampleCount
        desc.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        desc.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        desc.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    // Fullscreen alpha-blended tint drawn while the eye is submerged in a liquid.
    static func buildUnderwaterPipeline(device: MTLDevice, layerRenderer: LayerRenderer) throws -> MTLRenderPipelineState {
        return try buildTintPipeline(device: device, layerRenderer: layerRenderer, fragment: "underwaterFragment")
    }

    /// A fullscreen alpha-blended tint pass (underwaterVertex + the given
    /// fragment). Used for the underwater cast and the red death cast.
    static func buildTintPipeline(device: MTLDevice, layerRenderer: LayerRenderer, fragment: String,
                                  vertex: String = "underwaterVertex") throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "TintPipeline-\(fragment)"
        desc.vertexFunction = library?.makeFunction(name: vertex)
        desc.fragmentFunction = library?.makeFunction(name: fragment)
        desc.rasterSampleCount = device.rasterSampleCount
        desc.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        desc.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        let ca = desc.colorAttachments[0]!
        ca.pixelFormat = layerRenderer.configuration.colorFormat
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .sourceAlpha
        ca.sourceAlphaBlendFactor = .sourceAlpha
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    static func buildLiquidPipeline(device: MTLDevice, layerRenderer: LayerRenderer,
                                    mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "LiquidPipeline"
        desc.vertexFunction = library?.makeFunction(name: "liquidVertex")
        desc.fragmentFunction = library?.makeFunction(name: "liquidFragment")
        desc.vertexDescriptor = mtlVertexDescriptor
        desc.rasterSampleCount = device.rasterSampleCount
        desc.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        desc.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        let ca = desc.colorAttachments[0]!
        ca.pixelFormat = layerRenderer.configuration.colorFormat
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .sourceAlpha
        ca.sourceAlphaBlendFactor = .sourceAlpha
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    static func buildEntityPipeline(device: MTLDevice, layerRenderer: LayerRenderer,
                                    mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "EntityPipeline"
        desc.vertexFunction = library?.makeFunction(name: "entityVertex")
        desc.fragmentFunction = library?.makeFunction(name: "entityFragment")
        desc.vertexDescriptor = mtlVertexDescriptor
        desc.rasterSampleCount = device.rasterSampleCount
        desc.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        desc.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        desc.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    // The vitals glass backing: entityVertex (head-locked quad) + glassFragment,
    // alpha-blended so the panel is translucent over the world (HUD layout B).
    static func buildGlassPipeline(device: MTLDevice, layerRenderer: LayerRenderer,
                                   mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "GlassPipeline"
        desc.vertexFunction = library?.makeFunction(name: "entityVertex")
        desc.fragmentFunction = library?.makeFunction(name: "glassFragment")
        desc.vertexDescriptor = mtlVertexDescriptor
        desc.rasterSampleCount = device.rasterSampleCount
        desc.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        desc.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        let ca = desc.colorAttachments[0]!
        ca.pixelFormat = layerRenderer.configuration.colorFormat
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add; ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .sourceAlpha; ca.sourceAlphaBlendFactor = .sourceAlpha
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    /// Hand boxes: entityVertex (world-space, model-matrix-free) + a solid tan
    /// fragment. Same vertex layout as entities so it reuses that descriptor.
    static func buildHandPipeline(device: MTLDevice, layerRenderer: LayerRenderer,
                                  mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "HandPipeline"
        desc.vertexFunction = library?.makeFunction(name: "entityVertex")
        desc.fragmentFunction = library?.makeFunction(name: "handFragment")
        desc.vertexDescriptor = mtlVertexDescriptor
        desc.rasterSampleCount = device.rasterSampleCount
        desc.colorAttachments[0].pixelFormat = layerRenderer.configuration.colorFormat
        desc.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        desc.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    static func buildDepthStencilState(device: MTLDevice) -> MTLDepthStencilState {
        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.greater
        depthStateDescriptor.isDepthWriteEnabled = true
        return device.makeDepthStencilState(descriptor: depthStateDescriptor)!
    }


    private func updateDynamicBufferState(frameIndex: UInt64) {
        /// Update the state of our uniform buffers before rendering

        uniformBufferIndex = (uniformBufferIndex + 1) % maxBuffersInFlight

        uniformBufferOffset = alignedUniformsSize * uniformBufferIndex

        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents() + uniformBufferOffset).bindMemory(to: Uniforms.self, capacity: 1)

        // The per-frame residency set is cleared + refilled + committed once,
        // down at the draw site (removeAll immediately before addAllocations),
        // instead of committing an empty set here and a full one there: two
        // commits per frame became one (#182). Safe because by the rebuild point
        // this slot's prior frame has completed (the same endFrameEvent wait the
        // world residency set relies on).

        /// Remove all per drawable target resources that are older than 90 frames

        perDrawableTarget = perDrawableTarget.filter { $0.value.lastUsedFrameIndex + 90 > frameIndex }
    }

    private func updateGameState() {
        // First-person 1:1 placement. The mesher emits vertices at
        // (node - meshRef) * scale; here we translate so the player's eye node
        // lands at the device-anchor origin, then rotate the world by the
        // player's locomotion yaw (head orientation comes from the drawable's
        // view transform on top of this).
        let scale = PlayerState.scale
        // One consistent read of feet/origin/sky/sun under a single lock, instead
        // of six separate lock acquisitions per frame (#184).
        let rs = appModel.player.renderState()
        let s = rs.snap
        self.worldMeshRef = s.meshRef   // for frustum culling in the draw pass (#1)
        let eye = rs.origin   // floor under the player on device (see PlayerState.origin)
        self.worldEye = eye   // for the front-to-back block sort (#4)
        let d = (eye - s.meshRef) * scale
        // NOTE: an earlier "lift the world by the head height" fix for the
        // too-tall camera lifted ONLY the world mesh (this modelMatrix), while
        // mobs/highlight/particles are drawn in the entity stream that skips
        // it -- so the mesh floated ~a block above everything else (sunk mobs,
        // targeting outline a block low, worse clipping). Reverted to keep the
        // whole scene consistent; the too-tall camera needs a fix that shifts
        // the entity stream too (tracked separately).
        let t = matrix4x4_translation(-d.x, -d.y, -d.z)
        let r = matrix4x4_rotation(radians: -s.yaw, axis: SIMD3<Float>(0, 1, 0))
        // Luanti's world is left-handed (Irrlicht); Metal/ARKit are right-handed.
        // Drawing node coords straight in was a mirror image (desktop: door on
        // the left, here: on the right). Mirror Z after the yaw so the picture
        // matches desktop; every entity/billboard/head conversion mirrors too.
        let mirror = matrix_float4x4(diagonal: SIMD4<Float>(1, 1, -1, 1))
        self.uniforms[0].modelMatrix = mirror * r * t
        self.uniforms[0].daylight = rs.daylight
        #if targetEnvironment(simulator)
        // Sim testing aid: force full daylight so screenshots of the world/UI
        // aren't lost to a dark interior or night. -vrdev.day 1.
        if UserDefaults.standard.bool(forKey: "vrdev.day") { self.uniforms[0].daylight = 1.0 }
        #endif
        self.uniforms[0].skySolid = rs.skySolid
        // a = 2 tells skyFragment to sample the cube instead of the flat colour;
        // the flat bgcolor stays up until the six faces have downloaded.
        if rs.skySolid.w > 0, rs.sky.fog.z > 0.5, skyboxTexture != nil { self.uniforms[0].skySolid.w = 2 }
        // Server sky look (#102): colours, sun/moon, stars, clouds, saturation.
        let sky = rs.sky
        self.uniforms[0].skyDayZenith = sky.dayZenith
        self.uniforms[0].skyDayHorizon = sky.dayHorizon
        self.uniforms[0].skyNightZenith = sky.nightZenith
        self.uniforms[0].skyNightHorizon = sky.nightHorizon
        self.uniforms[0].skyBodies = sky.bodies
        self.uniforms[0].skyStars = sky.stars
        self.uniforms[0].skyStarColor = sky.starColor
        self.uniforms[0].skyClouds = sky.clouds
        self.uniforms[0].skyCloudColor = sky.cloudColor
        self.uniforms[0].saturation = sky.saturation
        // Distance fog (#285), as Game::updateFrame sets it up: linear from
        // fog_start * range to range, where range is the view distance (our
        // wanted_range in blocks * 16) unless SET_SKY gave a fog_distance, and
        // the colour is what Sky::getFogColor returns: the server's fog_color
        // when set, else the flat plain/skybox colour, else the horizon colour
        // exactly as skyFragment paints it (so the world edge melts into the
        // sky instead of ending at a hard line). The Nether's haze is just
        // VoxeLibre setting every sky colour to the biome fog colour.
        let rangeNodes = sky.fog.x > 0 ? sky.fog.x : Float(ViewSettings.shared.blocks * 16)
        let fogStart = sky.fog.y >= 0 ? sky.fog.y : 0.4
        self.uniforms[0].fog = SIMD4(rangeNodes * scale, 1 / max(0.05, 1 - fogStart), 0, 0)
        // Dawn/dusk point colour (Sky::update): the sun tint (fog_sun_tint when
        // fog_tint_type is "custom", else the engine's brightness-derived
        // orange) and the moon tint, mixed into the horizon at 50% and the
        // zenith at 25% by m_horizon_blend, which is nonzero only for
        // time-of-day 0.15-0.25 and 0.75-0.85. The shader picks sun vs moon
        // tint per pixel by which side of the sky it's on; the fog uses the
        // average.
        let tod = rs.timeOfDay
        let x = tod >= 0.5 ? (1 - tod) * 2 : tod * 2
        let hb: Float = x <= 0.3 ? 0 : x <= 0.4 ? (x - 0.3) * 10 : x <= 0.5 ? (0.5 - x) * 10 : 0
        let br = rs.daylight
        let pl = max(0.2, min(1, br * 3))
        var sunTint: SIMD3<Float>
        if sky.sunTint.w > 0 {
            sunTint = SIMD3(sky.sunTint.x, sky.sunTint.y, sky.sunTint.z)
        } else {
            let b = pl * (0.25 + (max(0.25, min(0.75, br)) - 0.25) * 2 * 0.75)
            let g = pl * (b * 0.375 + (max(0.05, min(0.15, br)) - 0.05) * 10 * 0.625)
            sunTint = SIMD3(pl, g, b)
        }
        let moonTint = sky.sunTint.w > 0
            ? SIMD3(sky.moonTint.x, sky.moonTint.y, sky.moonTint.z) * pl
            : SIMD3(0.5, 0.6, 0.8) * pl
        self.uniforms[0].skySunTint = SIMD4(sunTint, hb)
        self.uniforms[0].skyMoonTint = SIMD4(moonTint, 0)
        var fogRGB: SIMD3<Float>
        if sky.fogColor.w > 0 {
            fogRGB = SIMD3(sky.fogColor.x, sky.fogColor.y, sky.fogColor.z)
        } else if rs.skySolid.w > 0 {
            fogRGB = SIMD3(rs.skySolid.x, rs.skySolid.y, rs.skySolid.z)
        } else {
            let dl = max(0, min(1, (self.uniforms[0].daylight - 0.175) / 0.825))
            let night = SIMD3(sky.nightHorizon.x, sky.nightHorizon.y, sky.nightHorizon.z) * 0.12
            let day = SIMD3(sky.dayHorizon.x, sky.dayHorizon.y, sky.dayHorizon.z)
            fogRGB = night + (day - night) * dl
            let point = (sunTint + moonTint) * 0.5
            fogRGB += (point - fogRGB) * (hb * 0.5)
            // Cave fog: the engine's sky/fog go toward indoors * brightness when
            // the camera can't see the sky. Scale by the decoded day light at
            // the head so a cave hazes to black, not to noon sky blue.
            let sv = rs.skyVisible
            if sv < 0.999 {
                let v = max(0, min(1, sv))
                var b = (-0.5 * v + 1.5) * v * v
                b += 0.2 * exp(-0.5 * pow((v - 0.5) / 0.2, 2))
                fogRGB *= max(0.02, min(1, b))
            }
        }
        self.uniforms[0].fogColor = SIMD4(fogRGB, 0)
        // Last frame's head (render() refreshes it after this); a frame of lag
        // is nothing against a 100 m fog range.
        let hx = rs.head.columns.3   // folded into renderState, no extra lock (perf review)
        self.uniforms[0].eyePos = SIMD4(hx.x, hx.y, hx.z, 0)
        // Rotate the sun into the same (origin) space the world lives in after
        // the model matrix, so the sky tracks the world when you stick-turn.
        // Without this the world spins but the sun/sky stay put. (Y is the turn
        // axis, so sun height is unchanged.)
        // Stars/clouds are hashed in world space so they turn with a stick-turn
        // like the sun does; pass the inverse of the world rotation (orthogonal,
        // so transpose) to map a view ray back to world space.
        self.uniforms[0].skyRayToWorld = (mirror * r).transpose
        let sd = rs.sunDir
        let sdRot = mirror * r * SIMD4<Float>(sd, 0)
        let tSec = Float(ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: 100000))
        // Unit length here, once: skyFragment dots against it per pixel.
        let sdUnit = simd_normalize(SIMD3<Float>(sdRot.x, sdRot.y, sdRot.z))
        self.uniforms[0].sunDir = SIMD4<Float>(sdUnit.x, sdUnit.y, sdUnit.z, tSec)
    }

    /// Swap in a freshly streamed+meshed world if one is waiting. Runs on the
    /// render thread; Metal retains the old buffers until in-flight frames finish.
    private func consumeHandoff() {
        guard let d = appModel.meshHandoff.take() else { return }
        // Fold the per-block delta into the block dict (#183). Buffers were built
        // on the mesher thread; Metal keeps replaced ones alive for in-flight
        // frames. `reset` drops everything first (atlas grew -> all re-meshed).
        if d.reset { worldBlocks.removeAll(keepingCapacity: true) }
        for bp in d.removed { worldBlocks[bp] = nil }
        for (bp, g) in d.changed { worldBlocks[bp] = g }
        blockListDirty = true
        // Swap the node atlas in the SAME frame as the mesh it was built with,
        // so blocks never sample a grown atlas with stale layer indices.
        if let a = d.atlas { textureArray = a; animLayers = d.animated; animLastFrame.removeAll() }
        #if !targetEnvironment(simulator)
        // The block set changed: refresh every in-flight slot's residency set
        // over the next few frames (each on its own frame, never while in use).
        if !d.changed.isEmpty || !d.removed.isEmpty || d.reset {
            worldResidencyRefresh = worldResidencySets.count
        }
        #endif
    }

    // Animated node tiles (#137): layers whose pixels cycle over time (lava, fire,
    // furnace). Re-uploaded per frame only when the frame index advances.
    // World index counts of the last drawable (solid/cutout/liquid), for the
    // [perf] line: the GPU review had to guess the vertex load; now a device
    // log says it.
    private var idxSolid = 0, idxCutout = 0, idxLiquid = 0
    private var animLayers: [TextureAtlas.AnimLayer] = []
    private var animLastFrame: [Int: Int] = [:]
    private func stepTileAnimation() {
        guard !animLayers.isEmpty, let tex = textureArray else { return }
        let now = CACurrentMediaTime()
        let edge = TextureAtlas.tile, need = edge * edge * 4
        for a in animLayers where a.frames.count > 1 && a.layer < tex.arrayLength {
            let idx = Int(now / Double(a.secPerFrame)) % a.frames.count
            if animLastFrame[a.layer] == idx { continue }
            animLastFrame[a.layer] = idx
            let px = a.frames[idx]
            guard px.count == need else { continue }
            // Whole mip chain per frame step (a 64x64 box filter, microseconds)
            // so a far lava pool animates instead of freezing on frame 0's mips.
            TileMips.upload(tex, slice: a.layer, px: px, edge: edge)
        }
    }

    private func consumeEntityHandoff() {
        // Already split at post time (#186): head-locked HUD is placed per-drawable
        // against the fresh head pose (buildHudBillboards); world billboards are
        // placed here in origin space.
        let (ents, hud) = appModel.entityHandoff.read()
        hudInstances = hud
        guard !ents.isEmpty else { entityIndexCount = 0; return }
        let rs = appModel.player.renderState()   // snap + origin under one lock (#184)
        let snap = rs.snap
        let eye = rs.origin
        let scale = PlayerState.scale
        let c = cos(snap.yaw), sn = sin(snap.yaw)
        var v: [Float] = []; v.reserveCapacity(ents.count * 32)
        var idx: [UInt32] = []; idx.reserveCapacity(ents.count * 6)
        for e in ents {
            // entity feet in origin space: R(-yaw) * (entityNode - eye) * scale
            let rx = (e.pos.x - eye.x) * scale, ry = (e.pos.y - eye.y) * scale, rz = (e.pos.z - eye.z) * scale
            let op = SIMD3<Float>(rx * c - rz * sn, ry, -(rx * sn + rz * c))   // Z mirrored like the world mesh
            // face the camera (origin) horizontally
            var dh = SIMD3<Float>(-op.x, 0, -op.z)
            let dl = (dh.x * dh.x + dh.z * dh.z).squareRoot()
            if dl > 1e-4 { dh /= dl } else { dh = SIMD3(0, 0, -1) }
            let right = SIMD3<Float>(dh.z, 0, -dh.x)
            let w2 = e.width * scale * 0.5, hgt = e.height * scale
            let bl = op - right * w2
            let br = op + right * w2
            let up = SIMD3<Float>(0, hgt, 0)
            let vb = UInt32(v.count / 9)
            pushQuadV9(&v, bl, br, br + up, bl + up, layer: e.layer, shade: 1.0, light: e.light, tint: e.tint)
            pushQuad(&idx, vb)
        }
        upload(v, into: &entityVertexBuffer)
        upload(idx, into: &entityIndexBuffer)
        entityIndexCount = idx.count
    }

    /// Gravity-stabilised, pitch-capped basis from a look direction (mirrors
    /// WorldSession.stableFrame). Keeps the HUD upright and unflipped when you
    /// look straight up/down, and drops head roll so icons don't swirl.
    private func stableFrame(_ dir: SIMD3<Float>) -> (fwd: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>) {
        let g = simd_normalize(dir)
        var h = SIMD3<Float>(g.x, 0, g.z)
        let hl = simd_length(h)
        h = hl > 1e-3 ? h / hl : SIMD3<Float>(0, 0, -1)
        let maxSin: Float = 0.82
        let y = max(-maxSin, min(maxSin, g.y))
        let c = (1 - y * y).squareRoot()
        let fwd = SIMD3<Float>(h.x * c, y, h.z * c)
        let right = simd_normalize(simd_cross(fwd, SIMD3<Float>(0, 1, 0)))
        let up = simd_normalize(simd_cross(right, fwd))
        return (fwd, right, up)
    }

    /// Place the head-locked HUD against THIS frame's head pose (the same one the
    /// view matrix uses), so it doesn't lag the camera and ghost/double under
    /// reprojection while turning. Each instance's `pos` is a canonical head-local
    /// offset (fwd -Z, right +X, up +Y, node units); map it through the current
    /// head's gravity-stable basis and scale into origin space.
    private func buildHudBillboards(head: simd_float4x4) {
        guard !hudInstances.isEmpty else { hudIndexCount = 0; return }
        let scale = PlayerState.scale
        let headPos = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        let headFwd = -SIMD3<Float>(head.columns.2.x, head.columns.2.y, head.columns.2.z)
        let (fwd, right, up) = stableFrame(headFwd)
        // Raw head basis (full pitch, includes roll) for the crosshair, so it
        // stays on the true aim ray the raycast/highlight use.
        let rawRight = SIMD3<Float>(head.columns.0.x, head.columns.0.y, head.columns.0.z)
        let rawUp = SIMD3<Float>(head.columns.1.x, head.columns.1.y, head.columns.1.z)
        let rawFwd = headFwd
        hudScratchV.removeAll(keepingCapacity: true); hudScratchIdx.removeAll(keepingCapacity: true)
        for e in hudInstances {
            let (bR, bU, bF) = e.centered ? (rawRight, rawUp, rawFwd) : (right, up, fwd)
            // canonical offset (x=right, y=up, z=back) -> origin space
            let o = e.pos * scale
            let center = headPos + bR * o.x + bU * o.y - bF * o.z
            let w2 = e.width * scale * 0.5, hgt = e.height * scale
            let bl = center - bR * w2
            let br = center + bR * w2
            let upv = bU * hgt
            let vb = UInt32(hudScratchV.count / 9)
            pushQuadV9(&hudScratchV, bl, br, br + upv, bl + upv, layer: e.layer, shade: 1.0, light: e.light, tint: e.tint)
            pushQuad(&hudScratchIdx, vb)
        }
        upload(hudScratchV, into: &hudVertexBuffer)
        upload(hudScratchIdx, into: &hudIndexBuffer)
        hudIndexCount = hudScratchIdx.count

        // Glass backing behind the low vitals band (HUD layout B): one soft
        // translucent panel in the same low band the hearts/hunger rows occupy,
        // projected against the head like the icons so it tracks with them.
        let gd = 1.35 * scale
        func bandDir(_ az: Float, _ e: Float) -> SIMD3<Float> { simd_normalize(fwd + right * tan(az) + up * tan(e)) }
        let pc = headPos + bandDir(0, -0.30) * gd
        // Hug the vitals rows (they reach ~az ±0.185, one row tall) instead of a
        // wide slab -- Eric: the backing read too big on device (#194/#9).
        let hw = gd * tan(0.27), hh = gd * tan(0.05)
        let bl = pc - right * hw - up * hh, br = pc + right * hw - up * hh
        hudScratchGV.removeAll(keepingCapacity: true)
        pushQuadV9(&hudScratchGV, bl, br, br + up * (2 * hh), bl + up * (2 * hh), layer: 0, shade: 1, light: 255, tint: 16777215)
        upload(hudScratchGV, into: &hudGlassVertexBuffer); upload(Self.hudGlassIdx, into: &hudGlassIndexBuffer)
        hudGlassIndexCount = Self.hudGlassIdx.count
    }

    private func ensureCaptureTexture(like src: MTLTexture) {
        if let ct = captureTexture, ct.width == src.width, ct.height == src.height { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: src.pixelFormat,
                                                         width: src.width, height: src.height, mipmapped: false)
        d.storageMode = .shared
        d.usage = [.shaderRead]
        captureTexture = device.makeTexture(descriptor: d)
    }

    /// Convert a captured rgba16Float frame to sRGB and write a PNG into the
    /// app's Documents dir. Runs on a GPU completion thread.
    private func writeScreenshot(_ tex: MTLTexture, _ w: Int, _ h: Int) {
        let count = w * h * 4
        var half = [UInt16](repeating: 0, count: count)
        tex.getBytes(&half, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var rgba = [UInt8](repeating: 0, count: count)
        func enc(_ v: Float) -> UInt8 {
            let c = max(0, min(1, v))
            let e = c <= 0.0031308 ? 12.92 * c : 1.055 * powf(c, 1 / 2.4) - 0.055
            return UInt8(max(0, min(255, e * 255 + 0.5)))
        }
        for i in 0..<(w * h) {
            rgba[i*4+0] = enc(Float(Float16(bitPattern: half[i*4+0])))
            rgba[i*4+1] = enc(Float(Float16(bitPattern: half[i*4+1])))
            rgba[i*4+2] = enc(Float(Float16(bitPattern: half[i*4+2])))
            rgba[i*4+3] = 255
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let img = ctx.makeImage() else { return }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("shot-\(Int(Date().timeIntervalSince1970)).png")
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dst, img, nil)
        CGImageDestinationFinalize(dst)
        print("[shot] saved \(url.lastPathComponent) (\(w)x\(h))"); fflush(stdout)
    }

    /// Mob model geometry (already in origin space) for this frame.
    /// Upload `src` into a persistent buffer, reusing it (memcpy) and only
    /// re-allocating when it must grow. Replaces makeBuffer(bytes:) on the
    /// per-frame path so the render loop stops churning MTLBuffers (#163).
    private func upload<T>(_ src: [T], into buf: inout MTLBuffer) {
        let bytes = src.count * MemoryLayout<T>.stride
        guard bytes > 0 else { return }
        if buf.length < bytes {
            buf = device.makeBuffer(length: bytes, options: [.storageModeShared])!
        }
        src.withUnsafeBytes { memcpy(buf.contents(), $0.baseAddress!, bytes) }
    }

    private func consumeModelHandoff() {
        let (gen, v, idx) = appModel.modelHandoff.read()
        if gen == lastModelGen { return }   // producer hasn't posted new geometry; keep the buffers
        lastModelGen = gen
        guard !idx.isEmpty else { modelIndexCount = 0; return }
        upload(v, into: &modelVertexBuffer)
        upload(idx, into: &modelIndexBuffer)
        modelIndexCount = idx.count
    }

    /// On-top modal UI geometry (keyboard/panel/menu/chat/banner): same vertex
    /// layout + model texture array as the mob stream, but drawn with no depth
    /// test so nearby terrain can't occlude it.
    private func consumeOverlayHandoff() {
        let (gen, v, idx) = appModel.modelHandoff.readOverlay()
        if gen == lastOverlayGen { return }
        lastOverlayGen = gen
        guard !idx.isEmpty else { overlayIndexCount = 0; return }
        upload(v, into: &overlayVertexBuffer)
        upload(idx, into: &overlayIndexBuffer)
        overlayIndexCount = idx.count
    }

    /// Build (or drop) the skybox cube from the six faces WorldSession baked.
    /// Face order on the wire is the API's Y+ Y- X- X+ Z+ Z-; Metal cube slices
    /// are +X -X +Y -Y +Z -Z.
    private func consumeSkyboxHandoff() {
        guard let upd = appModel.skyboxHandoff.take() else { return }
        guard let faces = upd, faces.count == 6 else { skyboxTexture = nil; return }
        let n = SkyboxHandoff.size, need = n * n * 4
        let d = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba8Unorm_srgb, size: n, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { return }
        let order = [3, 2, 0, 1, 4, 5]
        for (slice, fi) in order.enumerated() where faces[fi].count == need {
            faces[fi].withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                tex.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, slice: slice,
                            withBytes: base, bytesPerRow: n * 4, bytesPerImage: need)
            }
        }
        skyboxTexture = tex
        print("[sky] skybox cube uploaded"); fflush(stdout)
    }

    /// Build the full-res mob-skin texture array (one 128x128 layer per skin).
    private func consumeModelTextureHandoff() {
        let upd = appModel.modelTextureHandoff.take()
        let edge = ModelTextureHandoff.size, need = edge * edge * 4
        let region = MTLRegionMake2D(0, 0, edge, edge)
        // The layer count grew. The array is append-only (a layer's identity
        // never changes; pixel edits arrive as patches), so growing means
        // uploading ONLY the new slices. Allocate with headroom so the common
        // grow (a new icon, nametag, skin) fits in place; reallocation -- a
        // fresh 50-60 MB texture plus re-copying every layer on the render
        // thread -- now happens once per 64 layers instead of once per layer
        // (it was ~230 times a session, a multi-ms stall each; perf review #3).
        if let texs = upd.full, !texs.isEmpty {
            @inline(__always) func upload(_ tex: MTLTexture, _ i: Int) {
                let mt = texs[i]
                guard mt.rgba.count == need else { return }
                mt.rgba.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    tex.replace(region: region, mipmapLevel: 0, slice: i,
                                withBytes: base, bytesPerRow: edge * 4, bytesPerImage: need)
                }
            }
            if let tex = modelTextureArray, texs.count <= tex.arrayLength, texs.count >= modelArrayLogical {
                // Fits: only the layers beyond what we already hold are new.
                for i in modelArrayLogical..<texs.count { upload(tex, i) }
                modelArrayLogical = texs.count
                appModel.modelTextureHandoff.reportBuilt(texs.count)   // ack so the producer knows the array actually grew (#254)
                print("[model] grew to \(texs.count) layers (capacity \(tex.arrayLength))"); fflush(stdout)
            } else {
                let desc = MTLTextureDescriptor()
                desc.textureType = .type2DArray
                desc.pixelFormat = .rgba8Unorm_srgb
                desc.width = edge; desc.height = edge
                desc.arrayLength = min(WorldSession.maxTextureLayers, (texs.count + 63) / 64 * 64)   // headroom, under Metal's slice cap
                desc.usage = .shaderRead
                // On failure leave the old array + logical count alone: builtCount
                // stays behind postedCount and the producer re-posts (self-heal).
                guard let tex = device.makeTexture(descriptor: desc) else { return }
                for i in 0..<min(texs.count, desc.arrayLength) { upload(tex, i) }
                modelTextureArray = tex
                modelArrayLogical = texs.count
                appModel.modelTextureHandoff.reportBuilt(texs.count)
                print("[model] rebuilt \(texs.count)-layer array (capacity \(desc.arrayLength))"); fflush(stdout)
            }
        }
        // In-place patches: rewrite only the changed layers of the existing array,
        // no reallocation. This is the common case (chat, HUD timer, counts, XP).
        // Applied AFTER any full above, so an edit to an existing layer that was
        // queued alongside a grow still lands.
        guard let tex = modelTextureArray, !upd.patches.isEmpty else { return }
        for p in upd.patches where p.index < modelArrayLogical && p.rgba.count == need {
            p.rgba.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                tex.replace(region: region, mipmapLevel: 0, slice: p.index,
                            withBytes: base, bytesPerRow: edge * 4, bytesPerImage: need)
            }
        }
    }

    func renderFrame() {
        /// Per frame updates here

        guard let frame = layerRenderer.queryNextFrame() else { return }

        guard self.endFrameEvent.wait(untilSignaledValue: committedFrameIndex - UInt64(maxBuffersInFlight), timeoutMS: 10000) else {
            return
        }

        frame.startUpdate()
        let pf0 = perf.now()

        // Perform frame independent work

        self.updateDynamicBufferState(frameIndex: frame.frameIndex)
        self.resolveHandPoses(frameIndex: frame.frameIndex)   // once; buildHandHud + render read the memo

        self.updateGameState()

        self.consumeHandoff()
        self.stepTileAnimation()   // cycle animated node tiles (lava/fire) this frame


        self.consumeEntityHandoff()

        self.consumeModelTextureHandoff()
        self.consumeSkyboxHandoff()

        self.consumeModelHandoff()
        self.consumeOverlayHandoff()

        #if targetEnvironment(simulator)
        self.simulateHandPoses()
        #endif
        self.consumeHands()
        let pf1 = perf.now()

        self.buildHandHud()
        let pf2 = perf.now()
        perf.add("update", pf0, pf1); perf.add("handHud", pf1, pf2)

        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            fatalError("Failed to create command buffer")
        }

        #if !targetEnvironment(simulator)
        commandBuffer.useResidencySet(self.residencySets[uniformBufferIndex])
        #endif

        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty else { return }

        frame.startSubmission()

        let wantShot = appModel.screenshotFlag.take()
        let pe0 = perf.now()
        for (i, drawable) in drawables.enumerated() {
            render(drawable: drawable, commandBuffer: commandBuffer, frameIndex: frame.frameIndex,
                   capture: wantShot && i == 0)
        }
        perf.add("encode", pe0, perf.now())
        perf.endIteration(note: "blocks=\(worldBlocks.count) visible=\(visibleBlocks.count) tris=\(idxSolid / 3)/\(idxCutout / 3)/\(idxLiquid / 3) billboards=\(entityIndexCount / 6)")

        committedFrameIndex += 1
        commandBuffer.addCompletedHandler { cb in
            if let e = cb.error { print("[gpu] command buffer error: \(e)"); fflush(stdout) }
        }

        commandBuffer.encodeSignalEvent(self.endFrameEvent, value: committedFrameIndex)

        commandBuffer.commit()

        frame.endSubmission()
    }

    /// Frustum planes of a node->clip matrix, as (a,b,c,d) with a*x+b*y+c*z+d>=0
    /// meaning "inside". Left/right/bottom/top (from w±x, w±y) plus the w>=0
    /// "in front of the camera" plane. No near/far z planes, so it doesn't depend
    /// on the depth-buffer convention (reverse-Z or [0,1]); far is bounded by the
    /// stream radius anyway. (#1 frustum culling.)
    private struct Frustum { let p0, p1, p2, p3, p4: SIMD4<Float> }   // five planes as locals, no heap array per frame
    private static func frustumPlanes(_ m: float4x4) -> Frustum {
        let r0 = SIMD4<Float>(m.columns.0.x, m.columns.1.x, m.columns.2.x, m.columns.3.x)
        let r1 = SIMD4<Float>(m.columns.0.y, m.columns.1.y, m.columns.2.y, m.columns.3.y)
        let r3 = SIMD4<Float>(m.columns.0.w, m.columns.1.w, m.columns.2.w, m.columns.3.w)
        return Frustum(p0: r3 + r0, p1: r3 - r0, p2: r3 + r1, p3: r3 - r1, p4: r3)
    }

    /// True if the AABB is at least partly inside every plane (positive-vertex
    /// test): pick the corner furthest along each plane normal; if even that is
    /// outside, the whole box is outside that plane and thus invisible.
    @inline(__always) private static func inside(_ p: SIMD4<Float>, _ lo: SIMD3<Float>, _ hi: SIMD3<Float>) -> Bool {
        let px = p.x >= 0 ? hi.x : lo.x
        let py = p.y >= 0 ? hi.y : lo.y
        let pz = p.z >= 0 ? hi.z : lo.z
        return p.x * px + p.y * py + p.z * pz + p.w >= 0
    }
    private static func aabbVisible(lo: SIMD3<Float>, hi: SIMD3<Float>, planes f: Frustum) -> Bool {
        inside(f.p0, lo, hi) && inside(f.p1, lo, hi) && inside(f.p2, lo, hi) && inside(f.p3, lo, hi) && inside(f.p4, lo, hi)
    }

    func render(drawable: LayerRenderer.Drawable, commandBuffer: MTLCommandBuffer, frameIndex: UInt64,
                capture: Bool = false) {
        let time = drawable.frameTiming.presentationTime.timeInterval
        let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: time)

        drawable.deviceAnchor = deviceAnchor

        // Feed the player's look direction (node space) back for raycasting.
        let head = (deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4) * Renderer.simHeadOffset()
        // Pin the in-game eye to a fixed standing height no matter the real head
        // height: originLift + realHeadY = eyeHeight, so sitting and standing both
        // render at desktop eye level (you're not "short" when you sit). Only Y is
        // pinned; horizontal head lean still comes through. Sim: untracked anchor
        // -> nominal eye.
        if deviceAnchor?.isTracked == true {
            appModel.player.setOriginLift(appModel.player.eyeHeight - head.columns.3.y)
        } else {
            appModel.player.setOriginLift(appModel.player.eyeHeight)
        }
        appModel.player.setHeadXform(head)   // for head-locked overlays (Kogane menu, death text)
        appModel.player.setRightHand(handPose(left: false))   // inventory pointer ray
        buildHudBillboards(head: head)       // place the HUD against this frame's head (no lag/ghost)
        // View frame -> node frame: undo the Z mirror, then the yaw (see modelMatrix).
        let fwdOrigin = simd_normalize(SIMD3<Float>(-head.columns.2.x, -head.columns.2.y, head.columns.2.z))
        let yaw = appModel.player.snapshot().yaw
        let ry = matrix4x4_rotation(radians: yaw, axis: SIMD3<Float>(0, 1, 0))
        let fwd4 = ry * SIMD4<Float>(fwdOrigin, 0)
        appModel.player.setAim(simd_normalize(SIMD3<Float>(fwd4.x, fwd4.y, fwd4.z)))
        // Real head position in node space (origin is the nominal eye), so
        // dig/place/crosshair rays start from where you actually look. Identity
        // anchor in the sim -> falls back to the nominal eye.
        let headOff = ry * SIMD4<Float>(head.columns.3.x, head.columns.3.y, -head.columns.3.z, 0)
        let eyeN = appModel.player.origin()
        appModel.player.setHeadPos(SIMD3<Float>(eyeN.x + headOff.x / PlayerState.scale,
                                                eyeN.y + headOff.y / PlayerState.scale,
                                                eyeN.z + headOff.z / PlayerState.scale))

        if perDrawableTarget[drawable.target] == nil {
            perDrawableTarget[drawable.target] = .init(drawable: drawable)
        }
        let drawableTarget = perDrawableTarget[drawable.target]!

        drawableTarget.updateBufferState(uniformBufferIndex: uniformBufferIndex, frameIndex: frameIndex)

        drawableTarget.updateViewProjectionArray(drawable: drawable)


        let renderPassDescriptor = MTLRenderPassDescriptor()

        if device.supportsMSAA {
            let renderTargets = drawableTarget.memorylessTargets[uniformBufferIndex]

            renderPassDescriptor.colorAttachments[0].resolveTexture = drawable.colorTextures[0]
            renderPassDescriptor.colorAttachments[0].texture = renderTargets.color
            renderPassDescriptor.depthAttachment.resolveTexture = drawable.depthTextures[0]
            renderPassDescriptor.depthAttachment.texture = renderTargets.depth

            renderPassDescriptor.colorAttachments[0].storeAction = .multisampleResolve
            renderPassDescriptor.depthAttachment.storeAction = .multisampleResolve
        } else {
            renderPassDescriptor.colorAttachments[0].texture = drawable.colorTextures[0]
            renderPassDescriptor.depthAttachment.texture = drawable.depthTextures[0]

            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.depthAttachment.storeAction = .store
        }

        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        // Sky colour fills everywhere there is no geometry (full immersion, so
        // opaque alpha = no passthrough).
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.28, green: 0.55, blue: 0.92, alpha: 1.0)
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.clearDepth = 1e-5   // non-zero: visionOS reprojection drops depth==0
        renderPassDescriptor.rasterizationRateMap = drawable.rasterizationRateMaps.first
        if layerRenderer.configuration.layout == .layered {
            renderPassDescriptor.renderTargetArrayLength = drawable.views.count
        }

        #if !targetEnvironment(simulator)
        let residencySet = self.residencySets[uniformBufferIndex]
        var perFrame: [any MTLAllocation] = [
            drawable.colorTextures[0],
            drawable.depthTextures[0],
            drawableTarget.viewProjectionBuffer,
            entityVertexBuffer,
            handVertexBuffer,
            handIndexBuffer,
            entityIndexBuffer,
            modelVertexBuffer,
            modelIndexBuffer,
            // These are all bound and drawn below and get REALLOCATED when they
            // grow (upload()/consumeHandoff swap in a fresh MTLBuffer), so a
            // grown one belongs to no residency set unless listed here. Missing
            // them risks a GPU fault reading an unresident buffer on device.
            hudVertexBuffer, hudIndexBuffer,
            hudGlassVertexBuffer, hudGlassIndexBuffer,
            handHudVertexBuffer, handHudIndexBuffer,
            handHudTextVertexBuffer, handHudTextIndexBuffer,
            overlayVertexBuffer, overlayIndexBuffer,
        ]
        if let tex = textureArray { perFrame.append(tex) }
        if let mtex = modelTextureArray { perFrame.append(mtex) }
        if capture { ensureCaptureTexture(like: drawable.colorTextures[0]); if let ct = captureTexture { perFrame.append(ct) } }
        residencySet.removeAllAllocations()   // clear the prior frame's set (slot's GPU work is done)
        residencySet.addAllocations(perFrame)
        residencySet.commit()                 // one commit per frame, not two (#182)
        // World block buffers live in a dedicated set, rebuilt only when the
        // block set changed (#182/#183). Refresh this slot's set if armed; each
        // slot's prior frame has completed (endFrameEvent wait) so it's safe.
        let worldRes = self.worldResidencySets[uniformBufferIndex]
        if worldResidencyRefresh > 0 {
            worldResidencyRefresh -= 1
            worldRes.removeAllAllocations()
            var world: [any MTLAllocation] = []
            world.reserveCapacity(worldBlocks.count * 4)
            for (_, b) in worldBlocks {
                if let v = b.opaqueVerts { world.append(v) }
                if let s = b.solid { world.append(s.buffer) }
                if let c = b.cutout { world.append(c.buffer) }
                if let l = b.liquid { world.append(l.vertices); world.append(l.indices) }
            }
            worldRes.addAllocations(world)
            worldRes.commit()
        }
        commandBuffer.useResidencySet(worldRes)
        #endif

        /// Final pass rendering code here
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            fatalError("Failed to create render encoder")
        }

        renderEncoder.label = "Primary Render Encoder"

        renderEncoder.pushDebugGroup("Draw World")

        // Winding (#85): the mesher winds faces counter-clockwise with outward
        // normals in node space, but modelMatrix's Z mirror flips handedness, so
        // outward faces arrive CLOCKWISE on screen. Front = clockwise makes
        // back-face culling correct for the world mesh. Culling is switched on
        // only around the opaque world draw below: the sky triangle, liquids
        // (seen from underneath), billboards, hands and HUD quads are drawn
        // two-sided.
        renderEncoder.setCullMode(.none)
        renderEncoder.setFrontFacing(.clockwise)

        renderEncoder.setRenderPipelineState(pipelineState)

        renderEncoder.setDepthStencilState(depthState)

        let viewports = drawable.views.map { $0.textureMap.viewport }


        renderEncoder.setViewports(viewports)

        if drawable.views.count > 1 {
            var viewMappings = (0..<drawable.views.count).map {
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: UInt32($0),
                                                  renderTargetArrayIndexOffset: UInt32($0))
            }
            renderEncoder.setVertexAmplificationCount(viewports.count, viewMappings: &viewMappings)
        }

        // Uniforms (incl. daylight) are read by both the sky and world fragments.
        renderEncoder.setFragmentBuffer(dynamicUniformBuffer, offset: uniformBufferOffset, index: BufferIndex.uniforms.rawValue)

        // The world, drawn PER MAPBLOCK
        // (#183). Solid cubes and cutout (leaves/plants/nodeboxes) each get their
        // own index stream over the block's vertex buffer: solid through the
        // no-discard early-Z pipeline, cutout through the alpha-discard pipeline
        // (#164). Uniforms/vp/atlas are shared across all blocks.
        renderEncoder.setDepthStencilState(depthState)
        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset: uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(drawableTarget.viewProjectionBuffer, offset: drawableTarget.viewProjectionBufferOffset, index: BufferIndex.viewProjection.rawValue)
        if let tex = textureArray { renderEncoder.setFragmentTexture(tex, index: TextureIndex.color.rawValue) }

        // Frustum cull (perf #1): draw only the blocks in view. Test each block's
        // node-space AABB (key*16 .. +16, shifted to mesh space) against the left
        // eye's node->clip matrix; a one-block margin covers the ~6cm eye offset
        // and a frame of turn latency. Only side + "in front" planes are used, so
        // it's independent of the depth-buffer convention. Kill switch: -vrdev.noCull 1.
        if blockListDirty {
            blockListDirty = false
            blockList.removeAll(keepingCapacity: true)
            blockList.reserveCapacity(worldBlocks.count)
            for (key, gpu) in worldBlocks {
                blockList.append(BlockEntry(key: key, loN: SIMD3<Float>(Float(key.x) * 16, Float(key.y) * 16, Float(key.z) * 16), gpu: gpu))
            }
        }
        visibleBlocks.removeAll(keepingCapacity: true)
        if !blockList.isEmpty {
            let e = worldEye
            if noCull {
                for i in blockList.indices { visibleBlocks.append((0, i)) }
            } else {
                let m = drawableTarget.viewProjectionArray[0].viewProjectionMatrix.0 * uniforms[0].modelMatrix
                let planes = Self.frustumPlanes(m)
                let mref = worldMeshRef, sc = PlayerState.scale
                let sixteen = SIMD3<Float>(16, 16, 16), mvec = SIMD3<Float>(repeating: 16 * PlayerState.scale)
                let eight = SIMD3<Float>(8, 8, 8)
                for i in blockList.indices {
                    let loN = blockList[i].loN
                    let lo = (loN - mref) * sc - mvec
                    let hi = (loN + sixteen - mref) * sc + mvec
                    if Self.aabbVisible(lo: lo, hi: hi, planes: planes) {
                        visibleBlocks.append((simd_length_squared(loN + eight - e), i))
                    }
                }
                // Front-to-back so the opaque early-Z pass rejects occluded
                // fragments sooner (perf audit #4); the distance is computed once
                // per block, not once per comparison.
                visibleBlocks.sort { $0.dist < $1.dist }
            }
        }

        idxSolid = 0; idxCutout = 0; idxLiquid = 0
        if textureArray != nil, !worldBlocks.isEmpty {
            renderEncoder.setCullMode(.back)     // opaque world only (see the winding note above)
            // Solid pass: all blocks through the early-Z pipeline.
            renderEncoder.setRenderPipelineState(worldOpaquePipelineState)
            for vb in visibleBlocks {
                let b = blockList[vb.idx].gpu
                guard let v = b.opaqueVerts, let s = b.solid else { continue }
                renderEncoder.setVertexBuffer(v, offset: 0, index: BufferIndex.meshPositions.rawValue)
                renderEncoder.drawIndexedPrimitives(type: .triangle, indexCount: s.count,
                                                    indexType: .uint32, indexBuffer: s.buffer, indexBufferOffset: 0)
                idxSolid += s.count
            }
            // Cutout pass: leaves/plants/nodeboxes through the alpha-discard
            // pipeline, two-sided (the engine only back-face culls NDT_NORMAL;
            // the mesher used to emit a reversed twin per quad instead).
            renderEncoder.setCullMode(.none)
            renderEncoder.setRenderPipelineState(pipelineState)
            for vb in visibleBlocks {
                let b = blockList[vb.idx].gpu
                guard let v = b.opaqueVerts, let c = b.cutout else { continue }
                renderEncoder.setVertexBuffer(v, offset: 0, index: BufferIndex.meshPositions.rawValue)
                renderEncoder.drawIndexedPrimitives(type: .triangle, indexCount: c.count,
                                                    indexType: .uint32, indexBuffer: c.buffer, indexBufferOffset: 0)
                idxCutout += c.count
            }
        }

        // Sky AFTER the opaque world: a fullscreen triangle at far depth
        // (5e-5) with a .greater test, so it only shades the pixels the world
        // left at the clear depth (1e-5). Drawn first with depth .always it
        // was submitted for every pixel of both eyes and the ~350-op cloud
        // shader relied on the tile GPU's hidden-surface pass to skip it. It
        // still writes depth there, so the compositor's depth reprojection
        // keeps background pixels instead of dropping them to black. Before
        // the liquids so water blends over the sky it faces.
        renderEncoder.setRenderPipelineState(skyPipelineState)
        renderEncoder.setDepthStencilState(skyDepthState)
        renderEncoder.setFragmentTexture(skyboxTexture ?? skyboxPlaceholder, index: 1)
        renderEncoder.setFragmentTexture(cloudNoiseTexture, index: 2)
        renderEncoder.setVertexBuffer(drawableTarget.viewProjectionBuffer, offset: drawableTarget.viewProjectionBufferOffset, index: BufferIndex.viewProjection.rawValue)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Liquids: a blended second pass over the opaque world (depth-test on,
        // depth-write off) so water reads as translucent, per block.
        if textureArray != nil, !worldBlocks.isEmpty {
            renderEncoder.setRenderPipelineState(liquidPipelineState)
            renderEncoder.setDepthStencilState(liquidDepthState)
            for vb in visibleBlocks {
                guard let l = blockList[vb.idx].gpu.liquid else { continue }
                renderEncoder.setVertexBuffer(l.vertices, offset: 0, index: BufferIndex.meshPositions.rawValue)
                renderEncoder.drawIndexedPrimitives(type: .triangle, indexCount: l.indexCount,
                                                    indexType: .uint32, indexBuffer: l.indices, indexBufferOffset: 0)
                idxLiquid += l.indexCount
            }
        }

        // Entities: camera-facing billboards (model-matrix-free vertex shader).
        if entityIndexCount > 0, textureArray != nil {
            renderEncoder.setRenderPipelineState(entityPipelineState)
            renderEncoder.setDepthStencilState(depthState)
            renderEncoder.setVertexBuffer(entityVertexBuffer, offset: 0, index: BufferIndex.meshPositions.rawValue)
            renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                indexCount: entityIndexCount,
                                                indexType: .uint32,
                                                indexBuffer: entityIndexBuffer,
                                                indexBufferOffset: 0)
        }

        // Mob models: real 3D meshes (already in origin space), sampling the
        // full-res mob-skin array instead of the node atlas. Reuses the entity
        // pipeline (same vertex layout, model-matrix-free).
        if modelIndexCount > 0, let mtex = modelTextureArray {
            renderEncoder.setRenderPipelineState(entityPipelineState)
            renderEncoder.setDepthStencilState(depthState)
            renderEncoder.setFragmentTexture(mtex, index: TextureIndex.color.rawValue)
            renderEncoder.setVertexBuffer(modelVertexBuffer, offset: 0, index: BufferIndex.meshPositions.rawValue)
            renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                indexCount: modelIndexCount,
                                                indexType: .uint32,
                                                indexBuffer: modelIndexBuffer,
                                                indexBufferOffset: 0)
        }

        // Underwater tint: last, so it casts the whole view (world, entities,
        // HUD) toward water colour whenever the eye node is a liquid. Fullscreen
        // blended triangle; no vertex/index buffers (driven by vertex_id).
        var fx = appModel.player.postEffect()
        if fx.w > 0 {
            renderEncoder.pushDebugGroup("Underwater Tint")
            renderEncoder.setRenderPipelineState(underwaterPipelineState)
            renderEncoder.setDepthStencilState(underwaterDepthState)
            renderEncoder.setFragmentBytes(&fx, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            renderEncoder.popDebugGroup()
        }
        // Diegetic threshold vignette (HUD P8): a soft edge cast for low health /
        // low breath, over the world but under the HUD so the readouts stay crisp.
        var vig = appModel.player.vignette()
        if vig.w > 0 {
            renderEncoder.pushDebugGroup("Threshold Vignette")
            renderEncoder.setRenderPipelineState(vignettePipelineState)
            renderEncoder.setDepthStencilState(underwaterDepthState)
            renderEncoder.setFragmentBytes(&vig, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            renderEncoder.popDebugGroup()
        }
        // Head-locked HUD (hearts/hunger/breath): drawn AFTER the water/solid-node
        // tint like Luanti's HUD-after-renderPostFx, so the readout stays visible
        // when the head is in a wall (black-out) and isn't blue-tinted underwater.
        // Depth-cleared placement in buildHudBillboards against this frame's head.
        // Glass backing plate first, so the vitals icons draw on top of it.
        if hudGlassIndexCount > 0 {
            renderEncoder.setRenderPipelineState(hudGlassPipelineState)
            renderEncoder.setDepthStencilState(noDepthState)
            renderEncoder.setVertexBuffer(hudGlassVertexBuffer, offset: 0, index: BufferIndex.meshPositions.rawValue)
            renderEncoder.drawIndexedPrimitives(type: .triangle, indexCount: hudGlassIndexCount,
                                                indexType: .uint32, indexBuffer: hudGlassIndexBuffer, indexBufferOffset: 0)
        }
        if hudIndexCount > 0, textureArray != nil {
            renderEncoder.setRenderPipelineState(entityPipelineState)
            renderEncoder.setDepthStencilState(noDepthState)   // always visible, even against an indoor wall
            renderEncoder.setFragmentTexture(textureArray, index: TextureIndex.color.rawValue)
            renderEncoder.setVertexBuffer(hudVertexBuffer, offset: 0, index: BufferIndex.meshPositions.rawValue)
            renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                indexCount: hudIndexCount,
                                                indexType: .uint32,
                                                indexBuffer: hudIndexBuffer,
                                                indexBufferOffset: 0)
        }
        // Hands + hand-anchored HUD (wield item, wrist hotbar), drawn here AFTER
        // the world, tint, and head-locked HUD. Drawing them earlier (before the
        // post-effect/HUD passes) left them invisible in the sim, so keep them at
        // this proven point for both platforms. Sim uses no-depth (always on top
        // for headless screenshots); device depth-tests so the wield can be
        // occluded by terrain like a real held item.
        #if targetEnvironment(simulator)
        let handHudDepthState = noDepthState
        #else
        let handHudDepthState = depthState
        #endif
        // Controller hands: solid boxes at the tracked hand anchors (device only).
        if handIndexCount > 0 {
            renderEncoder.setRenderPipelineState(handPipelineState)
            renderEncoder.setDepthStencilState(handHudDepthState)
            renderEncoder.setVertexBuffer(handVertexBuffer, offset: 0, index: BufferIndex.meshPositions.rawValue)
            renderEncoder.drawIndexedPrimitives(type: .triangle, indexCount: handIndexCount,
                                                indexType: .uint32, indexBuffer: handIndexBuffer, indexBufferOffset: 0)
        }
        if handHudIndexCount > 0, textureArray != nil {
            renderEncoder.setRenderPipelineState(entityPipelineState)
            renderEncoder.setDepthStencilState(handHudDepthState)
            renderEncoder.setFragmentTexture(textureArray, index: TextureIndex.color.rawValue)
            renderEncoder.setVertexBuffer(handHudVertexBuffer, offset: 0, index: BufferIndex.meshPositions.rawValue)
            renderEncoder.drawIndexedPrimitives(type: .triangle, indexCount: handHudIndexCount,
                                                indexType: .uint32, indexBuffer: handHudIndexBuffer, indexBufferOffset: 0)
        }
        // Wield stack count (#158): same hand pipeline/depth, but the digits live
        // in the MODEL texture array, so bind that for this one draw.
        if handHudTextIndexCount > 0, let mtex = modelTextureArray {
            renderEncoder.setRenderPipelineState(entityPipelineState)
            renderEncoder.setDepthStencilState(handHudDepthState)
            renderEncoder.setFragmentTexture(mtex, index: TextureIndex.color.rawValue)
            renderEncoder.setVertexBuffer(handHudTextVertexBuffer, offset: 0, index: BufferIndex.meshPositions.rawValue)
            renderEncoder.drawIndexedPrimitives(type: .triangle, indexCount: handHudTextIndexCount,
                                                indexType: .uint32, indexBuffer: handHudTextIndexBuffer, indexBufferOffset: 0)
        }
        // Modal UI overlay (keyboard/panel/menu/chat/banner): on top of the
        // world and the HUD, no depth test, so terrain never buries it.
        if overlayIndexCount > 0, let mtex = modelTextureArray {
            renderEncoder.setRenderPipelineState(entityPipelineState)
            renderEncoder.setDepthStencilState(noDepthState)
            renderEncoder.setFragmentTexture(mtex, index: TextureIndex.color.rawValue)
            renderEncoder.setVertexBuffer(overlayVertexBuffer, offset: 0, index: BufferIndex.meshPositions.rawValue)
            renderEncoder.drawIndexedPrimitives(type: .triangle, indexCount: overlayIndexCount,
                                                indexType: .uint32, indexBuffer: overlayIndexBuffer, indexBufferOffset: 0)
        }
        // Red death cast: over everything (including the underwater tint and HUD) once hp is 0.
        if appModel.player.isDead() {
            renderEncoder.pushDebugGroup("Death Tint")
            renderEncoder.setRenderPipelineState(deathPipelineState)
            renderEncoder.setDepthStencilState(underwaterDepthState)
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            renderEncoder.popDebugGroup()
        }

        renderEncoder.popDebugGroup()

        renderEncoder.endEncoding()

        // Screenshot: copy the resolved frame into a CPU-readable texture and
        // write a PNG once the GPU finishes.
        if capture {
            ensureCaptureTexture(like: drawable.colorTextures[0])
            if let ct = captureTexture, let blit = commandBuffer.makeBlitCommandEncoder() {
                let src = drawable.colorTextures[0]
                blit.copy(from: src, sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: src.width, height: src.height, depth: 1),
                          to: ct, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.endEncoding()
                let w = ct.width, h = ct.height
                commandBuffer.addCompletedHandler { [weak self] _ in self?.writeScreenshot(ct, w, h) }
            }
        }

        drawable.encodePresent(commandBuffer: commandBuffer)

    }

    func renderLoop() {
        while true {
            if layerRenderer.state == .invalidated {
                print("Layer is invalidated")
                Task { @MainActor in
                    appModel.immersiveSpaceState = .closed
                }
                return
            } else if layerRenderer.state == .paused {
                Task { @MainActor in
                    appModel.immersiveSpaceState = .inTransition
                }
                layerRenderer.waitUntilRunning()
                continue
            } else {
                Task { @MainActor in
                    if appModel.immersiveSpaceState != .open {
                        appModel.immersiveSpaceState = .open
                    }
                }
                autoreleasepool {
                    self.renderFrame()
                }
            }
        }
    }
}

extension Renderer {
    class DrawableTarget {
        var lastUsedFrameIndex: UInt64

        let memorylessTargets: [(color: MTLTexture, depth: MTLTexture)]

        let viewProjectionBuffer: MTLBuffer

        var viewProjectionBufferOffset = 0

        var viewProjectionArray: UnsafeMutablePointer<ViewProjectionArray>

        nonisolated init(drawable: LayerRenderer.Drawable) {
            lastUsedFrameIndex = 0

            let device = drawable.colorTextures[0].device
            nonisolated func renderTarget(resolveTexture: MTLTexture) -> MTLTexture {
                assert(device.supportsMSAA)

                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: resolveTexture.pixelFormat,
                                                                          width: resolveTexture.width,
                                                                          height: resolveTexture.height,
                                                                          mipmapped: false)
                descriptor.usage = .renderTarget
                descriptor.textureType = .type2DMultisampleArray
                descriptor.sampleCount = device.rasterSampleCount
                descriptor.storageMode = .memoryless
                descriptor.arrayLength = resolveTexture.arrayLength
                return device.makeTexture(descriptor: descriptor)!
            }

            if device.supportsMSAA {
                // A distinct MSAA color+depth pair per in-flight frame: render()
                // indexes memorylessTargets[uniformBufferIndex] and up to
                // maxBuffersInFlight frames overlap. Array(repeating:) evaluates
                // its element once, so it would hand every frame the SAME pair.
                memorylessTargets = (0..<maxBuffersInFlight).map { _ in
                    (renderTarget(resolveTexture: drawable.colorTextures[0]),
                     renderTarget(resolveTexture: drawable.depthTextures[0]))
                }
            } else {
                memorylessTargets = []
            }

            let bufferSize = alignedViewProjectionArraySize * maxBuffersInFlight

            viewProjectionBuffer = device.makeBuffer(length: bufferSize,
                                                     options: [MTLResourceOptions.storageModeShared])!
            viewProjectionArray = UnsafeMutableRawPointer(viewProjectionBuffer.contents() + viewProjectionBufferOffset).bindMemory(to: ViewProjectionArray.self, capacity: 1)
        }
    }
}

extension Renderer.DrawableTarget {
    nonisolated func updateBufferState(uniformBufferIndex: Int, frameIndex: UInt64) {
        viewProjectionBufferOffset = alignedViewProjectionArraySize * uniformBufferIndex

        viewProjectionArray = UnsafeMutableRawPointer(viewProjectionBuffer.contents() + viewProjectionBufferOffset).bindMemory(to: ViewProjectionArray.self, capacity: 1)

        lastUsedFrameIndex = frameIndex
    }

    nonisolated func updateViewProjectionArray(drawable: LayerRenderer.Drawable) {
        let simdDeviceAnchor = (drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4) * Renderer.simHeadOffset()

        nonisolated func viewProjection(forViewIndex viewIndex: Int) -> float4x4 {
            let view = drawable.views[viewIndex]
            let viewMatrix = (simdDeviceAnchor * view.transform).inverse
            let projectionMatrix = drawable.computeProjection(viewIndex: viewIndex)

            return projectionMatrix * viewMatrix
        }

        let vp0 = viewProjection(forViewIndex: 0)
        viewProjectionArray[0].viewProjectionMatrix.0 = vp0
        viewProjectionArray[0].inverseViewProjectionMatrix.0 = vp0.inverse
        if drawable.views.count > 1 {
            let vp1 = viewProjection(forViewIndex: 1)
            viewProjectionArray[0].viewProjectionMatrix.1 = vp1
            viewProjectionArray[0].inverseViewProjectionMatrix.1 = vp1.inverse
        }
    }
}

// Generic matrix math utility functions
nonisolated func matrix4x4_rotation(radians: Float, axis: SIMD3<Float>) -> matrix_float4x4 {
    let unitAxis = normalize(axis)
    let ct = cosf(radians)
    let st = sinf(radians)
    let ci = 1 - ct
    let x = unitAxis.x, y = unitAxis.y, z = unitAxis.z
    return .init(columns: (vector_float4(    ct + x * x * ci, y * x * ci + z * st, z * x * ci - y * st, 0),
                           vector_float4(x * y * ci - z * st, ct + y * y * ci, z * y * ci + x * st, 0),
                           vector_float4(x * z * ci + y * st, y * z * ci - x * st, ct + z * z * ci, 0),
                           vector_float4(                  0, 0, 0, 1)))
}

nonisolated func matrix4x4_translation(_ translationX: Float, _ translationY: Float, _ translationZ: Float) -> matrix_float4x4 {
    return .init(columns: (vector_float4(1, 0, 0, 0),
                           vector_float4(0, 1, 0, 0),
                           vector_float4(0, 0, 1, 0),
                           vector_float4(translationX, translationY, translationZ, 1)))
}