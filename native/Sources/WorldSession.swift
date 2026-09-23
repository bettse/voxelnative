// The app-side game session: drives LuantiKit's Client, meshes the streamed
// world, and renders HUD/formspecs. The `-vrdev.*` defaults read throughout are
// simulator/dev aids only; the ones that send chat commands (/grantme, /giveme,
// /teleport, /setblock) are ordinary Luanti chat run against the developer's own
// local dev world to stage a test scene.
import Foundation
import os
import CoreText
import CoreGraphics
import simd
#if canImport(UIKit)
import UIKit
#endif
import LuantiKit

// Element-wise vertex/index appends. An `append(contentsOf: [..])` array literal
// heap-allocates a throwaway Array every call; these emitters run per corner /
// per quad on the tick thread, so that churn adds up (#248). Same layout out.
@inline(__always) private func pushV(_ a: inout [Float], _ x: Float, _ y: Float, _ z: Float,
                                     _ u: Float, _ w: Float, _ layer: Float, _ shade: Float,
                                     _ light: Float, _ tint: Float) {
    a.append(x); a.append(y); a.append(z); a.append(u); a.append(w)
    a.append(layer); a.append(shade); a.append(light); a.append(tint)
}
/// A back-to-front quad's two triangles from its base vertex index.
@inline(__always) private func pushQuad(_ a: inout [UInt32], _ b: UInt32) {
    a.append(b); a.append(b &+ 1); a.append(b &+ 2)
    a.append(b); a.append(b &+ 2); a.append(b &+ 3)
}

/// Owns the live Luanti connection: auto-logs into the dev server, drives the
/// protocol poll loop, integrates player movement, sends PLAYERPOS (so the
/// server streams chunks around the player), and re-meshes the streamed world
/// (debounced) into the MeshHandoff. No login UI (server selection is later).
final class WorldSession {
    // Connection target. Configurable at runtime (the server-select screen writes
    // these to UserDefaults); falls back to the dev defaults when unset.
    static let defaultHost: String = {
        #if targetEnvironment(simulator)
        return "127.0.0.1"    // sim shares the Mac's loopback (no local-network prompt)
        #else
        return ""             // no default on device: enter your server in the launcher
        #endif
    }()
    static var host: String {
        let h = UserDefaults.standard.string(forKey: "vrdev.host")
        return (h?.isEmpty == false) ? h! : defaultHost
    }
    static var port: UInt16 {
        let p = UserDefaults.standard.integer(forKey: "vrdev.port")
        return p > 0 && p <= 65535 ? UInt16(p) : 30000
    }
    // Stable per-launch fallback name so the sim (which doesn't persist one) is
    // consistent across the several reads during a connect.
    private static let generatedName = "vrdev-" + String(format: "%04x", UInt16.random(in: 0...0xFFFF))
    // Prefer a name the server-select screen saved; else the per-launch fallback.
    // The server recognizes a saved name on relaunch and restores our position.
    static var playerName: String {
        if let n = UserDefaults.standard.string(forKey: "vrdev.playerName"), !n.isEmpty { return n }
        return generatedName
    }
    // A stable (registered) password so re-login authenticates as the same
    // account instead of hitting "empty passwords not allowed". On a server where
    // this name has no account yet the join takes the engine's FIRST_SRP path
    // (Client::startAuth, src/client/client.cpp) and registers it, which is what
    // the desktop client's Register button does; the launcher lets the player set
    // their own name/password instead.
    static let password: String = {
        let key = "vrdev.password"
        if let p = UserDefaults.standard.string(forKey: key), !p.isEmpty { return p }
        let p = UUID().uuidString
        UserDefaults.standard.set(p, forKey: key)
        return p
    }()
    static let walkSpeed: Float = 4.0   // m/s
    static let turnSpeed: Float = 2.2   // rad/s at full stick

    let handoff: MeshHandoff
    let entityHandoff: EntityHandoff
    let modelHandoff: ModelHandoff
    let modelTextureHandoff: ModelTextureHandoff
    let skyboxHandoff: SkyboxHandoff
    private var skyboxWanted: [String] = []   // SET_SKY skybox textures (6) or empty
    private var skyboxBuilt: [String] = []    // what the renderer currently holds
    let handHudHandoff: HandHudHandoff
    let screenshotFlag: ScreenshotFlag
    let player: PlayerState
    private var prevSnap = false
    // Parsed models + model-texture atlas assignment, built lazily as mobs stream.
    private var modelCache: [String: B3DLoader.Mesh] = [:]
    // Parsed node mesh models (drawtype "mesh"), keyed by model file name. Failed
    // parses are remembered so we don't retry a broken file every remesh.
    private var nodeModelCache: [String: B3DLoader.Mesh] = [:]
    private var nodeModelFailed: Set<String> = []
    private var modelTexLayer: [String: Int] = [:]
    private var modelTexUV: [String: SIMD2<Float>] = [:]
    private var modelTexData: [[UInt8]] = []
    private var modelTexNames: [String] = []
    private var modelTexCount = 0
    private var modelTexPostedCount = 0        // layer count of the last full we POSTED (vs handoff.builtCount, what the renderer acked) (#254)
    private var modelTexDirty: Set<Int> = []   // existing layers whose pixels changed (patch, don't rebuild)
    /// Overwrite an existing layer's pixels and mark it for an in-place GPU patch
    /// (not a full array rebuild). Use this for every content update of a layer
    /// that already exists (chat, HUD timer, counts, XP) -- the perf win (#perf).
    private func updateModelLayer(_ i: Int, _ px: [UInt8]) {
        guard i >= 0, i < modelTexData.count else { return }
        modelTexData[i] = px; modelTexDirty.insert(i); modelTexturesDirty = true
    }
    private var modelFailed: Set<String> = []
    // Crack overlay frames live in the model texture array (the model draw
    // binds that, not the node atlas). One (layer, uvScale) per dig stage.
    private var crackTex: [(layer: Int, uv: SIMD2<Float>)] = []
    private var deathTextLayer: Int = -1   // model-array layer for the "YOU DIED" overlay
    // A solid-opaque white layer in the model texture array, sampled (with a
    // black vertex tint) to draw the pointed-node highlight box. -1 until baked.
    private var highlightLayer: Int = -1

    // --- Kogane: the shoulder companion that fronts the in-headset menu. ---
    // A small sprite floats forward-and-left of the body (body-anchored, so you
    // can turn your head to look at it). Looking at it + the right trigger (or a
    // pinch on device) opens an OSD menu to leave the world. Its sprite and menu
    // text live in the model-texture array like the death overlay.
    weak var appModel: AppModel?               // set by AppModel so the menu can leave the space
    private var koganeLayer = -1               // the companion sprite, eyes open
    private var koganeClosedLayer = -1         // eyes closed (shown until you look at it)
    private var koganeTitleLayer = -1          // "Kogane" heading
    private var koganeOptionLayers: [Int] = [] // one text layer per menu option
    // "Resume" is first and is the default selection, so opening the menu and
    // confirming (a double trigger) just closes it — no accidental exit.
    // "Bug note" appears only in testing mode (-vrdev.testingMode / the launcher
    // toggle): capture a bug from inside the world without leaving to the
    // launcher. Testing mode doesn't flip mid-session, so reading it here (used
    // for nav bounds, render, highlight and dispatch) stays consistent per frame.
    // Audio is controlled by the launcher's volume sliders now, so the old
    // in-game music/sound toggles are gone (they duplicated the sliders and
    // confused more than helped) (#240). Stored, not computed: it was read per
    // option per tick while the menu was open, rebuilding the array each time.
    private let koganeOptions: [String] = {
        var o = ["Resume", "Chat", "Exit to menu", "Quit game"]
        if UserDefaults.standard.bool(forKey: "vrdev.testingMode") { o.insert("Bug note", at: 2) }
        return o
    }()
    private var koganeFocused = false          // gaze is on the companion
    private var koganeMenuOpen = false
    private let koganeSpriteVisible = false   // #105: hidden for now (right X opens the menu); code kept
    private var koganeSel = 0                   // highlighted option
    private var koganeBob: Float = 0            // idle bob phase
    private var koganeOpenCooldown: Float = 0   // brief lockout so opening can't instant-confirm
    // Rising-edge trackers so a held trigger/stick doesn't repeat.
    private var prevKoganeTrigger = false
    private var prevKoganeCancel = false
    private var prevKoganeNav: Float = 0
    private var prevKoganeSelect = false
    // In-world chat overlay: a fixed ring of reusable text layers (no leak),
    // each showing a recent CHAT_MESSAGE that fades after a few seconds.
    private static let chatSlots = 6
    private var chatLayers: [Int] = []
    private var chatRing: [(text: String, born: Double, aspect: Float, lines: Int)] = []
    private var chatNext = 0
    private var chatClock: Double = 0
    // Spatial QWERTY keyboard (chat, sign text): aim + trigger to type, Done
    // to submit. Reuses the inventory ray/plane pick and appendQuad.
    private struct Key { let id: String; let u: Float; let v: Float; let hw: Float; var hh: Float = 0.034 }
    private var keyboardOpen = false
    // Bug notes use the "simple" board: no letter keys, just mic / clear /
    // submit at controller-friendly size, since nobody types a sentence on a
    // floating qwerty in a headset (Eric). Dictation is the only text source.
    private var kbSimple = false
    private var kbCursor: SIMD3<Float>? = nil   // aim ray hit on the board (node space) for the targeting dot
    private var keyboardBuffer = ""
    private var keyboardDone: ((String) -> Void)?
    private var kbSaveOnDismiss = false       // bug note: dismissing submits instead of discarding
    private var keyboardFrame: InvFrame? = nil
    private var keyboardKeys: [Key] = []
    // Voice dictation for the keyboard (no system keyboard in the immersive
    // space). The recognizer's transcript arrives on the main queue; stash it
    // under a lock and let the tick fold it into keyboardBuffer.
    private let dictation = Dictation()
    private var dictating = false
    private var dictationPrefix = ""          // buffer text before dictation began
    private var dictationCommitted = ""       // segments the recognizer already finalized this session
    private let dictationLock = NSLock()
    private var dictationInbox: String? = nil // full live text (prefix+committed+partial) pending apply
    private var keyLabelLayers: [String: Int] = [:]
    private var kbBufferLayer = -1          // model-texture layer holding the typed text (-1 = none yet)
    private var kbBufferDirty = true        // text changed: re-rasterise into that layer (in-place patch)
    private var kbBufferAspect: Float = 1   // width/height of the baked output text (renderTextFilled)
    private var kbHover: Int? = nil
    private var kbPrevDig = false
    private var kbPrevCancel = false        // edge-detect the cancel (menu/inventory) button so the press that OPENED the keyboard doesn't instantly close it (#238)
    #if targetEnvironment(simulator)
    private var koganeSimClock: Float = 0       // sim-only: auto-opens the menu so it can be screenshotted
    #endif
    private var atlas = TextureAtlas()
    private var atlasBuilt = false
    private var lastAtlasStore = -1
    // Force a rebuild even when the media store didn't grow (e.g. new hotbar
    // item icons need baking into the atlas).
    private var atlasNeedsRebuild = false
    private var expireAccum: Float = 0                  // dt since the last block age-out sweep
    // Tiles whose media was re-pushed since the last build: evicted from the
    // seeded atlas so the next rebuild re-evaluates their pixels (the atlas is
    // otherwise append-only and would keep the stale bytes).
    private var atlasDropTiles: Set<String> = []
    // Hotbar (session-queue only): the 9 main slots' base item names, the icon
    // tile string resolved for each slot (item inventory_image or a node face
    // tile fallback), and the set of tiles to bake into the atlas.
    private var hotbar: [String?] = Array(repeating: nil, count: 9)
    private var hotbarIcons: [String?] = Array(repeating: nil, count: 9)
    private var hotbarTiles: Set<String> = []
    static let maxTextureLayers = 2048          // MTLTextureDescriptor arrayLength cap
    private var texLayerCapLogged = false
    private var atlasGeneration = 0                 // bumped by every rebuildAtlas
    private var lastPostedAtlasGen = -1
    // Atlas builds run here, off the tick queue. At 64px tiles a full bake is
    // heavy enough (~16x the 16px pixel count) to blow the 16ms physics budget
    // if run inline during client.poll, which froze locomotion then snap-
    // corrected the player (a fall risk, #152). Session-queue-only flags below
    // coalesce overlapping requests.
    private let atlasQueue = DispatchQueue(label: "world.atlas", qos: .userInitiated)
    private var atlasBuilding = false               // a build is in flight on atlasQueue
    private var atlasRebuildPending = false         // asked again mid-build; rebuild once more when done
    private var mediaAtlasDirty = false             // media arrived; coalesce the rebuild (#188)
    private var sinceMediaAtlas: Double = 999       // seconds since the last atlas rebuild (first is prompt)
    private let client = Client(name: WorldSession.playerName, password: WorldSession.password)
    private let audio = AudioManager()
    private let finishedSounds = OSAllocatedUnfairLock<[Int]>(initialState: [])   // server sound ids that ended (audio queue -> tick)
    private var attachedSounds: [Int: Int] = [:]   // sound id -> object id (type 2 sounds follow their mob)
    private let queue = DispatchQueue(label: "world.session", qos: .userInitiated)
    // Meshing runs here, off the poll/input queue, so a whole-world rebuild
    // (hundreds of ms as the world grows) never stalls input or PLAYERPOS.
    private let mesherQueue = DispatchQueue(label: "world.mesher", qos: .userInitiated)
    private var meshing = false   // session-queue only; coalesces remesh requests
    private var reconnectAttempts = 0
    private var reconnectPending = false   // one retry in flight at a time
    private var connEpoch = 0              // bumped on start()/stop(); a pending retry from an older epoch is stale (F1)
    private var fatalDenied = false        // true after a non-retryable ACCESS_DENIED (wrong pw, name not allowed, etc)
    // Human-readable connection trouble for the in-world banner (mid-session
    // drops, after the launcher is gone). nil while all is well. Session-queue side.
    private(set) var connProblem: String? = nil
    // A button-only dialog (the bed "Leave bed" sleep form) shown as a banner;
    // pressing the inventory button submits it so you can get up. Without this a
    // sleep freeze (physics_override speed=0/jump=0) had no escape.
    private var noticeText: String? = nil
    private var noticeExpiry: Double = 0          // uptime after which noticeText clears itself (0 = sticky)
    private var pendingButtonForm: (formname: String, button: String)? = nil

    /// Push the connection phase to the launcher (main actor). Also mirrors a
    /// short problem string for the in-world banner.
    private func setPhase(_ phase: AppModel.ConnPhase) {
        switch phase {
        case .reconnecting(let n): connProblem = "Reconnecting\u{2026} (\(n))"
        case .failed(let r):       connProblem = "Disconnected: \(r)"
        case .connecting:          connProblem = "Connecting\u{2026}"
        default:                   connProblem = nil
        }
        DispatchQueue.main.async { [weak self] in self?.appModel?.connPhase = phase }
    }
    private var stopped = false            // true after stop(); blocks stray reconnects
    private var timer: DispatchSourceTimer?
    private let perf = PerfStats("tick")   // -vrdev.perfStats / testing mode: per-phase ms every 5 s
    private var lastModelsDrawn = 0, skinMisses = 0

    private var dirty = false
    private var remeshCooldown: Double = 0
    private var playersSeen: Set<String> = []
    private var creepersNear: Set<Int> = []   // creeper object ids within hiss range (#gag: hot-pink creepers)
    private var loggedDropIds: Set<Int> = []  // dropped items already reported by the one-shot [drop] draw log (#358)
    private var creeperCache: [Int: Bool] = [:]   // per-entity creeper flag; mesh/name are stable, so don't re-lowercase every frame (#247)
    private var bgMissLogged: Set<String> = []    // one-time log for a missing fill-background texture (#254)
    private var skinCache: [Int: (mesh: String, frame: Float, bones: Int, positions: [SIMD3<Float>])] = [:]   // entity id -> last skin
    // #165 perf: how far out we skin+draw real mob meshes. Capped at 96 nodes
    // (past that they're clutter), but a lower view-distance slider pulls it in
    // so fewer mobs get skinned each tick (skinning is the fan-spinning cost).
    private var mobRenderDist: Float = 96
    // #162 perf: the bind-pose bounds/fit-height of a model depend only on its
    // mesh + visible-surface set (never on pose or the player), so cache them
    // per entity instead of scanning every draw index every tick.
    // Reserve the model vertex/index arrays to last tick's size so a ~140k-float
    // stream isn't regrown from zero (repeated reallocs) every tick (#162).
    private var lastModelVerts = 0
    private var lastModelIdx = 0
    private var seenEntityTiles: Set<String> = []   // entity texture strings already offered to the atlas
    // Gate for ensureModelTextures' entity scan (#251): only walk all entities'
    // textures when a new one appeared (objects.tiles is a monotonic "seen" set,
    // so its count only grows) or media just landed (a pending skin may resolve
    // now). Otherwise every tick re-parsed each pending skin's modifier string.
    private var modelTexRescan = true
    private var lastModelTexTilesCount = -1
    private var simMobPhase = 0                       // -vrdev.spawnMob framing state (#91)
    private var simMobTimer: Double = 0
    private var simRealHudDone = false                // one-shot guard for -vrdev.realHud
    private var simBedSpawned = false                 // one-shot guard for -vrdev.spawnBed
    private var simGlassSpawned = false               // one-shot guard for -vrdev.spawnGlass
    private var simRailsSpawned = false               // one-shot guard for -vrdev.spawnRails
    private var simCmdDone = false                     // one-shot guard for -vrdev.cmd
    private var simCmdQueue: [String]? = nil           // remaining -vrdev.cmd commands, drained one per ~12 frames
    private var simCmdTimer: Double = 1.3               // seconds since the last -vrdev.cmd send (kept >= the server's chat allowance)
    private var fakeRainSpawned = false
    // free_move (#291): Luanti toggles it with K when the player has "fly";
    // in VR a double-tap of jump does it. Off again if the priv goes away.
    private var flying = false
    private var flyPrevJump = false
    private var flyLastTap: TimeInterval = -10
    private var fakeSkyboxSent = false
    private var digCapsTestDone = false
    private var audioTestPhase = 0
    private var audioTestTimer: Float = 0
    private var fakeRainLogTimer: Double = 0                // one-shot guard for -vrdev.fakeRain (#199/#201)
    private var simRideDone = false                    // one-shot guard for -vrdev.rideTest
    private var simEatPhase = 0                         // -vrdev.eatTest state machine
    private var simGripOverride: Bool? = nil            // -vrdev.bowTest: stands in for the controller grip
    private var simEatTimer: Double = 0
    // Per-scene scratch for the -vrdev.*Test harness: only one scene runs per
    // launch, so these mean whatever the running scene sets them to (a count,
    // a low-water mark, a target node, a paced chat queue).
    private var simScratchCount = 0
    private var simDigPhase = 0                         // -vrdev.digTest state machine (#179)
    private var simDigTimer: Double = 0
    private var simTarget: SIMD3<Int>? = nil        // per-scene scratch: the node the scene works on
    private var audioResolveLogged = Set<String>()       // sound names already logged by [audio] resolve
    private var lastHotbarLog = ""
    private var loggedMobNames = Set<String>()           // [mob] identity line, once per entity name
    private var simDropResult = ""                       // -vrdev.dropTest: RESULT line, printed after cleanup
    private var simChatQueue: [String] = []               // per-scene scratch: commands/items still to process (chat-rate paced)
    private var awardBox: (lo: SIMD2<Float>, hi: SIMD2<Float>)? = nil   // this frame's toast background (nominal px), to fit its text
    private var simAwardRects: [String: (lo: SIMD2<Float>, hi: SIMD2<Float>)] = [:]   // -vrdev.awardTest: drawn toast rects (nominal px)
    private var simScratchInt = Int.max                  // per-scene scratch: a low-water mark or a start value x100
    private var simInvPhase = 0                         // -vrdev.invPickTest state machine (#81)
    private var simInvCyclePhase = 0                    // -vrdev.invCycle (#296)
    private var simInvTimer: Double = 0
    private var simInvHoverOverride: Int? = nil         // sim: force invHover to a slot (no ray)
    private var prevInventory = false
    private var prevKoganeMenuBtn = false
    private var prevDismissChat = false
    // After a long teleport (dimension change), show a "Loading terrain" notice
    // until the ground under the player streams in, so the empty void doesn't
    // read as a broken/dangerous world. Counts down as a safety cap.
    private var teleportSettle: Float = 0
    private var terrainLoading = false
    private var simSceneTimer: Double = 0
    private var inventoryOpen = false   // right O toggles; panel itself is #81
    // Per-mapblock mesh cache (mesherQueue-only). A dig/place re-meshes just the
    // touched block + its neighbours instead of the whole world, then the cache
    // entries are concatenated into the combined buffer the renderer wants. Keyed
    // by mapblock position; positions are baked against a fixed meshRef (set once
    // at spawn), so cached geometry stays valid as the player moves.
    private typealias BlockGeom = (opaque: (v: [Float], solid: [UInt32], cutout: [UInt32]), liquid: ([Float], [UInt32]))
    private var blockCache: [SIMD3<Int>: BlockGeom] = [:]   // mesherQueue only
    private var dirtyBlocks: Set<SIMD3<Int>> = []           // session queue
    private var fullRemesh = true                           // rebuild every block next remesh
    private var cachedMeshRef = SIMD3<Float>(.nan, .nan, .nan)   // mesherQueue only
    private static let neighborOffsets = [
        SIMD3(1,0,0), SIMD3(-1,0,0), SIMD3(0,1,0), SIMD3(0,-1,0), SIMD3(0,0,1), SIMD3(0,0,-1)
    ]
    private var started = false
    private var prevDig = false, prevPlace = false
    // Drop chord (#341): right trigger + right grip together = desktop Q.
    private var dropChordLatched = false        // chord fired; both buttons ignored until both release
    private var chordWait: Float = 0            // a lone press waits this long for its partner
    private var chordPendingDig = false         // which button started the wait
    private static let chordWindow: Float = 0.08
    private var objectHitDelay: Float = 0               // game.cpp object_hit_delay_timer, counts down every tick (#284)
    private var digInstantly = false                    // last break was an instant dig (game.cpp dig_instantly)
    private var prevFeet: SIMD3<Float>? = nil           // last tick's feet, for the PLAYERPOS velocity
    private var slipVel = SIMD2<Float>(0, 0)            // eased horizontal velocity while on a slippery node (#269)
    // Hold-to-place repeat (#178): armed while performPlace keeps returning true (see its doc).
    private static let placeRepeatTime: Float = 0.25   // Luanti repeat_place_time
    private var placeRepeatArmed = false
    private var placeRepeatTimer: Float = 0
    private var prevHotbarPrev = false, prevHotbarNext = false
    private var dead = false            // hp == 0; blocks dig/place and arms respawn
    private var damageFlash: Float = 0  // seconds of red hit-cast left (#279)
    private var recentFallDamage: Float = 0   // set by reportFallDamage so the HP drop plays the fall sound
    private var simDeadTimer: Float = 0 // sim: auto-respawn after 2 s dead
    private var prevRespawnBtn = false
    // Timed dig: hold the trigger on a node to crack it, then break it. Cleared
    // when the aim leaves the node or the trigger releases. digTime is fixed for
    // now (per-node hardness comes later).
    private var digNode: SIMD3<Int>? = nil
    private var digAbove: SIMD3<Int> = .zero
    // Short-lived break-burst particles (small textured billboards flung out of
    // a node when it's removed). Session-queue only, stepped each tick.
    private struct BreakParticle {
        var pos: SIMD3<Float>, vel: SIMD3<Float>, acc: SIMD3<Float>
        var age: Float, life: Float, size: Float
        var collide = false, removeOnHit = false   // collisiondetection / collision_removal (#275)
        var layer: Int32     // atlas layer at spawn (informational; render re-resolves by tex)
        var tex: String      // texture key, re-resolved every frame (never the spawn
                             // index) so an atlas rebuild's remap can't point a live
                             // particle at the wrong tile (rain/snow->dirt #201/#256)
        /// Tile animation (#307): one atlas texture key per frame (baked through
        /// the [verticalframe / [sheet modifiers) and the seconds per frame; empty
        /// = a still texture. Frames are re-resolved by key like `tex`.
        var frameKeys: [String] = []
        var frameLen: Float = 0
        var frameLayers: [Int32] = []   // frameKeys resolved for atlasGeneration == layerGen
        var layerGen = -1               // atlasGeneration the cached layer(s) were resolved against
        var glow: UInt8 = 0  // light floor on both day/night nibbles (Particle::updateLight)
        // Particle::step extras (#308): per-axis drag, brownian jitter picked
        // each frame, bounce on collision; scale tween over the lifetime.
        var drag: SIMD3<Float> = .zero
        var jitterMin: SIMD3<Float> = .zero, jitterMax: SIMD3<Float> = .zero
        var bounce: Float = 0
        var scaleStart: Float = 1, scaleEnd: Float = 1
    }
    private var particles: [BreakParticle] = []
    private var particleAnimLogged: Set<String> = []   // one [particles] frames line per animated texture
    // Reused per-surface vertex remap for appendModel (#247 perf): a fresh
    // [Int32] was allocated per surface per mob per frame on the tick thread.
    // `modelRemapSeen` stamps which local index was assigned this surface via a
    // monotonic generation, so we skip both the per-surface heap alloc AND the
    // memset-to-(-1) that a plain reused buffer would need.
    private var modelRemap: [Int32] = []
    private var modelRemapSeen: [Int32] = []
    private var modelRemapGen: Int32 = 0
    // Sorted server-HUD elements, cached by Client.hudGeneration so the ~80
    // pre-created potion-effect slots aren't mapped + z-sorted every frame (#249).
    private var sortedHud: [(Int, Client.HudElement)] = []
    private var sortedHudGen = -1
    // Constant quad UVs, hoisted so the emission helpers don't re-allocate the
    // array literal every call (#248 follow-up). BL = bottom-left texture origin
    // (y-up quads), TL = top-left (y-down quads).
    private static let quadUVsBL: [(Float, Float)] = [(0, 1), (1, 1), (1, 0), (0, 0)]
    private static let quadUVsTL: [(Float, Float)] = [(0, 0), (1, 0), (1, 1), (0, 1)]
    // Head transform snapshotted once per postEntities pass: it was fetched (and
    // its basis re-normalized) ~7x/frame, each call locking PlayerState. The pose
    // is fixed for the frame, so one read feeds every HUD/nametag helper (#250).
    private var frameHeadXform = matrix_identity_float4x4
    private struct ActiveSpawner { let spec: Client.ParticleSpawner; var emitted: Int; var age: Float; var gone: Float; var spawnRemainder: Float = 0 }
    private var activeSpawners: [Int: ActiveSpawner] = [:]
    private var digElapsed: Float = 0
    private var digTime: Float = 0.55   // per dig, from node groups + hand caps; < 0 = undiggable
    private var clipLogKey = SIMD4<Int32>(repeating: .min)   // last [clip] state logged (dedupes the per-tick line)
    private var posLogTimer: Double = 0
    private var wasSubmerged = false   // last eye-in-liquid state, for toggle logging
    private var autoDigTimer: Double = 0
    // Player health 0..20 (session-queue only: written by onHP inside client.poll,
    // read by postEntities, both on `queue`). Drives the peripheral heart HUD.
    private var hp: Int = 20
    // Player food points 0..20 (session-queue only, like hp): written by
    // onHunger inside client.poll, read by postEntities. Drives the drumstick HUD.
    private var hunger: Int = 20
    private var armor: Int = 0    // 0..20 from the mcl_hbarmor statbar (onArmor)
    private var breath: Int = 20   // 0..20 oxygen; bubbles show only while submerged
    static let reach: Float = 5.0   // fallback before ITEMDEF/hand arrive; see currentReach()
    private var loggedHand: String? = nil

    /// The player's hand item: Luanti reads it from the "hand" inventory list
    /// (VoxeLibre's mcl_meshhand puts mcl_meshhand:<skin>_surv or _crea there,
    /// the creative one digging at 0.2 s with a 10-node range). Nil until the
    /// server has sent that list (#267).
    private func handItemName() -> String? {
        guard let h = client.inventory["hand"], let first = h.first, let st = first, !st.name.isEmpty else { return nil }
        if loggedHand != st.name { loggedHand = st.name; print("[hand] \(st.name) range=\(client.items.range(for: st.name).map { String($0) } ?? "nil")"); fflush(stdout) }
        return st.name
    }

    /// Pointing range the way game.cpp getToolRange does: the wielded item's
    /// range when it sets one (>= 0), else the hand's, else 4 (#267).
    private var currentReach: Float {
        let wield = client.wieldIndex
        if wield >= 0, wield < hotbar.count, let w = hotbar[wield], let r = client.items.range(for: w), r >= 0 { return r }
        if let h = handItemName(), let r = client.items.range(for: h), r >= 0 { return r }
        return client.items.range(for: "").map { $0 >= 0 ? $0 : 4 } ?? Self.reach
    }
    private let simAutoDig = false

    private let input = GameInput()
    private var worldReadyLogged = false
    private var skyBrightnessSmooth: Float = 1   // day-bank light at the head, 0..1, eased (cave fog)
    /// sky.cpp getWickedTimeOfDay: night takes 0.415 of the cycle.
    static func wickedTimeOfDay(_ t: Float) -> Float {
        let wn: Float = 0.415 / 2
        if t > wn && t < 1 - wn { return (t - wn) / (1 - wn * 2) * 0.5 + 0.25 }
        if t < 0.5 { return t / wn * 0.25 }
        return 1 - ((1 - t) / wn * 0.25)
    }
    /// Headless-sim auto-walk / auto-sneak (the test scenes flip them). Off
    /// everywhere by default; the device drives movement from the controller.
    private var simAutoWalk = false
    private var simAutoSneak = false
    private var simChordHold = false                    // -vrdev.chordDropTest: hold right trigger + grip
    private var simTapPlace = false                     // -vrdev.chordDropTest: one-frame grip tap
    private var simChordPreIds: Set<Int> = []           // item entities that existed before the chord
    private var simChordLeak = 0                        // frames the chord was held but dig/place leaked past the gate
    private var simPostGatePlace = 0                    // place frames after the gate (tap-replay check)
    #if targetEnvironment(simulator)
    private var simSneakMark = SIMD3<Float>(0, 0, 0)   // -vrdev.sneakTest: feet at t=4s
    private var simDigPredictedAir = false              // -vrdev.digTest
    private var simFallMaxY: Float = 0
    #endif

    #if targetEnvironment(simulator)
    /// Sim scenes start on the spawn pad at (0, 121, 0). Two hops, because a
    /// MOVE_PLAYER under 6 nodes is not applied (see onSpawn): a scene that
    /// starts near the pad would otherwise begin wherever the last one ended.
    private func simTeleportToPad() {
        client.sendChat("/teleport 0 140 0"); client.sendChat("/teleport 0 121 0")
    }
    #endif

    init(handoff: MeshHandoff, entityHandoff: EntityHandoff,
         modelHandoff: ModelHandoff, modelTextureHandoff: ModelTextureHandoff,
         handHudHandoff: HandHudHandoff, skyboxHandoff: SkyboxHandoff,
         screenshotFlag: ScreenshotFlag, player: PlayerState) {
        self.handoff = handoff
        self.skyboxHandoff = skyboxHandoff
        self.entityHandoff = entityHandoff
        self.modelHandoff = modelHandoff
        self.modelTextureHandoff = modelTextureHandoff
        self.handHudHandoff = handHudHandoff
        self.screenshotFlag = screenshotFlag
        self.player = player
        client.wantedRange = ViewSettings.shared.blocks   // view-distance slider (#161)
        mobRenderDist = min(96, Float(ViewSettings.shared.blocks * 16))
        client.onAuthenticated = { [weak self] seed in
            print("[session] AUTHENTICATED map_seed=\(seed) \(PerfStats.uptime())"); fflush(stdout)
            self?.reconnectAttempts = 0
            self?.setPhase(.streaming)
        }
        client.onSpawn = { [weak self] pos, yaw, pitch in
            guard let self else { return }
            // Drop the spawn onto the ground surface if the server placed us above
            // it (respawn points are often a bit high), so we don't free-fall in.
            // Only when the column is loaded; otherwise keep the server Y and let
            // physics settle once blocks stream in.
            // groundHeight skips unloaded nodes (right for the walking probes),
            // which here would look straight through a not-yet-streamed surface
            // block into a cave below and drop us there (the sim spawned at
            // y=12 under a y=22 surface, then fell to -10). Only snap when every
            // node between the server's Y and the ground is loaded.
            func grounded(_ p: SIMD3<Float>) -> SIMD3<Float> {
                guard let g = self.groundHeight(x: Int(floor(p.x)), z: Int(floor(p.z)),
                                                near: Int(floor(p.y))) else { return p }
                for y in g...Int(floor(p.y)) + 3 where self.client.world.nodeId(SIMD3(Int(floor(p.x)), y, Int(floor(p.z)))) == WorldMap.CONTENT_IGNORE {
                    print("[session] spawn column not loaded at y=\(y); keeping server Y"); fflush(stdout)
                    return p
                }
                let surface = Float(g) + 1.0                 // our mesh surface for node g ([g, g+1])
                return p.y > surface + 0.1 ? SIMD3(p.x, surface, p.z) : p
            }
            // The official client applies every TOCLIENT_MOVE_PLAYER
            // (clientpackethandler.cpp handleCommand_MovePlayer -> setPosition).
            // The server sends one on join / teleport / respawn (PlayerSAO::setPos)
            // or when its movement check put us back at its last good position
            // because our predicted physics drifted from its own. We apply the
            // big ones; a small (< 6 node) reset is left to converge over the
            // next ticks, because snapping the headset view is worse in VR than
            // a brief drift. The server's position stays authoritative either
            // way (#180, #319).
            if !self.player.haveSpawn {
                let sp = grounded(pos)
                print("[session] initial spawn at \(pos) -> \(sp) yaw=\(yaw) \(PerfStats.uptime())"); fflush(stdout)
                self.player.setSpawn(sp, yaw: -yaw, pitch: pitch)
                self.sneakNode = nil
            } else {
                let cur = self.player.snapshot().feet
                if simd_distance(cur, pos) > 6 {
                    let sp = grounded(pos)
                    print("[session] teleport/respawn to \(pos) -> \(sp)"); fflush(stdout)
                    self.player.setSpawn(sp, yaw: -yaw, pitch: pitch)
                    // LocalPlayer::setPosition drops the sneak node: the glue would
                    // otherwise clamp us straight back toward the ledge we left.
                    self.sneakNode = nil
                    // A long jump (portal / dimension change / teleport): drop the
                    // area we left so its stale geometry doesn't hang in the void,
                    // force a rebuild, and show a loading notice until the new
                    // ground streams under us (#transition).
                    let nb = WorldMap.blockPos(SIMD3(Int(floor(sp.x)), Int(floor(sp.y)), Int(floor(sp.z))))
                    for b in self.client.purgeFarBlocks(near: nb) { self.markBlockDirty(b) }
                    self.fullRemesh = true; self.remeshCooldown = 0
                    self.teleportSettle = 12
                }
            }
        }
        client.onHP = { [weak self] hp, damageEffect in
            guard let self else { return }
            if hp != self.hp { print("[hud] HP \(self.hp) -> \(hp)"); fflush(stdout) }
            // Damage feedback (game.cpp handleClientEvent_PlayerDamage +
            // SoundMaker::playerDamage): a red flash and the "player_damage"
            // sound (VoxeLibre ships it in mcl_sounds) on every HP drop while
            // alive, so a zombie or arrow hit registers without reading the
            // hearts (#279). Fall damage plays "player_falling_damage" instead,
            // keyed off our own [fall] report.
            if hp < self.hp, self.hp > 0, damageEffect {
                self.damageFlash = 0.35
                self.input.rumble(intensity: 1.0, sharpness: 0.35, duration: 0.12)   // a solid hit buzz (#357)
                let fall = self.recentFallDamage > 0
                self.recentFallDamage = 0
                self.queue.async {
                    self.playSound(SoundSpec(id: -1, name: fall ? "player_falling_damage" : "player_damage",
                                             gain: 0.5, type: 0, pos: .zero, objectId: 0, loop: false, fade: 0, pitch: 1.0, ephemeral: true))
                }
            }
            self.hp = hp
            let dead = hp <= 0
            if dead != self.dead { print("[death] \(dead ? "died - press an action to respawn" : "respawned")"); fflush(stdout) }
            self.dead = dead
            self.player.setDead(dead)
        }
        client.onArmor = { [weak self] a in
            guard let self else { return }
            if a != self.armor { print("[hud] armor \(self.armor) -> \(a)"); fflush(stdout) }
            self.armor = a
        }
                client.onHunger = { [weak self] hunger in
            guard let self else { return }
            if hunger != self.hunger { print("[hud] hunger \(self.hunger) -> \(hunger)"); fflush(stdout) }
            self.hunger = hunger
        }
        client.onBreath = { [weak self] breath in
            guard let self else { return }
            if breath != self.breath { print("[hud] breath \(self.breath) -> \(breath)"); fflush(stdout) }
            self.breath = breath
        }
        // Hotbar: cache the 9 main slots + resolve each to an icon tile, and bake
        // any newly-seen icons into the atlas (forces a rebuild + remesh so the
        // renderer uploads them). Runs on the session queue (fired from poll()).
        client.onInventory = { [weak self] main in
            guard let self else { return }
            self.hotbar = main
            var icons: [String?] = []
            var newTiles = Set<String>()
            let stacks = self.client.inventory["main"] ?? []
            for (i, name) in main.enumerated() {
                guard let name else { icons.append(nil); continue }
                let tile: String?
                if i < stacks.count, let img = stacks[i]?.customImage {
                    tile = img                       // stack meta: bow charge frame, enchant glint (#271)
                } else if let img = self.client.items.image(for: name), !img.isEmpty {
                    tile = img
                } else {
                    tile = self.nodeIconTile(name)   // node-item with no explicit icon
                }
                if let tile { newTiles.insert(tile) }
                icons.append(tile)
            }
            self.hotbarIcons = icons
            // Pull any icon PNG we don't have yet (a tool image that's not a node
            // tile, or an item picked up after the up-front request). request()
            // intersects announced media and skips what's already fetched, so a
            // no-op when everything's present.
            var wantImgs = Set<String>()
            for t in icons { if let t { for n in NodeRegistry.imageNames(t) where self.client.media.bytes(n) == nil { wantImgs.insert(n) } } }
            if !wantImgs.isEmpty { self.client.media.request(wantImgs) }
            let line = "[hud] hotbar: [\(main.map { $0 ?? "nil" }.joined(separator: ", "))] wield=\(self.client.wieldIndex)"
            if line != self.lastHotbarLog { self.lastHotbarLog = line; print(line); fflush(stdout) }
            if !newTiles.isSubset(of: self.hotbarTiles) {
                self.hotbarTiles.formUnion(newTiles)
                self.atlasNeedsRebuild = true
                self.rebuildAtlas()
            }
        }
        client.onInventoryLists = { [weak self] in self?.refreshInventoryTiles() }
        client.onShowFormspec = { [weak self] spec, name in self?.openFormspec(spec, name) }
        client.onEyeOffset = { [weak self] v in self?.player.setEyeOffset(v) }
        client.onPrivileges = { [weak self] privs in
            guard let self, !privs.contains("fly") else { return }
            self.queue.async { if self.flying { self.flying = false; self.addChat(sender: "", text: "Flying off (no fly privilege)") } }
        }
        client.onInventoryFormspec = { [weak self] spec in
            // The engine only stores it; but mcl_inventory re-sends the form on
            // a creative tab/page change while it's open, so swap the layout
            // in place (the held stack and pointer survive).
            guard let self, self.formspecOpen, self.formspecIsInventory, !spec.isEmpty else { return }
            let held = self.invHeld
            self.openFormspec(spec, "", inventory: true)
            self.invHeld = held
        }
        client.onChat = { [weak self] _, sender, text in self?.addChat(sender: sender, text: text) }
        client.onSky = { [weak self] s in
            #if targetEnvironment(simulator)
            // -vrdev.fakeSkybox: mcl_weather re-sends the overworld sky every
            // second, which would wipe the fake End sky before the shot.
            if UserDefaults.standard.bool(forKey: "vrdev.fakeSkybox"), s.skyboxTextures.isEmpty, self?.fakeSkyboxSent == true { return }
            #endif
            self?.player.setSky(s)
            self?.queue.async { self?.skyboxWanted = s.skyboxTextures.count == 6 ? s.skyboxTextures : [] }
        }
        client.onXp = { [weak self] level, fraction in self?.xpLevel = level; self?.xpFraction = fraction }
        client.onMediaPushed = { [weak self] name in self?.forgetTexture(name) }
        client.onPlayerSpeed = { [weak self] v in                                       // knockback
            guard let self else { return }
            self.player.addVelocity(v)
            // A shove you can feel: mob hits and explosions arrive as a server
            // velocity kick (PLAYER_SPEED), which is the "pushed back" moment.
            if simd_length(v) > 1 { self.input.rumble(intensity: 0.6, sharpness: 0.3, duration: 0.15) }
        }
        client.onMovePlayerRel = { [weak self] d in self?.player.addPosition(d) }        // piston/elevator nudge
        client.onMovement = { [weak self] walk, fast, crouch, jump, gravity in
            self?.player.setMovement(walk: walk, fast: fast, crouch: crouch, jump: jump, gravity: gravity)
            print("[move] server params walk=\(walk) fast=\(fast) jump=\(jump) gravity=\(gravity) climb=\(self?.client.speedClimb ?? 0)"); fflush(stdout)
        }
        client.onLiquidMovement = { [weak self] fluidity, smooth, sink in
            self?.player.setLiquidMovement(fluidity: fluidity, fluiditySmooth: smooth, sink: sink)
            print("[move] liquid fluidity=\(fluidity) smooth=\(smooth) sink=\(sink)"); fflush(stdout)
        }
        client.objects.onLocalProperties = { [weak self] cbMin, cbMax, step, eye in
            guard let self else { return }
            let hw = max(0.1, min(1, max(abs(cbMin.x), abs(cbMax.x), abs(cbMin.z), abs(cbMax.z))))
            let h = max(0.3, min(3, cbMax.y - cbMin.y))
            self.queue.async {
                self.playerHW = hw; self.playerHeight = h
                self.playerStep = max(0, min(1.5, step))
            }
            self.player.setEyeHeight(max(0.2, min(2.5, eye)))
            print("[props] local player box +-\(hw) x \(h) step=\(step) eye=\(eye)"); fflush(stdout)
        }
        client.objects.onLocalPhysicsOverride = { [weak self] speed, jump, gravity, speedCrouch, speedWalk in
            guard let self else { return }
            self.player.setPhysicsOverride(speed: speed, jump: jump, gravity: gravity,
                                           speedCrouch: speedCrouch, speedWalk: speedWalk)
            print("[move] physics override speed=\(speed) jump=\(jump) gravity=\(gravity) crouch=\(speedCrouch) walk=\(speedWalk)"); fflush(stdout)
            // Sleeping in a bed freezes the player via physics_override
            // (speed 0 + jump 0). Current VoxeLibre also sends the mcl_beds_form
            // dialog (handled in openFormspec), but older builds sent nothing, so
            // detect the freeze directly too and let the inventory button (O)
            // submit the known bed form's leave field to get up. Clearing the
            // override (speed restored) ends it.
            if speed == 0, jump == 0 {
                self.pendingButtonForm = ("mcl_beds_form", "leave")
                self.noticeText = "Press O to get up"; self.noticeExpiry = 0
            } else if self.pendingButtonForm?.formname == "mcl_beds_form" {
                self.pendingButtonForm = nil; self.noticeText = nil
            }
        }
        client.onBlock = { [weak self] bpos in self?.markBlockDirty(bpos) }
        // A relight (torch placed, wall dug into daylight) touched these blocks'
        // light values: remesh them now, like the engine's addNodeAndUpdate
        // remeshing every modified block (#278).
        client.world.onRelit = { [weak self] blocks in
            guard let self else { return }
            for b in blocks { self.dirtyBlocks.insert(b) }
            // Pull the coalesce window in (not to zero): a torch's light should
            // land promptly, but an explosion's burst of ADDNODEs must still
            // batch into one remesh instead of one per packet.
            self.dirty = true; self.remeshCooldown = min(self.remeshCooldown, 0.1)
        }
        // Luanti never predicts on_rightclick results (doors, switches, levers
        // all wait for the server's ADDNODE); what makes them feel instant is
        // remeshing that block the moment it lands. Skip the 0.4s coalesce here.
        client.onNodeChanged = { [weak self] p in
            guard let self else { return }
            self.markNodeDirty(p); self.remeshCooldown = 0
            // A container we have open just changed its metadata (items moved in
            // by a hopper, another player, or the initial contents arriving after
            // the formspec): rebake its item icons, else new item types show as
            // empty slots until the panel is reopened (#254). onNodeChanged only
            // remeshed before, which never touched the inventory tile cache.
            if self.formspecOpen, self.formspecContext == p {
                self.refreshOpenNodeFormspec()   // fire/arrow gauge + any image[] update (#344)
                self.refreshInventoryTiles()
            }
        }
        // Media streams in continuously at join; each file used to force an atlas
        // rebuild + full-world remesh. Coalesce to at most ~1/s (first is prompt),
        // driven from the tick, so the busy streaming phase isn't a remesh storm (#188).
        client.onMediaReady = { [weak self] in
            guard let self else { return }
            self.mediaAtlasDirty = true; self.modelTexRescan = true
            // A texture referenced before its bytes streamed in (or before the
            // media announce arrived) got blacklisted in modelFailed. Now that
            // more media has landed, drop any blacklisted spec whose files are
            // all present so it re-bakes -- the stone-panel background9 announced
            // late this way and stayed a grey slab forever (#254). A genuine
            // decode failure just re-blacklists on the retry.
            self.modelFailed = self.modelFailed.filter { spec in
                !NodeRegistry.imageNames(spec).allSatisfy { self.client.media.store[$0] != nil }
            }
        }
        // Server-driven audio: resolve the sound name to a downloaded .ogg and
        // hand it to the audio manager (footsteps, mobs, ambience, ...).
        client.onPlaySound = { [weak self] spec in self?.playSound(spec) }
        client.onSpawnParticle = { [weak self] pos, vel, acc, size, life, texture, collide, look in
            self?.spawnServerParticle(pos: pos, vel: vel, size: size, life: life, texture: texture, acc: acc,
                                      collide: collide, removeOnHit: look.collisionRemoval, look: look)
        }
        client.onAddParticleSpawner = { [weak self] sp in
            // Diagnostic (#199/#201): rain/snow arrive as player-attached spawners;
            // log the texture + size + spread once so the next weather run shows
            // exactly what the server sends (the giant-bar and rain->dirt bugs).
            print("[spawner] id=\(sp.serverId) tex=\(sp.texture) size=\(sp.sizeMin)..\(sp.sizeMax) amount=\(sp.amount) attached=\(sp.attachedId) pos=\(sp.posMin)..\(sp.posMax) anim=\(sp.look.animType):\(sp.look.animA)x\(sp.look.animB)/\(sp.look.animLength)s glow=\(sp.look.glow) node=\(sp.look.nodeId)"); fflush(stdout)
            self?.activeSpawners[sp.serverId] = ActiveSpawner(spec: sp, emitted: 0, age: 0, gone: 0)
        }
        client.onDeleteParticleSpawner = { [weak self] id in self?.activeSpawners.removeValue(forKey: id) }
        client.onStopSound = { [weak self] id in self?.audio.stop(id: id); self?.attachedSounds.removeValue(forKey: id) }
        // Finished handles go back to the server in one TOSERVER_REMOVED_SOUNDS
        // per batch (the engine collects them and sends every ~1 s too).
        audio.onFinished = { [weak self] id in self?.finishedSounds.withLock { $0.append(id) } }
        client.onFadeSound = { [weak self] id, step, gain in self?.audio.fade(id: id, step: step, gain: gain) }
        // ACCESS_DENIED also closes the connection, so onDisconnected fires too.
        // Retry from ONE place (below) to avoid double connect() calls racing.
        client.onAccessDenied = { [weak self] r, code in
            print("[session] ACCESS DENIED (\(code)): \(r)"); fflush(stdout)
            // Transient codes clear on their own, so keep retrying: 6 too-many-
            // users, 8 already-connected (old session still timing out -- the
            // common fast-relaunch case), 9 server-fail, 11 shutdown, 12 crash.
            // Everything else (wrong password, disallowed name, mod's custom
            // denial) never will, so stop and surface it. Code-based, not string-
            // based, so a custom/localized reason for those codes still retries.
            let retryable: Set<Int> = [6, 8, 9, 11, 12]
            if !retryable.contains(code) {
                self?.fatalDenied = true
                self?.setPhase(.failed(r.isEmpty ? "access denied" : r))
            }
        }
        client.onDisconnected = { [weak self] r in
            print("[session] disconnected: \(r)"); fflush(stdout)
            self?.scheduleReconnect(after: r)
        }
    }

    /// Live view-distance change from the launcher slider (#161): applies to the
    /// running client so the next PLAYERPOS asks the server for the new range.
    func setViewDistance(_ blocks: Int) {
        // Both writes hop onto the session queue: mobRenderDist is read from
        // postEntities on that queue, so writing it from the main-thread slider
        // callback would race (client.wantedRange already hops for the same reason).
        queue.async { [weak self] in
            self?.mobRenderDist = min(96, Float(blocks * 16))
            self?.client.wantedRange = blocks
        }
    }

    func start() {
        if started { return }   // main-thread re-entry guard (start/stop are main-actor)
        started = true
        // Build stamp first: deploy is install-only and a live app keeps running
        // old code, so "which build is this log from?" must be answerable here.
        let build = (Bundle.main.infoDictionary?["GitHash"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        print("[build] \(build)"); fflush(stdout)
        Client.processStart = PerfStats.processStart   // one origin for the t=+Ns join stamps
        print("[session] connecting to \(Self.host):\(Self.port) as \(Self.playerName) \(PerfStats.uptime())"); fflush(stdout)
        // The reconnect-lifecycle flags and connProblem are session-queue state
        // (scheduleReconnect and the callbacks read them there), so set them on
        // the queue, not from this main-thread call. connect() also mutates
        // transport state that poll() touches, so it belongs here too.
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = false
            self.reconnectAttempts = 0
            self.reconnectPending = false
            self.connEpoch += 1
            self.fatalDenied = false
            self.setPhase(.connecting)
            // Reopening the immersive space hands us a brand-new Renderer with
            // empty buffers, but our world blocks are already loaded, so no
            // onBlock fires to trigger a remesh and we'd show only sky. Force a
            // full re-post: remesh the whole world and make the atlas travel
            // with it to the new renderer (reset so it isn't skipped as "same").
            self.lastPostedAtlasGen = -1
            self.fullRemesh = true      // new renderer: rebuild + re-post the whole buffer
            self.dirty = true
            self.client.connect(host: Self.host, port: Self.port)
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(16))
        var last = Date()
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date(); let dt = now.timeIntervalSince(last); last = now
            let t0 = self.perf.now()
            // Clamp the physics step (Luanti caps dtime too): after a stall the
            // world should not integrate a quarter second of gravity in one go.
            // The connection still sees the real interval for its timeouts.
            self.tick(dt: Float(min(dt, 0.25)))
            let t1 = self.perf.now()
            self.client.poll(dt)
            let t2 = self.perf.now()
            self.perf.add("tick", t0, t1); self.perf.add("poll", t1, t2)
            defer { self.skinMisses = 0 }
            self.perf.endIteration(note: "ents=\(self.client.objects.count) models=\(self.lastModelsDrawn) skinMiss=\(self.skinMisses) verts=\(self.lastModelVerts / 9) particles=\(self.particles.count) spawners=\(self.activeSpawners.count)")
        }
        t.resume()
        timer = t
    }

    /// Cleanly leave the server so it frees our name immediately (a fast
    /// relaunch can then reconnect without waiting for the ~15s peer timeout).
    /// Called when the app backgrounds or the immersive space closes.
    func stop() {
        timer?.cancel(); timer = nil
        started = false     // main-thread re-entry guard: allow a later start()
        // The rest is session-queue state; set it on the queue (this async is
        // enqueued with no delay, so it runs before any delayed reconnect, and
        // the epoch bump invalidates one already scheduled).
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true          // block any in-flight reconnect from firing
            self.reconnectPending = false
            self.connEpoch += 1          // invalidate any pending reconnect from this epoch (F1)
            self.client.disconnect("app exited")
        }
    }

    /// Single guarded reconnect path (both ACCESS_DENIED and timeouts land here
    /// via onDisconnected). Retries on the session queue, one at a time, long
    /// enough to outlast the server's ~30s hold on our name after an unclean
    /// exit. Skips our own clean disconnect.
    private func scheduleReconnect(after reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.stopped || reason == "app exited" || reason == "client disconnect" { return }
            if self.fatalDenied { return }   // wrong password / name not allowed: don't hammer the server
            if self.reconnectPending || self.reconnectAttempts >= 25 {
                if self.reconnectAttempts >= 25 { self.setPhase(.failed("server unreachable")) }
                return
            }
            self.reconnectPending = true
            self.reconnectAttempts += 1
            let n = self.reconnectAttempts
            let epoch = self.connEpoch
            self.setPhase(.reconnecting(n))
            // Ramp the backoff: try quickly at first so a name freed fast (a clean
            // exit whose goodbye landed) reconnects in well under a second, then
            // settle to 3s so the ~25 attempts still span past the server's ~30s
            // peer-timeout hold after an unclean exit (crash/kill).
            let delay = n <= 2 ? 0.5 : (n <= 5 ? 1.5 : 3.0)
            self.queue.asyncAfter(deadline: .now() + delay) {
                self.reconnectPending = false
                // A stop()/start() (app background+foreground) since we scheduled
                // this bumps connEpoch and issues its own connect(); bail so we
                // don't fire a SECOND overlapping handshake on the one Connection.
                guard !self.stopped, epoch == self.connEpoch else { return }
                print("[session] reconnect attempt \(n) (after: \(reason))"); fflush(stdout)
                self.client.connect(host: Self.host, port: Self.port)
            }
        }
    }

    /// Bake a "skybox" sky's six faces once their PNGs are here and hand them
    /// to the renderer; clear it when the sky type changes back. The End is
    /// the one VoxeLibre skybox (six copies of its starry texture) (#290).
    private func stepSkybox() {
        guard skyboxWanted != skyboxBuilt else { return }
        if skyboxWanted.isEmpty { skyboxHandoff.postClear(); skyboxBuilt = []; return }
        var missing = Set<String>()
        for t in skyboxWanted { for n in NodeRegistry.imageNames(t) where client.media.bytes(n) == nil { missing.insert(n) } }
        if !missing.isEmpty { client.media.request(missing); return }
        var faces: [[UInt8]] = []
        for t in skyboxWanted {
            guard let px = TextureAtlas.evaluateModifiedFill(t, media: client.media, canvas: SkyboxHandoff.size) else { return }
            faces.append(px)
        }
        skyboxHandoff.post(faces); skyboxBuilt = skyboxWanted
        print("[sky] skybox built from \(skyboxWanted.first ?? "")"); fflush(stdout)
    }

    private func tick(dt: Float) {
        stepSkybox()
        // An uncontended unfair lock is ~20 ns; the audio queue only ever
        // appends here when a handled sound actually ends.
        let doneSounds = finishedSounds.withLock { l -> [Int] in let d = l; l.removeAll(keepingCapacity: true); return d }
        if !doneSounds.isEmpty { client.sendRemovedSounds(doneSounds); attachedSounds = attachedSounds.filter { !doneSounds.contains($0.key) } }
        guard player.haveSpawn else { return }
        let pStart = perf.now()
        defer { perf.add("total", pStart, perf.now()) }
        refreshPhysicsSnapshot()   // one lock per tick instead of ~8 per scanned node (perf #312)
        // Coalesced media-driven atlas rebuild (#188): prompt the first time, then
        // at most once a second, so a burst of streaming media doesn't restart the
        // full-world remesh over and over.
        sinceMediaAtlas += Double(dt)
        if mediaAtlasDirty, sinceMediaAtlas >= 1.0 { mediaAtlasDirty = false; rebuildAtlas() }
        #if targetEnvironment(simulator)
        // Headless simulator test scenes. They run only against the developer's
        // own local VoxeLibre dev server (tools/server.sh, world vrdev) using its
        // standard chat commands (/grantme, /giveme, /teleport, /setblock); see
        // AGENTS.md.
        // Teleport to open sky first, THEN spawn the lineup (#91 framing): at the
        // normal spawn the fake camera is buried in terrain, so the old one-shot
        // dropped the mobs where only their nametags showed through. Floating over
        // open sky puts the whole facing lineup against a clean backdrop.
        if UserDefaults.standard.bool(forKey: "vrdev.spawnMob"), simMobPhase < 2, client.objects.localPlayerId != 0 {
            simMobTimer += Double(dt)
            if simMobPhase == 0 {
                // The 5x5 stone platform at y=120 sits in open sky; y=150 used to
                // drop the player 29 nodes onto it, fatal now that fall damage is real.
                client.sendChat("/grantme all"); simTeleportToPad()
                print("[spawnMob] teleporting to the sky platform for a clean facing shot"); fflush(stdout)
                simMobPhase = 1; simMobTimer = 0
            } else if simMobPhase == 1, simMobTimer > 4 {
                spawnSimMob()
                simMobPhase = 2
            }
        }
        if !simRealHudDone, UserDefaults.standard.bool(forKey: "vrdev.realHud") {
            simRealHudDone = true
            simulateServerHud()
        }
        if !simBedSpawned, UserDefaults.standard.bool(forKey: "vrdev.spawnBed") {
            simBedSpawned = true
            spawnSimBed()
        }
        if !simGlassSpawned, UserDefaults.standard.bool(forKey: "vrdev.spawnGlass") {
            simGlassSpawned = true
            spawnSimGlass()
        }
        if !simRailsSpawned, UserDefaults.standard.bool(forKey: "vrdev.spawnRails") {
            simRailsSpawned = true
            spawnSimRails()
        }
        // Fire server chat commands once the player exists in-game, so tests can
        // set up REAL server-streamed scenes: -vrdev.cmd "/teleport 0 200 0;;/grantme all;;/giveme mcl_core:glass_red 64".
        // Split on ";;" (chat commands contain spaces). Needs the matching privs.
        // Sent one per 1.3 s, about the pace a person typing commands manages,
        // so the server's chat_message_limit_per_10sec budget
        // (RemotePlayer::canSendChatMessage, src/remoteplayer.cpp; default 8 per
        // 10 s, refilled at limit/8 per second) accepts every command and the
        // scene setup applies fully instead of half of it being dropped.
        if !simCmdDone, client.objects.localPlayerId != 0,
           let cmd = UserDefaults.standard.string(forKey: "vrdev.cmd"), !cmd.isEmpty {
            if simCmdQueue == nil {
                simCmdQueue = cmd.components(separatedBy: ";;").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            simCmdTimer += Double(dt)
            if simCmdTimer >= 1.3, let next = simCmdQueue?.first {
                simCmdTimer = 0
                simCmdQueue?.removeFirst()
                client.sendChat(next); print("[simcmd] \(next)"); fflush(stdout)
                if simCmdQueue?.isEmpty == true { simCmdDone = true }
            }
        }
        // Wait for the local player AO before attaching, so the ride actually binds.
        if !simRideDone, UserDefaults.standard.bool(forKey: "vrdev.rideTest"), client.objects.localPlayerId != 0 {
            simRideDone = true
            spawnSimRide()
        }
        // -vrdev.eatTest 1: verify the HOLD-to-eat mechanic (#173) headless. Uses a
        // golden apple (can_eat_when_full) so it eats at full hunger, drives the
        // place-hold + activate the gesture would, and logs the stack count before
        // and after. Bypasses the hand-at-mouth geometry (that's device-only).
        if UserDefaults.standard.bool(forKey: "vrdev.eatTest"), client.objects.localPlayerId != 0, atlasBuilt {
            simEatTimer += Double(dt)
            func appleGoldCount() -> Int {
                (client.inventory["main"] ?? []).reduce(0) { $0 + (($1?.name == "mcl_core:apple_gold") ? ($1?.count ?? 0) : 0) }
            }
            switch simEatPhase {
            case 0 where simEatTimer > 2:
                client.sendChat("/grantme all"); client.sendChat("/clearinv"); client.sendChat("/giveme mcl_core:apple_gold 5")   // clearinv: the sim account keeps its inventory between runs
                print("[eattest] gave golden apples"); fflush(stdout)
                simEatPhase = 1; simEatTimer = 0
            case 1 where simEatTimer > 4:
                let names = (client.inventory["main"] ?? []).map { $0?.name ?? "nil" }
                print("[eattest] main=\(names)"); fflush(stdout)
                if let m = client.inventory["main"], let slot = m.firstIndex(where: { $0?.name == "mcl_core:apple_gold" }) {
                    client.setWieldIndex(slot); simScratchCount = appleGoldCount()
                    print("[eattest] wield slot \(slot), count \(simScratchCount), holding place..."); fflush(stdout)
                    simEatPhase = 2; simEatTimer = 0
                } else { print("[eattest] no golden apple in inventory"); fflush(stdout); simEatPhase = 99 }
            case 2:
                client.placeHeld = true                                   // report RMB held, like the gesture
                if Int(simEatTimer / 0.5) != Int((simEatTimer - Double(dt)) / 0.5) {
                    client.sendInteract(action: 5, under: nil, above: nil)
                }
                if simEatTimer > 4 {
                    client.placeHeld = false
                    let now = appleGoldCount()
                    print("[eattest] RESULT start=\(simScratchCount) now=\(now) eaten=\(simScratchCount - now) pass=\(simScratchCount - now >= 1)"); fflush(stdout)
                    simEatPhase = 99
                }
            default: break
            }
        }
        // -vrdev.bowTest 1: prove the RMB control bit reaches the server for a
        // non-food wield (parity #263). mcl_bows charges on register_on_hold(RMB)
        // by swapping the wield to mcl_bows:bow_0/_1/_2 server-side; that swap
        // shows up in our inventory only if PLAYERPOS carries bit 256 while the
        // grip is held. Drives the real grip path: simGripOverride stands in for
        // gi.place at the one updateEat call site below, so nothing else in the
        // tick clobbers placeHeld (the harness runs BEFORE that call).
        if UserDefaults.standard.bool(forKey: "vrdev.bowTest"), client.objects.localPlayerId != 0, atlasBuilt {
            simEatTimer += Double(dt)
            func wieldName() -> String? {
                let wi = client.wieldIndex; let m = client.inventory["main"] ?? []
                return (wi >= 0 && wi < m.count) ? m[wi]?.name : nil
            }
            switch simEatPhase {
            case 0 where simEatTimer > 2:
                client.sendChat("/grantme all"); client.sendChat("/giveme mcl_bows:bow"); client.sendChat("/giveme mcl_bows:arrow 16")
                print("[bowtest] gave bow + arrows"); fflush(stdout)
                simEatPhase = 1; simEatTimer = 0
            case 1 where simEatTimer > 4:
                if let m = client.inventory["main"], let slot = m.firstIndex(where: { $0?.name == "mcl_bows:bow" }) {
                    client.setWieldIndex(slot)
                    // The grip PRESS edge: performPlace sends activate (action 5)
                    // when aimed at air, which runs the bow's on_secondary_use and
                    // sets its "active" meta -- the precondition on_hold checks.
                    client.sendInteract(action: 5, under: nil, above: nil)
                    print("[bowtest] wield slot \(slot) = \(wieldName() ?? "nil"), pressed + holding grip..."); fflush(stdout)
                    simEatPhase = 2; simEatTimer = 0
                } else { print("[bowtest] no bow in inventory"); fflush(stdout); simEatPhase = 99 }
            case 2:
                // Hold ~1.5 s (BOW_CHARGE_TIME_FULL is 1 s), then release. Charging
                // only changes the bow's inventory_image META (which we don't parse
                // yet, #271), so the observable signal is the RELEASE firing: mcl_bows
                // spawns an mcl_bows:arrow_entity. Count arrow AOs before/after.
                simGripOverride = true
                if simEatTimer > 1.5 {
                    simScratchCount = client.objects.snapshot().filter { $0.name.contains("arrow") }.count
                    simGripOverride = false   // release -> register_on_release -> shoot
                    if let m = client.inventory["main"], let bow = m.first(where: { $0?.name.hasPrefix("mcl_bows:bow") == true }) ?? nil {
                        print("[bowtest] bow stack \(bow.name) meta=\(bow.meta) hotbarIcon=\(hotbarIcons.first ?? nil ?? "nil")"); fflush(stdout)
                    }
                    print("[bowtest] released after \(simEatTimer)s, arrows before=\(simScratchCount)"); fflush(stdout)
                    simEatPhase = 3; simEatTimer = 0
                }
            case 3 where simEatTimer > 1.5:
                let now = client.objects.snapshot().filter { $0.name.contains("arrow") }.count
                print("[bowtest] RESULT arrows before=\(simScratchCount) after=\(now) fired=\(now > simScratchCount) pass=\(now > simScratchCount)"); fflush(stdout)
                simEatPhase = 99
            default: break
            }
        }
        // -vrdev.fallTest 1: prove client-computed fall damage reaches the server
        // (#264). Once settled on the ground, lift the feet 12 nodes and let the
        // land physics drop them: at 2x10.4 airborne accel that lands at ~22
        // node/s, i.e. ~8 hp past the 14 node/s tolerance. The [fall] line is our
        // send; the [hud] HP line is the server's TOCLIENT_HP answer.
        if UserDefaults.standard.bool(forKey: "vrdev.fallTest"), client.objects.localPlayerId != 0, atlasBuilt {
            simDigTimer += Double(dt)
            switch simDigPhase {
            case 0 where simDigTimer > 8 && player.physics().grounded:
                simScratchCount = hp
                let f = player.physics().feet
                player.setPhysics(feet: f + SIMD3(0, 12, 0), vy: 0, grounded: false)
                print("[falltest] hp=\(hp), lifted feet from \(f) by 12 nodes"); fflush(stdout)
                simDigPhase = 1; simDigTimer = 0
            case 1:
                // Track the low-water mark: full saturation regens ~1 hp/0.5 s, so
                // by the time we report, hp may already be back to where it was.
                simScratchInt = min(simScratchInt, hp)
                if simDigTimer > 4 {
                    print("[falltest] RESULT hp before=\(simScratchCount) min=\(simScratchInt) damaged=\(simScratchInt < simScratchCount) pass=\(simScratchInt < simScratchCount)"); fflush(stdout)
                    simDigPhase = 2
                }
            default: break
            }
        }
        // -vrdev.placeTest 1: wield stone and place aiming straight down. The pointed node is the floor, so the
        // target is the feet node: the engine refuses that (you'd be inside the
        // block), no INTERACT goes out, and the node under us stays air (#268).
        if UserDefaults.standard.bool(forKey: "vrdev.placeTest"), client.objects.localPlayerId != 0, atlasBuilt {
            simDigTimer += Double(dt)
            switch simDigPhase {
            case 0 where simDigTimer > 2:
                client.sendChat("/grantme all"); client.sendChat("/giveme mcl_core:stone 8")
                simDigPhase = 1; simDigTimer = 0
            case 1 where simDigTimer > 4 && player.physics().grounded:
                if let m = client.inventory["main"], let slot = m.firstIndex(where: { $0?.name == "mcl_core:stone" }) {
                    client.setWieldIndex(slot)
                    let f = player.physics().feet
                    let feetNode = SIMD3(Int(floor(f.x)), Int(floor(f.y)), Int(floor(f.z)))
                    let before = client.world.nodeId(feetNode)
                    let placed = performPlace(aim: SIMD3(0, -1, 0))
                    let after = client.world.nodeId(feetNode)
                    print("[placetest] RESULT feetNode=\(feetNode) before=\(before) after=\(after) returned=\(placed) refused=\(after == before && !placed) pass=\(after == before && !placed)"); fflush(stdout)
                } else { print("[placetest] no stone in inventory"); fflush(stdout) }
                simDigPhase = 2
            default: break
            }
        }
        // -vrdev.bounceTest 1: bouncy parity (#269). Swap the node under the sim
        // player for a slime block (local world copy is what physics reads),
        // lift 8 nodes and drop: the landing must reflect vy upward (bouncy=44
        // -> ~44% of the impact) instead of stopping dead.
        if UserDefaults.standard.bool(forKey: "vrdev.bounceTest"), client.objects.localPlayerId != 0, atlasBuilt {
            simDigTimer += Double(dt)
            switch simDigPhase {
            case 0 where simDigTimer > 2:
                client.sendChat("/grantme all"); simTeleportToPad()   // known open platform
                simDigPhase = 10; simDigTimer = 0
            case 10 where simDigTimer > 6 && player.physics().grounded && player.physics().feet.y > 100:
                let f = player.physics().feet
                let under = SIMD3(Int(floor(f.x)), Int(floor(f.y - 0.1)), Int(floor(f.z)))
                if let slime = client.nodes.id(for: "mcl_core:slimeblock") {
                    client.world.setNode(under, param0: slime, param2: 0); markNodeDirty(under)
                    player.setPhysics(feet: f + SIMD3(0, 8, 0), vy: 0, grounded: false)
                    simScratchInt = 0   // reused as "max vy seen after the landing"
                    print("[bouncetest] slime at \(under) (groups=\(client.nodes.groups(slime))), lifted 8"); fflush(stdout)
                    simDigPhase = 1; simDigTimer = 0
                } else { print("[bouncetest] no slimeblock def"); fflush(stdout); simDigPhase = 99 }
            case 1:
                let ph = player.physics()
                if ph.vy > 0.5 && simDigTimer > 0.3 { simScratchInt = max(simScratchInt, Int(ph.vy * 100)) }
                if simDigTimer > 4 {
                    print("[bouncetest] RESULT maxUpwardVyAfterDrop=\(Float(simScratchInt) / 100) bounced=\(simScratchInt > 100) pass=\(simScratchInt > 100)"); fflush(stdout)
                    simDigPhase = 2
                }
            default: break
            }
        }
        // -vrdev.iglooTest 1: Eric's igloo-basement report (#303). Teleport to the
        // spot from his bug note (solid stone in the vrdev world, which is fine:
        // it's the buried case) and auto-walk for 10 s. The feet must hold; the
        // bug lifted them 3 nodes a tick through solid rock (the eject probe only
        // saw this tick's local collision boxes) into the room above.
        if UserDefaults.standard.bool(forKey: "vrdev.iglooTest"), client.objects.localPlayerId != 0, atlasBuilt {
            simDigTimer += Double(dt)
            let f = player.physics().feet
            switch simDigPhase {
            case 0 where simDigTimer > 2:
                client.sendChat("/grantme all"); client.sendChat("/teleport -113.08 -9.5 -104.94")   // the #303 repro spot in the developer's own dev world, in server coords (ours - 0.5)
                simDigPhase = 10; simDigTimer = 0
            case 10 where simDigTimer > 8:
                simScratchInt = Int(f.y * 100); simFallMaxY = f.y
                // Print the node column around the #303 repro coordinates so the client's decoded map can
                // be compared with what his device log saw.
                for y in stride(from: -4, through: -12, by: -1) {
                    var row = "[igloo] y=\(y):"
                    for dx in -2...2 { for dz in -2...2 {
                        let id = client.world.nodeId(SIMD3(-113 + dx, y, -105 + dz))
                        row += " \(client.nodes.name(id).replacingOccurrences(of: "mcl_core:", with: ""))"
                    } ; row += " |" }
                    print(row); fflush(stdout)
                }
                simAutoWalk = true
                print("[igloo] start feet=\(f) grounded=\(player.physics().grounded)"); fflush(stdout)
                simDigPhase = 1; simDigTimer = 0
            case 1:
                simFallMaxY = max(simFallMaxY, f.y)
                if Int(simDigTimer * 2) != Int((simDigTimer - Double(dt)) * 2) {
                    print("[igloo] t=\(String(format: "%.1f", simDigTimer)) feet=\(f) climbing=\(overlapsClimbable(feet: f)) grounded=\(player.physics().grounded)"); fflush(stdout)
                }
                if simDigTimer > 10 {
                    simAutoWalk = false
                    let rose = simFallMaxY - Float(simScratchInt) / 100
                    print("[igloo] RESULT rose=\(rose) pass=\(rose < 1.5)"); fflush(stdout)
                    simDigPhase = 2
                }
            default: break
            }
        }
        // -vrdev.ladderTest 1: igloo-ladder report (#331) -- "climb down works,
        // can't walk into the ladder cube to go back up". Build a minimal
        // wall-mounted ladder column in the local world (a brick shaft like the
        // igloo's), then check the two things the report implicates, with no
        // navigation flake: (A) the player can walk horizontally INTO the ladder
        // column past the surrounding bricks, and (B) once inside, climbing is
        // detected and jump carries them up. We enter along -Z so the ladder's
        // thin plate (always on an X face for an x-wall mount) can never be what
        // blocks entry -- that isolates the collision-cube-vs-nodebox question.
        if UserDefaults.standard.bool(forKey: "vrdev.ladderTest"), client.objects.localPlayerId != 0, atlasBuilt {
            simDigTimer += Double(dt)
            switch simDigPhase {
            case 0 where simDigTimer > 2:
                client.sendChat("/grantme all"); simTeleportToPad()   // known open platform
                simDigPhase = 10; simDigTimer = 0
            case 10 where simDigTimer > 6 && player.physics().grounded && player.physics().feet.y > 100:
                guard let ladder = client.nodes.id(for: "mcl_core:ladder"),
                      let brick = client.nodes.id(for: "mcl_core:stonebrick") else {
                    print("[laddertest] RESULT missing node defs pass=false"); fflush(stdout); simDigPhase = 99; break
                }
                let f = player.physics().feet
                let cy = Int(floor(f.y - 0.1))              // platform node under the feet; feet rest at cy+1
                let cx = Int(floor(f.x)) + 2               // ladder column two nodes aside, clear of the player
                let cz = Int(floor(f.z))
                // Floor under the whole footprint so nobody falls through.
                for dx in -1...1 { for dz in -1...2 {
                    let n = SIMD3(cx + dx, cy, cz + dz); client.world.setNode(n, param0: brick); markNodeDirty(n)
                } }
                // Three-tall ladder column with brick backing (-X) and side walls
                // (+X, -Z). +Z is the open entry the player walks in from. param2=3
                // is a wall mount (its plate lands on an X face, out of the -Z path).
                for dy in 1...3 {
                    let y = cy + dy
                    client.world.setNode(SIMD3(cx, y, cz), param0: ladder, param2: 3)
                    client.world.setNode(SIMD3(cx - 1, y, cz), param0: brick)   // backing wall
                    client.world.setNode(SIMD3(cx + 1, y, cz), param0: brick)   // +X wall
                    client.world.setNode(SIMD3(cx, y, cz - 1), param0: brick)   // -Z wall (far side)
                    for n in [SIMD3(cx, y, cz), SIMD3(cx - 1, y, cz), SIMD3(cx + 1, y, cz), SIMD3(cx, y, cz - 1)] { markNodeDirty(n) }
                }
                let climbNode = phys.isClimbable(client.world.nodeId(SIMD3(cx, cy + 1, cz)))
                // (A) Walk from the open +Z cell straight into the ladder column.
                let entryFeet = SIMD3(Float(cx) + 0.5, Float(cy + 1), Float(cz) + 1.5)
                let afterEntry = collideMove(feet: entryFeet, delta: SIMD3(0, 0, -1.0), grounded: true, climbing: false)
                let enteredColumn = Int(floor(afterEntry.feet.z)) == cz
                // (B) From wherever entry left us, climb: gravity-free, jump held.
                let climbDetected = overlapsClimbable(feet: afterEntry.feet)
                var cf = afterEntry.feet
                let startY = cf.y
                let cdt: Float = 1.0 / 60
                for _ in 0..<48 {
                    guard overlapsClimbable(feet: cf) else { break }
                    cf = collideMove(feet: cf, delta: SIMD3(0, client.speedClimb * cdt, 0), grounded: false, climbing: true).feet
                }
                let rose = cf.y - startY
                let pass = climbNode && enteredColumn && climbDetected && rose >= 1.5
                print("[laddertest] climbNode=\(climbNode) entered=\(enteredColumn) (z \(entryFeet.z)->\(afterEntry.feet.z)) climbDetected=\(climbDetected) rose=\(String(format: "%.2f", rose))"); fflush(stdout)
                print("[laddertest] RESULT entered=\(enteredColumn) climb=\(climbDetected) rose=\(String(format: "%.2f", rose)) pass=\(pass)"); fflush(stdout)
                simDigPhase = 2
            default: break
            }
        }
        // -vrdev.iceTest 1: slippery parity (#269). Lay a local 21x21 ice patch under
        // the sim player, auto-walk for 3 s, then stop: on ice the speed must
        // ramp up slowly (accel 2.4/(3+1) = 0.6 node/s^2) and coast on after the
        // stick is released, instead of the usual instant start/stop.
        if UserDefaults.standard.bool(forKey: "vrdev.iceTest"), client.objects.localPlayerId != 0, atlasBuilt {
            simDigTimer += Double(dt)
            let f = player.physics().feet
            let hs = simd_length(SIMD2(slipVel.x, slipVel.y))
            switch simDigPhase {
            case 0 where simDigTimer > 2:
                // Earlier harness runs can leave the sim player anywhere (a bounce
                // test walked it off the sky platform into a cave): start on the
                // known open platform.
                client.sendChat("/grantme all"); simTeleportToPad()
                simDigPhase = 10; simDigTimer = 0
            case 10 where simDigTimer > 6 && player.physics().grounded && f.y > 100:
                if let ice = client.nodes.id(for: "mcl_core:ice") {
                    let cy = Int(floor(f.y - 0.1))
                    // 31x31: at the engine's real ice acceleration the walk hits
                    // full speed in under a second, so 1.5 s of walking covers ~6 nodes.
                    for x in -15...15 { for z in -15...15 {
                        let n = SIMD3(Int(floor(f.x)) + x, cy, Int(floor(f.z)) + z)
                        client.world.setNode(n, param0: ice, param2: 0); markNodeDirty(n)
                    } }
                    simAutoWalk = true
                    print("[icetest] ice patch laid (slippery=\(client.nodes.groups(ice)["slippery"] ?? 0)) accel=\(client.accelDefault) node/s^2, walking"); fflush(stdout)
                    simDigPhase = 1; simDigTimer = 0
                } else { print("[icetest] no ice def"); fflush(stdout); simDigPhase = 99 }
            case 1:
                if simDigTimer > 0.5 && simDigPhase == 1 { print("[icetest] t=0.5s speed=\(hs)"); fflush(stdout); simDigPhase = 2 }
            case 2:
                if simDigTimer > 1.5 { print("[icetest] t=1.5s speed=\(hs) -> stick released"); fflush(stdout); simAutoWalk = false; simDigPhase = 3 }
            case 3:
                // Luanti: no stick input doubles the slip factor, so ice (slippery
                // 3) coasts down at 24/7 = 3.4 node/s^2: 4.3 -> ~0.9 after 1 s.
                if simDigTimer > 2.5 {
                    print("[icetest] RESULT 1s after release speed=\(hs) coasting=\(hs > 0.5) pass=\(hs > 0.5 && hs < 2.0)"); fflush(stdout)
                    client.sendChat("/teleport 0 121 0")   // the ice was local-only; don't leave the server-side player over air
                    simDigPhase = 4
                }
            default: break
            }
        }
        // -vrdev.sneakTest 1: sneak edge-glue parity (localplayer.cpp). The sim's
        // sky platform is small, so from its origin a straight sneak-walk reaches
        // an edge within a couple of seconds. The feet must never drop (no fall)
        // and the walk must come to a stop (glued at the edge, centre at most
        // sneak_max = 0.306 past it (with VoxeLibre's 0.312 half-width box)) rather than carry on into the void.
        if UserDefaults.standard.bool(forKey: "vrdev.sneakTest"), client.objects.localPlayerId != 0, atlasBuilt {
            simDigTimer += Double(dt)
            let f = player.physics().feet
            switch simDigPhase {
            case 0 where simDigTimer > 2:
                client.sendChat("/grantme all"); simTeleportToPad()
                simDigPhase = 10; simDigTimer = 0
            case 10 where simDigTimer > 6 && player.physics().grounded && f.y > 100:
                simFallMaxY = f.y; simScratchInt = Int(f.y * 100)
                // Face a fixed heading: the yaw otherwise carries over from
                // whatever the last scene left, and toward +X/+Z the pad is
                // wider than the 4 s walk.
                player.addYaw(-1.67 - player.snapshot().yaw)
                simAutoWalk = true; simAutoSneak = true
                print("[sneaktest] start feet=\(f), sneaking forward"); fflush(stdout)
                simDigPhase = 1; simDigTimer = 0
            case 1:
                simFallMaxY = min(simFallMaxY, f.y)
                if Int(simDigTimer * 5) != Int((simDigTimer - Double(dt)) * 5) {
                    print("[sneaktest] t=\(String(format: "%.2f", simDigTimer)) feet=\(f) grounded=\(player.physics().grounded) sneakNode=\(sneakNode.map { "\($0.pos) top=\($0.box.hi.y)" } ?? "nil")"); fflush(stdout)
                }
                if simDigTimer > 4 { simSneakMark = f; simDigPhase = 2 }
            case 2:
                simFallMaxY = min(simFallMaxY, f.y)
                if simDigTimer > 6 {
                    simAutoWalk = false; simAutoSneak = false
                    let start = Float(simScratchInt) / 100
                    let moved = simd_length(SIMD2(f.x - simSneakMark.x, f.z - simSneakMark.z))
                    let fell = simFallMaxY < start - 0.5
                    let sn = sneakNode.map { "\($0.pos)" } ?? "nil"
                    // Leaning: the centre is past one of the sneak node's XZ edges
                    // (by up to sneak_max), which only the glue allows without a fall.
                    var lean: Float = 0
                    if let n = sneakNode {
                        lean = max(n.box.lo.x - f.x, f.x - n.box.hi.x, n.box.lo.z - f.z, f.z - n.box.hi.z)
                    }
                    print("[sneaktest] RESULT feet=\(f) minY=\(simFallMaxY) start=\(start) fell=\(fell) movedLast2s=\(moved) sneakNode=\(sn) lean=\(lean) pass=\(!fell && lean > 0.25 && lean < 0.32)"); fflush(stdout)
                    simDigPhase = 3
                }
            default: break
            }
        }
        // -vrdev.probe 1: print the client's OWN already-decoded world nodes in a 7x7 at
        // y=120 around the origin (the sim's sky platform) so a harness that ate
        // it can be spotted. Local debug print of already-received map data, no network.
        if UserDefaults.standard.bool(forKey: "vrdev.probe"), client.objects.localPlayerId != 0, atlasBuilt, simDigPhase == 0 {
            simDigTimer += Double(dt)
            if simDigTimer > 2, simDigTimer < 2.2 { client.sendChat("/grantme all"); simTeleportToPad() }
            if simDigTimer > 9 {
                simDigPhase = 99
                for z in -3...3 {
                    var row = ""
                    for x in -3...3 {
                        let id = client.world.nodeId(SIMD3(x, 120, z))
                        row += id == WorldMap.CONTENT_AIR ? " . " : (id == WorldMap.CONTENT_IGNORE ? " ? " : " # ")
                    }
                    print("[probe] z=\(z) \(row)"); fflush(stdout)
                }
                let c = client.world.nodeId(SIMD3(0, 120, 0))
                print("[probe] (0,120,0) = \(client.nodes.name(c)) feet=\(player.physics().feet)"); fflush(stdout)
            }
        }
        // -vrdev.bugNoteTest 1: open the Kogane "Bug note" keyboard the way the
        // menu does, type via prefill, press Done, and expect the [bugnote] line
        // + Documents/bug-notes.txt. Eric's device sessions closed the keyboard
        // without a note ever landing (the completion was nilled before use).
        if UserDefaults.standard.bool(forKey: "vrdev.bugNoteTest"), client.objects.localPlayerId != 0, atlasBuilt {
            simDigTimer += Double(dt)
            switch simDigPhase {
            case 0 where simDigTimer > 4:
                koganeSel = koganeOptions.firstIndex(of: "Bug note") ?? 0
                activateKoganeOption()
                keyboardBuffer = "sim note"
                simDigPhase = 1; simDigTimer = 0
            case 1 where simDigTimer > 2:
                submitKeyboard()
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("bug-notes.txt")
                let saved = (try? String(contentsOf: url, encoding: .utf8))?.contains("sim note") ?? false
                print("[bugnotetest] RESULT keyboardOpen=\(keyboardOpen) noteSaved=\(saved) pass=\(saved && !keyboardOpen)"); fflush(stdout)
                simDigPhase = 2
            default: break
            }
        }
        // -vrdev.torchTest 1: client-side relight with the real NODEDEF (#278).
        // Drop a torch into the local world 2 nodes ahead on the platform and
        // read the night light around it; then dig it and read again. Starts
        // from the spawn pad like the other scenes: wherever the previous scene
        // left the player may have walls or terrain in the torch's light path.
        if UserDefaults.standard.bool(forKey: "vrdev.torchTest"), client.objects.localPlayerId != 0, atlasBuilt {
            simDigTimer += Double(dt)
            if simDigPhase == 0, simDigTimer > 2 {
                simTeleportToPad(); simDigPhase = 6; simDigTimer = 0
            } else if simDigPhase == 6, simDigTimer > 5, player.physics().grounded {
                simDigPhase = 99
                let f = player.physics().feet
                let p = SIMD3(Int(floor(f.x)) + 2, Int(floor(f.y)), Int(floor(f.z)))
                if let torch = client.nodes.id(for: "mcl_torches:torch") {
                    func nl(_ q: SIMD3<Int>) -> Int { Int(client.world.nodeLight(q) >> 4) }   // night bank
                    func nd(_ q: SIMD3<Int>) -> Int { Int(client.world.nodeLight(q) & 15) }   // day bank
                    client.world.setNode(p, param0: torch, param2: 1)
                    let lit = nl(p), lit1 = nl(p &+ SIMD3(1,0,0)), lit3 = nl(p &+ SIMD3(3,0,0))
                    let dayLit = nd(p)
                    print("[torchtest] placed at \(p): self=\(lit) +1=\(lit1) +3=\(lit3) +6=\(nl(p &+ SIMD3(6,0,0))) up2=\(nl(p &+ SIMD3(0,2,0))) dayBank=\(dayLit)"); fflush(stdout)
                    client.world.removeNode(p)
                    // A torch (light 13 in VoxeLibre) must light its neighbours
                    // while placed and go fully dark once dug (#278).
                    let dark = nl(p), dark1 = nl(p &+ SIMD3(1,0,0)), dark3 = nl(p &+ SIMD3(3,0,0))
                    print("[torchtest] RESULT after dig: self=\(dark) +1=\(dark1) +3=\(dark3) pass=\(lit >= 10 && lit1 == lit - 1 && lit3 == lit - 3 && dark == 0 && dark1 == 0 && dark3 == 0 && dayLit >= lit)"); fflush(stdout)
                } else { print("[torchtest] no torch def"); fflush(stdout) }
            }
        }
        // -vrdev.awardTest 1 (with -vrdev.fakeAward 1): the advancement toast's
        // title, header and icon must all land inside its background box, and
        // the two text lines must not overlap. Uses a long real title by
        // default, since short ones hid overflow before (#222, device report
        // 2026-09-23 "looked bad").
        if UserDefaults.standard.bool(forKey: "vrdev.awardTest"), client.objects.localPlayerId != 0, atlasBuilt {
            simDigTimer += Double(dt)
            if simDigPhase == 0, simDigTimer > 4 {
                simDigPhase = 1
                let r = simAwardRects
                func fmt(_ k: String) -> String { r[k].map { "(\(Int($0.lo.x)),\(Int($0.lo.y)))-(\(Int($0.hi.x)),\(Int($0.hi.y)))" } ?? "missing" }
                for k in ["award_bg", "award_au", "award_title", "award_icon"] { print("[awardtest] \(k) \(fmt(k))") }
                var ok = r.count == 4
                if let bg = r["award_bg"] {
                    for k in ["award_au", "award_title", "award_icon"] {
                        guard let e = r[k] else { ok = false; continue }
                        let inside = e.lo.x >= bg.lo.x - 1 && e.lo.y >= bg.lo.y - 1 && e.hi.x <= bg.hi.x + 1 && e.hi.y <= bg.hi.y + 1
                        if !inside { print("[awardtest] \(k) spills outside award_bg"); ok = false }
                    }
                    if let a = r["award_au"], let t = r["award_title"], a.hi.y > t.lo.y, t.hi.y > a.lo.y,
                       a.hi.x > t.lo.x, t.hi.x > a.lo.x { print("[awardtest] header and title overlap"); ok = false }
                    if let i = r["award_icon"], let t = r["award_title"], i.hi.x > t.lo.x, t.hi.x > i.lo.x,
                       i.hi.y > t.lo.y, t.hi.y > i.lo.y { print("[awardtest] icon overlaps title"); ok = false }
                }
                print("[awardtest] RESULT elements=\(r.count) pass=\(ok)"); fflush(stdout)
            }
        }
        // -vrdev.stationTest 1: stations that are rightclickable AND keep their
        // form in node meta (grindstone, shulker box) must open on rightclick,
        // as Game::nodePlacement opens the meta formspec after sending the use.
        // Places each 3 nodes ahead at eye level, rightclicks it, checks a form
        // opened, closes it, moves on (parity review 2026-09-23 #1).
        if UserDefaults.standard.bool(forKey: "vrdev.stationTest"), client.objects.localPlayerId != 0, atlasBuilt {
            simDigTimer += Double(dt)
            let stations = ["mcl_grindstone:grindstone", "mcl_chests:violet_shulker_box"]
            switch simDigPhase {
            case 0 where simDigTimer > 2:
                client.sendChat("/grantme all"); simTeleportToPad()
                simDigPhase = 1; simDigTimer = 0
            case 1 where simDigTimer > 6 && player.physics().grounded:
                let feet = player.physics().feet, bf = player.bodyForward()
                simTarget = SIMD3<Int>(Int((feet.x + bf.x * 3).rounded(.down)), Int((feet.y + 1.2).rounded(.down)),
                                           Int((feet.z + bf.z * 3).rounded(.down)))
                simChatQueue = stations
                simScratchCount = 0
                simDigPhase = 2; simDigTimer = 2
            case 2 where simDigTimer > 1.5:     // place the next station (chat-rate paced)
                guard let t = simTarget, let name = simChatQueue.first else { simDigPhase = 9; break }
                client.sendChat("/setblock \(t.x),\(t.y),\(t.z) \(name)")
                simDigPhase = 3; simDigTimer = 0
            case 3 where simDigTimer > 3:       // rightclick it
                guard let t = simTarget, let name = simChatQueue.first else { simDigPhase = 9; break }
                let centre = SIMD3<Float>(Float(t.x) + 0.5, Float(t.y) + 0.5, Float(t.z) + 0.5)
                let hasMetaForm = client.world.nodeFormspec(t) != nil
                _ = performPlace(aim: simd_normalize(centre - player.rayOrigin()))
                let ok = formspecOpen
                print("[stationtest] \(name) node=\(client.nodes.name(client.world.nodeId(t))) metaForm=\(hasMetaForm) opened=\(ok)"); fflush(stdout)
                if ok { simScratchCount += 1 }
                closeFormspec()
                simChatQueue.removeFirst()
                simDigPhase = simChatQueue.isEmpty ? 9 : 2; simDigTimer = 0
            case 9:
                print("[stationtest] RESULT opened=\(simScratchCount)/\(stations.count) pass=\(simScratchCount == stations.count)"); fflush(stdout)
                // Leave the shared spawn pad as we found it: a station left at
                // head height walls off the sneak test's edge.
                if let t = simTarget { client.sendChat("/setblock \(t.x),\(t.y),\(t.z) air") }
                simDigPhase = 10
            default: break
            }
        }
        // -vrdev.statusTest 1: status effects must reach the heart row the way
        // vl_hudbars shows them. Poison swaps the heart statbar's icon (we must
        // pick up the new icon AND have a layer for it); absorption adds gold
        // hearts via a second statbar (parity review 2026-09-23 #4).
        if UserDefaults.standard.bool(forKey: "vrdev.statusTest"), client.objects.localPlayerId != 0, atlasBuilt {
            simDigTimer += Double(dt)
            switch simDigPhase {
            case 0 where simDigTimer > 3:
                client.sendChat("/grantme all"); client.sendChat("/effect clear")
                simDigPhase = 1; simDigTimer = 0
            case 1 where simDigTimer > 1.5:
                client.sendChat("/effect poison 60 1 NOPART")
                simDigPhase = 2; simDigTimer = 0
            case 2 where simDigTimer > 1.5:
                client.sendChat("/effect absorption 60 1 NOPART")
                simDigPhase = 6; simDigTimer = 0
            case 6 where simDigTimer > 3:        // health boost: hp_max above 20
                simScratchCount = client.absorption   // record before the boost/heal disturb it
                client.sendChat("/effect health_boost 60 2 NOPART")
                simDigPhase = 7; simDigTimer = 0
            case 7 where simDigTimer > 1.5:
                client.sendChat("/effect heal 40")
                simDigPhase = 3; simDigTimer = 0
            case 3 where simDigTimer > 3:
                let icon = client.healthIcon ?? "nil"
                let poisoned = icon.contains("poison"), hasLayer = atlas.statusIconPairs[icon] != nil
                let absorb = simScratchCount, gold = atlas.statusIconPairs["mcl_potions_icon_absorb.png"] != nil
                print("[statustest] healthIcon=\(icon) layer=\(hasLayer) absorption=\(absorb) goldLayer=\(gold)"); fflush(stdout)
                print("[statustest] hp=\(hp) (above 20 draws extra heart rows)"); fflush(stdout)
                print("[statustest] RESULT pass=\(poisoned && hasLayer && absorb > 0 && gold && hp > 20)"); fflush(stdout)
                simDigPhase = 4
            default: break
            }
        }
        // -vrdev.stepTest 1: footstep cadence follows speed like the engine's
        // view bobbing: walk 3 s, then sneak-walk 3 s on the open stone flat at
        // 0,78,0 (the spawn pad is too small to walk on); sneaking must step far
        // less often (parity review 2026-09-23 #7).
        if UserDefaults.standard.bool(forKey: "vrdev.stepTest"), client.objects.localPlayerId != 0, atlasBuilt {
            let prevT = simDigTimer
            simDigTimer += Double(dt)
            if (simDigPhase == 1 || simDigPhase == 2), Int(simDigTimer * 2) != Int(prevT * 2) {
                let ph = player.physics()
                print("[steptest] t=\(String(format: "%.1f", simDigTimer)) phase=\(simDigPhase) feet=\(ph.feet) grounded=\(ph.grounded) steps=\(stepCount)"); fflush(stdout)
            }
            switch simDigPhase {
            case 0 where simDigTimer > 2:
                client.sendChat("/grantme all"); client.sendChat("/teleport 0 78 0")
                simDigPhase = 5; simDigTimer = 0
            case 5 where simDigTimer > 6 && player.physics().grounded:
                stepCount = 0; cadenceStepCount = 0; simAutoWalk = true; simAutoSneak = false
                simDigPhase = 1; simDigTimer = 0
            case 1 where simDigTimer > 3:
                simScratchCount = cadenceStepCount
                stepCount = 0; cadenceStepCount = 0; simAutoSneak = true
                simDigPhase = 2; simDigTimer = 0
            case 2 where simDigTimer > 3:
                simAutoWalk = false; simAutoSneak = false
                // Cadence steps only: landings (stepping down the slope here)
                // play too, like PLAYER_REGAIN_GROUND, but aren't the cadence.
                let walk = simScratchCount, sneak = cadenceStepCount
                print("[steptest] RESULT walkBobSteps=\(walk) sneakBobSteps=\(sneak) landingsInSneak=\(stepCount - sneak) pass=\(walk >= 2 && sneak * 2 < walk)"); fflush(stdout)
                simDigPhase = 3
            default: break
            }
        }
        // -vrdev.offhandTest 1: put a stack of torches in the offhand slot so the
        // HUD inventory element's count (and wear bar, for tools) can be seen
        // headless. Also -vrdev.offhandItem "<itemstring>" (e.g. a worn shield).
        if UserDefaults.standard.bool(forKey: "vrdev.offhandTest"), client.objects.localPlayerId != 0, atlasBuilt {
            simDigTimer += Double(dt)
            switch simDigPhase {
            case 0 where simDigTimer > 2:
                // Empty the offhand first: mcl_offhand never forgets its HUD ids
                // on leave, so a relog with the slot already full shows no slot
                // HUD at all (a VoxeLibre bug, desktop too). Emptying it lets the
                // mod remove + re-add the HUD fresh for this session.
                client.sendChat("/grantme all")
                client.sendInventoryAction("Drop 99 current_player offhand 0")
                simDigPhase = 1; simDigTimer = 0
            case 1 where simDigTimer > 2:
                client.sendChat("/clearinv")
                simDigPhase = 2; simDigTimer = 0
            case 2 where simDigTimer > 1.5:
                client.sendChat("/giveme \(UserDefaults.standard.string(forKey: "vrdev.offhandItem") ?? "mcl_torches:torch 32")")
                simDigPhase = 3; simDigTimer = 0
            case 3 where simDigTimer > 2:
                let n = client.inventory["main"]?.first.flatMap { $0?.count } ?? 0
                client.sendInventoryAction("Move \(max(1, n)) current_player main 0 current_player offhand 0")
                simDigPhase = 4; simDigTimer = 0
            case 4 where simDigTimer > 2:
                let off = client.inventory["offhand"]?.first.flatMap { $0 }
                print("[offhandtest] RESULT offhand=\(off?.name ?? "nil") count=\(off?.count ?? 0) wear=\(off?.wear ?? 0) pass=\(off != nil)"); fflush(stdout)
                simDigPhase = 5
            default: break
            }
        }
        // -vrdev.dropTest 1: the thing that hovers after you mine a block. Put a
        // deepslate node four nodes ahead at eye level (past VoxeLibre's item
        // magnet, so the drop stays put instead of flying into the inventory),
        // dig it, and 1.5 s later check the __builtin:item entity is there AND
        // has a resolved icon layer, i.e. it would actually draw. Bug note
        // 2026-09-22 "I don't see mined blocks" (#358).
        if UserDefaults.standard.bool(forKey: "vrdev.dropTest"), client.objects.localPlayerId != 0, atlasBuilt {
            simDigTimer += Double(dt)
            switch simDigPhase {
            case 0 where simDigTimer > 2:
                // The sim account keeps its inventory between runs, so empty it
                // first: the pick must land in hotbar slot 0 (the wielded one) or
                // the server rejects the instant dig as "completed digging too fast".
                client.sendChat("/grantme all"); client.sendChat("/clearinv"); client.sendChat("/giveme mcl_tools:pick_diamond")
                simTeleportToPad()
                simDigPhase = 1; simDigTimer = 0
            case 1 where simDigTimer > 6 && player.physics().grounded:
                let feet = player.physics().feet, bf = player.bodyForward()
                // Target two above the feet, floor one above them: the floor
                // replaces the spawn pad's tall grass (which hid the drop in every
                // shot) and the drop lands at eye height, four nodes ahead.
                let t = SIMD3<Int>(Int((feet.x + bf.x * 4).rounded(.down)), Int((feet.y + 2.2).rounded(.down)),
                                   Int((feet.z + bf.z * 4).rounded(.down)))
                simTarget = t
                // The sim spawn is a small floating pad, so lay a 3x3 floor two
                // below the target first or the drop just rolls off into the void.
                for dx in -1...1 { for dz in -1...1 {
                    simChatQueue.append("/setblock \(t.x + dx),\(t.y - 2),\(t.z + dz) mcl_core:snowblock")   // light floor: dark drop stands out
                } }
                simChatQueue.append("/setblock \(t.x),\(t.y),\(t.z) mcl_deepslate:deepslate")
                print("[droptest] target \(t) feet=\(feet) bf=\(bf); laying floor + target (\(simChatQueue.count) setblocks)"); fflush(stdout)
                simDigPhase = 6; simDigTimer = 2
            case 6 where simDigTimer > 1.3:   // one chat command per 1.3 s (server allows 8 per 10 s)
                simDigTimer = 0
                if simChatQueue.isEmpty { simDigPhase = 2 } else { client.sendChat(simChatQueue.removeFirst()) }
            case 2 where simDigTimer > 3:
                guard let t = simTarget else { simDigPhase = 99; break }
                let id = client.world.nodeId(t)
                if id == WorldMap.CONTENT_AIR || id == WorldMap.CONTENT_IGNORE {
                    if simDigTimer > 12 { print("[droptest] RESULT placed node never streamed in pass=false"); fflush(stdout); simDigPhase = 99 }
                    break
                }
                let centre = SIMD3<Float>(Float(t.x) + 0.5, Float(t.y) + 0.5, Float(t.z) + 0.5)
                performDig(dir: simd_normalize(centre - player.rayOrigin()))
                print("[droptest] dug \(t) (id \(id))"); fflush(stdout)
                simDigPhase = 3; simDigTimer = 0
            case 3 where simDigTimer > 1.5:
                let feet = player.physics().feet
                let drops = client.objects.snapshot().filter { $0.name == "__builtin:item" && simd_distance($0.pos, feet) < 24 }
                var drawable = 0, sunk = 0
                for d in drops {
                    let spec = d.textures.first.flatMap(droppedItemSpec)
                    let layer = spec.flatMap { modelTexLayer[$0] }
                    print("[droptest] drop id=\(d.id) item=\(d.textures.first ?? "") pos=\(d.pos) dist=\(simd_distance(d.pos, feet)) spec=\(spec ?? "nil") layer=\(layer.map(String.init) ?? "nil") vel=\(d.vel) acc=\(d.acc) physical=\(d.physical)"); fflush(stdout)
                    if layer != nil { drawable += 1 }
                    // Ground under the drop, so a drop that "fell into a hole" is
                    // distinguishable from one that fell through the world.
                    let dx = Int(d.pos.x.rounded(.down)), dz = Int(d.pos.z.rounded(.down))
                    var top = Int.min
                    for y in stride(from: Int(feet.y) + 3, through: Int(feet.y) - 20, by: -1) {
                        let nid = client.world.nodeId(SIMD3(dx, y, dz))
                        if nid != WorldMap.CONTENT_AIR, nid != WorldMap.CONTENT_IGNORE, client.nodes.isSolidCube(nid) { top = y; break }
                    }
                    // Sunk = the item's collisionbox bottom is below the floor it should rest on.
                    if top != Int.min, d.pos.y + d.cbMin.y < Float(top + 1) - 0.05 { sunk += 1 }
                    print("[droptest] ground under drop column x=\(dx) z=\(dz): highest solid y=\(top) (drop y=\(d.pos.y) cbMin.y=\(d.cbMin.y))"); fflush(stdout)
                }
                // Held back until the floor is cleared (phase 8): simtests.sh
                // kills the app on the RESULT line.
                simDropResult = "[droptest] RESULT drops=\(drops.count) drawable=\(drawable) sunk=\(sunk) pass=\(drawable > 0 && sunk == 0)"
                simDigPhase = 4; simDigTimer = 0
            case 4 where simDigTimer > 4:
                // Settle check (#360): the server's send threshold drops to 0.01
                // after 1 s of quiet, so a landed item's residual velocity should
                // have been zeroed by now instead of dead-reckoning it away.
                let feet = player.physics().feet
                for d in client.objects.snapshot() where d.name == "__builtin:item" && simd_distance(d.pos, feet) < 24 {
                    print("[droptest] settled id=\(d.id) pos=\(d.pos) vel=\(d.vel) acc=\(d.acc)"); fflush(stdout)
                }
                // Leave the shared spawn pad as we found it: the floor sits at
                // foot height and walls off the sneak test's edge.
                if let t = simTarget {
                    for dx in -1...1 { for dz in -1...1 { simChatQueue.append("/setblock \(t.x + dx),\(t.y - 2),\(t.z + dz) air") } }
                }
                simDigPhase = 8; simDigTimer = 0
            case 8 where simDigTimer > 1.3:   // chat-rate paced, like phase 6
                simDigTimer = 0
                if simChatQueue.isEmpty { print(simDropResult); fflush(stdout); simDigPhase = 7 }
                else { client.sendChat(simChatQueue.removeFirst()) }
            default: break
            }
        }
        // -vrdev.digTest 1: prove dig prediction is synchronous (#179). Teleports
        // onto open ground, then digs the block underfoot and logs the target's
        // node id right before and right after performDig IN THE SAME TICK: if the
        // node is already air post-call (no server round-trip) and remeshCooldown
        // is 0 (remesh scheduled for the next tick, not the 0.4 s coalesce), the
        // block change is immediate. A before/after screenshot shows the hole.
        if UserDefaults.standard.bool(forKey: "vrdev.digTest"), client.objects.localPlayerId != 0, atlasBuilt {
            simDigTimer += Double(dt)
            switch simDigPhase {
            case 0 where simDigTimer > 2:
                client.sendChat("/grantme all"); client.sendChat("/giveme mcl_tools:pick_diamond")
                simTeleportToPad()
                print("[digtest] granted pick + teleporting over open ground"); fflush(stdout)
                simDigPhase = 1; simDigTimer = 0
            case 1 where simDigTimer > 6:
                guard let hit = client.world.raycast(origin: player.rayOrigin(), dir: SIMD3(0, -1, 0),
                                                     maxDist: currentReach, pointable: client.nodes.isPointable, boxes: pointBoxes) else {
                    print("[digtest] no ground under feet yet (still falling/streaming), waiting"); fflush(stdout)
                    simDigTimer = 4   // retry in ~2 s
                    break
                }
                let target = hit.under
                let before = client.world.nodeId(target)
                performDig(dir: SIMD3(0, -1, 0))                       // prediction + immediate remesh
                let after = client.world.nodeId(target)               // same tick, before any server reply
                simDigPredictedAir = after == WorldMap.CONTENT_AIR && before != WorldMap.CONTENT_AIR
                print("[digtest] target=\(target) before=\(before) afterSameTick=\(after) predictedAir=\(after == WorldMap.CONTENT_AIR) remeshCooldown=\(remeshCooldown)"); fflush(stdout)
                simDigPhase = 2; simDigTimer = 0
            case 2 where simDigTimer > 1:
                print("[digtest] RESULT dug node went to air within the dig call (no server wait) and a remesh was scheduled for the next tick (#179 prediction is synchronous) pass=\(simDigPredictedAir)"); fflush(stdout)
                // Put the sky platform's block back: this dig once removed
                // (0,120,0) for real and every later teleport there fell through.
                client.sendChat("/setblock 0,120,0 mcl_core:stone")
                simDigPhase = 99
            default: break
            }
        }
        // -vrdev.chordDropTest 1: right trigger + grip together drops the
        // wielded stack like desktop Q (#341), and neither dig nor place leaks
        // through while the chord is held. Then a lone one-frame grip tap must
        // still come out of the gate as a place press (the chord wait replays it).
        if UserDefaults.standard.bool(forKey: "vrdev.chordDropTest"), client.objects.localPlayerId != 0, atlasBuilt {
            simDigTimer += Double(dt)
            let m = client.inventory["main"] ?? []
            let cobble = m.reduce(0) { $0 + (($1?.name == "mcl_core:cobble") ? ($1?.count ?? 0) : 0) }
            switch simDigPhase {
            case 0 where simDigTimer > 2:
                client.sendChat("/grantme all"); client.sendChat("/clearinv"); client.sendChat("/giveme mcl_core:cobble 10")
                simTeleportToPad()
                simDigPhase = 1; simDigTimer = 0
            case 1 where simDigTimer > 6 && player.physics().grounded:
                guard let slot = m.firstIndex(where: { $0?.name == "mcl_core:cobble" }) else {
                    if simDigTimer > 15 { print("[chorddrop] RESULT no cobble given pass=false"); fflush(stdout); simDigPhase = 9 }
                    break
                }
                client.setWieldIndex(slot)
                simChordPreIds = Set(client.objects.snapshot().filter { $0.name == "__builtin:item" }.map { $0.id })
                print("[chorddrop] holding chord with \(cobble) cobble in slot \(slot)"); fflush(stdout)
                simChordLeak = 0; simChordHold = true
                simDigPhase = 2; simDigTimer = 0
            case 2 where simDigTimer > 0.4:
                simChordHold = false
                simDigPhase = 3; simDigTimer = 0
            case 3 where simDigTimer > 2:
                let feet = player.physics().feet
                // Any new cobble item, wherever it landed: VoxeLibre throws the drop
                // forward and it can sail off the small spawn pad.
                let drops = client.objects.snapshot().filter { $0.name == "__builtin:item" && !simChordPreIds.contains($0.id) && ($0.wieldItem.hasPrefix("mcl_core:cobble") || $0.textures.first?.hasPrefix("mcl_core:cobble") == true) }
                for d in client.objects.snapshot() where d.name == "__builtin:item" && simd_distance(d.pos, feet) < 30 {
                    print("[chorddrop] item id=\(d.id) wield=\(d.wieldItem) tex=\(d.textures.first ?? "") dist=\(simd_distance(d.pos, feet))"); fflush(stdout)
                }
                print("[chorddrop] after chord: cobble left=\(cobble) nearby drops=\(drops.count) leakFrames=\(simChordLeak)"); fflush(stdout)
                simScratchCount = (cobble == 0 && !drops.isEmpty && simChordLeak == 0) ? 1 : 0
                simPostGatePlace = 0; simTapPlace = true
                simDigPhase = 4; simDigTimer = 0
            case 4 where simDigTimer > 0.5:
                let tapOk = simPostGatePlace == 1
                print("[chorddrop] RESULT chordOk=\(simScratchCount == 1) tapPlaceFrames=\(simPostGatePlace) pass=\(simScratchCount == 1 && tapOk)"); fflush(stdout)
                simDigPhase = 9
            default: break
            }
        }
        // -vrdev.invPickTest 1: drive a real inventory pick-and-place headless
        // (#81). Gives cobble, opens the panel, then forces the hovered slot and
        // feeds a synthetic dig edge so the actual click logic (moveAction +
        // client-side prediction) runs -- proving the panel's slots map to real
        // inventory refs and a move predicts, without a controller ray.
        if UserDefaults.standard.bool(forKey: "vrdev.invPickTest"), client.objects.localPlayerId != 0, atlasBuilt {
            simInvTimer += Double(dt)
            switch simInvPhase {
            case 0 where simInvTimer > 2:
                client.sendChat("/grantme all"); client.sendChat("/clearinv"); client.sendChat("/giveme mcl_core:cobble 40")
                print("[invpick] gave cobble"); fflush(stdout)
                simInvPhase = 1; simInvTimer = 0
            case 1 where simInvTimer > 4:   // three paced chat commands
                if !inventoryOpen { toggleInventory() }
                print("[invpick] opened inventory, slots=\(invSlots.count)"); fflush(stdout)
                simInvPhase = 2; simInvTimer = 0
            case 2 where simInvTimer > 1:
                guard let src = invSlots.firstIndex(where: { $0.loc == "current_player" && $0.list == "main" && inventoryStack($0)?.name == "mcl_core:cobble" }),
                      let dst = invSlots.firstIndex(where: { $0.loc == "current_player" && $0.list == "main" && inventoryStack($0) == nil }) else {
                    print("[invpick] no source/empty slot yet, waiting"); fflush(stdout); simInvTimer = 0; break
                }
                let s = invSlots[src], d = invSlots[dst]
                let before = "src[\(s.index)]=\(inventoryStack(s)?.count ?? 0) dst[\(d.index)]=\(inventoryStack(d)?.count ?? -1)"
                var pick = GameInput.State(); pick.dig = true
                let rel = GameInput.State()                      // dig=false: resets the edge
                simInvHoverOverride = src; handleInventoryInput(rel); handleInventoryInput(pick)   // pick up
                let held = invHeld.map { "\($0.list)[\($0.index)]x\($0.count)" } ?? "nil"
                simInvHoverOverride = dst; handleInventoryInput(rel); handleInventoryInput(pick)   // place
                simInvHoverOverride = nil
                let after = "src[\(s.index)]=\(inventoryStack(s)?.count ?? 0) dst[\(d.index)]=\(inventoryStack(d)?.count ?? -1)"
                print("[invpick] RESULT before[\(before)] held=\(held) after[\(after)] moved=\(inventoryStack(d) != nil) pass=\(inventoryStack(d) != nil)"); fflush(stdout)
                simInvPhase = 99
            default: break
            }
        }
        #endif
        // Age out mapblocks left far behind and tell the server (#97). Runs
        // every tick, ahead of the UI early-outs below, the way Client::step
        // does. Evicted blocks are marked dirty so the remesh sweeps their
        // cached meshes (and re-meshes the neighbours' now-open faces).
        // Once a second, not every tick: expire() walks every loaded block
        // (up to 7500) and the age-out timeout is 600 s, so per-tick precision
        // buys nothing. Luanti's own unload sweep is on a coarse timer too.
        // Accumulate dt so blocks still age by real elapsed time.
        let feet = player.snapshot().feet
        expireAccum += dt
        if expireAccum >= 1.0 {
            let myBlock = WorldMap.blockPos(SIMD3(Int(floor(feet.x)), Int(floor(feet.y)), Int(floor(feet.z))))
            for b in client.unloadUnusedBlocks(dt: expireAccum, near: myBlock) { markBlockDirty(b) }
            expireAccum = 0
        }
        // Post-teleport terrain-loading notice: while the ground under the feet
        // is still unstreamed (IGNORE), tell the player the world is loading in
        // rather than leaving them in a silent void (#transition). Clears as soon
        // as the feet column loads, or after the safety cap runs out.
        if teleportSettle > 0 {
            teleportSettle -= dt
            let below = client.world.nodeId(SIMD3(Int(floor(feet.x)), Int(floor(feet.y - 0.5)), Int(floor(feet.z))))
            terrainLoading = below == WorldMap.CONTENT_IGNORE
            if !terrainLoading { teleportSettle = 0 }
        } else {
            terrainLoading = false
        }
        // Diegetic threshold vignette (HUD P8): a soft red edge cast as health runs
        // low (with a gentle throb near death), or a dark-blue edge as breath runs
        // out underwater, so the danger registers peripherally without reading the
        // stat columns. Death has its own full-screen cast, so skip then.
        var vig = SIMD4<Float>(0, 0, 0, 0)
        damageFlash = max(0, damageFlash - dt)
        if !dead, damageFlash > 0 {
            // Hit flash (#279): a strong red edge cast that fades over ~0.35 s.
            vig = SIMD4(0.85, 0.05, 0.05, min(0.7, damageFlash / 0.35 * 0.7))
        } else if !dead {
            if hp > 0 && hp <= 6 {
                let t = Float(6 - hp) / 6                               // 0..1 as hp 6 -> 0
                let throb = 0.82 + 0.18 * sin(Float(chatClock) * 6)     // faint pulse
                vig = SIMD4(0.75, 0.02, 0.02, min(0.6, 0.12 + 0.48 * t) * throb)
            } else if player.submerged() && breath <= 6 {
                let t = Float(6 - breath) / 6
                vig = SIMD4(0.0, 0.05, 0.14, min(0.55, 0.1 + 0.45 * t))
            }
        }
        player.setVignette(vig)
        var gi = input.poll()
        #if targetEnvironment(simulator)
        // -vrdev.flyTest 1: free_move parity (#291). Grant fly, double-tap
        // jump, hold jump 2 s (should rise ~8 nodes at walk speed), release
        // (should HOVER, not fall), then double-tap again to land.
        if UserDefaults.standard.bool(forKey: "vrdev.flyTest"), client.objects.localPlayerId != 0, atlasBuilt {
            simDigTimer += Double(dt)
            let f = player.physics().feet
            switch simDigPhase {
            case 0 where simDigTimer > 2:
                client.sendChat("/grantme all"); simTeleportToPad()
                simDigPhase = 10; simDigTimer = 0
            case 10 where simDigTimer > 6 && player.physics().grounded:
                simDigPhase = 1; simDigTimer = 0; simScratchInt = Int(f.y * 100)
                print("[flytest] start y=\(f.y) privs has fly=\(client.privileges.contains("fly"))"); fflush(stdout)
            case 1:   // tap, release, tap = double-tap within 0.35 s
                gi.jump = simDigTimer < 0.05 || (simDigTimer > 0.12 && simDigTimer < 0.17)
                if simDigTimer > 0.3 { simDigPhase = 2; simDigTimer = 0 }
            case 2:   // hold jump 2 s: rise
                gi.jump = true
                if simDigTimer > 2 { simDigPhase = 3; simDigTimer = 0; print("[flytest] after 2 s of jump: y=\(f.y) flying=\(flying)"); fflush(stdout) }
            case 3:   // release 2 s: must hover
                if simDigTimer > 2 {
                    let rose = f.y - Float(simScratchInt) / 100
                    print("[flytest] RESULT rose=\(rose) hoverY=\(f.y) flying=\(flying) pass=\(flying && rose > 4)"); fflush(stdout)
                    simDigPhase = 4; simDigTimer = 0
                }
            case 4:   // double-tap again: land
                gi.jump = simDigTimer < 0.05 || (simDigTimer > 0.12 && simDigTimer < 0.17)
                if simDigTimer > 3 { print("[flytest] after toggle off: y=\(f.y) flying=\(flying) grounded=\(player.physics().grounded)"); fflush(stdout); simDigPhase = 5 }
            default: break
            }
        }
        #endif
        // Button-only dialog (bed sleep form): the player is frozen by the
        // server's physics override, so the inventory button (O) submits the
        // dialog's button to get up. Handled before anything else so a sleep
        // can't trap you.
        if let pf = pendingButtonForm {
            var press = gi.inventory && !prevInventory
            #if targetEnvironment(simulator)
            // Headless: nobody presses O. VoxeLibre's death screen is one of these
            // button-only forms, so auto-submit after 2 s or every harness after a
            // death runs (and screenshots) through the red cast.
            simDeadTimer += dt
            if simDeadTimer > 2 { press = true; simDeadTimer = 0 }
            #endif
            if press {
                client.sendPlayerFields(formname: pf.formname, fields: [pf.button: "", "quit": "true"])
                pendingButtonForm = nil; noticeText = nil
                print("[formspec] submitted \(pf.button) for \(pf.formname)"); fflush(stdout)
            }
            prevInventory = gi.inventory
            postEntities()
            return
        }
        // Kogane (the shoulder companion) gets first look at the input: while its
        // menu is open it swallows movement and interaction, and looking at it +
        // the trigger opens the menu instead of digging.
        // While the menu is open the game PAUSES (like Esc on desktop): render the
        // frozen world and the menu, but skip physics, movement, and interaction.
        if keyboardOpen {
            handleKeyboardInput(gi)
            postEntities()
            return
        }
        if updateKogane(&gi, dt: dt) {
            postEntities()
            return
        }
        // Right face buttons cycle the hotbar selection (X = prev, O = next).
        // Cycle within the server's hotbar size (HUD_SET_PARAM 1; VoxeLibre 9),
        // capped by our 9 wrist slots.
        let hb = max(1, min(client.hotbarItemCount, hotbar.count))
        if gi.hotbarNext && !prevHotbarNext { client.setWieldIndex((client.wieldIndex + 1) % hb); print("[hotbar] wield=\(client.wieldIndex)"); fflush(stdout) }
        if gi.hotbarPrev && !prevHotbarPrev { client.setWieldIndex((client.wieldIndex + hb - 1) % hb); print("[hotbar] wield=\(client.wieldIndex)"); fflush(stdout) }
        prevHotbarNext = gi.hotbarNext; prevHotbarPrev = gi.hotbarPrev
        // Sim-only: -vrdev.openInventory 1 opens the panel a few seconds in, so
        // its layout can be screenshotted without a controller. The whole aid
        // block is simulator-only: on device it was 14 UserDefaults reads per
        // tick (CFPreferences lock + string bridge each) for flags never set.
        simSceneTimer += Double(dt)
        #if targetEnvironment(simulator)
        if !inventoryOpen, simSceneTimer > 8, UserDefaults.standard.bool(forKey: "vrdev.openInventory"), atlasBuilt { toggleInventory(); simSceneTimer = -1e9 }
        // -vrdev.invCycle 1: open at 8 s, close at 16 s, reopen at 20 s, so the
        // [icon] released/reused layer counts show in the log (#296).
        if UserDefaults.standard.bool(forKey: "vrdev.invCycle"), atlasBuilt {
            if simInvCyclePhase == 0, simSceneTimer > 8, !inventoryOpen { toggleInventory(); simInvCyclePhase = 1 }
            else if simInvCyclePhase == 1, simSceneTimer > 16, inventoryOpen { let before = modelTexCount; toggleInventory(); print("[invcycle] closed: layers=\(before) free=\(freeModelLayers.count)"); fflush(stdout); simInvCyclePhase = 2 }
            else if simInvCyclePhase == 2, simSceneTimer > 20, !inventoryOpen { toggleInventory(); simInvCyclePhase = 3 }
            else if simInvCyclePhase == 3, simSceneTimer > 26 { print("[invcycle] RESULT reopened: layers=\(modelTexCount) free=\(freeModelLayers.count)"); fflush(stdout); simInvCyclePhase = 4 }
        }
        // Sim-only: -vrdev.fakeStation 1 opens a canned station formspec (labels +
        // a small list) so the #176 label rendering can be screenshotted headless.
        if !inventoryOpen, simSceneTimer > 8, UserDefaults.standard.bool(forKey: "vrdev.fakeStation"), atlasBuilt {
            seedFakePlayerInventory()
            let spec = "size[9,9]label[0.5,0.5;Cartography Table]label[2,2;Map]label[4,2;Paper]" +
                       "list[current_player;main;0,5;9,3;]list[current_player;main;0,8;9,1;8]"
            openFormspec(spec, ""); simSceneTimer = -1e9
        }
        // Sim-only: -vrdev.fakeAchieve 1 opens a VoxeLibre-shaped achievements
        // form (awards:awards: tabheader + textlist rows + an icon image[] + a
        // hypertext description) so the #339 read-only info-form render can be
        // screenshotted headless. A player form, so no node context.
        if !inventoryOpen, simSceneTimer > 8, UserDefaults.standard.bool(forKey: "vrdev.fakeAchieve"), atlasBuilt {
            let spec = "size[11,5]tabheader[0,0;tab;Advancements,Goals,Challenges;1;false;false]" +
                       "image[0.5,0.5;2,2;mcl_potions_effect_swiftness.png]" +
                       "textlist[4.75,0;6,5;awards;Acquire Hardware,Sleep in a Bed,Time to Farm!,Diamonds\\, Diamonds\\, Diamonds,The Lie,Hot Stuff,Local Brewery,The End?;1;false]" +
                       "hypertext[0.5,3;4,2;desc;<b>Acquire Hardware</b>\nSmelt an iron ingot.]"
            openFormspec(spec, "awards:awards"); simSceneTimer = -1e9
        }
        // Sim-only: -vrdev.fakeFurnace 1 opens VoxeLibre's real inactive furnace
        // formspec (mcl_furnaces/init.lua, formspec_version 4, per-slot
        // mcl_formspec_itemslot.png backgrounds at 1.25 spacing) so the slot
        // alignment Eric saw on device can be checked headless.
        if !inventoryOpen, simSceneTimer > 8, UserDefaults.standard.bool(forKey: "vrdev.fakeFurnace"), atlasBuilt {
            formspecContext = SIMD3(0, 0, 0)
            seedFakePlayerInventory()
            func slotBg(_ x: Float, _ y: Float, _ w: Int, _ h: Int, _ size: Float = 0.05) -> String {
                var out = ""
                for i in 0..<w { for j in 0..<h {
                    let sx = x + Float(i) * 1.25 - size, sy = y + Float(j) * 1.25 - size
                    out += "image[\(sx),\(sy);\(1 + size * 2),\(1 + size * 2);mcl_formspec_itemslot.png]"
                } }
                return out
            }
            // Active furnace (mcl_furnaces active_formspec): the fire + arrow are
            // [lowpart:N:fg composites, not the inactive plain-bg image. Use the
            // lit spec so the fire-gauge composite is exercised headless (#344).
            let spec = "formspec_version[4]size[11.75,10.425]label[0.375,0.375;Furnace]"
                + slotBg(3.5, 0.75, 1, 1) + "list[context;src;3.5,0.75;1,1;]"
                + "image[3.5,2;1,1;default_furnace_fire_bg.png^[lowpart:50:default_furnace_fire_fg.png]"
                + slotBg(3.5, 3.25, 1, 1) + "list[context;fuel;3.5,3.25;1,1;]"
                + "image[5.25,2;1.5,1;gui_furnace_arrow_bg.png^[lowpart:40:gui_furnace_arrow_fg.png^[transformR270]"
                + slotBg(7.875, 2, 1, 1, 0.2) + "list[context;dst;7.875,2;1,1;]"
                + "label[0.375,4.7;Inventory]"
                + slotBg(0.375, 5.1, 9, 3) + "list[current_player;main;0.375,5.1;9,3;9]"
                + slotBg(0.375, 9.05, 9, 1) + "list[current_player;main;0.375,9.05;9,1;]"
                + "image_button[0.325,1.95;1.1,1.1;craftguide_book.png;__mcl_craftguide;]"
            openFormspec(spec, "mcl_furnaces:furnace_0_0_0"); simSceneTimer = -1e9
        }
        // Sim-only: -vrdev.fakeAnvil 1 opens an anvil-style form (item lists + a
        // rename field + a button) to screenshot the #229 widget boxes headless.
        // A field needs a node context to submit, so stub one.
        if !inventoryOpen, simSceneTimer > 8, UserDefaults.standard.bool(forKey: "vrdev.fakeAnvil"), atlasBuilt {
            formspecContext = SIMD3(0, 0, 0)
            seedFakePlayerInventory()
            // Worn tool in input so the wear bar shows too; a craftitem output.
            client.world.setNodeInventoryForTest(SIMD3(0, 0, 0), list: "input",
                [Client.ItemStack(name: "mcl_tools:pick_iron", count: 1, wear: 30000)])
            client.world.setNodeInventoryForTest(SIMD3(0, 0, 0), list: "output",
                [Client.ItemStack(name: "mcl_tools:pick_iron", count: 1, wear: 0)])
            let spec = "formspec_version[4]size[11.75,10.425]label[4.125,0.375;Repair and Name]" +
                       "field[4.125,0.75;7.25,1;name;;Excalibur]" +
                       "list[context;input;1.625,2.6;1,1;]list[context;output;9.125,2.6;1,1;]" +
                       "button[4.125,1.9;3.5,0.8;setname;Rename]" +
                       "list[current_player;main;0.375,5.1;9,3;9]list[current_player;main;0.375,9.05;9,1;]"
            openFormspec(spec, ""); simSceneTimer = -1e9
        }
        // Sim-only: -vrdev.fakeChest 1 opens the chest form (Chest + Inventory
        // labels, item grids) to screenshot the #241 layout headless.
        if !inventoryOpen, simSceneTimer > 8, UserDefaults.standard.bool(forKey: "vrdev.fakeChest"), atlasBuilt {
            formspecContext = SIMD3(0, 0, 0)
            seedFakePlayerInventory()
            // Seed the chest's nodemeta with items so the nodemeta render path
            // (not just the player list) shows real icons headless (#254).
            var chest = [Client.ItemStack?](repeating: nil, count: 27)
            // Mix cube nodes (3D isometric icon path #255) with craftitems whose
            // inventory_image was never a node face (raw_iron, flint, boots...).
            // Those are the ones that came up blank on device: the icon used to
            // wait on the node atlas, so a chest-only craftitem stayed empty until
            // the next full rebuild. Seeding them here reproduces #254 headless.
            let seed = ["mcl_core:cobble", "mcl_core:dirt", "mcl_core:stone", "mcl_core:sand",
                        "mcl_raw_ores:raw_iron", "mcl_core:flint", "mcl_armor:boots_iron", "mcl_core:glass",
                        "mcl_copper:raw_copper", "mcl_core:tree", "mcl_mobitems:bone", "mcl_core:brick_block",
                        "mcl_core:iron_ingot", "mcl_farming:carrot_item", "mcl_mobitems:saddle", "mcl_core:andesite",
                        "mcl_core:coal_lump", "mcl_core:apple"]
            for (i, name) in seed.enumerated() where i < 27 { chest[i] = Client.ItemStack(name: name, count: 1, wear: 0) }
            client.world.setNodeInventoryForTest(SIMD3(0, 0, 0), list: "main", chest)
            // The server's formspec_prepend already carries the background9 stone
            // panel, so it gets prepended in openFormspec -- no need to inject one.
            // The spec is VoxeLibre's real one (mcl_chests/api.lua + mcl_formspec
            // get_itemslot_bg_v4): 27 image[] slot backgrounds ahead of each
            // list[], nodemeta: list refs and escaped/translated labels. A
            // simplified list[context;...] version rendered fine here while the
            // device showed an empty chest, so the aid has to match the wire.
            func slots(_ x: Double, _ y: Double, _ w: Int, _ h: Int) -> String {
                var out = ""
                for i in 0..<w { for j in 0..<h {
                    out += String(format: "image[%g,%g;1.1,1.1;mcl_formspec_itemslot.png]",
                                  x - 0.05 + Double(i) * 1.25, y - 0.05 + Double(j) * 1.25)
                } }
                return out
            }
            let e = "\u{1b}"
            let spec = "formspec_version[4]size[11.75,10.425]" +
                       "label[0.375,0.375;\(e)(c@#313131)\(e)(T@mcl_chests)Chest\(e)E\(e)(c@#fff)]" +
                       slots(0.375, 0.75, 9, 3) + "list[nodemeta:0,0,0;main;0.375,0.75;9,3;]" +
                       "label[0.375,4.7;\(e)(c@#313131)\(e)(T@mcl_chests)Inventory\(e)E\(e)(c@#fff)]" +
                       slots(0.375, 5.1, 9, 3) + "list[current_player;main;0.375,5.1;9,3;9]" +
                       slots(0.375, 9.05, 9, 1) + "list[current_player;main;0.375,9.05;9,1;]" +
                       "listring[nodemeta:0,0,0;main]listring[current_player;main]"
            openFormspec(spec, "mcl_chests:chest_0_0_0"); simSceneTimer = -1e9
        }
        // Sim-only: -vrdev.fakeFurnace 1 opens the active furnace form (fire gauge
        // + cook arrow via image[] with ^[lowpart) to screenshot #223 headless.
        if !inventoryOpen, simSceneTimer > 8, UserDefaults.standard.bool(forKey: "vrdev.fakeFurnace"), atlasBuilt {
            formspecContext = SIMD3(0, 0, 0)
            seedFakePlayerInventory()
            // Seed real craftitems in the item slots (not just the fire/arrow
            // images): src/dst are exactly the chest-only-craftitem icon case
            // that #254 left blank, so an empty furnace form never caught it.
            client.world.setNodeInventoryForTest(SIMD3(0, 0, 0), list: "src",
                [Client.ItemStack(name: "mcl_raw_ores:raw_iron", count: 3, wear: 0)])
            client.world.setNodeInventoryForTest(SIMD3(0, 0, 0), list: "fuel",
                [Client.ItemStack(name: "mcl_core:coal_lump", count: 8, wear: 0)])
            client.world.setNodeInventoryForTest(SIMD3(0, 0, 0), list: "dst",
                [Client.ItemStack(name: "mcl_core:iron_ingot", count: 2, wear: 0)])
            let spec = "formspec_version[4]size[11.75,10.425]label[0.375,0.375;Furnace]" +
                       "list[context;src;3.5,0.75;1,1;]" +
                       "image[3.5,2;1,1;default_furnace_fire_bg.png^[lowpart:40:default_furnace_fire_fg.png]" +
                       "list[context;fuel;3.5,3.25;1,1;]" +
                       "image[5.25,2;1.5,1;gui_furnace_arrow_bg.png^[lowpart:60:gui_furnace_arrow_fg.png^[transformR270]" +
                       "list[context;dst;7.875,2;1,1;]" +
                       "list[current_player;main;0.375,5.1;9,3;9]list[current_player;main;0.375,9.05;9,1;]"
            openFormspec(spec, ""); simSceneTimer = -1e9
        }
        // Sim-only: -vrdev.fakeBeacon 1 opens a beacon-style form (item_image[]
        // payment icons + image_button[] effect selector) to screenshot #232/#233.
        if !inventoryOpen, simSceneTimer > 8, UserDefaults.standard.bool(forKey: "vrdev.fakeBeacon"), atlasBuilt {
            formspecContext = SIMD3(0, 0, 0)
            seedFakePlayerInventory()
            let spec = "formspec_version[4]size[11.75,10.425]label[0.375,0.375;Beacon]" +
                       "item_image[1,2;1,1;mcl_core:diamond]item_image[2.25,2;1,1;mcl_core:emerald]" +
                       "item_image[3.5,2;1,1;mcl_core:iron_ingot]item_image[4.75,2;1,1;mcl_core:gold_ingot]" +
                       "image_button[1,3.5;1,1;mcl_potions_swift.png;swiftness;]" +
                       "image_button[2.25,3.5;1,1;mcl_potions_leaping.png;leaping;]" +
                       "list[current_player;main;0.375,5.1;9,3;9]list[current_player;main;0.375,9.05;9,1;]"
            openFormspec(spec, ""); simSceneTimer = -1e9
        }
        // Sim-only: -vrdev.fakeBrewing 1 opens the brewing form with its full-panel
        // background[] art (mcl_brewing_inventory.png) to screenshot #245 headless.
        if !inventoryOpen, simSceneTimer > 8, UserDefaults.standard.bool(forKey: "vrdev.fakeBrewing"), atlasBuilt {
            formspecContext = SIMD3(0, 0, 0)
            seedFakePlayerInventory()
            client.world.setNodeInventoryForTest(SIMD3(0, 0, 0), list: "fuel",
                [Client.ItemStack(name: "mcl_mobitems:blaze_powder", count: 4, wear: 0)])
            client.world.setNodeInventoryForTest(SIMD3(0, 0, 0), list: "input",
                [Client.ItemStack(name: "mcl_potions:river_water", count: 1, wear: 0)])
            let spec = "size[9,8.75]background[-0.19,-0.25;9.5,9.5;mcl_brewing_inventory.png]" +
                       "list[context;fuel;0.5,1.75;1,1;]list[context;input;2.5,0.5;1,1;]" +
                       "list[context;output;4.1,1.42;1,1;]list[context;output;5.05,0.75;1,1;]list[context;output;6.0,1.42;1,1;]" +
                       "list[current_player;main;0,4.75;9,3;9]list[current_player;main;0,8.0;9,1;]"
            openFormspec(spec, ""); simSceneTimer = -1e9
        }
        // Sim-only: -vrdev.fakeRain 1 feeds the exact mcl_weather rain spawner
        // (player-attached, size 4..8, box above the head) so #199 (giant bars)
        // and #201 (wrong texture) can be seen without the server's biome/outdoor
        // gate. Skips mcl_weather's has_rain/is_outdoor gate by feeding the
        // spawner locally (no server involved).
        // Sim aid (-vrdev.fakeSkybox 1): the End's SET_SKY as mcl_weather sends
        // it (type skybox, six mcl_playerplus_end_sky.png), through the real
        // packet path, so the cube-texture sky can be screenshotted (#290).
        if !fakeSkyboxSent, simSceneTimer > 8, UserDefaults.standard.bool(forKey: "vrdev.fakeSkybox"), atlasBuilt {
            fakeSkyboxSent = true
            let w = PacketWriter()
            w.u32(0xFF00_0000 | 0x00_0A08_0A).string16("skybox").u8(0)   // bgcolor #0A080A, no clouds
            w.u32(0).u32(0).string16("default")                           // fog tints
            w.u16(6); for _ in 0..<6 { w.string16("mcl_playerplus_end_sky.png") }
            client.simulateServerPacket(op: Op.toclientSetSky, payload: w.data)
            print("[sky] fakeSkybox sent"); fflush(stdout)
        }
        // -vrdev.audioTest 1: a 2D sound, then 1.5 s later a positional one --
        // the order that raised 'player started when in a disconnected state'
        // on device (#302). Unmuted launch needed (no -vrdev.mute).
        if UserDefaults.standard.bool(forKey: "vrdev.audioTest"), atlasBuilt, client.objects.localPlayerId != 0 {
            audioTestTimer += dt
            if audioTestPhase == 0, audioTestTimer > 3 {
                audioTestPhase = 1
                playSound(SoundSpec(id: -1, name: "player_damage", gain: 1.0, type: 0, pos: .zero, objectId: 0, loop: false, fade: 0, pitch: 1.0, ephemeral: true))
                print("[audiotest] 2D played"); fflush(stdout)
            } else if audioTestPhase == 1, audioTestTimer > 4.5 {
                audioTestPhase = 2
                let f = player.physics().feet
                playNodeSound("default_dirt_footstep", at: SIMD3(Int(floor(f.x)), Int(floor(f.y - 0.1)), Int(floor(f.z))))
                print("[audiotest] 3D played (no crash = pass)"); fflush(stdout)
            } else if audioTestPhase == 2, audioTestTimer > 6 {
                audioTestPhase = 3
                print("[audiotest] RESULT pass"); fflush(stdout)
            }
        }
        // -vrdev.digCapsTest 1: with the real VoxeLibre ITEMDEF/NODEDEF, print
        // what getDigParams says for pick/shovel/hand on dirt and stone, so the
        // hand fallback (#297) can be checked without a controller.
        if !digCapsTestDone, simSceneTimer > 8, UserDefaults.standard.bool(forKey: "vrdev.digCapsTest"), atlasBuilt, handItemName() != nil {
            digCapsTestDone = true
            // ITEMDEF tail check (#298): VoxeLibre sets place_param2 on crops/kelp,
            // wield_scale 1.8 on tools.
            for item in ["mcl_farming:wheat_1", "mcl_ocean:kelp_sand", "mesecons_noteblock:noteblock", "mcl_tools:pick_iron", "mcl_shields:shield", "mcl_core:dirt"] {
                print("[itemtail] \(item) place_param2=\(client.items.placeParam2(for: item).map(String.init) ?? "nil") wield_scale=\(client.items.wieldScale(for: item).x)"); fflush(stdout)
            }
            for node in ["mcl_core:dirt", "mcl_core:stone", "mcl_core:bedrock"] {
                guard let nid = client.nodes.id(for: node) else { continue }
                let g = client.nodes.groups(nid)
                var line = "[digcaps] \(node)"
                for tool in ["mcl_tools:pick_diamond", "mcl_tools:shovel_iron", "mcl_tools:sword_iron"] {
                    let tc = client.items.caps(for: tool)
                    let t = DigParams.params(groups: g, caps: tc)
                    var hc = client.items.handCaps()
                    if let hn = handItemName(), let h = client.items.caps(for: hn), !h.groupCaps.isEmpty { hc = h }
                    let h = DigParams.params(groups: g, caps: hc)
                    let chosen = t ?? h
                    line += " \(tool.split(separator: ":").last ?? ""):tool=\(t.map { String(format: "%.2f", $0.time) } ?? "nil")/final=\(chosen.map { String(format: "%.2f", $0.time) } ?? "undiggable")"
                }
                print(line); fflush(stdout)
            }
        }
        if !fakeRainSpawned, simSceneTimer > 8, UserDefaults.standard.bool(forKey: "vrdev.fakeRain"), atlasBuilt {
            fakeRainSpawned = true
            let sp = Client.ParticleSpawner(serverId: 990001, amount: 900, time: 0,
                posMin: SIMD3(-15, 20, -15), posMax: SIMD3(15, 25, 15),
                velMin: SIMD3(0, -20, 0), velMax: SIMD3(0, -15, 0),
                accMin: SIMD3(0, -0.8, 0), accMax: SIMD3(0, -0.8, 0),
                expMin: 1, expMax: 4, sizeMin: 4, sizeMax: 8,
                attachedId: client.objects.localPlayerId,
                texture: "weather_pack_rain_raindrop_1.png", collisionRemoval: true,
                collisionDetection: !UserDefaults.standard.bool(forKey: "vrdev.fakeRainNoCollide"))   // control run for #275
            client.onAddParticleSpawner?(sp)
            print("[fakeRain] spawned rain spawner"); fflush(stdout)
        }
        // With collision on, no drop may end up below the platform we stand on
        // (it would have had to pass through stone). Reports the count (#275).
        if fakeRainSpawned, UserDefaults.standard.bool(forKey: "vrdev.fakeRain") {
            fakeRainLogTimer += Double(dt)
            if fakeRainLogTimer > 3 {
                fakeRainLogTimer = 0
                // Only drops whose column actually has the platform count: the
                // spawn box is 30x30 and the platform is a small island in the sky.
                let floorY = Int(floor(player.physics().feet.y)) - 1
                let through = particles.filter { pt in
                    guard pt.pos.y < Float(floorY) else { return false }
                    let id = client.world.nodeId(SIMD3(Int(floor(pt.pos.x)), floorY, Int(floor(pt.pos.z))))
                    return id != WorldMap.CONTENT_AIR && id != WorldMap.CONTENT_IGNORE && client.nodes.isWalkable(id)
                }.count
                print("[fakeRain] particles=\(particles.count) fellThroughPlatform=\(through)"); fflush(stdout)
            }
        }
        // Sim-only: -vrdev.openKeyboard 1 pops the on-screen keyboard for a layout screenshot.
        if !keyboardOpen, simSceneTimer > 6, UserDefaults.standard.bool(forKey: "vrdev.openKeyboard"), atlasBuilt {
            openKeyboard(prefill: UserDefaults.standard.string(forKey: "vrdev.kbText") ?? "hello world", simple: UserDefaults.standard.bool(forKey: "vrdev.simpleKb")) { _ in }; simSceneTimer = -1e9   // -vrdev.kbText overrides (long text tests the tail); -vrdev.simpleKb 1 = the bug-note board
        }
        #endif
        if gi.inventory && !prevInventory { toggleInventory() }
        prevInventory = gi.inventory
        if gi.dismissChat && !prevDismissChat { dismissChat() }
        prevDismissChat = gi.dismissChat
        var move = gi.move
        var turn = gi.turn * Self.turnSpeed
        // Auto-walk only fills in when there's no real stick input (sim has a
        // phantom controller that reports zero), so a real stick overrides it.
        // Skip it while the menu is open so the player holds still.
        if simAutoWalk && !koganeMenuOpen && !inventoryOpen && move == SIMD2(0, 0) && turn == 0 {
            move = SIMD2(0, 1); turn = simAutoSneak ? 0 : 0.15
            if simAutoSneak { gi.sneak = true }   // -vrdev.sneakTest: creep straight ahead
        }
        // Freeze locomotion while a panel is open (inventory or a server
        // formspec): the stick aims the panel cursor, it shouldn't also walk or
        // turn the player. inventoryOpen is set for both.
        if inventoryOpen { move = SIMD2(0, 0); turn = 0; gi.jump = false; gi.lookYaw = 0 }
        // Normalize the move vector so diagonals aren't faster: keyboard sets
        // x and y to +/-1 each, giving a length of 1.41 diagonally. Clamp length
        // to 1 (a stick already inside the unit circle is untouched) (#231).
        let mlen = simd_length(move)
        if mlen > 1 { move /= mlen }
        // Forward = where you're looking (head gaze flattened to horizontal),
        // so pushing the stick forward walks toward your view, not a fixed
        // heading. Fall back to body yaw when looking straight up/down.
        var fwd = player.aim(); fwd.y = 0
        let hlen = simd_length(fwd)
        fwd = hlen > 1e-3 ? fwd / hlen : player.bodyForward()
        let right = SIMD3<Float>(fwd.z, 0, -fwd.x)       // right of fwd in Luanti's left-handed frame
        // Is the player's body in a liquid? Feet node = the water we swim/settle
        // in; eye node = fully submerged (head under). Water slows walking and
        // swaps gravity for a buoyant model (see PlayerState.buoyantVY).
        // Double-tap jump toggles free_move when the server granted "fly"
        // (Game::toggleFreeMove's privilege check); a single tap still jumps.
        if gi.jump && !flyPrevJump && !inventoryOpen {
            let now = ProcessInfo.processInfo.systemUptime
            if now - flyLastTap < 0.35, client.privileges.contains("fly") {
                flying.toggle(); flyLastTap = -10
                addChat(sender: "", text: flying ? "Flying on" : "Flying off")
                print("[fly] \(flying ? "on" : "off")"); fflush(stdout)
            } else { flyLastTap = now }
        }
        flyPrevJump = gi.jump
        let pre = player.snapshot()
        let inLiquid = liquidAt(pre.feet)
        let submerged = inLiquid && liquidAt(pre.feet + SIMD3(0, player.eyeHeight, 0))
        // Underwater tint keys off the EYE node alone (head under, which can
        // differ from feet-in-liquid), so the renderer casts the view blue only
        // when we're actually looking through water.
        // View post-effects (tint, blackout) key off the REAL tracked head so
        // they agree with each other and the audio listener; fall back to the
        // nominal eye before a head pose exists (sim). Gameplay buoyancy/breath
        // stays on the feet-based path (matches the server model).
        let viewEye = player.hasHead() ? player.rayOrigin() : pre.feet + SIMD3(0, player.eyeHeight, 0)
        let eyeSubmerged = liquidAt(viewEye)
        player.setSubmerged(eyeSubmerged)
        // Post-effect over the whole view: the camera node's NODEDEF colour
        // (water), OR opaque black when the head is inside a solid node. On AVP
        // the tracked head can lean past the collision box into a wall, and
        // visionOS's fixed near plane then clips through the terrain (see-through,
        // #60). Luanti's ClientMap::renderPostFx blacks out a camera inside a
        // solid node in first person, which both matches desktop and hides the
        // artifact. Use the REAL head (rayOrigin) so a room-scale lean counts.
        var fx = postEffectAt(viewEye)
        // Require the head to be solidly INSIDE (a 3cm inward margin) for two
        // consecutive ticks before blacking out, so tracking jitter at a node
        // face doesn't strobe. Only once a real head transform has arrived.
        if player.hasHead(), headDeepInSolid(player.rayOrigin()) {
            headSolidFrames += 1
        } else {
            headSolidFrames = 0
        }
        #if targetEnvironment(simulator)
        // The sim's fixed eye usually reads as inside a block, whose post-effect
        // tint would wash every headless screenshot. Drop it there (a genuine
        // underwater tint still comes through, since that isn't headSolidFrames).
        if headSolidFrames >= 2 { fx = .zero }
        #else
        if headSolidFrames >= 2 { fx = SIMD4(0, 0, 0, 1) }   // device: black out when the head is genuinely in a wall
        #endif
        player.setPostEffect(fx)
        if eyeSubmerged != wasSubmerged {
            wasSubmerged = eyeSubmerged
            // No local refill on surfacing: the server refills breath a point at
            // a time and reports each step (TOCLIENT_BREATH), and the bubbles
            // should follow that like desktop's hudbar does.
            print("[water] eye submerged -> tint \(eyeSubmerged ? "on" : "off")"); fflush(stdout)
        }
        // Send the same control bits the official client sends in PLAYERPOS:
        // the server derives the allowed speed from them (mcl_sprint raises the
        // physics override when it sees aux1 + up), and its authoritative
        // MOVE_PLAYER correction overrides any locally predicted speed that
        // doesn't match (#180). Directional bits follow the stick; aux1 = the
        // sprint grip.
        client.moveKeys = Client.moveControlBits(dx: move.x, dy: move.y, sprint: gi.fast)
        var speed = player.moveSpeed(fast: gi.fast, sneak: gi.sneak)
        // Movement resistance from the node the box is in (water 1 -> x0.5, lava
        // 7 -> molasses, cobweb 14 -> near-stop), from the server's per-node
        // move_resistance rather than the drawtype so plantlike cobwebs slow you
        // too (#211). Falls back to the flat liquid factor if a liquid reports 0.
        let resist = overlapResistance(feet: pre.feet)
        if resist > 0 { speed /= Float(1 + resist) }
        else if inLiquid { speed *= PlayerState.liquidSpeedFactor }
        var vel = (fwd * move.y + right * move.x) * speed
        // Slippery nodes (ice, slippery=3): Luanti scales the ground acceleration
        // by 1/(slippery+1), doubled when there's no stick input, so you glide
        // on and coast off (localplayer.cpp getSlipFactor). Off ice the stick
        // speed applies directly, as before, and the eased velocity resyncs.
        let phys0 = player.physics()
        var slippery = 0
        if phys0.grounded, !inLiquid {
            let under = SIMD3(Int(floor(phys0.feet.x)), Int(floor(phys0.feet.y - 0.1)), Int(floor(phys0.feet.z)))
            let uid = client.world.nodeId(under)
            if phys.isWalkable(uid) { slippery = phys.slipperyLevel(uid) }
        }
        if slippery >= 1 {
            let s = mlen < 0.01 ? slippery * 2 : slippery
            let inc = client.accelDefault * max(0.001, 1 / Float(s + 1)) * dt
            // LocalPlayer::accelerate clamps the LENGTH of the horizontal change,
            // not each axis: per-axis clamping made a diagonal glide stop ~1.4x
            // faster than the engine.
            let want = SIMD2(vel.x, vel.z) - slipVel
            let len = simd_length(want)
            slipVel += len > inc ? want * (inc / len) : want
            vel.x = slipVel.x; vel.z = slipVel.y
        } else {
            slipVel = SIMD2(vel.x, vel.z)
        }
        let dx = vel.x * dt, dz = vel.z * dt
        // Riding (#139): while the local player is attached to a vehicle, mirror
        // the vehicle's position instead of running our own locomotion/gravity
        // (which would leave the camera behind as the boat/horse moves). The
        // server owns the vehicle pos; we sit at parent.pos + the attach offset
        // rotated by the vehicle's yaw. Gated on a real server attach, so normal
        // play (attachParent 0) is untouched.
        if let lp = client.objects.entity(client.objects.localPlayerId), lp.attachParent != 0,
           let parent = client.objects.entity(lp.attachParent) {
            // Same rotation convention as the entity attach-follow, so a rider and
            // a passenger AO land in the same spot (not mirrored ones).
            let feet = ActiveObjects.attachedPosition(parent: parent.pos, yaw: parent.yaw, offset: lp.attachOffset)
            player.setPhysics(feet: feet, vy: 0, grounded: true)
        } else {
        player.integrate(worldVel: .zero, turn: turn, dt: dt)   // stick turn only; movement resolved below
        if gi.lookYaw != 0 { player.addYaw(gi.lookYaw) }        // mouse-look: a direct per-frame yaw delta
        if inLiquid {
            // Buoyant vertical model, but sweep BOTH axes through the same
            // collision as land so climbing out of water into a solid can't
            // embed you and suffocate you (#114), and swimming up under an
            // overhang stops at the ceiling instead of clipping through it
            // (#167). Settling onto the column floor falls out of the sweep.
            let (feet0, _, _) = player.physics()
            let vy = player.buoyantVY(dt: dt, submerged: submerged, swimUp: gi.jump)
            // Sweep server knockback here too (like the land branch): you can be
            // pushed by explosions/mobs in water, and — importantly — this decays
            // the impulse. Skipping it left an impulse taken underwater sitting
            // undecayed in _extVel until you surfaced, then firing as a lurch.
            let kb = player.takeExternalDelta(dt: dt)
            let r = collideMove(feet: feet0, delta: SIMD3(dx + kb.x, vy * dt, dz + kb.y), grounded: false)
            var newVy = vy
            if r.hitCeil && newVy > 0 { newVy = 0 }
            if r.hitFloor && newVy < 0 { newVy = 0 }
            player.setPhysics(feet: r.feet, vy: newVy, grounded: r.hitFloor)
        } else {
            // Luanti-style physics (localplayer.cpp / collision.cpp): gravity every
            // frame, jump sets vy, then sweep the player's box against walkable
            // node boxes per axis. Landing/ceilings come out of the sweep, and a
            // horizontal hit steps up rises <= stepHeight (slabs, stairs), so full
            // blocks still need a jump and you hit your head indoors.
            var (feet, vy, grounded) = player.physics()
            // Climbing = Luanti's centre-column sample, PLUS a jump-gated body grab
            // so you can catch a ladder whose lowest rung is a node above your feet
            // (the igloo shaft, #331) by pressing up while standing under/against it.
            let climbing = overlapsClimbable(feet: feet) || (gi.jump && climbGrab(feet: feet))
            if climbing {
                // On a ladder/vine: jump climbs, sneak descends, otherwise hover
                // (the fall is arrested). Gravity is suppressed, matching Luanti
                // localplayer.cpp's is_climbing branch (#209).
                let climbSpeed = client.speedClimb   // MOVEMENT's movement_speed_climb (#299)
                vy = gi.jump ? climbSpeed : (gi.sneak ? -climbSpeed : 0)
                grounded = false
            } else {
                // disable_jump on the node you stand on OR the one your feet are
                // in (cobweb, end portal) blocks the jump (localplayer.cpp) (#269).
                var jumpBlocked = false
                if gi.jump && grounded {
                    let fx = Int(floor(feet.x)), fz = Int(floor(feet.z)), fy = Int(floor(feet.y))
                    for y in [fy - 1, fy] {
                        let id = client.world.nodeId(SIMD3(fx, y, fz))
                        if id != WorldMap.CONTENT_IGNORE, (client.nodes.groups(id)["disable_jump"] ?? 0) != 0 { jumpBlocked = true; break }
                    }
                }
                if flying {
                    // free_move (localplayer.cpp applyControl, free_move branch):
                    // no gravity, jump rises and sneak sinks at walk speed,
                    // otherwise hover. Node collision still applies (no noclip).
                    let fs = player.moveSpeed(fast: false, sneak: false)
                    vy = gi.jump ? fs : (gi.sneak ? -fs : 0)
                    grounded = false
                } else {
                    if gi.jump && grounded && !jumpBlocked { vy = player.jumpNow; grounded = false }
                    vy -= player.gravityNow * dt
                }
            }
            // Diagnostic (#209 follow-up): when near a ladder/trapdoor, log whether
            // we flag it climbable and whether descent is happening, so the "can't
            // climb down the shaft" report can be pinned from a device log.
            climbLogTick += 1
            // Off by default now that the igloo climb is fixed (#331): the scan
            // below does 36 locked name() lookups + substring tests, too much for
            // the shipping per-tick path. Re-enable with -vrdev.climbLog to debug.
            if climbLogEnabled, climbLogTick % 12 == 0 {
                // Fire whenever a ladder/trapdoor is anywhere the body touches or
                // one node around it, so the log captures the approach (not just
                // the moment the feet land on it). Pins the "can't climb up" case.
                let fx = Int(floor(feet.x)), fz = Int(floor(feet.z))
                var near: String? = nil
                for dx in -1...1 { for dy in -1...2 { for dz in -1...1 {
                    let id = client.world.nodeId(SIMD3(fx + dx, Int(floor(feet.y)) + dy, fz + dz))
                    let nm = client.nodes.name(id)
                    if nm.contains("ladder") || nm.contains("trapdoor") { near = "\(nm)@(\(fx+dx),\(Int(floor(feet.y))+dy),\(fz+dz))" }
                } } }
                if let near {
                    print("[climb] climbing=\(climbing) grab=\(climbGrab(feet: feet)) vy=\(String(format: "%.2f", vy)) jump=\(gi.jump) sneak=\(gi.sneak) feet=(\(String(format: "%.2f", feet.x)),\(String(format: "%.2f", feet.y)),\(String(format: "%.2f", feet.z))) near=\(near)"); fflush(stdout)
                    // Once, dump the node column around the feet so the exact shaft
                    // layout (which cells are brick, air, ladder) is visible and the
                    // "can't reach the ladder" case can be solved, not guessed (#331).
                    if !climbColumnLogged {
                        climbColumnLogged = true
                        for y in stride(from: Int(floor(feet.y)) + 3, through: Int(floor(feet.y)) - 2, by: -1) {
                            var row = "[climbmap] y=\(y):"
                            for dz in -1...1 {
                                for dx in -1...1 {
                                    let nm = client.nodes.name(client.world.nodeId(SIMD3(fx + dx, y, fz + dz)))
                                        .replacingOccurrences(of: "mcl_core:", with: "").replacingOccurrences(of: "mcl_", with: "")
                                    row += " \(nm.isEmpty ? "air" : nm)"
                                }
                                row += " |"
                            }
                            print(row); fflush(stdout)
                        }
                    }
                }
            }
            let mdx = dx, mdz = dz
            let kb = player.takeExternalDelta(dt: dt)   // server knockback (PLAYER_SPEED), swept against walls
            let r = collideMove(feet: feet, delta: SIMD3(mdx + kb.x, vy * dt, mdz + kb.y), grounded: grounded, climbing: climbing)
            feet = r.feet
            // Sneak edge-glue (localplayer.cpp move(): "keep on top of last
            // walked node"): while sneaking on the ground, the player's centre is
            // clamped to the sneak node's box +- 0.49 x the box's full width
            // (sneak_max = getExtent() * 0.49), so
            // you can lean most of the box over an edge but never step off, and
            // the glue follows you along a fence line or a slab edge because the
            // nearest walkable node under the feet becomes the new sneak node
            // each tick. The old rule (all four footprint corners supported) froze
            // the player on fence tops and allowed no overhang at all.
            // Not gated on `grounded`: hanging most of the box over the edge,
            // the sweep can miss the floor for a tick (only a sliver overlaps),
            // and the glue is exactly what must catch that. It's the sneak node
            // itself (found under the feet last tick) that says we're on a ledge.
            let couldSneak = gi.sneak && !climbing && !inLiquid
            var hitFloor = r.hitFloor
            if couldSneak, let sn = sneakNode,
               abs(feet.x - (sn.box.lo.x + sn.box.hi.x) * 0.5) < 1.5, abs(feet.z - (sn.box.lo.z + sn.box.hi.z) * 0.5) < 1.5 {
                let yDiff = sn.box.hi.y - feet.y
                if yDiff < 0.05 {
                    let m = playerHW * 2 * 0.49
                    let cx = min(max(feet.x, sn.box.lo.x - m), sn.box.hi.x + m)
                    let cz = min(max(feet.z, sn.box.lo.z - m), sn.box.hi.z + m)
                    if cx != feet.x { feet.x = cx; slipVel.x = 0 }
                    if cz != feet.z { feet.z = cz; slipVel.y = 0 }
                }
                // "Move player to the maximal height when falling": a tick that
                // slipped a hair below the node top (box no longer overlapping
                // the floor) is put back on it, and counts as a landing.
                if yDiff > 0, yDiff < 0.05, vy <= 0 { feet.y = sn.box.hi.y + 1e-4; vy = 0; hitFloor = true }
            }
            sneakNode = couldSneak ? updateSneakNode(feet: feet) : nil
            if hitFloor {
                let impact = -vy
                if vy < 0 { reportFallDamage(impactSpeed: impact, feet: feet) }
                // bouncy (slime 44, beds 66): a landing faster than 3 node/s
                // reflects vy by bouncy/100 (collision.cpp collide_with). A
                // controllable (>0) bouncy node lets jump add a boost and sneak
                // damp the bounce by a third (localplayer.cpp) (#269).
                let under = SIMD3(Int(floor(feet.x)), Int(floor(feet.y - 0.1)), Int(floor(feet.z)))
                let bouncy = client.nodes.groups(client.world.nodeId(under))["bouncy"] ?? 0
                if bouncy != 0, impact > 3 {
                    vy = impact * Float(abs(bouncy)) / 100
                    grounded = false
                    if bouncy > 0 {
                        let js = player.jumpNow
                        if gi.jump, js > 0 { vy += js / (1 + vy * 2.8 / js) }
                        else if gi.sneak { vy *= 2.0 / 3.0 }
                    }
                } else { vy = 0; grounded = true }
            } else { grounded = false }
            if r.hitCeil && vy > 0 { vy = 0 }
            player.setPhysics(feet: feet, vy: vy, grounded: grounded)
        }
        }
        // A mob's killing blow puffs smoke instead of flashing (GenericCAO
        // PUNCHED -> createSmokePuff, sized by visual_size) (#306). VoxeLibre
        // ships mcl_particles_smoke.png; the engine's own smoke_puff.png isn't
        // server media.
        for puff in client.objects.takeDeathPuffs() {
            let sz = max(0.3, min(2, (puff.size.x + puff.size.y) * 0.5))
            for _ in 0..<6 {
                let j = SIMD3<Float>(.random(in: -0.2...0.2), .random(in: 0...0.4), .random(in: -0.2...0.2)) * sz
                spawnServerParticle(pos: puff.pos + j, vel: SIMD3(0, .random(in: 0.3...0.8), 0), size: sz * 4,
                                    life: 1.0, texture: "mcl_particles_smoke.png")
            }
        }
        // Footstep sounds, timed like the engine's view bobbing (camera.cpp):
        // the bob advances by dt * speed * 0.03 (speed in BS, capped at 70) and
        // a step plays at each half cycle, so cadence follows speed (~0.4 s
        // walking, ~0.3 s sprinting, ~1.3 s sneaking). Bobbing runs while
        // walking on ground, swimming, or climbing; a landing also plays a step
        // (PLAYER_REGAIN_GROUND). The node probed is getFootstepNodePos's:
        // feet node in liquid, 0.05 below the feet on ground, 0.5 below in air.
        let ph = player.physics()
        let dFeet = ph.feet - stepLastFeet
        stepLastFeet = ph.feet
        let spd = dt > 0 ? simd_length(dFeet) / dt : 0                     // nodes/s
        let hspd = dt > 0 ? simd_length(SIMD2(dFeet.x, dFeet.z)) / dt : 0
        let vspd = dt > 0 ? abs(dFeet.y) / dt : 0
        let teleported = spd > 40
        let climbingNow = overlapsClimbable(feet: ph.feet)
        let bobbing = !teleported && !flying
            && ((hspd > 1 && ph.grounded) || ((hspd > 1 || vspd > 1) && inLiquid) || (vspd > 1 && climbingNow))
        func stepNode() -> SIMD3<Int> {
            let dy: Float = inLiquid ? 0 : ph.grounded ? 0.05 : 0.5
            return SIMD3(Int(floor(ph.feet.x)), Int(floor(ph.feet.y - dy)), Int(floor(ph.feet.z)))
        }
        func playStep() { let n = stepNode(); stepCount += 1; playNodeSound(client.nodes.footstepSound(client.world.nodeId(n)), at: n) }
        if bobbing {
            let was = stepPhase
            stepPhase = (stepPhase + dt * min(spd * 10, 70) * 0.03).truncatingRemainder(dividingBy: 1)
            if was == 0 || (was < 0.5 && stepPhase >= 0.5) || (was > 0.5 && stepPhase <= 0.5) { cadenceStepCount += 1; playStep() }
        } else {
            stepPhase = 0
        }
        if ph.grounded && !stepWasGrounded && !teleported && !inLiquid { playStep() }   // landing
        stepWasGrounded = ph.grounded
        var s = player.snapshot()
        // Diagnostics only (the [clip]/heartbeat logs). Scan just a few nodes
        // under the feet, not the whole 300-deep column: this runs every tick and
        // clip detection only cares about the ground right below you (#167).
        let groundTop = groundHeight(x: Int(floor(s.feet.x)), z: Int(floor(s.feet.z)),
                                     near: Int(floor(s.feet.y)), maxDrop: 6)
        s = player.snapshot()
        // Send the head look direction (not locomotion yaw) so the server
        // streams blocks where we're actually looking. Without this it only
        // sends a cone in one fixed direction and everything else stays empty.
        let aim = player.aim()
        let headYaw = atan2(-aim.x, aim.z)   // Luanti: dir = (-sin yaw, 0, cos yaw)
        let headPitch = -asin(max(-1, min(1, aim.y)))
        // Velocity for PLAYERPOS (#270): the feet delta over the tick covers every
        // mover (walk, jump/fall, swim, climb, ride, knockback) without plumbing
        // each branch. A teleport (MOVE_PLAYER, respawn) shows up as one huge
        // delta, which the desktop client's m_speed never contains, so drop it.
        var posVel = SIMD3<Float>.zero
        if let pf = prevFeet, dt > 0 {
            let d = s.feet - pf
            if simd_length(d) < 5 { posVel = d / dt }
        }
        prevFeet = s.feet
        client.setPose(pos: s.feet, yaw: headYaw, pitch: headPitch, velocity: posVel)
        // 3D audio listener = the head; attached sounds follow their objects.
        // Avoid a degenerate HRTF basis when the gaze is near-vertical (forward
        // parallel to up): fall back to the horizontal body heading for forward.
        var listenFwd = aim
        if abs(aim.y) > 0.98 { let bf = player.bodyForward(); listenFwd = SIMD3(bf.x, 0, bf.z) }
        audio.setListener(pos: player.rayOrigin(), forward: listenFwd, up: SIMD3<Float>(0, 1, 0))
        for (sid, oid) in attachedSounds {
            if let e = client.objects.entity(oid) { audio.setPosition(id: sid, pos: e.pos) }
            else { attachedSounds.removeValue(forKey: sid) }
        }
        // Clipping diagnostics: log when the feet end up below where the ground
        // scan says we should be standing (sinking into terrain), and a periodic
        // heartbeat with the ground/grounded state.
        let (gnd, vy) = player.debugVertical()
        if let gt = groundTop {
            let stand = Float(gt) + 1
            // Only when the situation changes: the scan treats every solid as a
            // full cube, so standing on a snow layer / carpet / slab reads as
            // "below stand" every tick and one session logged 54k identical
            // lines (a print+fflush per frame). Key on column + rounded height.
            let key = SIMD4<Int32>(Int32(floor(s.feet.x)), Int32(floor(s.feet.z)), Int32(gt), Int32(s.feet.y * 4))
            if s.feet.y < stand - 0.6, key != clipLogKey {
                clipLogKey = key
                print("[clip] feet.y=\(s.feet.y) stand=\(stand) col=(\(Int(floor(s.feet.x))),\(Int(floor(s.feet.z)))) grounded=\(gnd) vy=\(vy) inLiquid=\(inLiquid) dt=\(dt)"); fflush(stdout)
            }
        }
        posLogTimer += Double(dt)
        if posLogTimer >= 5 { posLogTimer = 0
            let gts = groundTop.map { String($0) } ?? "nil"
            print("[session] pos \(s.feet) groundTop=\(gts) grounded=\(gnd) vy=\(vy) inLiquid=\(inLiquid)"); fflush(stdout) }
        // Underground the engine slides the sky and fog toward the "indoors"
        // colour scaled by how much sunlight the camera can see
        // (Sky::update, getBackgroundBrightness). Cheap stand-in: the day-bank
        // light at the head, smoothed over ~0.4 s so a cave mouth doesn't
        // flicker. 15 = open sky = untouched fog; 0 = deep cave = near black.
        do {
            let eye = s.feet + SIMD3(0, player.eyeHeight, 0)
            let n = SIMD3(Int(floor(eye.x)), Int(floor(eye.y)), Int(floor(eye.z)))
            let dayNib = client.world.nodeLight(n) & 15
            let target = Float(dayNib) / 15
            let k = min(1, dt / 0.4)
            skyBrightnessSmooth += (target - skyBrightnessSmooth) * k
        }
        player.setDaylight(client.daylight, timeOfDay: client.timeFraction, skyVisible: skyBrightnessSmooth)
        // Sun arcs east->overhead->west over the day; below the horizon at night.
        // The engine compresses the night to 0.415 of the cycle before turning
        // time into an angle (sky.cpp getWickedTimeOfDay), so the sun rises at
        // ~4980 and sets at ~19020, right when the daylight ramp starts/ends,
        // not at 6000/18000 two minutes after the world already got bright.
        // Orbit tilt 0 like the engine default (VoxeLibre doesn't set one).
        let a = (Self.wickedTimeOfDay(client.timeFraction) - 0.25) * 2 * .pi
        player.setSunDir(simd_normalize(SIMD3<Float>(cos(a), sin(a), 0)))

        // Both grips = screenshot. Suppress dig/place that frame so the gesture
        // doesn't also break/place a block.
        var act = gi
        #if targetEnvironment(simulator)
        if simChordHold { act.dig = true; act.place = true }
        if simTapPlace { act.place = true; simTapPlace = false }
        #endif
        if gi.snap && !prevSnap { screenshotFlag.request(); print("[shot] requested"); fflush(stdout) }
        if inventoryOpen { handleInventoryInput(gi); act.dig = false; act.place = false }   // trigger/grip belong to the panel
        else { invPrevDig = gi.dig; invPrevPlace = gi.place }
        prevSnap = gi.snap
        if gi.snap { act.dig = false; act.place = false }
        let pA = perf.now()
        handleInteraction(act, dt: dt)
        let pB = perf.now()
        stepSpawners(dt)
        stepParticles(dt)
        let pC = perf.now()
        postEntities()
        let pD = perf.now()
        perf.add("interact", pA, pB); perf.add("particles", pB, pC); perf.add("entities", pC, pD)

        remeshCooldown -= Double(dt)
        if dirty && remeshCooldown <= 0 && !meshing {
            dirty = false
            remeshCooldown = 0.4
            meshing = true
            scheduleRemesh(meshRef: s.meshRef)
        }
    }

    // Companion placement, body-relative: forward, left(-)/right(+), up(-)/down.
    // Above eye level and near-centre so it's easy to see and to gaze at.
    // Centred (no left/right offset), high overhead at ~65 deg elevation (25 deg
    // off straight-up), so you tilt up to look at it but not straight overhead.
    // Metric offset from the head at ~0.7m: fwd = 0.7*cos65, up = 0.7*sin65.
    private static let koganeFwd: Float = 0.30
    private static let koganeSide: Float = 0.0
    private static let koganeUp: Float = 0.63
    private static let koganeFocusCos: Float = 0.94   // ~20-degree gaze cone (was 0.86/31deg, widened before the position fix)

    /// Focus + menu state for the Kogane companion, run before movement so the
    /// menu can freeze the world and looking at the companion can steal the
    /// trigger. Mutates `gi`: clears it entirely while the menu is open.
    /// Returns true while the menu is open (the caller pauses the game then).
    @discardableResult
    private func updateKogane(_ gi: inout GameInput.State, dt: Float) -> Bool {
        koganeBob += dt
        chatClock += Double(dt)
        if koganeOpenCooldown > 0 { koganeOpenCooldown -= dt }
        // While dead, Kogane is disabled so the trigger goes to respawn (opening
        // the menu would swallow the trigger and pause the game, leaving you
        // stuck on the death screen).
        if dead {
            koganeMenuOpen = false; koganeFocused = false
            prevKoganeTrigger = gi.dig
            return false
        }
        // Focus: gaze direction vs the eye->companion direction, in world space.
        let gaze = simd_normalize(player.aim())
        let bf = player.bodyForward()                 // horizontal body forward
        let right = SIMD3<Float>(bf.z, 0, -bf.x)
        let up = SIMD3<Float>(0, 1, 0)
        let dir = simd_normalize(bf * Self.koganeFwd + right * Self.koganeSide + up * Self.koganeUp)
        koganeFocused = koganeSpriteVisible && simd_dot(gaze, dir) > Self.koganeFocusCos

        let trigger = gi.dig                          // right trigger (pinch too, later)
        let triggerEdge = trigger && !prevKoganeTrigger
        let menuBtnEdge = gi.koganeMenu && !prevKoganeMenuBtn   // right X: open the menu without looking up
        prevKoganeMenuBtn = gi.koganeMenu
        prevKoganeTrigger = trigger
        let cancel = gi.place || gi.menu
        let cancelEdge = cancel && !prevKoganeCancel
        prevKoganeCancel = cancel

        #if targetEnvironment(simulator)
        // No headset input in the sim: force focus so the companion is always
        // visible. The menu auto-opens (for a screenshot) only when the demo
        // default is set, so normal sim runs aren't blocked by the panel.
        koganeFocused = true
        if UserDefaults.standard.bool(forKey: "vrdev.koganeDemo") {
            koganeSimClock += dt
            // (skipped when the sim run is screenshotting the inventory panel instead)
            if koganeSimClock > 4 && !koganeMenuOpen && !UserDefaults.standard.bool(forKey: "vrdev.openInventory") { koganeMenuOpen = true; koganeOpenCooldown = 0.6 }
        }
        #endif

        if koganeMenuOpen {
            let navY = gi.menuNavY                      // either controller's stick
            if navY > 0.5 && prevKoganeNav <= 0.5 { koganeSel = max(0, koganeSel - 1) }
            if navY < -0.5 && prevKoganeNav >= -0.5 { koganeSel = min(koganeOptions.count - 1, koganeSel + 1) }
            prevKoganeNav = navY
            let selEdge = gi.menuSelect && !prevKoganeSelect   // either controller's trigger
            prevKoganeSelect = gi.menuSelect
            // Ignore the trigger for a beat after opening so the same double-tap
            // that opened the menu can't immediately confirm "Exit to menu".
            if selEdge && koganeOpenCooldown <= 0 { activateKoganeOption() }
            // Cancel (grip/menu) OR the Kogane-activate button (right X) closes
            // it, same as Resume. The cooldown stops the opening press from
            // instantly re-closing it.
            else if cancelEdge || (menuBtnEdge && koganeOpenCooldown <= 0) { koganeMenuOpen = false; print("[kogane] menu closed"); fflush(stdout) }
            gi = GameInput.State()                    // swallow input; caller pauses the game
            return true
        }
        prevKoganeNav = 0
        if (koganeFocused && triggerEdge) || (menuBtnEdge && !inventoryOpen) {
            koganeMenuOpen = true; koganeSel = 0; koganeOpenCooldown = 0.6
            gi.dig = false                            // open the menu instead of digging
            print("[kogane] menu opened"); fflush(stdout)
        }
        return false
    }

    private func activateKoganeOption() {
        // Switch on the option label so reordering the list can't misfire an
        // action. Audio toggles keep the menu open (adjust both, then Resume);
        // everything else closes it.
        let opt = koganeSel >= 0 && koganeSel < koganeOptions.count ? koganeOptions[koganeSel] : "Resume"
        switch opt {
        case "Chat":
            koganeMenuOpen = false
            openKeyboard(prefill: "") { [weak self] t in self?.client.sendChat(t) }
        case "Bug note":
            koganeMenuOpen = false
            screenshotFlag.request()               // capture the bug as seen, before the keyboard covers it
            let ctx = bugNoteContext()               // pos/look/wield/shot, gathered now
            openKeyboard(prefill: "", saveOnDismiss: true, simple: true) { [weak self] t in self?.appendBugNote(t, context: ctx) }
        case "Exit to menu":
            koganeMenuOpen = false
            DispatchQueue.main.async { [weak self] in self?.appModel?.requestExit(.toMenu) }
        case "Quit game":
            koganeMenuOpen = false
            DispatchQueue.main.async { [weak self] in self?.appModel?.requestExit(.quit) }
        default:
            koganeMenuOpen = false   // Resume
        }
        print("[kogane] action \(opt)"); fflush(stdout)
    }

    /// Snapshot the world at the moment a bug note is invoked so the note is
    /// useful with little typing: position/facing, the node under the gaze, the
    /// wield item, and the screenshot filename just requested.
    private func bugNoteContext() -> String {
        func f(_ v: Float) -> String { String(format: "%.1f", v) }
        let s = player.snapshot()
        var parts = ["pos=(\(f(s.feet.x)),\(f(s.feet.y)),\(f(s.feet.z)))", "yaw=\(f(s.yaw)) pitch=\(f(s.pitch))"]
        if let hit = client.world.raycast(origin: player.rayOrigin(), dir: player.aim(), maxDist: currentReach,
                                          pointable: { _ in true }, boxes: pointBoxes) {
            parts.append("look=\(client.nodes.name(client.world.nodeId(hit.under)))@(\(hit.under.x),\(hit.under.y),\(hit.under.z))")
        }
        let wi = client.wieldIndex
        if wi >= 0, wi < hotbar.count, let w = hotbar[wi] { parts.append("wield=\(w)") }
        parts.append("shot=shot-\(Int(Date().timeIntervalSince1970)).png")
        return parts.joined(separator: " ")
    }

    /// Append a timestamped bug note (auto-context + typed text) to the SAME
    /// Documents/bug-notes.txt the launcher writes, so it pulls with the logs and
    /// screenshots. Empty typed text still records the context + screenshot.
    private func appendBugNote(_ text: String, context: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = "[\(stamp)] \(context)" + (body.isEmpty ? "\n" : " -- \(body)\n")
        guard let data = line.data(using: .utf8) else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("bug-notes.txt")
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile(); try? fh.write(contentsOf: data); try? fh.close()
        } else { try? data.write(to: url) }
        noticeText = "Bug note saved"
        noticeExpiry = ProcessInfo.processInfo.systemUptime + 2.5   // a quick confirmation, not a sticky banner
        print("[bugnote] \(context) -- \(body)"); fflush(stdout)
    }

    /// Resolve a PLAY_SOUND spec's base name to a concrete .ogg in the media
    /// store and start it. Logs when the file isn't present so an unheard sound is
    /// diagnosable (the .ogg either wasn't announced or isn't downloaded yet).
    /// Play a node's "dug" sound locally when we break it. Luanti plays dig/dug
    /// sounds client-side (the server doesn't send them), so without this a break
    /// is silent. The name is a sound group; resolveSound picks a variant.
    private func playDugSound(id: UInt16, at node: SIMD3<Int>) {
        playNodeSound(client.nodes.dugSound(id), at: node)
        // No haptic here on purpose: at mining pace even a faint tick per block
        // was too much (bug notes 2026-09-22/23). Haptics are for things that
        // happen TO the player: damage and knockback.
    }
    /// Play a node sound group positionally at a node (dig loop / dug on break).
    private func playNodeSound(_ name: String?, at node: SIMD3<Int>) {
        guard let name, !name.isEmpty else { return }
        let pos = SIMD3<Float>(Float(node.x) + 0.5, Float(node.y) + 0.5, Float(node.z) + 0.5)   // node centre in our [g,g+1] grid (built locally, so gridShift is not applied)
        let g = client.nodes.soundGain(name)   // the NODEDEF's gain/pitch for this sound (#280)
        playSound(SoundSpec(id: -1, name: name, gain: g.gain, type: 1, pos: pos,
                            objectId: 0, loop: false, fade: 0, pitch: g.pitch, ephemeral: true))
    }
    private var digSoundTimer: Float = 0
    private var stepPhase: Float = 0          // view-bobbing phase that times footsteps (camera.cpp)
    private var stepLastFeet = SIMD3<Float>(0, 0, 0)
    private var stepWasGrounded = true
    private var stepCount = 0              // footsteps played (read by -vrdev.stepTest)
    private var cadenceStepCount = 0       // of those, cadence (not landing) steps
    private var climbLogTick = 0            // rate-limit the [climb] diagnostic
    private var climbColumnLogged = false         // one-shot [climbmap] node-column dump (#331)
    private lazy var climbLogEnabled = UserDefaults.standard.bool(forKey: "vrdev.climbLog")   // opt-in ladder diagnostic (read once)

    private func playSound(_ spec: SoundSpec) {
        guard let file = client.media.resolveSound(spec.name) else {
            print("[audio] no media for '\(spec.name)' (not announced or not yet downloaded)"); fflush(stdout)
            return
        }
        guard let data = client.media.bytes(file) else {
            print("[audio] '\(file)' not yet downloaded for '\(spec.name)'"); fflush(stdout)
            return
        }
        if audioResolveLogged.insert(spec.name).inserted {
            print("[audio] resolve '\(spec.name)' -> \(file) (\(data.count) bytes)"); fflush(stdout)
        }
        // Positional (type 1) and object-attached (type 2) sounds are real 3D
        // sources; local sounds (type 0) play flat 2D. Positions arrive already
        // shifted into our grid by Client.gridShift.
        var pos: SIMD3<Float>? = nil
        if spec.type == 2 {
            // Bind the id->object mapping even if the object hasn't streamed in
            // yet, so setPosition upgrades it to 3D once it arrives (else it'd
            // stay flat 2D forever). Start at the object's pos, or spec.pos as a
            // best-guess origin until the first UPDATE_POSITION.
            if spec.id > 0 { attachedSounds[spec.id] = spec.objectId }   // ephemerals (id -1) start at the mob and play out (#280)
            pos = client.objects.entity(spec.objectId)?.pos ?? spec.pos
        } else if spec.type != 0 {
            pos = spec.pos
        }
        audio.play(spec: spec, data: data, file: file, pos: pos)
    }

    /// Right trigger + right grip pressed together drops the wielded stack, like
    /// desktop Q (sneak held: just one item; game.cpp dropSelectedItem). There's
    /// no spare button on the Sense controllers, so it's a chord (#341). A lone
    /// dig or place press is held back for chordWindow so a near-simultaneous
    /// chord doesn't also dig or place first; after the drop both buttons stay
    /// blanked until both are released.
    private func gateDropChord(_ gi: inout GameInput.State, dt: Float) {
        if gi.dig && gi.place && !dropChordLatched {
            dropChordLatched = true; chordWait = 0
            dropWielded(single: gi.sneak)
        }
        if dropChordLatched {
            if !gi.dig && !gi.place { dropChordLatched = false }
            gi.dig = false; gi.place = false
        } else if chordWait > 0 {
            chordWait -= dt
            if gi.dig || gi.place {
                if chordWait > 0 { gi.dig = false; gi.place = false }   // still waiting for the partner
                else { chordWait = 0 }                                  // no partner: let the press through
            } else {
                // Released inside the window: replay it as a one-frame press so
                // a quick tap still digs or places.
                gi.dig = chordPendingDig; gi.place = !chordPendingDig; chordWait = 0
            }
        } else if (gi.dig && !prevDig) || (gi.place && !prevPlace) {
            chordWait = Self.chordWindow; chordPendingDig = gi.dig
            gi.dig = false; gi.place = false
        }
    }

    private func dropWielded(single: Bool) {
        let w = client.wieldIndex
        guard w >= 0, w < hotbar.count, hotbar[w] != nil else { return }
        if let dn = digNode { client.sendInteract(action: 1, under: dn, above: digAbove); digNode = nil; digElapsed = 0 }
        client.sendInventoryAction(Client.dropAction(count: single ? 1 : 0,
            from: Client.InvRef("current_player", "main", w)))
        print("[drop] chord dropped \(single ? "one" : "stack") of \(hotbar[w] ?? "") from slot \(w)"); fflush(stdout)
    }

    private func handleInteraction(_ gi: GameInput.State, dt: Float) {
        var gi = gi
        // Dead: no digging/placing; any action button respawns (no text death
        // screen yet, so the red cast + this is the whole death UX for now).
        if dead {
            var btn = gi.jump || gi.place || gi.dig || gi.menu
            #if targetEnvironment(simulator)
            // Headless runs have no button to press: respawn automatically so a
            // harness never runs (and screenshots) through the red death cast.
            // (A bounce/ice test once walked the sim player into a cave, and
            // every run after that was dead without anyone noticing.)
            simDeadTimer += dt
            if simDeadTimer > 2 { btn = true; simDeadTimer = 0 }
            #endif
            if btn && !prevRespawnBtn { client.sendRespawn(); print("[death] sent respawn"); fflush(stdout) }
            prevRespawnBtn = btn
            updateDig(false, dt: dt)   // ensure any in-progress dig is released
            prevPlace = gi.place
            return
        }
        prevRespawnBtn = false
        gateDropChord(&gi, dt: dt)
        // game.cpp updateInteractTimers: both count down every frame, not only
        // while the trigger is held at something.
        if nodigDelay > 0 { nodigDelay -= dt }
        if objectHitDelay > 0 { objectHitDelay -= dt }
        // Releasing after an instant dig clears the delay so tapping through
        // torches and grass isn't sticky ("Remove e.g. torches faster when
        // clicking instead of holding dig button").
        if !gi.dig && prevDig && digInstantly { nodigDelay = 0; digInstantly = false }
        #if targetEnvironment(simulator)
        if simChordHold && (gi.dig || gi.place) { simChordLeak += 1 }
        if gi.place { simPostGatePlace += 1 }
        #endif
        // A "usable" item (has on_use: egg, snowball, ender pearl, bow) throws/
        // uses on the attack-button PRESS, and that takes priority over digging
        // (Luanti game.cpp: usable && DIG pressed -> INTERACT_USE). The pointed
        // thing is the aimed node, or nothing when you throw into the air.
        let wield = client.wieldIndex
        let wieldName = (wield >= 0 && wield < hotbar.count) ? hotbar[wield] : nil
        if let wieldName, client.items.isUsable(wieldName) {
            if let dn = digNode { client.sendInteract(action: 1, under: dn, above: digAbove); digNode = nil; digElapsed = 0 }  // cancel any dig
            if gi.dig && !prevDig {
                let hit = client.world.raycast(origin: player.rayOrigin(), dir: player.aim(), maxDist: currentReach,
                                               pointable: client.nodes.isPointable, boxes: pointBoxes)
                client.sendInteract(action: 4, under: hit?.under, above: hit?.above)   // INTERACT_USE
                print("[use] \(wieldName) (throw)"); fflush(stdout)
            }
        } else {
            // Melee: if the aim hits a mob nearer than any node, punch it on the
            // attack press (Luanti: object punch = INTERACT_START_DIGGING with the
            // pointed object). Only raycast nodes when there's an entity to beat,
            // so the common no-mob case stays a single raycast.
            // While a dig is under way the engine stops looking for objects
            // (game.cpp: look_for_object = !btn_down_for_dig), so a mob walking
            // through the ray doesn't reset the crack and eat a punch.
            let o = player.rayOrigin(), a = player.aim()
            let digging = gi.dig && prevDig && digNode != nil
            let obj = digging ? nil : client.objects.raycastEntity(origin: o, dir: a, maxDist: currentReach)
            let nodeHit = obj != nil ? client.world.raycast(origin: o, dir: a, maxDist: currentReach,
                                                            pointable: client.nodes.isPointable, boxes: pointBoxes) : nil
            let nodeDist: Float = nodeHit.map { simd_length((SIMD3<Float>($0.under) + SIMD3(0.5, 0.5, 0.5)) - o) } ?? .infinity
            if let obj, obj.dist <= nodeDist {
                if let dn = digNode { client.sendInteract(action: 1, under: dn, above: digAbove); digNode = nil; digElapsed = 0 }
                // game.cpp handlePointingAtObject: while the trigger is held, a
                // punch is reported whenever object_hit_delay (0.2 s, counting
                // down every tick) has run out, so spam-clicking can't beat the
                // hold rate; any punch holds off digging for 0.15 s. mcl_mobs'
                // 0.5 s invulnerability paces the actual damage (#284).
                if gi.dig {
                    if objectHitDelay <= 0 {
                        objectHitDelay = 0.2
                        nodigDelay = max(nodigDelay, 0.15)
                        client.sendInteract(action: 0, objectId: obj.id)
                        // Immediate hit feedback (#149); flash() skips immortal
                        // objects (armor stands, item frames), which take no damage.
                        client.objects.flash(obj.id, seconds: 0.25)
                        print("[melee] punch object \(obj.id)"); fflush(stdout)
                    } else if !prevDig {
                        nodigDelay = max(nodigDelay, 0.15)
                    }
                }
            } else {
                updateDig(gi.dig, dt: dt)
            }
        }
        prevDig = gi.dig
        client.sneakHeld = gi.sneak   // report sneak so mods see it + it can force placement (#178)
        // Place, with hold-to-repeat (#178): first press places, then while held
        // it repeats every repeat_place_time as long as performPlace pointed at
        // a node it placed against (not a rightclick/formspec/entity/air use).
        // Sneak-place also repeats (build a wall).
        if gi.place && !prevPlace {
            placeRepeatArmed = performPlace(sneak: gi.sneak)
            placeRepeatTimer = Self.placeRepeatTime
        } else if gi.place && placeRepeatArmed {
            placeRepeatTimer -= dt
            if placeRepeatTimer <= 0 {
                placeRepeatArmed = performPlace(sneak: gi.sneak)
                placeRepeatTimer = Self.placeRepeatTime
            }
        } else if !gi.place {
            placeRepeatArmed = false
        }
        prevPlace = gi.place
        updateEat(dt: dt, gripHeld: simGripOverride ?? gi.place)   // hold grip on food to eat (#173); also mirrors RMB bit
        client.digHeld = gi.dig                  // LMB control bit: mcl_playerplus reads control.LMB
        client.jumpHeld = gi.jump                // jump bit: horse jump, boat dismount (#270)
        // Sim aid: periodically dig straight down on the local dev world to
        // exercise the dig loop without a controller. Off by default (it chews
        // up the world); flip to verify.
        if simAutoDig {
            autoDigTimer += Double(dt)
            if autoDigTimer >= 2.0 { autoDigTimer = 0; performDig(dir: SIMD3(0, -1, 0)) }
        }
    }

    /// Hold-to-dig: while the trigger is down and aimed at a node, accumulate
    /// dig time (the crack overlay reads digElapsed/digTime). Break on complete,
    /// re-target if the aim moves to a different node, and send stop on release.
    private func updateDig(_ digging: Bool, dt: Float) {
        guard digging else {
            if let dn = digNode { client.sendInteract(action: 1, under: dn, above: digAbove) }  // stop
            digNode = nil; digElapsed = 0
            return
        }
        guard let hit = client.world.raycast(origin: player.rayOrigin(), dir: player.aim(), maxDist: currentReach, pointable: client.nodes.isPointable, boxes: pointBoxes) else {
            if let dn = digNode { client.sendInteract(action: 1, under: dn, above: digAbove) }
            digNode = nil; digElapsed = 0
            return
        }
        // Between digs the engine waits nodig_delay_timer (game.cpp): the last
        // dig time over the crack frame count, capped at 0.3 s, 0.15 s for
        // instant nodes, so holding the trigger across tall grass or torches
        // doesn't chain-delete them faster than desktop (#297).
        if nodigDelay > 0, digNode == nil { return }   // counted down in handleInteraction
        if digNode != hit.under {
            if let dn = digNode { client.sendInteract(action: 1, under: dn, above: digAbove) }  // stop old
            digNode = hit.under; digAbove = hit.above; digElapsed = 0
            let id = client.world.nodeId(hit.under)
            let dp = digParamsFor(id)
            digTime = dp.time; digGroup = dp.group
            client.sendInteract(action: 0, under: hit.under, above: hit.above)   // start digging
            // sound_dig only when the node is actually diggable (game.cpp);
            // bedrock with the wrong tool stays silent instead of chattering.
            if digTime >= 0 { playNodeSound(resolvedDigSound(id), at: hit.under) }
            digSoundTimer = 0
            print("[dig] start \(client.nodes.name(id)) wield=\(dp.wield) caps=\(dp.source) t=\(digTime) group=\(digGroup)"); fflush(stdout)
        } else {
            // handleDigging recomputes the params every frame: swapping to the
            // right tool mid-dig (or the node changing under us) retimes the
            // crack right away instead of after a re-aim.
            let dp = digParamsFor(client.world.nodeId(hit.under))
            digTime = dp.time; digGroup = dp.group
        }
        digElapsed += dt
        // Repeat the node's dig sound while mining (client-side, like Luanti).
        digSoundTimer += dt
        if digSoundTimer >= 0.33, digTime >= 0 {
            digSoundTimer = 0
            playNodeSound(resolvedDigSound(client.world.nodeId(hit.under)), at: hit.under)
        }
        if digTime >= 0 && digElapsed >= digTime {
            client.sendInteract(action: 2, under: hit.under, above: hit.above)   // completed
            let brokenId = client.world.nodeId(hit.under)                        // tile before removal
            applyDigPrediction(at: hit.under, id: brokenId)                       // local prediction
            spawnBreakParticles(at: hit.under, id: brokenId)
            playDugSound(id: brokenId, at: hit.under)
            markNodeDirty(hit.under); remeshCooldown = 0   // show the hole now, don't wait out the coalesce
            print("[dig] break \(hit.under)"); fflush(stdout)
            nodigDelay = digTime > 0 ? min(0.3, digTime / Float(max(1, crackTex.count))) : 0.15
            digInstantly = digTime == 0
            digNode = nil; digElapsed = 0
        }
    }

    private var nodigDelay: Float = 0     // game.cpp nodig_delay_timer
    private var digGroup: String? = nil   // the groupcap that won getDigParams (for "__group" dig sounds)

    /// Dig time for the node under the crosshair the way game.cpp handleDigging
    /// picks it: the wielded item's caps (an item with none inherits the hand's),
    /// and if THAT says not diggable, the hand's caps -- so a pickaxe still digs
    /// dirt at hand speed instead of not at all (#297). time < 0 = undiggable.
    private func digParamsFor(_ id: UInt16) -> (time: Float, group: String?, wield: String, source: String) {
        let groups = client.nodes.groups(id)
        let wield = client.wieldIndex
        let wieldName = (wield >= 0 && wield < hotbar.count) ? hotbar[wield] : nil
        // The real hand item first (survival vs creative caps), then the
        // ITEMDEF-wide guess until the "hand" list has arrived (#267).
        var hand = client.items.handCaps()
        var handSource = "hand"
        if let hn = handItemName(), let hc = client.items.caps(for: hn), !hc.groupCaps.isEmpty { hand = hc; handSource = hn }
        guard hand != nil || wieldName != nil else { return (0.55, nil, "empty", "flat") }   // no ITEMDEF yet
        if let wieldName, let wc = client.items.caps(for: wieldName), !wc.groupCaps.isEmpty,
           let r = DigParams.params(groups: groups, caps: wc) {
            return (r.time, r.group, wieldName, wieldName)
        }
        if let r = DigParams.params(groups: groups, caps: hand) { return (r.time, r.group, wieldName ?? "empty", handSource) }
        return (-1, nil, wieldName ?? "empty", handSource)
    }

    /// sound_dig, with the engine's "__group" placeholder resolved to
    /// default_dig_<winning group> (game.cpp handleDigging).
    private func resolvedDigSound(_ id: UInt16) -> String? {
        guard let name = client.nodes.digSound(id) else { return nil }
        if name == "__group" { return digGroup.map { "default_dig_\($0)" } }
        return name
    }

    private func performDig(dir: SIMD3<Float>? = nil) {
        guard let hit = client.world.raycast(origin: player.rayOrigin(), dir: dir ?? player.aim(), maxDist: currentReach, pointable: client.nodes.isPointable, boxes: pointBoxes) else { return }
        print("[dig] \(hit.under)"); fflush(stdout)
        client.sendInteract(action: 0, under: hit.under, above: hit.above)   // start
        client.sendInteract(action: 2, under: hit.under, above: hit.above)   // completed
        let brokenId = client.world.nodeId(hit.under)                        // tile before removal
        applyDigPrediction(at: hit.under, id: brokenId)                      // local prediction
        spawnBreakParticles(at: hit.under, id: brokenId)
        playDugSound(id: brokenId, at: hit.under)
        markNodeDirty(hit.under); remeshCooldown = 0
    }

    // Hold-to-eat (#173): VoxeLibre eating is a HOLD, not a click. mcl_hunger sets
    // is_eating on the item's on_secondary_use (the grip press already sends that
    // via performPlace), then ticks a ~1.6s delay off the HELD place/RMB key
    // before the bite lands. So while the right grip stays held on a wielded food,
    // report the place bit in PLAYERPOS and re-arm the activate every 0.5s; bites
    // land and repeat while held. Gated to the food/eatable group so holding grip
    // on a tool or block does nothing. (The panel steals the grip when open, so
    // this can't fire while an inventory/chest is up.)
    private var eatKick: Float = 0
    /// Fall damage the way Luanti's client does it (clientenvironment.cpp
    /// step): on a floor collision, the vertical speed lost beyond a 14 node/s
    /// tolerance is the damage in hp (1 hp per node/s), scaled by the landed
    /// node's fall_damage_add_percent group (hay/honey -80, slime -100, beds
    /// -50 ...). Sent as TOSERVER_DAMAGE; the server decides whether it
    /// applies (#264). Water never gets here: the liquid branch has no floor hit.
    static let fallTolerance: Float = 14
    private func reportFallDamage(impactSpeed: Float, feet: SIMD3<Float>) {
        guard impactSpeed > Self.fallTolerance else { return }
        let below = SIMD3(Int(floor(feet.x)), Int(floor(feet.y - 0.1)), Int(floor(feet.z)))
        let addPercent = client.nodes.groups(client.world.nodeId(below))["fall_damage_add_percent"] ?? 0
        let preFactor = 1 + Float(addPercent) / 100
        guard preFactor > 0 else { return }
        let speed = preFactor * impactSpeed
        guard speed > Self.fallTolerance else { return }
        let damage = Int((speed - Self.fallTolerance + 0.5).rounded(.down))
        guard damage > 0 else { return }
        print("[fall] impact \(impactSpeed) node/s on \(client.nodes.name(client.world.nodeId(below))) (\(addPercent)%) -> \(damage) hp"); fflush(stdout)
        recentFallDamage = 1.0
        client.sendDamage(damage)
    }

    private func updateEat(dt: Float, gripHeld: Bool) {
        #if targetEnvironment(simulator)
        // The -vrdev.eatTest harness drives placeHeld itself; don't clobber it.
        if UserDefaults.standard.bool(forKey: "vrdev.eatTest") { return }
        #endif
        eatKick = max(0, eatKick - dt)
        // The RMB control bit mirrors the grip for EVERY wield, not just food.
        // VoxeLibre's bow, crossbow, trident, spear, spyglass and shield all
        // run off controls.register_on_hold/release(RMB), which reads
        // get_player_control() -- i.e. these PLAYERPOS bits. Gating the bit to
        // eatables silently disabled all of them (parity #263). Only the eat
        // re-arm below stays food-only.
        client.placeHeld = gripHeld
        let wi = client.wieldIndex
        guard gripHeld, wi >= 0, wi < hotbar.count, let name = hotbar[wi], client.items.isEatable(name) else { return }
        if eatKick <= 0 {
            client.sendInteract(action: 5, under: nil, above: nil)   // (re)arm on_secondary_use -> is_eating
            eatKick = 0.5
            print("[eat] hold \(name)"); fflush(stdout)
        }
    }

    /// Predict a placed node's param2 the way Luanti's client does (game.cpp
    /// nodePlacement), so oriented nodes (stairs, chests, torches, pumpkins)
    /// appear facing the right way instead of snapping a round-trip later (#178).
    /// Node coords and the player are in the same translated (non-mirrored) frame,
    /// so these differences match the server's. Colour/palette (colored variants)
    /// and torch wallmounted_rotate_vertical are left to the server's correction.
    private func predictedParam2(id: UInt16, nodepos: SIMD3<Int>, neighborpos: SIMD3<Int>, item: String? = nil) -> UInt8 {
        // game.cpp nodePlacement: an item's place_param2 wins over the
        // facedir/wallmounted derivation (VoxeLibre crops start at stage 1,
        // kelp/corals/lanterns carry their variant in param2) (#298).
        if let item, let p2 = client.items.placeParam2(for: item) { return UInt8(truncatingIfNeeded: p2) }
        let feet = player.snapshot().feet
        let pn = SIMD3(Int(floor(feet.x)), Int(floor(feet.y)), Int(floor(feet.z)))
        return WorldMap.placementParam2(pt2: client.nodes.paramType2(id),
                                        nodepos: nodepos, neighborpos: neighborpos, playerpos: pn)
    }

    /// Returns true when the grip was used against a node (placed, or used the
    /// wielded item on it), so the caller repeats it while the grip is held, as
    /// game.cpp's repeat_place_timer does for any item (#178). Object
    /// rightclicks, rightclickable nodes, meta formspecs, refused attached
    /// placements and air uses return false, so a held grip never re-opens a
    /// chest or re-toggles a door.
    @discardableResult
    private func performPlace(sneak: Bool = false, aim: SIMD3<Float>? = nil) -> Bool {
        let o = player.rayOrigin(), a = aim ?? player.aim()   // aim override: sim harnesses only
        let nodeHit = client.world.raycast(origin: o, dir: a, maxDist: currentReach, pointable: client.nodes.isPointable, boxes: pointBoxes)
        // Right-click on a nearby entity (horse, boat, villager, ...) is an object
        // rightclick, not a node place: this is how you mount a horse or trade.
        // Send INTERACT_PLACE with the pointed object when it's nearer than the
        // node under the gaze. Mirrors the melee path (which punches objects on
        // the dig button); without it grip only ever hit the node behind the mob.
        if let obj = client.objects.raycastEntity(origin: o, dir: a, maxDist: currentReach) {
            let nodeDist: Float = nodeHit.map { simd_length((SIMD3<Float>($0.under) + SIMD3(0.5, 0.5, 0.5)) - o) } ?? .infinity
            // A rightclickable NODE wins over an overlapping decorative entity:
            // VoxeLibre chests/furnaces are nodes with on_rightclick plus a visual
            // lid/flame ENTITY sitting right on them. #155 diverted the grip to
            // that entity (whose object-rightclick does nothing), so containers
            // wouldn't open (#166). Only rightclick the object when the node under
            // it isn't itself rightclickable (so mounting a horse on grass still works).
            let nodeRightclick = nodeHit.map { client.nodes.isRightclickable(client.world.nodeId($0.under)) } ?? false
            if obj.dist <= nodeDist, !nodeRightclick {
                client.sendInteract(action: 3, objectId: obj.id)   // rightclick object (mount horse, ...)
                print("[place] rightclick object \(obj.id)"); fflush(stdout)
                return false
            }
        }
        guard let hit = nodeHit else {
            // Nothing pointable in reach: still a right-click ("activate", the
            // engine's rightclick-air) so the item's on_secondary_use runs. That
            // is how a bucket dips into open water and food gets eaten while
            // looking at the sky: VoxeLibre's bucket ignores our pointed node
            // and raycasts server-side along the look we send (the gaze), with
            // liquids included, so the aim just has to land on a source.
            client.sendInteract(action: 5, under: nil, above: nil)
            // Diagnostic (#166): the pointable-filtered raycast found nothing, but
            // was there actually a node under the gaze that got skipped? Re-cast
            // ignoring pointability and report it, so a furnace that won't open
            // tells us whether it's a pointability parse (node present, skipped)
            // or a pure aim miss (nothing there).
            if let raw = client.world.raycast(origin: o, dir: a, maxDist: currentReach, pointable: { _ in true }, boxes: pointBoxes) {
                let rid = client.world.nodeId(raw.under)
                print("[place] activate (no pointed node); raw gaze node=\(client.nodes.name(rid)) id=\(rid) pointable=\(client.nodes.isPointable(rid)) rightclick=\(client.nodes.isRightclickable(rid))"); fflush(stdout)
            } else {
                print("[place] activate (no pointed node); raw gaze: nothing in reach"); fflush(stdout)
            }
            return false
        }
        // A node with a `formspec` in its metadata but NO on_rightclick (furnaces,
        // and other stations that set meta:formspec instead of a callback) is
        // opened CLIENT-side on rightclick in real Luanti -- the server never
        // pushes a SHOW_FORMSPEC for it. Do the same: open it and send no place,
        // so grip actually opens the furnace (#166). Rightclickable nodes fall
        // through to the server (their on_rightclick sends the formspec).
        // Sneaking forces placement instead of "use", so you can build against a
        // furnace/chest/door (Luanti: the use branches bail when SNEAK is up) (#178).
        // Game::nodePlacement does this for rightclickable nodes too: it sends
        // the use (so on_rightclick still runs) AND opens the meta formspec.
        // Shulker boxes (on_rightclick only animates the lid) and the grindstone
        // (on_rightclick only rewrites meta.formspec) rely on the client opening
        // the form; skipping it for rightclickable nodes meant they never opened.
        let hitId = client.world.nodeId(hit.under)
        if !sneak, let fs = client.world.nodeFormspec(hit.under) {
            if client.nodes.isRightclickable(hitId) { client.sendInteract(action: 3, under: hit.under, above: hit.above) }
            formspecContext = hit.under
            openFormspec(fs, "")
            print("[place] open node formspec \(client.nodes.name(hitId)) at \(hit.under)"); fflush(stdout)
            return false
        }
        // Local prediction: drop the wielded node into the empty neighbour now so
        // it appears instantly; the server's AddNode reconciles (and corrects
        // param2/rotation) a round-trip later. Only when the wield item is a
        // known node; tools/unknown items just wait for the server.
        // Right-click on a rightclickable node (door, chest, button, ...) is a
        // USE, not a placement -- Luanti runs on_rightclick and no node is placed.
        // Predicting a place there flashed a phantom block that the server then
        // "removed". Only predict a placement when the pointed node isn't
        // rightclickable (matching Luanti's place vs use branch).
        let underId = client.world.nodeId(hit.under)
        if !sneak, client.nodes.isRightclickable(underId) {
            client.sendInteract(action: 3, under: hit.under, above: hit.above)   // use, server runs on_rightclick
            formspecContext = hit.under   // a SHOW_FORMSPEC that follows refers to this node
            print("[place] use \(client.nodes.name(underId)) at \(hit.under) (no place)"); fflush(stdout)
            return false
        }
        let wi = client.wieldIndex
        let wield = wi >= 0 && wi < hotbar.count ? hotbar[wi] : nil
        // Which node to predict is the item's node_placement_prediction (the
        // engine's rule): usually the node itself, but "" for items whose
        // on_place decides (doors, beds, torches, buckets), where guessing put
        // the wrong node down for a round-trip. Unknown item: its own node.
        var predicted: String? = nil
        if let name = wield {
            if let p = client.items.prediction(for: name) { predicted = p.isEmpty ? nil : p }
            else if client.nodes.id(for: name) != nil { predicted = name }
        }
        if let name = wield, let pname = predicted, let id = client.nodes.id(for: pname), id != WorldMap.CONTENT_AIR {
            // If the pointed node is buildable_to (grass tuft, snow layer), the
            // block replaces IT; otherwise it lands in the empty neighbour. Only
            // predict when the target cell is itself replaceable, so we never
            // paint a phantom over a solid the server would reject (#178).
            let nodepos = client.nodes.isBuildableTo(client.world.nodeId(hit.under)) ? hit.under : hit.above
            // Don't place a walkable node inside your own body (game.cpp
            // nodePlacement): the standing node is the floor under the feet
            // (feet - 0.1 when grounded, else the feet node), and floor+1 /
            // floor+2 are where you are. The engine neither predicts nor sends
            // the INTERACT, and plays sound_place_failed instead (#268).
            if client.nodes.isWalkable(id) {
                let ph = player.physics()
                let standY = Int(floor(ph.feet.y - (ph.grounded ? 0.1 : 0)))
                let sx = Int(floor(ph.feet.x)), sz = Int(floor(ph.feet.z))
                if nodepos.x == sx && nodepos.z == sz && (nodepos.y == standY + 1 || nodepos.y == standY + 2) {
                    playNodeSound(client.items.placeFailedSound(for: name), at: nodepos)
                    print("[place] refused \(pname) at \(nodepos): inside the player (standing on y=\(standY))"); fflush(stdout)
                    return false
                }
            }
            client.sendInteract(action: 3, under: hit.under, above: hit.above)   // place
            // attached_node support check (game.cpp nodePlacement): a flower/
            // sapling/crop/rail needs a walkable node under it (an==3 or the
            // default), a hanging one needs the node above (an==4). Without the
            // support the server drops the node, so predicting it flickers (#340).
            // We handle only the Y-axis cases: wallmounted support (torches) and
            // the facedir an==2 case depend on a direction that's mirrored in our
            // frame, so leave those to the server rather than risk a false refuse.
            let an = client.nodes.groups(id)["attached_node"] ?? 0
            let pt2 = phys.pt2(id)
            let wallmounted = pt2 == 4 || pt2 == 10
            var support: SIMD3<Int>? = nil
            if an == 4 { support = SIMD3(nodepos.x, nodepos.y + 1, nodepos.z) }
            else if an == 3 || (an != 0 && an != 2 && !wallmounted) { support = SIMD3(nodepos.x, nodepos.y - 1, nodepos.z) }
            if let s = support, !phys.isWalkable(client.world.nodeId(s)) {
                playNodeSound(client.items.placeFailedSound(for: name), at: nodepos)
                print("[place] refused \(pname) at \(nodepos): attached_node(\(an)) support \(s) not walkable"); fflush(stdout)
                return false   // interact already reported; skip the local prediction
            }
            if client.nodes.isBuildableTo(client.world.nodeId(nodepos)) {
                let p2 = predictedParam2(id: id, nodepos: nodepos, neighborpos: hit.under, item: name)
                client.world.setNode(nodepos, param0: id, param2: p2)
                markNodeDirty(nodepos); remeshCooldown = 0   // remesh next tick, not after the 0.4s coalesce
                // The item's sound_place, at the placed node, like SoundMaker.
                playNodeSound(client.items.placeSound(for: name), at: nodepos)
                print("[place] on \(nodepos) = \(pname) (predicted for \(name))"); fflush(stdout)
            } else {
                print("[place] on \(nodepos) blocked (target not replaceable), server-only"); fflush(stdout)
            }
        } else {
            client.sendInteract(action: 3, under: hit.under, above: hit.above)   // place, no prediction
            print("[place] on \(hit.above) (wield=\(wield ?? "nil"), server-only)"); fflush(stdout)
        }
        // Holding grip at a node repeats for any item, like game.cpp's
        // repeat_place_timer: seeds, bone meal and hoes plant/till a row, not
        // only blocks. Rightclickable nodes and meta formspecs returned false
        // above, so a held grip never re-toggles a door or reopens a chest.
        return true
    }


    // MARK: - Inventory panel (#81)
    //
    // A spatial panel that opens where you're looking (right O) and stays put
    // in the world, visionOS style, instead of Luanti's flat formspec. Same
    // feature set as the desktop player inventory: 27 main slots + hotbar row,
    // the 2x2 craft grid with its preview, and the armor column. Pointing is
    // the right Sense controller's ray (gaze when it isn't tracked); trigger =
    // pick up / put down a whole stack, grip = one item (or take half). Every
    // change is a real InventoryAction the server applies, then echoes back.
    private struct InvSlot { let loc: String; let list: String; let index: Int; let u: Float; let v: Float }
    private struct InvFrame { let center: SIMD3<Float>; let right: SIMD3<Float>; let up: SIMD3<Float>; let fwd: SIMD3<Float> }
    private var invSlots: [InvSlot] = []
    private var invFrame: InvFrame? = nil
    private var invHeld: (loc: String, list: String, index: Int, count: Int)? = nil   // count 0 = whole stack
    private var formspecOpen = false
    private var formspecName = ""                     // the SHOW_FORMSPEC formname (e.g. "mcl_chests:chest_x_y_z")
    private var formspecContext: SIMD3<Int>? = nil   // node whose metadata a formspec's current_name/context refers to
    /// The open form is the player's own INVENTORY_FORMSPEC (formname ""): it
    /// closes with player fields, not node fields, and a re-sent inventory
    /// formspec (creative tab switch) re-lays it out in place (#281).
    private var formspecIsInventory = false
    private var formspecElements: [Formspec.List] = []
    private var formspecRings: [(loc: String, list: String)] = []        // listring[] chain for shift-click quick-move (#208)
    private var formspecLabelsRaw: [Formspec.Label] = []                 // static label[] text, formspec grid coords
    private var invLabels: [(u: Float, v: Float, text: String, color: Float?)] = []     // laid-out label positions (panel plane, metres)
    private var formspecFields: [Formspec.Field] = []                    // editable fields on a list-form (anvil rename, #229)
    private var formspecButtons: [Formspec.PositionedButton] = []        // tappable buttons on a list-form (#229)
    private var invWidgets: [(u: Float, v: Float, hw: Float, hh: Float, field: Formspec.Field?, button: Formspec.PositionedButton?)] = []   // laid-out tappable field/button boxes
    private var formspecInfoTargets: [Formspec.InfoTarget] = []   // info-form tab/row tap regions in grid coords (#346)
    private var infoTargets: [(u: Float, v: Float, hw: Float, hh: Float, field: String, value: String)] = []   // laid out in panel metres
    private var formspecImages: [Formspec.Image] = []                    // static image[] elements (furnace fire/arrow, #223)
    private var formspecBackgrounds: [Formspec.Background] = []          // background[]/background9[] panels (#244)
    private var invImages: [(u: Float, v: Float, hw: Float, hh: Float, texture: String, isItem: Bool)] = []   // laid-out image quads (isItem: draw as an item icon)
    private var invBackgrounds: [(u: Float, v: Float, hw: Float, hh: Float, texture: String)] = []   // laid-out background[] station art at its own coords (#245)
    private var formspecTooltips: [String: (text: String, color: Float?)] = [:]  // element name -> hover text + color (enchant cost, #236)
    private var formspecCheckboxes: [Formspec.Checkbox] = []             // checkbox[] toggles (#237)
    private var checkboxState: [String: Bool] = [:]                      // local checked state, flipped on tap
    private var invCheckboxes: [(u: Float, v: Float, hw: Float, hh: Float, name: String, label: String, color: Float?)] = []   // laid-out checkbox boxes
    private var formspecLabelLayers: [String: (layer: Int, aspect: Float)] = [:]   // label text -> text layer
    private var invHover: Int? = nil                                     // index into invSlots
    private var invCursor: SIMD3<Float>? = nil                           // ray hit on the panel plane (node space)
    private var invCountLayers: [Int: Int] = [:]                          // count -> model-texture layer
    private var invTileCache: [String: String?] = [:]                     // item name -> atlas tile
    private var invPrevDig = false, invPrevPlace = false
    private static let invCell: Float = 0.054, invPitch: Float = 0.062   // metres (1 node = 1 m); ~0.8 m wide panel

    private func inventoryStack(_ s: InvSlot) -> Client.ItemStack? {
        guard let list = listFor(loc: s.loc, name: s.list), s.index < list.count else { return nil }
        return list[s.index]
    }

    /// Desktop-style shift-click quick-move (#208): send `stack` to its logical
    /// destination and return true if an action was issued. Left-grip-held on a
    /// filled slot routes it without picking it up.
    private func shiftMove(_ h: InvSlot, _ stack: Client.ItemStack) -> Bool {
        let from = Client.InvRef(h.loc, h.list, h.index)
        // Log the source stack and the ring so a device pull shows exactly what a
        // shift-move sends and where (chest->inventory quick-move debugging).
        let ringStr = formspecRings.map { "\($0.loc)/\($0.list)" }.joined(separator: ",")
        print("[shift] from=\(h.loc)/\(h.list)[\(h.index)]=\(stack.name)x\(stack.count) fs=\(formspecOpen) rings=[\(ringStr)]"); fflush(stdout)
        // Shift-clicking the craft output: craft one batch and send it straight to
        // the inventory (desktop shift-click on a result), instead of onto the hand.
        if h.list == "craftpreview" {
            client.sendInventoryAction(Client.craftAction(count: 1, craftLoc: h.loc))
            client.sendInventoryAction(Client.moveSomewhereAction(count: 0,
                from: Client.InvRef(h.loc, "craftresult", 0), toLoc: "current_player", toList: "main"))
            return true
        }
        // A server container/station is open: follow its listring, exactly like
        // desktop. Moving to the NEXT ring entry after the source list routes a
        // furnace's items to the `distr` distributor (which sorts fuel vs
        // ingredient server-side), and cycles chest<->player correctly (#208).
        if formspecOpen, !formspecRings.isEmpty,
           let i = formspecRings.firstIndex(where: { $0.loc == h.loc && $0.list == h.list }) {
            let d = formspecRings[(i + 1) % formspecRings.count]
            client.sendInventoryAction(Client.moveSomewhereAction(count: 0, from: from, toLoc: d.loc, toList: d.list))
            return true
        }
        // Plain player inventory (no server formspec, so no ring): auto-equip an
        // armor piece to its slot when empty, and shift worn armor back out.
        if !formspecOpen {
            if h.list != "armor", let slot = client.items.armorSlot(stack.name),
               inventoryStack(InvSlot(loc: "current_player", list: "armor", index: slot, u: 0, v: 0)) == nil {
                client.sendInventoryAction(Client.moveAction(count: 0, from: from,
                    to: Client.InvRef("current_player", "armor", slot)))
                return true
            }
            if h.list == "armor" {
                client.sendInventoryAction(Client.moveSomewhereAction(count: 0, from: from, toLoc: "current_player", toList: "main"))
                return true
            }
        }
        // Container open but its formspec carried no listring (or the source list
        // isn't in it): best-effort player<->container using the first container list.
        if formspecOpen, let c = openContainerMain() {
            if h.loc == "current_player", h.list == "main" {
                client.sendInventoryAction(Client.moveSomewhereAction(count: 0, from: from, toLoc: c.loc, toList: c.list))
                return true
            }
            if h.loc == c.loc {
                client.sendInventoryAction(Client.moveSomewhereAction(count: 0, from: from, toLoc: "current_player", toList: "main"))
                return true
            }
        }
        return false
    }

    /// The open container's target list for shift-moves: prefer a "main" list
    /// (chests/shulkers), else the first non-player slot's own list (furnace src,
    /// etc.). nil when only the plain player inventory is open.
    private func openContainerMain() -> (loc: String, list: String)? {
        for s in invSlots where s.loc != "current_player" {
            if listFor(loc: s.loc, name: "main") != nil { return (s.loc, "main") }
            return (s.loc, s.list)
        }
        return nil
    }
    /// Resolve an inventory location string to its stacks: "current_player" is
    /// our inventory; "nodemeta:x,y,z" is a node's metadata inventory.
    private func listFor(loc: String, name: String) -> [Client.ItemStack?]? {
        if loc == "current_player" { return client.inventory[name] }
        if loc.hasPrefix("nodemeta:") {
            let c = loc.dropFirst("nodemeta:".count).split(separator: ",")
            guard c.count == 3, let x = Int(c[0]), let y = Int(c[1]), let z = Int(c[2]) else { return nil }
            return client.world.nodeInventory(SIMD3(x, y, z), list: name)
        }
        if loc.hasPrefix("detached:") { return client.detachedInventory(String(loc.dropFirst("detached:".count)), list: name) }
        return nil
    }

    private func toggleInventory() {
        // Right O closes an open server formspec first; otherwise toggles the
        // player inventory.
        if formspecOpen { closeFormspec(); return }
        // The server's own inventory form when it sent one (VoxeLibre's
        // survival page: armour column, offhand slot, 2x2 craft; or the
        // creative browser with its tabs) -- what desktop shows on E (#281).
        // The hand-built grid below stays as the fallback for a server that
        // never sent INVENTORY_FORMSPEC.
        if !inventoryOpen, !client.inventoryFormspec.isEmpty {
            formspecContext = nil
            openFormspec(client.inventoryFormspec, "", inventory: true)
            if formspecOpen { return }
        }
        inventoryOpen.toggle()
        invHeld = nil; invHover = nil; invCursor = nil
        if inventoryOpen { openInventoryPanel() } else { invFrame = nil; invSlots = []; releasePanelIconLayers() }
        print("[inventory] \(inventoryOpen ? "open" : "closed")"); fflush(stdout)
    }

    private func closeFormspec() {
        // A crafting-table form shows the player's `craft` grid. Return its input
        // items to the main inventory on close so nothing is stranded in the grid
        // (only when THIS form actually showed a craft grid: closing a chest must
        // not empty your craft slots).
        if formspecElements.contains(where: { $0.list == "craft" }), let craft = client.inventory["craft"] {
            for i in 0..<craft.count where craft[i] != nil {
                client.sendInventoryAction(Client.moveSomewhereAction(
                    count: craft[i]!.count, from: Client.InvRef("current_player", "craft", i),
                    toLoc: "current_player", toList: "main"))
            }
        }
        formspecOpen = false; inventoryOpen = false; invFrame = nil; invSlots = []
        invHeld = nil; invHover = nil; invCursor = nil
        formspecElements = []; formspecRings = []; formspecLabelsRaw = []; invLabels = []
        formspecFields = []; formspecButtons = []; invWidgets = []
        formspecInfoTargets = []; infoTargets = []
        formspecImages = []; invImages = []; invBackgrounds = []; formspecTooltips = [:]; formspecBackgrounds = []
        formspecCheckboxes = []; checkboxState = [:]; invCheckboxes = []
        // Tell the server the form was closed. A named show_formspec form (chests
        // use "mcl_chests:chest_x_y_z") closes via INVENTORY_FIELDS with that
        // formname + quit -- that is what fires mcl_chests' on_player_receive_
        // fields to play the lid-close animation. Sending NODEMETA_FIELDS to the
        // node (no formname) never matched "mcl_chests:", so the lid stayed open
        // (#130). Fall back to node fields for a bare nodemeta form (no formname).
        if !formspecName.isEmpty || formspecIsInventory {
            // The inventory form's name is "" on the wire; mcl_inventory's
            // receive_fields handler (craft-grid return, creative state) keys
            // on exactly that.
            client.sendPlayerFields(formname: formspecName, fields: ["quit": "true"])
        } else if let n = formspecContext {
            client.sendNodeFields(pos: n, fields: ["quit": "true"])
        }
        formspecName = ""; formspecIsInventory = false
        releasePanelIconLayers()
        pendingButtonForm = nil; noticeText = nil
        print("[formspec] closed"); fflush(stdout)
    }

    /// The open node-meta formspec (furnace, etc.) changed: a lit furnace
    /// re-sends its formspec each cook tick with a new fire/arrow `[lowpart:N`
    /// percent (mcl_furnaces active_formspec). We were only rebaking item icons
    /// on a meta change, so the fire gauge stayed frozen at its open-time value
    /// -- it read as "no animation" (#344). Re-parse just the visual elements
    /// (image/label/background) from the node's CURRENT meta formspec and
    /// re-lay-out; the item lists are identical between active/inactive, so a
    /// held stack, hover and cursor are left untouched.
    private func refreshOpenNodeFormspec() {
        guard formspecOpen, let ctx = formspecContext, let fs = client.world.nodeFormspec(ctx) else { return }
        let spec = Formspec.flattenContainers(client.formspecPrepend + fs)
        formspecImages = Formspec.parseImages(spec) + Formspec.parseItemImages(spec)
        formspecBackgrounds = Formspec.parseBackgrounds(spec)
        formspecLabelsRaw = Formspec.parseLabels(spec)
        layoutInventory()
    }

    /// Open a non-inventory info form (achievements / announcements / doc Help)
    /// read-only in the spatial panel: tab captions, textlist rows and hypertext
    /// are flattened to positioned text (Formspec.infoFormLabels), plus any
    /// image[] (the achievement icon) and background art. No item lists, so it's
    /// text-only for now; close it by clicking off the panel, which sends the
    /// form's quit like any other. Tab switching / row selection is a follow-up
    /// (the parsers already carry the field names) (#339).
    private func openInfoFormspec(spec: String, name: String) {
        // A re-send of the SAME form (tab switch, row select echo) should keep
        // the panel where it is instead of re-anchoring in front of the player
        // on every tap (#346).
        let reuse = formspecOpen && formspecName == name && invFrame != nil
        formspecContext = nil            // player form (show_formspec), not a node's meta form
        formspecElements = []
        formspecRings = []
        formspecLabelsRaw = Formspec.parseLabels(spec) + Formspec.infoFormLabels(spec)
        formspecFields = []
        formspecButtons = []
        invWidgets = []
        formspecInfoTargets = Formspec.infoTargets(spec)
        formspecImages = Formspec.parseImages(spec) + Formspec.parseItemImages(spec)
        formspecTooltips = [:]
        formspecBackgrounds = Formspec.parseBackgrounds(spec)
        formspecCheckboxes = []; checkboxState = [:]; invCheckboxes = []
        formspecName = name
        formspecOpen = true; inventoryOpen = true; formspecIsInventory = false
        invHeld = nil; invHover = nil; invCursor = nil
        if reuse { layoutInventory() } else { openInventoryPanel() }
        refreshInventoryTiles()
        print("[formspec] open info '\(name)' labels=\(formspecLabelsRaw.count) targets=\(formspecInfoTargets.count) reuse=\(reuse)"); fflush(stdout)
    }

    /// TOCLIENT_SHOW_FORMSPEC handler: an empty spec closes; otherwise parse the
    /// list[] elements and open the spatial panel over them.
    private func openFormspec(_ rawSpec0: String, _ name: String, inventory: Bool = false) {
        // An empty spec is a close request, but only for its own form: the
        // engine quits the open menu only when the formname is empty or matches
        // it, so a mod clearing its dialog can't shut a chest you have open.
        if rawSpec0.isEmpty {
            if name.isEmpty || name == formspecName { closeFormspec() }
            return
        }
        formspecIsInventory = inventory
        // The server's per-player formspec prepend carries the global stone
        // background9 panel + styles; Luanti prepends it to every formspec, so we
        // do too before parsing (#244).
        let rawSpec = client.formspecPrepend + rawSpec0
        // Log the raw spec (prepend + body) so a device capture shows the exact
        // slot/label/background coords the server sent -- needed to pin the
        // chest-panel misalignment and stray label fragment (#254). Truncated so
        // a huge creative form doesn't flood the log.
        print("[formspec] raw '\(name)' prepend=\(client.formspecPrepend.count)b spec=\(rawSpec0.prefix(700))"); fflush(stdout)
        // Bake container[]/container_end[] offsets into element positions so the
        // parsers below stay container-unaware (enchanting table rows, #234).
        let spec = Formspec.flattenContainers(rawSpec)
        let lists = Formspec.parseLists(spec, context: formspecContext)
        guard !lists.isEmpty else {
            // No item grids: a text dialog (sign, command block). If it's a pure
            // text editor and we know the node, edit it with the keyboard. A
            // form that also carries real buttons (the bed sleep form: chat
            // field + Send + "Leave bed") is a button dialog instead; the
            // keyboard used to pop up on its chat field every time Eric went to
            // sleep (#304).
            let fields = Formspec.parseFields(spec)
            if let field = fields.first, let ctx = formspecContext, Formspec.isTextEditorForm(spec) {
                openKeyboard(prefill: field.value) { [weak self] text in
                    self?.client.sendNodeFields(pos: ctx, formname: name, fields: [field.name: text])
                }
                return
            }
            // A non-inventory INFO form (achievements, announcements, doc Help):
            // no item grids, but textlist/tabheader/hypertext content. Render it
            // read-only in the panel so it's legible, instead of the one-button
            // notice that dropped everything but a single button (#339).
            if Formspec.isInfoForm(spec) {
                openInfoFormspec(spec: spec, name: name)
                return
            }
            // A button dialog (bed sleep form, death screen): show a notice and
            // let the inventory button submit its button so the player can get
            // up (they're frozen by physics_override).
            let buttons = Formspec.parseButtons(spec)
            if let b = buttons.first(where: { $0.name == "leave" }) ?? buttons.first {
                pendingButtonForm = (name, b.name)
                noticeText = "\(b.label.isEmpty ? "Get up" : b.label) — press O"; noticeExpiry = 0
                print("[formspec] button dialog '\(name)' button=\(b.name)"); fflush(stdout)
            }
            return
        }
        formspecElements = lists
        formspecRings = Formspec.parseListrings(spec, context: formspecContext)   // shift-click order (#208)
        formspecLabelsRaw = Formspec.parseLabels(spec)   // station name + slot captions (#176)
        // A list-form can also carry an editable field (anvil rename) or a button;
        // surface them as tappable boxes in the panel instead of dropping them (#229).
        formspecFields = formspecContext != nil ? Formspec.parseFieldsPositioned(spec) : []
        formspecButtons = Formspec.parseButtonsPositioned(spec) + Formspec.parseItemImageButtons(spec)   // + stonecutter recipes (#235)
        // Static images: furnace fire/arrow gauges (#223) + item_image[] icons
        // like the beacon payment row / trade hints (#232).
        formspecImages = Formspec.parseImages(spec) + Formspec.parseItemImages(spec)
        formspecTooltips = Formspec.parseTooltips(spec)   // hover text (enchant cost, #236)
        formspecBackgrounds = Formspec.parseBackgrounds(spec)   // stone panel + station art (#244)
        formspecCheckboxes = Formspec.parseCheckboxes(spec)   // toggles (#237)
        checkboxState = Dictionary(formspecCheckboxes.map { ($0.name, $0.selected) }, uniquingKeysWith: { a, _ in a })
        formspecName = name              // remembered so close sends the named-form quit (#130)
        formspecOpen = true; inventoryOpen = true
        invHeld = nil; invHover = nil; invCursor = nil
        openInventoryPanel()   // anchors invFrame ahead of the player, then layoutInventory()
        refreshInventoryTiles()
        print("[formspec] open '\(name)' lists=\(lists.map { "\($0.loc)/\($0.list)" })"); fflush(stdout)
        logInventoryContents(lists)
        logIconResolution(lists)
    }

    /// For each distinct item in the open panel, log where its icon resolution
    /// stands: image name, cached tile, atlas layer, and the baked model-texture
    /// layer the panel actually draws from. A nil at any stage is why the slot
    /// renders empty even though it holds an item (#254). Runs after
    /// refreshInventoryTiles so the atlas rebuild has happened.
    private func logIconResolution(_ lists: [Formspec.List]) {
        var stacks: [Client.ItemStack?] = Array(client.inventory.values.joined())
        for e in lists {   // visible window only, like refreshInventoryTiles
            guard let l = listFor(loc: e.loc, name: e.list) else { continue }
            let lo = max(0, min(e.start, l.count)), hi = max(lo, min(e.start + e.cols * e.rows, l.count))
            stacks += l[lo..<hi]
        }
        var seen = Set<String>()
        for case let st? in stacks where seen.insert(iconKey(st)).inserted {
            let tile = invTileCache[iconKey(st)] ?? nil
            let img = client.items.image(for: st.name)
            let atlasLayer = tile.flatMap { atlas.tileLayer($0) }
            let modelLayer = invIconModelLayer(iconKey(st))
            print("[icon] \(st.name) img=\(img ?? "nil") tile=\(tile ?? "nil") atlas=\(atlasLayer.map(String.init) ?? "nil") model=\(modelLayer.map(String.init) ?? "nil")")
        }
        fflush(stdout)
    }

    /// Sim/test only: fill the player's own "main" list with a mix of cube
    /// nodes AND non-atlased craftitems (raw_iron/flint/boots) so the panel's
    /// OWN grid -- the one every station form embeds via list[current_player;
    /// main] -- exercises the icon path each run. The sim dev account is nearly
    /// empty, so without this the player grid stayed blank in the sim and the
    /// #254 blank-icon class only showed in a container's own slots.
    private func seedFakePlayerInventory() {
        // Fill only the EMPTY slots so the dev account's real items stay put; the
        // sim account is nearly empty, so this populates the grid either way.
        // Run once (a marker item at the far end) so we don't re-seed every tick.
        var main = client.inventory["main"] ?? []
        if main.count < 36 { main += [Client.ItemStack?](repeating: nil, count: 36 - main.count) }
        if main[35]?.name == "mcl_core:apple" { return }   // already seeded
        let seed = ["mcl_core:cobble", "mcl_tools:pick_stone", "mcl_raw_ores:raw_iron",
                    "mcl_core:flint", "mcl_armor:boots_iron", "mcl_core:glass",
                    "mcl_copper:raw_copper", "mcl_core:coal_lump", "mcl_core:iron_ingot",
                    "mcl_mobitems:bone", "mcl_mobitems:saddle"]
        var si = 0
        for i in 0..<36 where main[i] == nil && si < seed.count {
            main[i] = Client.ItemStack(name: seed[si], count: si + 1, wear: 0); si += 1
        }
        main[35] = Client.ItemStack(name: "mcl_core:apple", count: 1, wear: 0)   // seed marker
        client.setPlayerInventoryForTest(list: "main", main)
    }

    /// Print the resolved contents of every list a formspec references, plus the
    /// player's own main list, so we can compare what the server actually sent
    /// against what the panel renders (chest slots showing empty, #254). Prints
    /// slot index -> item xN for each filled slot; `<no list resolved>` means the
    /// nodemeta/detached inventory never arrived (the real bug if the chest looks
    /// empty in-world too).
    private func logInventoryContents(_ lists: [Formspec.List]) {
        var seen = Set<String>()
        func logList(_ loc: String, _ list: String) {
            let key = "\(loc)/\(list)"
            guard seen.insert(key).inserted else { return }
            guard let stacks = listFor(loc: loc, name: list) else {
                print("[chest] \(key): <no list resolved>"); return
            }
            let filled = stacks.enumerated().compactMap { (i, s) -> String? in
                guard let s, !s.name.isEmpty, s.count > 0 else { return nil }
                return "\(i):\(s.name)x\(s.count)"
            }
            print("[chest] \(key) slots=\(stacks.count) filled=\(filled.count) [\(filled.joined(separator: ", "))]")
        }
        for e in lists { logList(e.loc, e.list) }
        logList("current_player", "main")
        fflush(stdout)
    }


    /// Anchor the panel 0.8 m ahead of the eye (horizontal gaze), a touch low,
    /// facing the player. Fixed in the world from then on.
    private func openInventoryPanel() {
        let eye = player.rayOrigin()
        var f = player.aim(); f.y = 0
        let l = simd_length(f); f = l > 1e-3 ? f / l : player.bodyForward()
        let right = SIMD3<Float>(f.z, 0, -f.x)          // right of fwd in Luanti's left-handed frame
        invFrame = InvFrame(center: eye + f * 0.9 - SIMD3(0, 0.06, 0), right: right, up: SIMD3(0, 1, 0), fwd: f)
        layoutInventory()
    }

    /// Slot positions (u right, v up, metres from the panel centre), matching the
    /// desktop layout: main rows on top, hotbar row below a gap, craft 2x2 +
    /// preview on the right, armor column on the left.
    private func layoutInventory() {
        let p = Self.invPitch
        var slots: [InvSlot] = []
        if formspecOpen {
            // One grid per list[] element at its formspec (x,y); recenter the
            // whole form about the panel origin.
            for e in formspecElements {
                for i in 0..<(e.cols * e.rows) {
                    let col = i % e.cols, row = i / e.cols
                    // formspec_version[4] spaces slots 1.25 units apart, and the
                    // slot's CENTER is +0.5 from its top-left x,y. Match that so the
                    // interactive slots line up with the slot-background images the
                    // stations emit (get_itemslot_bg_v4), which we now draw (#241).
                    slots.append(InvSlot(loc: e.loc, list: e.list, index: e.start + i,
                                         u: (e.gx + Float(col) * 1.25 + 0.5) * p,
                                         v: -(e.gy + Float(row) * 1.25 + 0.5) * p))
                }
            }
            var cu: Float = 0, cv: Float = 0
            if let uMin = slots.map({ $0.u }).min(), let uMax = slots.map({ $0.u }).max(),
               let vMin = slots.map({ $0.v }).min(), let vMax = slots.map({ $0.v }).max() {
                cu = (uMin + uMax) / 2; cv = (vMin + vMax) / 2
                slots = slots.map { InvSlot(loc: $0.loc, list: $0.list, index: $0.index, u: $0.u - cu, v: $0.v - cv) }
            } else {
                // A list-less info form (achievements / announcements / Help) has
                // no slots to center on, so its labels/images would lay out from
                // the panel origin and spill off the right edge. Center on the
                // label + image extent instead (#339).
                var us: [Float] = [], vs: [Float] = []
                for l in formspecLabelsRaw { us.append(l.gx * p); vs.append(-l.gy * p) }
                for im in formspecImages { us.append((im.gx + im.w * 0.5) * p); vs.append(-(im.gy + im.h * 0.5) * p) }
                if let uMin = us.min(), let uMax = us.max(), let vMin = vs.min(), let vMax = vs.max() {
                    cu = (uMin + uMax) / 2; cv = (vMin + vMax) / 2
                }
            }
            invSlots = slots
            // Labels share the slots' grid + recenter. Formspec y grows downward,
            // so negate. In real-coordinate forms (formspec_version >= 2, all of
            // VoxeLibre) label y is the text's vertical CENTER; the old half-cell
            // nudge up put "Inventory" (y=4.7) inside the chest's last row, where
            // the slot backgrounds hid all but its tail (#261).
            invLabels = formspecLabelsRaw.map {
                (u: $0.gx * p - cu, v: -$0.gy * p - cv, text: $0.text, color: $0.color)
            }
            // Info-form tab/row tap boxes (achievements/Help): same grid->metre
            // mapping as the labels, so a tap lands on the visible text. Invisible;
            // hit-tested in handleInventoryInput to submit the tab index / textlist
            // CHG event (#346). gy is the text's vertical centre, matching labels.
            infoTargets = formspecInfoTargets.map {
                (u: ($0.gx + $0.w * 0.5) * p - cu, v: -$0.gy * p - cv,
                 hw: $0.w * 0.5 * p, hh: $0.h * 0.5 * p, field: $0.field, value: $0.value)
            }
            // Tappable field/button boxes, centered on their grid rect (formspec
            // x,y is the box's top-left), recentered the same way as slots (#229).
            var widgets: [(u: Float, v: Float, hw: Float, hh: Float, field: Formspec.Field?, button: Formspec.PositionedButton?)] = []
            for f in formspecFields {
                widgets.append((u: (f.gx + f.w * 0.5) * p - cu, v: -(f.gy + 0.5) * p - cv,
                                hw: f.w * p * 0.5, hh: p * 0.42, field: f, button: nil))
            }
            for b in formspecButtons {
                widgets.append((u: (b.gx + b.w * 0.5) * p - cu, v: -(b.gy + 0.5) * p - cv,
                                hw: b.w * p * 0.5, hh: p * 0.42, field: nil, button: b))
            }
            invWidgets = widgets
            // Static image[] quads (furnace fire gauge + cook arrow), centered on
            // their grid rect the same way as slots/widgets (#223).
            invImages = formspecImages.map {
                (u: ($0.gx + $0.w * 0.5) * p - cu, v: -($0.gy + $0.h * 0.5) * p - cv,
                 hw: $0.w * p * 0.5, hh: $0.h * p * 0.5, texture: $0.texture, isItem: $0.isItem)
            }
            // Non-fill background[] art (brewing/trading/book panels): each draws
            // at its own grid rect, unlike the prepend's stone panel that fills
            // the whole backdrop. Same top-left -> center mapping as images (#245).
            invBackgrounds = formspecBackgrounds.filter { !$0.fill }.map {
                (u: ($0.gx + $0.w * 0.5) * p - cu, v: -($0.gy + $0.h * 0.5) * p - cv,
                 hw: $0.w * p * 0.5, hh: $0.h * p * 0.5, texture: $0.texture)
            }
            // Checkboxes: a small box at (gx,gy) (y is the box's center) plus a
            // label reaching right; the whole span is the tap target (#237).
            invCheckboxes = formspecCheckboxes.map {
                let box: Float = p * 0.5
                return (u: $0.gx * p - cu + box, v: -$0.gy * p - cv,
                        hw: box, hh: box, name: $0.name, label: $0.label, color: $0.color)
            }
            return
        }
        let main = client.inventory["main"]?.count ?? 36
        for i in 0..<main {
            let col = i % 9
            let u = (Float(col) - 4) * p
            let v: Float = i < 9 ? -1.9 * p : (1.5 - Float((i - 9) / 9)) * p
            slots.append(InvSlot(loc: "current_player", list: "main", index: i, u: u, v: v))
        }
        if let craft = client.inventory["craft"] {
            // The player's own inventory has a 2x2 craft grid on desktop (the 3x3
            // is the crafting table, shown via a formspec, handled above). The
            // server may still send a 9-slot craft list, so cap it at 2x2 here.
            let side = 2
            for i in 0..<min(craft.count, side * side) {
                let u = (5.5 + Float(i % side)) * p, v = (1.5 - Float(i / side)) * p
                slots.append(InvSlot(loc: "current_player", list: "craft", index: i, u: u, v: v))
            }
            let pu = (5.5 + Float(side) + 1.2) * p
            slots.append(InvSlot(loc: "current_player", list: "craftpreview", index: 0, u: pu, v: (1.5 - Float(side - 1) * 0.5) * p))
        }
        if let armor = client.inventory["armor"] {
            // mcl_armor uses armor-list slots 1..4 for head/torso/legs/feet (slot 0
            // is unused); skip it so the column is exactly those four (#168).
            for i in 1..<armor.count {
                slots.append(InvSlot(loc: "current_player", list: "armor", index: i, u: -5.5 * p, v: (2.0 - Float(i)) * p))
            }
        }
        invSlots = slots
    }

    /// Pointer ray in node space: the right controller (its -Z), else the gaze.
    /// Origin space -> node space undoes the renderer's Z mirror and yaw.
    private func inventoryRay() -> (origin: SIMD3<Float>, dir: SIMD3<Float>) {
        guard let m = player.rightHand() else { return (player.rayOrigin(), player.aim()) }
        let s = player.snapshot()
        let eyeN = player.origin()
        let cy = cos(s.yaw), sy = sin(s.yaw)
        func toNode(_ o: SIMD3<Float>) -> SIMD3<Float> {          // R(yaw) * mirrorZ
            let x = o.x, z = -o.z
            return SIMD3(x * cy + z * sy, o.y, -x * sy + z * cy)
        }
        let pos = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let fwd = -SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        return (eyeN + toNode(pos) / PlayerState.scale, simd_normalize(toNode(fwd)))
    }

    /// The panel backdrop rect in frame-local (u, v) metres: the whole inventory
    /// UI, not just the slots. Shared by the backdrop draw and the release
    /// hit-test so "over the panel" means exactly what's painted.
    private func invPanelBounds() -> (uMin: Float, uMax: Float, vMin: Float, vMax: Float) {
        let p = Self.invPitch
        var uMin: Float = -5 * p, uMax: Float = 5 * p, vMin: Float = -2.5 * p, vMax: Float = 2.2 * p
        for s in invSlots { uMin = min(uMin, s.u - p); uMax = max(uMax, s.u + p); vMin = min(vMin, s.v - p); vMax = max(vMax, s.v + p) }
        return (uMin, uMax, vMin, vMax)
    }

    /// Per tick while open: hover/cursor from the pointer ray, then act on
    /// trigger (dig) / grip (place) edges.
    private func handleInventoryInput(_ gi: GameInput.State) {
        guard let fr = invFrame else { return }
        let (o, d) = inventoryRay()
        let n = fr.fwd
        let denom = simd_dot(d, n)
        invHover = nil; invCursor = nil
        var overPanel = false
        if abs(denom) > 1e-4 {
            let t = simd_dot(fr.center - o, n) / denom
            if t > 0 && t < 3 {
                let hit = o + d * t
                invCursor = hit
                let rel = hit - fr.center
                let u = simd_dot(rel, fr.right), v = simd_dot(rel, fr.up)
                let half = Self.invCell * 0.5
                invHover = invSlots.firstIndex { abs($0.u - u) <= half && abs($0.v - v) <= half }
                // The whole backdrop is a safe drop zone: releasing anywhere over
                // it keeps the held item, so only a release truly off the panel
                // ejects into the world (Eric).
                let b = invPanelBounds()
                overPanel = u >= b.uMin && u <= b.uMax && v >= b.vMin && v <= b.vMax
            }
        }
        #if targetEnvironment(simulator)
        // -vrdev.invPickTest drives the real click logic without a controller ray
        // by forcing the hovered slot (#81). overPanel true so a release stays put.
        if let ov = simInvHoverOverride { invHover = (ov >= 0 && ov < invSlots.count) ? ov : nil; overPanel = true }
        #endif
        let primary = gi.dig && !invPrevDig, secondary = gi.place && !invPrevPlace
        invPrevDig = gi.dig; invPrevPlace = gi.place
        guard primary || secondary else { return }
        // Tap an info-form tab caption or textlist row (achievements/Help): submit
        // the field so the server re-sends the form on that tab / with that entry
        // selected (#346). A player form (no node context) submits via
        // INVENTORY_FIELDS; a node info form via nodemeta. Doesn't close.
        if primary, invHeld == nil, invHover == nil, let cur = invCursor, !infoTargets.isEmpty {
            let rel = cur - fr.center
            let u = simd_dot(rel, fr.right), v = simd_dot(rel, fr.up)
            if let t = infoTargets.first(where: { abs(u - $0.u) <= $0.hw && abs(v - $0.v) <= $0.hh }) {
                if let ctx = formspecContext {
                    client.sendNodeFields(pos: ctx, formname: formspecName, fields: [t.field: t.value])
                } else {
                    client.sendPlayerFields(formname: formspecName, fields: [t.field: t.value])
                }
                print("[formspec] info tap \(t.field)=\(t.value)"); fflush(stdout)
                return
            }
        }
        // Tap a field/button box (anvil rename, etc.): a field opens the keyboard
        // and submits nodemeta fields; a button submits immediately (#229). Only
        // with an empty hand and no slot under the pointer, so item moves win.
        if primary, invHeld == nil, invHover == nil, let cur = invCursor, !invWidgets.isEmpty {
            let rel = cur - fr.center
            let u = simd_dot(rel, fr.right), v = simd_dot(rel, fr.up)
            if let w = invWidgets.first(where: { abs(u - $0.u) <= $0.hw && abs(v - $0.v) <= $0.hh }),
               let ctx = formspecContext {
                let fname = formspecName
                if let f = w.field {
                    openKeyboard(prefill: f.value) { [weak self] text in
                        self?.client.sendNodeFields(pos: ctx, formname: fname, fields: [f.name: text])
                    }
                } else if let b = w.button {
                    client.sendNodeFields(pos: ctx, formname: fname, fields: [b.name: "true"])
                    if b.exit { closeFormspec() }
                }
                return
            }
        }
        // Tap a checkbox: flip local state and submit its field (#237).
        if primary, invHeld == nil, invHover == nil, let cur = invCursor, !invCheckboxes.isEmpty,
           let ctx = formspecContext {
            let rel = cur - fr.center
            let u = simd_dot(rel, fr.right), v = simd_dot(rel, fr.up)
            // Hit target spans the box plus its label to the right (~3 cells).
            if let cb = invCheckboxes.first(where: { u >= $0.u - $0.hw && u <= $0.u + Self.invCell * 3 && abs(v - $0.v) <= $0.hh }) {
                let now = !(checkboxState[cb.name] ?? false)
                checkboxState[cb.name] = now
                client.sendNodeFields(pos: ctx, formname: formspecName, fields: [cb.name: now ? "true" : "false"])
                return
            }
        }
        // The interaction button doubles as "close": clicking off the panel with
        // an empty hand dismisses the inventory (click-outside-to-close), so you
        // don't have to reach for the toggle. A held stack still drops instead.
        if primary, !overPanel, invHeld == nil { toggleInventory(); return }
        // Right grip also CLOSES an open container: the same button that opened
        // the chest/furnace shuts it, as long as you're not mid-move (empty hand)
        // and not clicking a slot, so item moves still work (Eric: "grip that
        // opens the chest should also close it"). Only for server formspecs, not
        // the plain player inventory (which has its own toggle).
        // ...but not while both grips are held for a screenshot (right grip is
        // part of that gesture): otherwise you can never screenshot an open
        // container. gi.snap = both grips (GameInput).
        // Only when truly OFF the panel, matching the primary close above. Gating
        // on invHover==nil closed the container on any grip that landed in the gap
        // between slots -- with a jittery VR ray that shut the chest constantly.
        // The backdrop is a safe zone.
        if secondary, !gi.snap, formspecOpen, invHeld == nil, !overPanel { closeFormspec(); return }
        let hover = invHover.map { invSlots[$0] }
        if let held = invHeld {
            if let h = hover {
                if h.loc == held.loc && h.list == held.list && h.index == held.index { invHeld = nil; return }
                // Clicking the craft output again while already holding the crafted
                // result crafts another batch and accumulates it in the hand, like
                // desktop (#160). The hand references the hidden craftresult slot,
                // so the extra output stacks into what we're already holding (the
                // server clamps at stack_max). Holding any other item, the output
                // isn't takeable, so do nothing.
                if h.list == "craftpreview" {
                    if held.list == "craftresult" {
                        client.sendInventoryAction(Client.craftAction(count: 1, craftLoc: h.loc))
                    }
                    return
                }
                // Holding a craft output is a REFERENCE to the output slot, which
                // is take-only and can't receive a swapped-in item. So clicking a
                // slot that holds a DIFFERENT item can't do the normal swap --
                // instead stash the output into the main inventory and pick up the
                // clicked stack, so "take the torch, then grab cobble to place it"
                // works instead of silently dropping both (Eric).
                if held.list == "craftresult", let ts = inventoryStack(h),
                   let hn = listFor(loc: held.loc, name: "craftresult").flatMap({ held.index < $0.count ? $0[held.index]?.name : nil }),
                   hn != ts.name {
                    client.sendInventoryAction(Client.moveSomewhereAction(count: 0,
                        from: Client.InvRef(held.loc, "craftresult", held.index), toLoc: "current_player", toList: "main"))
                    invHeld = (h.loc, h.list, h.index, 0)   // now hold the clicked stack
                    return
                }
                // Left-click deposits the held stack onto the target, like desktop:
                // same item -> merge/grow the target (server clamps at stack_max,
                // any remainder stays in the held source), different item -> swap,
                // empty -> place. (The old pull-into-hand was backwards, #150: it
                // blocked dropping onto an existing stack to grow it.)
                let count = secondary ? 1 : held.count
                // Nothing of the held stack fits the target (a different item, a
                // different name/enchant, or a full stack): the server swaps the
                // whole stacks, whatever count we send (inventorymanager.cpp
                // allow_swap), and desktop keeps the swapped-in stack in hand
                // (m_selected_swap).
                var willSwap = false
                if let list = listFor(loc: held.loc, name: held.list), held.index < list.count,
                   let src = list[held.index], let dst = inventoryStack(h) {
                    willSwap = !(dst.name == src.name && dst.meta == src.meta && dst.count < client.items.stackMax(dst.name))
                }
                client.sendInventoryAction(Client.moveAction(count: count,
                    from: Client.InvRef(held.loc, held.list, held.index),
                    to: Client.InvRef(h.loc, h.list, h.index)))
                if willSwap, held.list != "craftresult" {
                    invHeld = (held.loc, held.list, held.index, 0)   // the swapped-in stack, now at the source
                } else if held.list == "craftresult" {
                    // The craft output regenerates one batch per Craft action and
                    // never leaves a remainder, so the hand is empty once placed.
                    // (It's a hidden list, so the empty-slot guard can't clear it.)
                    invHeld = nil
                } else if secondary {
                    // Grip = place one. A whole-stack hold (count 0) keeps the hand
                    // so you can seed slots one at a time; the empty-slot guard
                    // clears it when the source drains. A partial hold decrements.
                    if held.count == 0 {
                        invHeld = (held.loc, held.list, held.index, 0)
                    } else {
                        invHeld = held.count > 1 ? (held.loc, held.list, held.index, held.count - 1) : nil
                    }
                } else if held.count > 0 {
                    // Left-click deposit of a partial (half) hold: it's a detached
                    // quantity, so the hand is empty once placed (don't re-grab the
                    // source remainder).
                    invHeld = nil
                } else if inventoryStack(h) == nil {
                    // Whole-stack left-click onto an EMPTY slot: a clean move, the
                    // source is now empty, so drop the hand right away. Don't wait
                    // for the empty-slot guard -- it checks the LOCAL inventory,
                    // which lags for a container (chest) list the server hasn't
                    // echoed yet, so the hand stayed stuck on the emptied chest
                    // slot and the next click deposited into it instead of picking
                    // up the new stack (Eric: moved apples out, then couldn't pick
                    // up the wheat).
                    invHeld = nil
                } else {
                    // Whole-stack left-click onto a filled slot: a swap or merge may
                    // leave a remainder, so keep the hand on the source; the
                    // empty-slot guard clears it once the source is actually empty.
                    invHeld = (held.loc, held.list, held.index, 0)
                }
            } else if primary {
                // Released over the panel but not on a slot: keep the item in
                // hand (the backdrop is a safe zone, no accidental eject).
                if overPanel { return }
                // Pointing truly off the panel: drop the held stack on the ground.
                client.sendInventoryAction(Client.dropAction(count: held.count,
                    from: Client.InvRef(held.loc, held.list, held.index)))
                invHeld = nil
            }
            return
        }
        guard let h = hover, let stack = inventoryStack(h) else { return }
        // Shift-click quick-move: left grip (gi.fast) held + a right-trigger TAP
        // on a filled slot, nothing in hand -> send the stack to its logical
        // destination instead of picking it up, like holding shift on desktop
        // (#208). Only on the primary tap; left grip does nothing else in the panel.
        if primary, gi.fast, shiftMove(h, stack) { return }
        if h.list == "craftpreview" {
            // Craft one into the hidden "craftresult" and pick it up onto the
            // hand, so the output behaves like grabbing any stack: you then click
            // a slot to place it (instead of it jumping straight to inventory).
            client.sendInventoryAction(Client.craftAction(count: 1, craftLoc: h.loc))
            invHeld = (h.loc, "craftresult", 0, 0)   // count 0 = whole stack on a Move
            return
        }
        invHeld = (h.loc, h.list, h.index, secondary ? max(1, stack.count / 2) : 0)
    }

    /// Resolve every stack's icon tile (same rule as the hotbar) and pull any
    /// new tiles into the atlas, so the panel never shows blank cells.
    private func refreshInventoryTiles() {
        // Re-resolve 3D icons on any inventory/panel change: a slot that
        // resolved to "no icon" while its media was still downloading gets
        // another look, and this is the only place that pays for it.
        nodeIconCache.removeAll()
        var newTiles = Set<String>()
        var wantImgs = Set<String>()
        var allLists = Array(client.inventory.values)
        // Only the slots a list[] element actually shows: the creative browser's
        // detached list holds ~1450 stacks but a page draws 45 (start ..<
        // start+cols*rows, the same window layoutInventory lays out). Baking
        // every stack made a 256 KB layer each (~370 MB) and a multi-frame
        // re-upload of the model-texture array (perf review).
        if formspecOpen {
            for e in formspecElements {
                guard let l = listFor(loc: e.loc, name: e.list) else { continue }
                let lo = max(0, min(e.start, l.count)), hi = max(lo, min(e.start + e.cols * e.rows, l.count))
                allLists.append(Array(l[lo..<hi]))
            }
        }
        // Only the player's own main list feeds the NODE atlas (hotbarTiles):
        // the wrist hotbar samples it. Every other icon (chest contents, the
        // creative browser's ~1500 items) is baked straight from media into
        // the model-texture array by iconLayerForTile. Pushing the creative
        // list into the node atlas blew past Metal's 2048-layer cap and
        // aborted in makeAtlas (#281).
        let ownMain = client.inventory["main"] ?? []
        for list in allLists {
            for st in list {
                guard let st else { continue }
                let key = iconKey(st)
                if invTileCache[key] == nil {
                    let img = st.customImage ?? client.items.image(for: st.name)
                    let tile = (img?.isEmpty == false) ? img : nodeIconTile(st.name)
                    invTileCache[key] = .some(tile)
                }
                if let tile = invTileCache[key] ?? nil {
                    for n in NodeRegistry.imageNames(tile) where client.media.bytes(n) == nil { wantImgs.insert(n) }
                }
            }
        }
        for case let st? in ownMain { if let tile = invTileCache[iconKey(st)] ?? nil { newTiles.insert(tile) } }
        if !wantImgs.isEmpty { client.media.request(wantImgs) }
        if !newTiles.isSubset(of: hotbarTiles) {
            hotbarTiles.formUnion(newTiles)
            atlasNeedsRebuild = true
            rebuildAtlas()
        }
        // Pre-bake every panel icon here in ONE batch. The draw loop used to
        // register each lazily, and every new model-texture layer kicks a full
        // array rebuild -- opening a chest set off ~20 rebuilds in a row, and the
        // array re-swapping each time blanked the whole panel (#254 regression).
        // Baking them together makes the layer count jump once -> one rebuild.
        // Mirror nodeIcon3D's own choice of layers so the pre-bake matches what
        // the draw samples: a flat item icon, or a cube's three visible faces
        // (top/right/left = 0/2/5), or a mesh node's face 0.
        for list in allLists {
            for case let st? in list {
                if let img = client.items.image(for: st.name), !img.isEmpty {
                    _ = invIconModelLayer(iconKey(st))             // flat icon
                } else if let nid = client.nodes.id(for: st.name), nid != WorldMap.CONTENT_AIR {
                    let top = client.nodes.faceTile(nid, 0)
                    for fi in [0, 2, 5] { if let t = client.nodes.faceTile(nid, fi) ?? top { _ = iconLayerForTile(t) } }
                } else {
                    _ = invIconModelLayer(iconKey(st))             // flat fallback
                }
            }
        }
        if inventoryOpen { layoutInventory() }
        // The crafted stack sits in the hidden "craftresult" list and is now held
        // on the hand (see the craftpreview click) until the player places it, so
        // we no longer auto-move it to main here.
        // The held slot emptied (moved/dropped): nothing left to hold. Exempt
        // craftresult: it fills a beat after the Craft action, so clearing on an
        // interim empty echo would drop the pickup before it appears.
        if let held = invHeld, held.list != "craftresult",
           let list = listFor(loc: held.loc, name: held.list), held.index < list.count, list[held.index] == nil { invHeld = nil }
    }

    // Item icon as a MODEL-texture layer (upscaled from the atlas tile), so the
    // inventory panel can draw icons as fixed panel-plane quads like the backdrop
    // instead of camera-facing billboards. Cached per item name.
    private var invIconLayers: [String: Int] = [:]
    /// Model-texture layers handed back by releasePanelIconLayers, reused by
    /// registerRGBALayer before the array grows.
    private var freeModelLayers: [Int] = []
    /// How each item string draws when it's an item entity (dropped item,
    /// falling node, item frame): resolved once instead of ~10 registry lookups
    /// per entity per tick. Cleared whenever model layers are released, since
    /// the cached layer indices would then point at reused slots.
    private enum ItemDraw { case model(nid: UInt16, layer: Int), cube([Int]), card(layer: Int, uv: SIMD2<Float>) }
    private var itemDrawCache: [String: ItemDraw] = [:]

    /// When a panel closes, give back the icon layers only that panel needed.
    /// Layers are append-only otherwise, and one creative page adds ~50: paging
    /// through the browser in a long session would hit Metal's 2048-slice cap
    /// and icons would start sharing the last layer (#296). Kept: every tile
    /// the player's own main list (the wrist hotbar's 3D icons) still draws.
    private func releasePanelIconLayers() {
        var keep = Set<String>()
        for case let st? in client.inventory["main"] ?? [] {
            if let t = invTileCache[iconKey(st)] ?? nil { keep.insert(t) }
            if let nid = client.nodes.id(for: st.name), nid != WorldMap.CONTENT_AIR {
                let top = client.nodes.faceTile(nid, 0)
                for fi in [0, 2, 5] { if let t = client.nodes.faceTile(nid, fi) ?? top { keep.insert(t) } }
            }
        }
        var freed = 0
        for (tile, layer) in invIconLayers where !keep.contains(tile) {
            invIconLayers[tile] = nil
            modelTexLayer["#invicon:\(tile)"] = nil
            freeModelLayers.append(layer); freed += 1
            nodeIconCache.removeAll()   // resolved icons pointed at these layers
        }
        if freed > 0 { itemDrawCache.removeAll() }
        if freed > 0 { print("[icon] released \(freed) panel icon layers (\(freeModelLayers.count) free of \(modelTexCount))"); fflush(stdout) }
    }

    private func invIconModelLayer(_ name: String) -> Int? {
        guard let tile = invTileCache[name] ?? nil else { return nil }
        return iconLayerForTile(tile)
    }
    /// Cache key for a stack's icon: the item name, or name + the stack's
    /// inventory_image meta override (bow charge frames, enchant glint) so
    /// two stacks of one item can show different pictures (#271).
    private func iconKey(_ st: Client.ItemStack) -> String {
        if let img = st.customImage { return st.name + "\u{0}" + img }
        return st.name
    }

    /// Upscale an ATLAS tile into a MODEL-texture layer (the inventory panel draws
    /// from the model-texture array, a different layer space than the world node
    /// atlas), cached by tile name. Used for item icons and for each face of a 3D
    /// node icon (#219).
    private func iconLayerForTile(_ tile: String) -> Int? {
        if let l = invIconLayers[tile] { return l }
        // Prefer an already-baked atlas layer (a node face we've decoded), then
        // its base PNG's layer when the full modifier chain ("a.png^b.png", a
        // [combine) isn't atlased itself -- otherwise a 3D-icon face drops and
        // shows a hole (#255).
        if let ai = atlas.tileLayer(tile) ?? NodeRegistry.imageNames(tile).first.flatMap({ atlas.tileLayer($0) }) {
            let i = Int(ai)
            if i >= 0, i < atlas.layers.count {
                let src = atlas.layers[i]
                let t = TextureAtlas.tile, cn = ModelTextureHandoff.size
                if src.count >= t * t * 4 {
                    var px = [UInt8](repeating: 0, count: cn * cn * 4)
                    for y in 0..<cn { for x in 0..<cn {
                        let sx = min(t - 1, x * t / cn), sy = min(t - 1, y * t / cn)
                        let si = (sy * t + sx) * 4, di = (y * cn + x) * 4
                        for c in 0..<4 { px[di + c] = src[si + c] }
                    } }
                    let l = registerRGBALayer("#invicon:\(tile)", px)
                    invIconLayers[tile] = l
                    return l
                }
            }
        }
        // Not in the node atlas: a chest-only craftitem's inventory_image lives
        // in media but was never a node face, so waiting on the atlas left the
        // slot blank until the next full atlas rebuild landed (#254). Bake it
        // straight from media (same path wield/dropped items use), so the icon
        // appears the instant the panel opens. All PNGs must be present.
        // Fill (not fit) the layer: the icon draw uses appendQuad with the full
        // 0..1 UV, matching the atlas-upscale branch above -- a fit sub-rect
        // would render a tiny icon in the corner. Item images are square, so a
        // square fill is exact.
        let imgs = NodeRegistry.imageNames(tile)
        guard !imgs.isEmpty, imgs.allSatisfy({ client.media.store[$0] != nil }),
              let px = TextureAtlas.evaluateModifiedFill(tile, media: client.media, canvas: ModelTextureHandoff.size)
        else { return nil }
        let l = registerRGBALayer("#invicon:\(tile)", px)
        invIconLayers[tile] = l
        return l
    }

    /// What a 3D inventory icon draws, resolved once per item name: the three
    /// cube faces' layers and shades, or a mesh node's model + fitted scale.
    /// nil = no 3D icon (a flat inventory_image, or an unknown node). Resolving
    /// this per slot per tick was ~8 registry lookups and 4 array allocations
    /// per block slot (#322); now it's one dictionary hit.
    private enum NodeIcon {
        case cube([(shade: Float, dep: Float, corners: Int, layer: Int)])   // corners: index into cubeIconCorners
        case mesh(file: String, layer: Int, mid: SIMD3<Float>, scale: Float)
    }
    private var nodeIconCache: [String: NodeIcon?] = [:]
    /// The three camera-facing faces at yaw 45 + pitch 30, unit half-size:
    /// left (-Z=5), right (+X=2), top (+Y=0). Order is draw order (top last
    /// so it wins the flattened overlap).
    private static let cubeIconFaces: [(fi: Int, shade: Float, dep: Float)] = [
        (5, packTint(184, 184, 184), -0.010), (2, packTint(140, 140, 140), -0.010), (0, packTint(255, 255, 255), -0.014)]
    private static let cubeIconCorners: [[SIMD3<Float>]] = [
        [SIMD3(1, -1, -1), SIMD3(-1, -1, -1), SIMD3(-1, 1, -1), SIMD3(1, 1, -1)],
        [SIMD3(1, -1, 1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(1, 1, 1)],
        [SIMD3(-1, 1, -1), SIMD3(-1, 1, 1), SIMD3(1, 1, 1), SIMD3(1, 1, -1)]]

    private func resolveNodeIcon(_ name: String) -> NodeIcon? {
        if let hit = nodeIconCache[name] { return hit }
        var out: NodeIcon? = nil
        defer { nodeIconCache[name] = out }
        if let img = client.items.image(for: name), !img.isEmpty { return nil }
        guard let id = client.nodes.id(for: name), id != WorldMap.CONTENT_AIR else { return nil }
        switch client.nodes.kind(id) {
        case .cube:
            let topTile = client.nodes.faceTile(id, 0)   // last-resort so no face is a hole (#255)
            var faces: [(shade: Float, dep: Float, corners: Int, layer: Int)] = []
            for (k, f) in Self.cubeIconFaces.enumerated() {
                let tile = client.nodes.faceTile(id, f.fi) ?? topTile
                guard let tile, let layer = iconLayerForTile(tile) ?? topTile.flatMap(iconLayerForTile) else { continue }
                faces.append((f.shade, f.dep, k, layer))
            }
            if !faces.isEmpty { out = .cube(faces) }
        case .mesh:
            guard let file = client.nodes.meshNodes()[id], let model = nodeMeshModel(for: id), !model.positions.isEmpty,
                  let tile = client.nodes.faceTile(id, 0), let layer = iconLayerForTile(tile) else { return nil }
            var lo = model.positions[0], hi = lo
            for p in model.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
            let ext = max(hi.x - lo.x, max(hi.y - lo.y, hi.z - lo.z))
            out = .mesh(file: file, layer: layer, mid: (lo + hi) * 0.5, scale: ext > 1e-4 ? 1 / ext : 1)
        default:
            break
        }
        return out
    }

    /// Draw a node item as a small 3D isometric icon on the panel plane -- a cube
    /// shows top + two sides, a mesh node (chest) shows its model -- instead of a
    /// flat face tile (#219). Uses model-texture layers (iconLayerForTile) so the
    /// geometry samples the right atlas. Returns false for non-node items (tools,
    /// craftitems, and nodes shipping a 2D inventory_image) so the caller draws
    /// the flat icon. Iso: yaw 45deg + pitch 30deg, the classic inventory angle.
    private func nodeIcon3D(_ name: String, center: SIMD3<Float>, oRight: SIMD3<Float>, oUp: SIMD3<Float>,
                            oToward: SIMD3<Float>, size: Float, v: inout [Float], idx: inout [UInt32]) -> Bool {
        guard let icon = resolveNodeIcon(name) else { return false }
        let cy = cosf(0.785), sy = sinf(0.785), cp = cosf(0.52), sp = sinf(0.52)
        @inline(__always) func iso(_ c: SIMD3<Float>) -> SIMD3<Float> {
            let x1 = c.x * cy + c.z * sy, z1 = -c.x * sy + c.z * cy
            return SIMD3(x1, c.y * cp - z1 * sp, c.y * sp + z1 * cp)
        }
        @inline(__always) func push(_ p: SIMD3<Float>, _ u: Float, _ w: Float, _ layer: Float, _ tint: Float) {
            pushV(&v, p.x, p.y, p.z, u, w, layer, 1.0, 255, tint)
        }
        let uvs = Self.quadUVsBL
        switch icon {
        case .cube(let faces):
            // 2.5D iso decal: each face keeps its iso screen shape but sits at a
            // constant depth, drawn sides then top so the top wins the overlap;
            // real per-vertex depth made the near faces occlude the top (#255).
            let h = size * 0.5
            for f in faces {
                let vb = UInt32(v.count / 9)
                let c = Self.cubeIconCorners[f.corners]
                for k in 0..<4 {
                    let r = iso(c[k] * h)
                    push(center + r.x * oRight + r.y * oUp + f.dep * oToward, uvs[k].0, uvs[k].1, Float(f.layer), f.shade)
                }
                pushQuad(&idx, vb)
            }
            return true
        case .mesh(let file, let layer, let mid, let scale):
            guard let model = nodeModelCache[file] else { return false }
            let s = size * scale
            let vb = UInt32(v.count / 9)
            for k in 0..<model.positions.count {
                let r = iso((model.positions[k] - mid) * s)
                push(center + r.x * oRight + r.y * oUp + r.z * oToward, model.uvs[k].x, model.uvs[k].y, Float(layer), 16777215)
            }
            for i in model.indices { idx.append(vb + i) }
            return true
        }
    }

    private func invCountLayer(_ n: Int) -> Int? {
        if let l = invCountLayers[n] { return l }
        guard let px = Self.renderTextRGBA("\(n)", canvas: ModelTextureHandoff.size, fontFrac: 0.42) else { return nil }
        let l = registerRGBALayer("#count\(n)", px)
        invCountLayers[n] = l
        modelTexturesDirty = true
        return l
    }

    // Armor-slot labels (helmet/chest/legs/boots/off-hand), baked once, shown on
    // empty armor cells so the slots are identifiable.
    // XP (#107) from mcl_experience's HUD elements, via Client.onXp.
    private var xpLevel = 0
    private var xpFraction: Float = 0
    private var xpLevelLayer = -1          // overlay text layer for the level digits
    private var xpLevelText = ""           // what that layer currently shows
    /// Level + fill to draw; the sim can stub them (-vrdev.fakeXp 1) so the bar
    /// and digits can be screenshotted headless (the dev account has no XP).
    private func xpDisplay() -> (level: Int, fraction: Float) {
        #if targetEnvironment(simulator)
        if UserDefaults.standard.bool(forKey: "vrdev.fakeXp") { return (7, 0.6) }
        #endif
        return (xpLevel, xpFraction)
    }

    // Entity nametags (#118): one overlay text layer per distinct label, kept
    // for the session (names are few; capped so a griefer can't grow the
    // texture array without bound).
    private var nametagLayers: [String: (layer: Int, aspect: Float)] = [:]
    private func nametagLayer(_ text: String) -> (layer: Int, aspect: Float)? {
        if let l = nametagLayers[text] { return l }
        // Filled (full-canvas) render, not renderTextRGBA at a small fontFrac: the
        // glyphs fill 128px instead of ~20px, so the upscaled quad reads crisp
        // instead of blurry (#175). Caller draws at the returned aspect.
        guard nametagLayers.count < 64,
              let r = Self.renderTextFilled(String(text.prefix(24)), canvas: ModelTextureHandoff.size)
        else { return nil }
        let l = registerRGBALayer("#nametag:\(text)", r.px)
        nametagLayers[text] = (l, r.aspect); modelTexturesDirty = true
        return (l, r.aspect)
    }

    // Server HUD elements (#103): generic image/text/waypoint elements from
    // HUDADD (boss bars, potion effects, vignettes), drawn in the overlay
    // against a nominal 1920x1080 screen mapped onto a +-0.42 x +-0.32 rad
    // window 1.2 m ahead. Statbars and the XP pair have their own paths.
    private var hudTextLayers: [Int: (layer: Int, text: String, aspect: Float)] = [:]
    private var hudTextBlocks: [Int: (layer: Int, text: String, aspect: Float, lines: Int, lineToCap: Float)] = [:]
    private var hudElementsLogged = false          // sim: one-shot dump of the server's HUD elements
    private static let hudScreen = SIMD2<Float>(1920, 1080)
    // Horizontal half-angle kept under the peripheral stat columns (hearts /
    // hunger at +-0.66 rad, bowing in to ~0.56 at the top) so VoxeLibre's
    // top-right potion-effect stack doesn't land on the drumsticks.
    private static let hudHalfAngle = SIMD2<Float>(0.36, 0.32)
    private static let hudDepth: Float = 1.2
    /// Desktop HUD sizes are tuned for a monitor, where 20 px of text is fine;
    /// at the same angular size in VR it's unreadable. Sizes (not positions)
    /// get this boost; the XP digits and nametags are already sized this way.
    private static let hudSizeBoost: Float = 2.5

    /// Width/height from a PNG's IHDR: the engine sizes image elements by the
    /// texture's original pixel size, which the fitted 128px canvas loses.
    private static func pngSize(_ d: Data) -> SIMD2<Float>? {
        guard d.count >= 24 else { return nil }
        let b = [UInt8](d.prefix(24))
        guard b[0] == 0x89, b[1] == 0x50, b[12] == 0x49, b[13] == 0x48, b[14] == 0x44, b[15] == 0x52 else { return nil }
        func u32(_ i: Int) -> Int { (Int(b[i]) << 24) | (Int(b[i + 1]) << 16) | (Int(b[i + 2]) << 8) | Int(b[i + 3]) }
        let w = u32(16), h = u32(20)
        guard w > 0, h > 0, w < 16384, h < 16384 else { return nil }
        return SIMD2(Float(w), Float(h))
    }

    /// Text colour from a HUD element's `number` (ARGB; the engine treats alpha
    /// 0 as opaque, and we have no per-vertex alpha anyway).
    private static func hudTint(_ n: Int) -> Float {
        packTint(Int((n >> 16) & 0xFF), Int((n >> 8) & 0xFF), Int(n & 0xFF))
    }

    /// Like hudTextLayer, but for server HUD *text elements*: multi-line and
    /// sized by line metrics (renderTextBlock). Separate cache; same layer cap.
    private func hudTextBlockLayer(id: Int, text: String) -> (layer: Int, aspect: Float, lines: Int, lineToCap: Float)? {
        if let cur = hudTextBlocks[id], cur.text == text { return (cur.layer, cur.aspect, cur.lines, cur.lineToCap) }
        let clean = ItemRegistry.stripEscapes(text)
        guard let r = Self.renderTextBlock(clean, canvas: ModelTextureHandoff.size) else { return nil }
        if let cur = hudTextBlocks[id] {
            updateModelLayer(cur.layer, r.px)
            hudTextBlocks[id] = (cur.layer, text, r.aspect, r.lines, r.lineToCap)
            return (cur.layer, r.aspect, r.lines, r.lineToCap)
        }
        guard hudTextLayers.count + hudTextBlocks.count < 96 else { return nil }
        let l = registerRGBALayer("#hudblock\(id)", r.px)
        hudTextBlocks[id] = (l, text, r.aspect, r.lines, r.lineToCap); modelTexturesDirty = true
        return (l, r.aspect, r.lines, r.lineToCap)
    }

    /// Per-element mutable text layer (timers change every second, so a
    /// per-string cache would churn); re-rendered in place when the text changes.
    /// Returns the layer and the text's aspect (width/height) so the caller draws
    /// a constant-height quad: server text carries translation/colour escapes
    /// (`show_wielded_item` pushes the item description on wield switch) which we
    /// strip here, matching the inventory name path.
    private func hudTextLayer(id: Int, text: String) -> (layer: Int, aspect: Float)? {
        // Cache hit first: it keys on the raw text, so the escape strip (a
        // per-character scan, per HUD text element per tick) only runs on a miss.
        if let cur = hudTextLayers[id], cur.text == text { return (cur.layer, cur.aspect) }
        let clean = ItemRegistry.stripEscapes(text)
        guard let r = Self.renderTextFilled(String(clean.prefix(48)), canvas: ModelTextureHandoff.size) else { return nil }
        if let cur = hudTextLayers[id] {
            updateModelLayer(cur.layer, r.px)
            hudTextLayers[id] = (cur.layer, text, r.aspect)
            return (cur.layer, r.aspect)
        }
        guard hudTextLayers.count < 96 else { return nil }
        let l = registerRGBALayer("#hud\(id)", r.px)
        hudTextLayers[id] = (l, text, r.aspect); modelTexturesDirty = true
        return (l, r.aspect)
    }

    /// The pixel size the engine sizes an image element by: the texture AFTER
    /// its modifiers. A `[resize:WxH` (or `[combine:WxH`) fixes it outright
    /// (boss bars and the XP bar end in one), a later `[transformR90/270`
    /// swaps it, otherwise it's the base PNG's own size.
    private func hudSpecSize(_ spec: String, base: SIMD2<Float>?) -> SIMD2<Float> {
        var size = base ?? SIMD2(64, 64)
        var sizeAt = spec.startIndex
        for key in ["[resize:", "[combine:"] {
            var search = spec.startIndex
            while let r = spec.range(of: key, range: search..<spec.endIndex) {
                let tail = spec[r.upperBound...]
                let w = tail.prefix { $0.isNumber }
                let afterW = tail.dropFirst(w.count)
                if afterW.first == "x" {
                    let h = afterW.dropFirst().prefix { $0.isNumber }
                    if let wi = Int(w), let hi = Int(h), wi > 0, hi > 0, r.lowerBound >= sizeAt {
                        size = SIMD2(Float(wi), Float(hi)); sizeAt = r.lowerBound
                    }
                }
                search = r.upperBound
            }
        }
        let after = spec[sizeAt...]
        if after.contains("[transformR90") || after.contains("[transformR270") { size = SIMD2(size.y, size.x) }
        return size
    }

    /// Model-texture layer for a HUD image spec, requesting any PNG it needs
    /// that hasn't been downloaded (HUD textures aren't in the initial fetch).
    // Resolved (layer, uv, src size) per HUD image spec. hudImage runs per HUD
    // element per tick; once a spec has its layer the rest of the work below
    // (imageNames parse, PNG header read, hudSpecSize string ops) is fixed, so
    // cache it. Dropped alongside the layer in forgetTexture on a re-push.
    private var hudImageCache: [String: (layer: Int, uv: SIMD2<Float>, src: SIMD2<Float>)] = [:]
    private func hudImage(_ spec: String) -> (layer: Int, uv: SIMD2<Float>, src: SIMD2<Float>)? {
        if let c = hudImageCache[spec] { return c }
        let imgs = NodeRegistry.imageNames(spec)
        if modelTexLayer[spec] == nil {
            guard !modelFailed.contains(spec) else { return nil }
            let missing = imgs.filter { client.media.store[$0] == nil }
            if !missing.isEmpty {
                // Only ask for files the server announced: request() with an
                // empty set fires onComplete, and doing that every frame churns
                // the texture rebuild. A never-announced name will never come.
                let fetchable = missing.filter { client.media.announced.contains($0) }
                if fetchable.count < missing.count { modelFailed.insert(spec); return nil }
                client.media.request(Set(fetchable))
                return nil
            }
            if assignModelTexture(spec) { modelTexturesDirty = true }
        }
        guard let layer = modelTexLayer[spec] else { return nil }
        let base = imgs.first.flatMap { client.media.store[$0] }.flatMap(Self.pngSize)
        let r = (layer, modelTexUV[spec] ?? SIMD2(1, 1), hudSpecSize(spec, base: base))
        hudImageCache[spec] = r
        return r
    }

    /// A textured overlay quad whose 0..1 texture coords are scaled by `uv`
    /// (fitted images occupy the [0, uv] corner of their 128px canvas).
    private func appendOverlayQuadUV(center: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                                     hw: Float, hh: Float, layer: Int, uv: SIMD2<Float>, tint: Float,
                                     v: inout [Float], idx: inout [UInt32]) {
        let corners = [center - right * hw - up * hh, center + right * hw - up * hh,
                       center + right * hw + up * hh, center - right * hw + up * hh]
        let uvs = Self.quadUVsBL
        let base = UInt32(v.count / 9)
        for k in 0..<4 {
            let p = corners[k]
            pushV(&v, p.x, p.y, p.z, uvs[k].0 * uv.x, uvs[k].1 * uv.y, Float(layer), 1.0, 255, tint)
        }
        pushQuad(&idx, base)
    }

    #if targetEnvironment(simulator)
    /// Sim aid (-vrdev.fakeHud 1): a boss bar and a potion effect the way
    /// mcl_bossbars / mcl_potions add them, so the generic path can be
    /// screenshotted headless.
    private static func fakeHudElements() -> [(Int, Client.HudElement)] {
        func el(_ type: Int, _ text: String, pos: SIMD2<Float>, align: SIMD2<Float>, offset: SIMD2<Float>,
                scale: SIMD2<Float> = SIMD2(1, 1), number: Int = 0xFFFFFF, z: Int = 0) -> Client.HudElement {
            var e = Client.HudElement()
            e.type = type; e.text = text; e.pos = pos; e.align = align; e.offset = offset
            e.scale = scale; e.number = number; e.zIndex = z
            return e
        }
        return [
            (9001, el(1, "Ender Dragon", pos: SIMD2(0.5, 0), align: SIMD2(0, 1), offset: SIMD2(0, 40), number: 0xFF55FF)),
            // The real mcl_bossbars spec for red at 60% (frames 4/5 of 14).
            (9002, el(0, "(mcl_bossbars.png^[transformR270^[verticalframe:14:4^(mcl_bossbars_empty.png^[lowpart:60:mcl_bossbars.png^[transformR270^[verticalframe:14:5))^[resize:1456x40",
                      pos: SIMD2(0.5, 0), align: SIMD2(0, 1), offset: SIMD2(0, 65), scale: SIMD2(0.375, 0.375))),
            (9003, el(0, "mcl_potions_effect_swiftness.png", pos: SIMD2(1, 0), align: SIMD2(1, 1), offset: SIMD2(-54, 3), scale: SIMD2(0.375, 0.375), z: 100)),
            (9004, el(1, "Swiftness II", pos: SIMD2(1, 0), align: SIMD2(0, 1), offset: SIMD2(-32, 50), z: 100)),
            (9005, el(1, "0:42", pos: SIMD2(1, 0), align: SIMD2(0, 1), offset: SIMD2(-32, 65), z: 100)),
        ]
    }
    #endif

    /// Sim-only: remember where each advancement-toast element landed, in
    /// nominal HUD pixels, so -vrdev.awardTest can check the text and icon sit
    /// inside the background box without a human squinting at a screenshot.
    @inline(__always) private func noteAwardRect(_ name: String, center: SIMD2<Float>, size: SIMD2<Float>) {
        #if targetEnvironment(simulator)
        guard name.hasPrefix("award_") else { return }
        simAwardRects[name] = (center - size / 2, center + size / 2)
        #endif
    }

    /// Draw the server's generic HUD elements (Hud::drawLuaElements): images
    /// sized by texture px * scale (negative scale = percent of screen) and
    /// anchored by align (-1..1), text in its `number` colour, waypoints at the
    /// projected world position. Sorted by z_index so vignettes go underneath.
    private func appendServerHUD(eye: SIMD3<Float>, cosY cy: Float, sinY sy: Float,
                                 v: inout [Float], idx: inout [UInt32]) {
        // Sorted view cached by hudGeneration: the server keeps ~80 pre-created
        // potion slots, so mapping + z-sorting them every frame was pure waste
        // (#249). COW keeps `var elems = sortedHud` alloc-free unless a sim path
        // appends to it below.
        if client.hudGeneration != sortedHudGen {
            sortedHud = client.hudElements.map { ($0.key, $0.value) }.sorted { $0.1.zIndex < $1.1.zIndex }
            sortedHudGen = client.hudGeneration
        }
        var elems = sortedHud
        #if targetEnvironment(simulator)
        let hudBaseCount = elems.count
        if UserDefaults.standard.bool(forKey: "vrdev.fakeHud") { elems.append(contentsOf: Self.fakeHudElements()) }
        // -vrdev.fakeAward 1: the exact 4 elements VoxeLibre's advancement toast
        // adds (awards/api.lua), including the icon-as-statbar, to verify #222.
        if UserDefaults.standard.bool(forKey: "vrdev.fakeAward") || UserDefaults.standard.bool(forKey: "vrdev.awardTest") {
            func aw(_ type: Int, _ text: String, name: String, off: SIMD2<Float>, align: SIMD2<Float>,
                    scale: SIMD2<Float> = SIMD2(1, 1), size: SIMD2<Float> = .zero, number: Int = 0xFFFFFF, z: Int) -> Client.HudElement {
                var e = Client.HudElement()
                e.type = type; e.text = text; e.name = name; e.pos = SIMD2(0.5, 0); e.offset = off
                e.align = align; e.scale = scale; e.size = size; e.number = number; e.zIndex = z
                return e
            }
            // Names match awards/api.lua so the render path's award_au/award_title
            // font-shrink and the award_icon statbar hack are exercised headless.
            elems.append((9101, aw(0, "awards_bg_default.png", name: "award_bg", off: SIMD2(0, 138), align: SIMD2(0, -1), scale: SIMD2(1.25, 1), z: 101)))
            elems.append((9102, aw(1, UserDefaults.standard.string(forKey: "vrdev.awardHeader") ?? "Advancement Made!", name: "award_au", off: SIMD2(30, 40), align: SIMD2(0, -1), number: 0xFFFF00, z: 102)))
            let title = UserDefaults.standard.string(forKey: "vrdev.awardTitle")
                ?? (UserDefaults.standard.bool(forKey: "vrdev.awardTest") ? "Isn't It Iron Pick" : "Acquire Hardware")
            elems.append((9103, aw(1, title, name: "award_title", off: SIMD2(35, 100), align: SIMD2(0, -1), z: 102)))
            elems.append((9104, aw(2, "mcl_potions_effect_swiftness.png", name: "award_icon", off: SIMD2(-138, 62), align: SIMD2(0, 0), size: SIMD2(64, 64), number: 2, z: 102)))
        }
        // Re-sort only if a sim path added fake elements; the cached list is
        // already z-sorted.
        if elems.count != hudBaseCount { elems.sort { $0.1.zIndex < $1.1.zIndex } }
        #endif
        awardBox = nil
        guard !elems.isEmpty else { return }
        let skip = client.xpHudIds
        let hx = frameHeadXform
        let headPos = SIMD3<Float>(hx.columns.3.x, hx.columns.3.y, hx.columns.3.z)
        let hr = simd_normalize(SIMD3<Float>(hx.columns.0.x, hx.columns.0.y, hx.columns.0.z))
        let hu = simd_normalize(SIMD3<Float>(hx.columns.1.x, hx.columns.1.y, hx.columns.1.z))
        let hf = -simd_normalize(SIMD3<Float>(hx.columns.2.x, hx.columns.2.y, hx.columns.2.z))
        let D = Self.hudDepth
        let kx = 2 * Self.hudHalfAngle.x / Self.hudScreen.x     // rad per nominal pixel
        let ky = 2 * Self.hudHalfAngle.y / Self.hudScreen.y
        // Origin-space point for a nominal screen pixel (y down), on the window.
        func at(_ px: SIMD2<Float>) -> SIMD3<Float> {
            let az = (px.x - Self.hudScreen.x / 2) * kx, el = (Self.hudScreen.y / 2 - px.y) * ky
            return headPos + hf * D + hr * (tan(az) * D) + hu * (tan(el) * D)
        }
        // Nominal screen pixel of a world (server-grid node) position, or nil
        // when it's behind the head (Hud::calculateScreenPos).
        func pixel(ofNode wp: SIMD3<Float>) -> SIMD2<Float>? {
            let p = wp + Client.gridShift
            let scale = PlayerState.scale
            let rx = (p.x - eye.x) * scale, ry = (p.y - eye.y) * scale, rz = (p.z - eye.z) * scale
            let op = SIMD3<Float>(rx * cy - rz * sy, ry, -(rx * sy + rz * cy)) - headPos
            let z = simd_dot(op, hf)
            guard z > 0.05 else { return nil }
            return SIMD2(Self.hudScreen.x / 2 + atan2(simd_dot(op, hr), z) / kx,
                         Self.hudScreen.y / 2 - atan2(simd_dot(op, hu), z) / ky)
        }
        // Budget counts quads actually emitted: VoxeLibre pre-creates ~80 empty
        // potion-effect slots, which must not starve the elements after them.
        var drawn = 0
        #if targetEnvironment(simulator)
        if !hudElementsLogged {
            hudElementsLogged = true
            for (id, e) in elems {
                print("[hud] elem id=\(id) type=\(e.type) pos=\(e.pos) off=\(e.offset) scale=\(e.scale) align=\(e.align) z=\(e.zIndex) num=\(String(e.number, radix: 16)) text='\(e.text.prefix(60))' skipXp=\(skip.contains(id))"); fflush(stdout)
            }
        }
        #endif
        // Visible text lines, for the stacking check in the text case below.
        let textLines: [(id: Int, pos: SIMD2<Float>, off: SIMD2<Float>)] = elems.compactMap { (id, e) in
            e.type == 1 && !e.text.isEmpty && !skip.contains(id) ? (id, e.pos, e.offset) : nil
        }
        for (id, e) in elems where !skip.contains(id) && drawn < 128 {
            // statbar/inventory/compass/minimap/hotbar aren't drawn here EXCEPT
            // the award-icon hack: VoxeLibre's advancement toast draws its icon as
            // a statbar (type 2) with an explicit size + small number so it can be
            // scaled (awards/api.lua). Let that one through; the real vitals
            // statbars (number ~20, no size) stay ours (#222).
            // The toast's statbar is named "award_icon", number 2, no text2;
            // vl_hudbars' vitals bars always set size (24) AND text2 (bgicon) and
            // hit number 1-2 exactly when you're about to die, which the old
            // size+number guess mistook for a toast icon (#289).
            let awardIcon = e.type == 2 && (e.name == "award_icon" || (e.text2.isEmpty && e.number == 2 && e.size.x >= 32))
            guard e.type == 0 || e.type == 1 || e.type == 3 || e.type == 4 || e.type == 5 || awardIcon else { continue }
            // VoxeLibre adds its own crosshair image; we deliberately draw no
            // reticle (#48: the pointed-node outline is the cue, and a reticle
            // at a guessed depth reads badly in stereo).
            if e.type == 0, e.text.range(of: "crosshair", options: .caseInsensitive) != nil { continue }
            // VoxeLibre also draws its hotbar background (mcl_inventory_hotbar.png)
            // as an image element; ours is wrist-anchored (#57), so a strip of
            // empty slots floating at the bottom of view is just noise.
            if e.type == 0, e.text.range(of: "hotbar", options: .caseInsensitive) != nil { continue }
            // Pixel offsets scale with the size boost so a mod's layout (a title
            // over its bar, a label over its timer) stays proportional; only the
            // normalised position stays pinned to the screen edge.
            let anchor = e.pos * Self.hudScreen + e.offset * Self.hudSizeBoost
            switch e.type {
            case 1:                                              // text
                guard !e.text.isEmpty, let t = hudTextBlockLayer(id: id, text: e.text) else { continue }
                let mul = (e.size.x > 0 ? e.size.x : 1) * Self.hudSizeBoost
                // Constant glyph HEIGHT, width follows the text's aspect, so a
                // long subtitle (death banner, wield name) reads at the same size
                // as a short title instead of being shrunk to fit a fixed square.
                // Exception: VoxeLibre's advancement toast (awards/api.lua) sizes
                // its two lines to a fixed 128px background box. Our VR-legible
                // 26px glyph (#157) is ~1.6x too tall for that box, so a real
                // (longer) achievement name spilled past it. Match desktop
                // proportions for just those two lines so the title fits (#222).
                let isAwardText = e.name == "award_au" || e.name == "award_title"
                // Size constants are cap heights; the block's rows are line
                // boxes, so scale by row count and line/cap to keep capitals put.
                var th = (isAwardText ? 16 : 26) * mul * Float(t.lines) * t.lineToCap, tw = th * max(0.4, t.aspect)
                // Mods lay out stacked lines for desktop's ~15px font (the
                // potion HUD puts an effect's name and timer 15px apart); our
                // enlarged glyph overlapped the line below. Cap each row at the
                // gap to the nearest text line sharing this anchor, so stacked
                // lines fit like desktop while lone text keeps its full size.
                var gap = Float.infinity
                for o in textLines where o.id != id && o.pos == e.pos && abs(o.off.x - e.offset.x) < 40 {
                    let dy = abs(o.off.y - e.offset.y)
                    if dy > 0.5 { gap = min(gap, dy) }
                }
                if gap.isFinite {
                    let maxTh = gap * Self.hudSizeBoost * Float(t.lines)
                    if th > maxTh { let k = maxTh / th; th *= k; tw *= k }
                }
                // Our glyphs run wider than desktop's, so the longest toast line
                // ("Secret Advancement Made!") overran the box. Shrink an award
                // line only as far as it takes to stay inside the background.
                if isAwardText, let box = awardBox {
                    let cx = anchor.x + e.align.x * tw / 2, pad: Float = 12 * Self.hudSizeBoost
                    let room = 2 * max(0, min(cx - box.lo.x, box.hi.x - cx) - pad)
                    if tw > room, room > 0 { let k = room / tw; tw *= k; th *= k }
                }
                // align.x: 0 centred on pos, 1 starts at pos, -1 ends at pos.
                let cpx = anchor + SIMD2(e.align.x * tw / 2, e.align.y * th / 2)
                let c = at(cpx)
                noteAwardRect(e.name, center: cpx, size: SIMD2(tw, th))
                appendOverlayQuadUV(center: c, right: hr, up: hu, hw: tw / 2 * kx * D, hh: th / 2 * ky * D,
                                    layer: t.layer, uv: SIMD2(1, 1), tint: Self.hudTint(e.number), v: &v, idx: &idx)
                drawn += 1
            case 0, 5:                                           // image / image_waypoint
                guard !e.text.isEmpty, let img = hudImage(e.text) else { continue }
                var dst = img.src * e.scale * Self.hudSizeBoost
                if e.scale.x < 0 { dst.x = Self.hudScreen.x * (-0.01 * e.scale.x) }   // percent of screen: no boost
                if e.scale.y < 0 { dst.y = Self.hudScreen.y * (-0.01 * e.scale.y) }
                var base = anchor
                if e.type == 5 { guard let p = pixel(ofNode: e.worldPos) else { continue }; base = p + e.offset * Self.hudSizeBoost }
                let c = at(base + e.align * dst / 2)
                if e.name == "award_bg" { awardBox = (base + e.align * dst / 2 - dst / 2, base + e.align * dst / 2 + dst / 2) }
                noteAwardRect(e.name, center: base + e.align * dst / 2, size: dst)
                appendOverlayQuadUV(center: c, right: hr, up: hu, hw: dst.x / 2 * kx * D, hh: dst.y / 2 * ky * D,
                                    layer: img.layer, uv: img.uv, tint: 16777215, v: &v, idx: &idx)
                drawn += 1
            case 3:                                              // inventory list: the offhand slot's item (mcl_offhand)
                // Desktop draws the offhand item as a flat inventory image here.
                // We already resolve every list's icon tile each tick, so just
                // draw the item icon(s) for list `text`, `number` slots wide, at
                // the same anchor/align as the slot's background image. A torch,
                // shield, compass or map in the offhand now shows, matching
                // desktop (the slot frame is a separate image element already).
                let stacks = client.inventory[e.text] ?? []
                let px: Float = 40 * Self.hudSizeBoost           // item size inside the ~44px slot
                for i in 0..<max(1, e.number) where i < stacks.count {
                    guard let st = stacks[i], !st.name.isEmpty, let layer = invIconModelLayer(st.name) else { continue }
                    let dst = SIMD2<Float>(px, px)
                    let cpx = anchor + SIMD2(Float(i) * px, 0) + e.align * dst / 2
                    let c = at(cpx)
                    appendOverlayQuadUV(center: c, right: hr, up: hu, hw: dst.x / 2 * kx * D, hh: dst.y / 2 * ky * D,
                                        layer: layer, uv: SIMD2(1, 1), tint: 16777215, v: &v, idx: &idx)
                    drawn += 1
                    // drawItemStack extras, like desktop: the stack count in the
                    // lower-right corner and, for worn tools/shields, a wear bar
                    // along the bottom going green -> red as durability drops.
                    if st.count > 1, let t = hudTextLayer(id: -2000 - i, text: String(st.count)) {
                        let th = 16 * Self.hudSizeBoost, tw = th * max(0.4, t.aspect)
                        let tc = at(cpx + SIMD2(dst.x / 2 - tw / 2, dst.y / 2 - th / 2))
                        appendOverlayQuadUV(center: tc + hf * -0.001, right: hr, up: hu, hw: tw / 2 * kx * D, hh: th / 2 * ky * D,
                                            layer: t.layer, uv: SIMD2(1, 1), tint: 16777215, v: &v, idx: &idx)
                    }
                    if st.wear > 0, highlightLayer >= 0 {
                        let left = max(0, min(1, 1 - Float(st.wear) / 65535))
                        let bh = 3 * Self.hudSizeBoost, bw = dst.x * 0.8
                        let by = cpx.y + dst.y / 2 - bh * 1.5
                        let bx0 = cpx.x - bw / 2
                        appendOverlayQuadUV(center: at(SIMD2(cpx.x, by)), right: hr, up: hu, hw: bw / 2 * kx * D, hh: bh / 2 * ky * D,
                                            layer: highlightLayer, uv: SIMD2(1, 1), tint: Self.packTint(0, 0, 0), v: &v, idx: &idx)
                        let fw = bw * left
                        appendOverlayQuadUV(center: at(SIMD2(bx0 + fw / 2, by)) + hf * -0.001, right: hr, up: hu, hw: fw / 2 * kx * D, hh: bh / 2 * ky * D,
                                            layer: highlightLayer, uv: SIMD2(1, 1),
                                            tint: Self.packTint(Int(255 * min(1, 2 * (1 - left))), Int(255 * min(1, 2 * left)), 0), v: &v, idx: &idx)
                    }
                }
            case 2:                                              // award-icon statbar drawn as one scaled image (#222)
                guard !e.text.isEmpty, let img = hudImage(e.text) else { continue }
                let dst = (e.size.x > 0 ? e.size : SIMD2(64, 64)) * Self.hudSizeBoost
                // Hud::drawStatbar puts the first icon's TOP-LEFT at pos+offset and
                // ignores alignment; centring it there pushed the toast icon half
                // its size up and left, hanging off the box (#222 follow-up).
                let c = at(anchor + dst / 2)
                noteAwardRect(e.name, center: anchor + dst / 2, size: dst)
                appendOverlayQuadUV(center: c, right: hr, up: hu, hw: dst.x / 2 * kx * D, hh: dst.y / 2 * ky * D,
                                    layer: img.layer, uv: img.uv, tint: 16777215, v: &v, idx: &idx)
                drawn += 1
            default:                                             // 4: waypoint = name + distance + unit text
                guard let p = pixel(ofNode: e.worldPos) else { continue }
                let dist = simd_distance(e.worldPos + Client.gridShift, eye)
                let label = (e.name.isEmpty ? "" : e.name + " ") + "\(Int(dist.rounded()))" + e.text
                guard let t = hudTextLayer(id: id, text: label) else { continue }
                let th: Float = 26 * Self.hudSizeBoost, tw = th * max(0.4, t.aspect)
                let c = at(p + e.offset * Self.hudSizeBoost)
                appendOverlayQuadUV(center: c, right: hr, up: hu, hw: tw / 2 * kx * D, hh: th / 2 * ky * D,
                                    layer: t.layer, uv: SIMD2(1, 1), tint: Self.hudTint(e.number), v: &v, idx: &idx)
                drawn += 1
            }
        }
    }

    /// A file the server re-pushed (MEDIA_PUSH) has landed: forget every model
    /// texture composed from it so its next use re-composites from the new
    /// bytes, and rebuild the node atlas if a node face uses it. Pushes are
    /// rare (skins, map items), so the atlas rebuild is an acceptable cost.
    private func forgetTexture(_ file: String) {
        var dropped = 0
        for spec in Array(modelTexLayer.keys) where NodeRegistry.imageNames(spec).contains(file) {
            modelTexLayer[spec] = nil; modelTexUV[spec] = nil; hudImageCache[spec] = nil; dropped += 1
        }
        modelFailed = modelFailed.filter { !NodeRegistry.imageNames($0).contains(file) }
        if dropped > 0 { itemDrawCache.removeAll() }
        // The node atlas is append-only now (seeded across rebuilds), so a
        // re-pushed file's tiles must be explicitly evicted from the seed or
        // the rebuild would keep their stale pixels.
        var evict: Set<String> = []
        for (name, _) in atlas.tileIndexSnapshot where NodeRegistry.imageNames(name).contains(file) { evict.insert(name) }
        if !evict.isEmpty {
            atlasDropTiles.formUnion(evict)
            atlasNeedsRebuild = true
            rebuildAtlas(); dropped += evict.count
        }
        if dropped > 0 { print("[media] re-pushed \(file): forgot \(dropped) texture(s)"); fflush(stdout) }
    }

    // Indexed by the mcl_armor "armor" list slot: 0 unused, 1 head .. 4 feet.
    private static let armorSlotLabels = ["", "Head", "Torso", "Legs", "Feet"]
    // Filled renderer via formspecLabelLayer for a crisp caption (#175).
    private func armorLabelLayer(_ i: Int) -> (layer: Int, aspect: Float)? {
        guard i >= 0, i < Self.armorSlotLabels.count else { return nil }
        return formspecLabelLayer(Self.armorSlotLabels[i])
    }

    /// Text layer for a formspec label (#176). Keyed by text; uses the filled
    /// renderer so a long station title keeps the same glyph height as a short
    /// slot caption (the caller draws the quad at the returned aspect).
    private func formspecLabelLayer(_ text: String) -> (layer: Int, aspect: Float)? {
        formspecLabelUse += 1
        if let cur = formspecLabelLayers[text] { formspecLabelLastUse[text] = formspecLabelUse; return cur }
        // The cache is shared by station titles, slot captions, tooltips, item
        // names AND the status banner ("Reconnecting... (3)" is a new string
        // each attempt). It used to stop at 96 entries for good, after which
        // the banner and every new label silently drew nothing. Recycle the
        // least recently used third instead; whatever the open panel shows
        // this tick has the newest stamps and survives.
        if formspecLabelLayers.count >= 96 {
            let victims = formspecLabelLastUse.sorted { $0.value < $1.value }.prefix(32)
            for (t, _) in victims {
                if let e = formspecLabelLayers.removeValue(forKey: t) {
                    modelTexLayer["#fslabel:\(t)"] = nil
                    freeModelLayers.append(e.layer)
                }
                formspecLabelLastUse[t] = nil
            }
        }
        guard let r = Self.renderTextFilled(String(text.prefix(48)), canvas: ModelTextureHandoff.size) else { return nil }
        let l = registerRGBALayer("#fslabel:\(text)", r.px)
        formspecLabelLayers[text] = (l, r.aspect)
        formspecLabelLastUse[text] = formspecLabelUse
        modelTexturesDirty = true
        return (l, r.aspect)
    }
    private var formspecLabelLastUse: [String: Int] = [:]
    private var formspecLabelUse = 0

    // Filled renderer so the tooltip name reads crisp regardless of length (#175);
    // the caller draws the quad at the returned aspect.
    private func invNameLayer(_ name: String, stack: Client.ItemStack? = nil) -> (layer: Int, aspect: Float, color: Float?)? {
        var d = client.items.descriptionColored(for: name)
        // An anvil rename lives in the stack's description meta (#271); the
        // first line is the name (VoxeLibre appends tooltip lines after \n).
        if let custom = stack?.customDescription {
            let first = custom.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? custom
            d = Formspec.cleanColored(first, caller: "item-desc")
        }
        guard let l = formspecLabelLayer(d.text) else { return nil }
        return (l.layer, l.aspect, d.color)
    }

    /// Draw the panel: dark backdrop + labels ride the model stream (tinted
    /// quads, origin space); slot cells, icons and rings are atlas billboards
    /// (node space). Everything is nudged toward the viewer in layers so it
    /// doesn't z-fight.
    private func appendInventoryPanel(eye: SIMD3<Float>, cosY: Float, sinY: Float,
                                      billboards: inout [EntityInstance], v: inout [Float], idx: inout [UInt32]) {
        _ = billboards   // panel is all fixed quads now (no billboards)
        guard inventoryOpen, let fr = invFrame, highlightLayer >= 0 else { player.setPanelPointer(nil); return }
        let scale = PlayerState.scale
        func toOrigin(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let rx = (p.x - eye.x) * scale, ry = (p.y - eye.y) * scale, rz = (p.z - eye.z) * scale
            return SIMD3(rx * cosY - rz * sinY, ry, -(rx * sinY + rz * cosY))
        }
        func toOriginDir(_ d: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(d.x * cosY - d.z * sinY, d.y, -(d.x * sinY + d.z * cosY))
        }
        let cell = Self.invCell
        let toward = -fr.fwd                       // toward the viewer
        let oRight = toOriginDir(fr.right), oUp = toOriginDir(fr.up)
        // Backdrop: wide enough for armor + main + craft (+preview).
        let (uMin, uMax, vMin, vMax) = invPanelBounds()
        let bc = fr.center + fr.right * ((uMin + uMax) * 0.5) + fr.up * ((vMin + vMax) * 0.5) - toward * 0.004
        appendQuad(center: toOrigin(bc), right: oRight, up: oUp, hw: (uMax - uMin) * 0.5, hh: (vMax - vMin) * 0.5,
                   layer: highlightLayer, tint: Self.packTint(8, 8, 12), v: &v, idx: &idx)
        // Server-sent stone panel (background9 from the formspec prepend): stretch
        // it over the whole backdrop so stations read as VoxeLibre instead of a
        // flat dark rect. Drawn just in front of the dark backdrop; slots/icons
        // sit in front of it (#244). MVP is a plain stretch, not a true 9-slice.
        for bg in formspecBackgrounds where bg.fill {
            guard let hi = hudImage(bg.texture) else {
                // The stone panel texture isn't baked -> panel falls back to the
                // bare dark backdrop, which reads as a plain grey slab (#254). Log
                // once per texture so a device capture shows if it's a missing-media
                // problem vs a look-pass (9-slice) one.
                // Only a genuinely stuck panel (blacklisted, or bytes never
                // arrived) is worth flagging -- a first-frame miss that self-heals
                // once media lands is normal. modelFailed used to keep it stuck
                // forever until onMediaReady learned to retry (#254).
                let names = NodeRegistry.imageNames(bg.texture)
                let stuck = modelFailed.contains(bg.texture) || !names.allSatisfy { client.media.store[$0] != nil }
                if stuck, bgMissLogged.insert(bg.texture).inserted {
                    print("[formspec] fill-bg STUCK \(bg.texture) failed=\(modelFailed.contains(bg.texture))"); fflush(stdout)
                }
                continue
            }
            let bgc = fr.center + fr.right * ((uMin + uMax) * 0.5) + fr.up * ((vMin + vMax) * 0.5) - toward * 0.0038
            appendOverlayQuadUV(center: toOrigin(bgc), right: oRight, up: oUp,
                                hw: (uMax - uMin) * 0.5 + Self.invCell * 0.5, hh: (vMax - vMin) * 0.5 + Self.invCell * 0.5,
                                layer: hi.layer, uv: hi.uv, tint: 16777215, v: &v, idx: &idx)
        }
        // Non-fill background[] art: each at its own rect (brewing bubbles, the
        // trade arrow panel, book/writing backdrops). Drawn in front of the stone
        // panel but behind slots/icons, like desktop VoxeLibre layers them (#245).
        for bg in invBackgrounds {
            guard let hi = hudImage(bg.texture) else { continue }
            let c = fr.center + fr.right * bg.u + fr.up * bg.v - toward * 0.0036
            appendOverlayQuadUV(center: toOrigin(c), right: oRight, up: oUp, hw: bg.hw, hh: bg.hh,
                                layer: hi.layer, uv: hi.uv, tint: 16777215, v: &v, idx: &idx)
        }
        // Static image[] elements (furnace fire gauge + cook arrow, #223). The
        // texture is a modifier chain (^[lowpart:PCT / ^[transformR270); hudImage
        // composes it (requesting any missing PNG) and the server re-sends the
        // form with a new percent as it burns, so the gauge fills over time.
        // Emitted BEFORE slots and labels: this pass has no depth test, so
        // emission order is draw order, and VoxeLibre puts 27 image[] slot
        // backgrounds ahead of each list[]. Drawing them after the icons hid
        // every item in the chest form on device (#261).
        for im in invImages {
            let c = fr.center + fr.right * im.u + fr.up * im.v - toward * 0.005
            if im.isItem {
                // item_image[]: draw the item's icon (3D node cube/chest, else its
                // flat inventory_image) so beacon payment rows / trade hints show
                // what item is meant (#232).
                let sz = min(im.hw, im.hh) * 1.4
                if nodeIcon3D(im.texture, center: toOrigin(c - toward * 0.006), oRight: oRight, oUp: oUp,
                              oToward: toOriginDir(toward), size: sz, v: &v, idx: &idx) { continue }
                if let flat = client.items.image(for: im.texture), let hi = hudImage(flat) {
                    appendOverlayQuadUV(center: toOrigin(c), right: oRight, up: oUp, hw: im.hw, hh: im.hh,
                                        layer: hi.layer, uv: hi.uv, tint: 16777215, v: &v, idx: &idx)
                }
                continue
            }
            guard let hi = hudImage(im.texture) else { continue }
            appendOverlayQuadUV(center: toOrigin(c), right: oRight, up: oUp, hw: im.hw, hh: im.hh,
                                layer: hi.layer, uv: hi.uv, tint: 16777215, v: &v, idx: &idx)
        }
        // Slots: all fixed panel-plane quads (no billboards), so cells, icons and
        // the backdrop share one orientation.
        for (i, s) in invSlots.enumerated() {
            func cq(_ off: Float) -> SIMD3<Float> { toOrigin(fr.center + fr.right * s.u + fr.up * s.v - toward * off) }
            let isHeld = invHeld.map { $0.loc == s.loc && $0.list == s.list && $0.index == s.index } ?? false
            // cell (dark) or hover/held (gold), both from the flat highlight layer.
            appendQuad(center: cq(0.002), right: oRight, up: oUp, hw: cell * 0.5, hh: cell * 0.5,
                       layer: highlightLayer, tint: (invHover == i || isHeld) ? Self.packTint(232, 184, 64) : Self.packTint(44, 44, 54),
                       v: &v, idx: &idx)
            let stack = inventoryStack(s)   // once per slot (was up to 3 lookups, each a nodemeta: parse)
            if let st = stack, !isHeld,
               nodeIcon3D(st.name, center: cq(0.008), oRight: oRight, oUp: oUp, oToward: toOriginDir(toward),
                          size: cell * 0.62, v: &v, idx: &idx) {
                // Drew a 3D node icon (block/chest); count/wear overlays below still apply.
                if st.count > 1, let cl = invCountLayer(st.count) {
                    let cc = fr.center + fr.right * (s.u + cell * 0.28) + fr.up * (s.v - cell * 0.28) - toward * 0.012
                    appendQuad(center: toOrigin(cc), right: oRight, up: oUp, hw: cell * 0.24, hh: cell * 0.24,
                               layer: cl, tint: 16777215, v: &v, idx: &idx)
                }
            } else if let st = stack, !isHeld, let icon = invIconModelLayer(iconKey(st)) {
                appendQuad(center: cq(0.005), right: oRight, up: oUp, hw: cell * 0.42, hh: cell * 0.42,
                           layer: icon, tint: 16777215, v: &v, idx: &idx)
                if st.count > 1, let cl = invCountLayer(st.count) {
                    let cc = fr.center + fr.right * (s.u + cell * 0.28) + fr.up * (s.v - cell * 0.28) - toward * 0.008
                    appendQuad(center: toOrigin(cc), right: oRight, up: oUp, hw: cell * 0.24, hh: cell * 0.24,
                               layer: cl, tint: 16777215, v: &v, idx: &idx)
                }
                // Durability bar for a damaged tool (wear 0 = pristine, 65535 =
                // about to break): a dark track with a green->red remaining fill,
                // low across the bottom of the cell like Luanti.
                if st.wear > 0 {
                    let remain = Float(65535 - st.wear) / 65535
                    let barV = s.v - cell * 0.34, halfFull = cell * 0.40, barHH = cell * 0.055
                    let track = fr.center + fr.right * s.u + fr.up * barV - toward * 0.006
                    appendQuad(center: toOrigin(track), right: oRight, up: oUp, hw: halfFull, hh: barHH,
                               layer: highlightLayer, tint: Self.packTint(20, 20, 20), v: &v, idx: &idx)
                    let fgHalf = max(0.0002, halfFull * remain)
                    let fgU = s.u - halfFull + fgHalf
                    let fg = fr.center + fr.right * fgU + fr.up * barV - toward * 0.007
                    appendQuad(center: toOrigin(fg), right: oRight, up: oUp, hw: fgHalf, hh: barHH,
                               layer: highlightLayer, tint: Self.packTint(Int((1 - remain) * 255), Int(remain * 255), 0),
                               v: &v, idx: &idx)
                }
            } else if s.list == "armor", stack == nil, let ll = armorLabelLayer(s.index) {
                // Empty armor slot: show what it holds (Head/Torso/Legs/Feet/Off-hand).
                // Constant height, width from aspect, capped so it fits the cell.
                let maxHW = cell * 0.46, baseHH = cell * 0.26
                let wantHW = baseHH * max(0.4, ll.aspect)
                let hw = min(maxHW, wantHW), hh = wantHW > maxHW ? baseHH * maxHW / wantHW : baseHH
                appendQuad(center: cq(0.005), right: oRight, up: oUp, hw: hw, hh: hh,
                           layer: ll.layer, tint: Self.packTint(150, 150, 165), v: &v, idx: &idx)
            }
        }
        // Static station labels (name + slot captions) float just off the backdrop.
        // Height under a third of a cell: 0.55 then 0.36 still read as oversized on
        // small station formspecs like the furnace (few slots, crisp filled text).
        for lab in invLabels {
            guard let t = formspecLabelLayer(lab.text) else { continue }
            let th = cell * 0.30, tw = th * max(0.4, t.aspect)
            // Luanti labels are LEFT-anchored at their x. Centering them pushed a
            // long label (e.g. "Inventory") half its width off the panel's left
            // edge, so it read as "Inve" (#241). Anchor the left edge at lab.u.
            let lc = fr.center + fr.right * (lab.u + tw * 0.5) + fr.up * lab.v - toward * 0.006
            appendQuad(center: toOrigin(lc), right: oRight, up: oUp, hw: tw * 0.5, hh: th * 0.5,
                       layer: t.layer, tint: lab.color ?? 16777215, v: &v, idx: &idx)
        }
        // Tappable field/button boxes (#229): a framed plate, brighter when the
        // pointer is over it, with the field's current value or the button label.
        var tipText: (text: String, color: Float?)? = nil   // hover tooltip for the widget under the pointer (#236)
        for w in invWidgets {
            let over = invCursor.map { c -> Bool in
                let rel = c - fr.center
                let u = simd_dot(rel, fr.right), v = simd_dot(rel, fr.up)
                return abs(u - w.u) <= w.hw && abs(v - w.v) <= w.hh
            } ?? false
            if over, !formspecTooltips.isEmpty, let nm = w.button?.name ?? w.field?.name, let tip = formspecTooltips[nm] { tipText = tip }
            let plate = fr.center + fr.right * w.u + fr.up * w.v - toward * 0.005
            appendQuad(center: toOrigin(plate), right: oRight, up: oUp, hw: w.hw, hh: w.hh,
                       layer: highlightLayer, tint: over ? Self.packTint(90, 90, 110) : Self.packTint(45, 45, 55), v: &v, idx: &idx)
            // image_button[]: draw its icon texture over the plate (the beacon
            // effect selector uses these; a plain plate showed 8 identical "OK"
            // buttons) (#233). The plate stays as the hover highlight behind it.
            if let tex = w.button?.texture, !tex.isEmpty {
                if let hi = hudImage(tex) {
                    let ic = fr.center + fr.right * w.u + fr.up * w.v - toward * 0.007
                    let s = min(w.hw, w.hh) * 0.9
                    appendOverlayQuadUV(center: toOrigin(ic), right: oRight, up: oUp, hw: s, hh: s,
                                        layer: hi.layer, uv: hi.uv, tint: 16777215, v: &v, idx: &idx)
                }
                continue
            }
            // item_image_button[]: draw the item's icon on the plate (stonecutter
            // recipe picker) (#235).
            if let item = w.button?.itemName, !item.isEmpty {
                let ic = fr.center + fr.right * w.u + fr.up * w.v - toward * 0.007
                let s = min(w.hw, w.hh) * 1.4
                if !nodeIcon3D(item, center: toOrigin(ic - toward * 0.006), oRight: oRight, oUp: oUp,
                               oToward: toOriginDir(toward), size: s, v: &v, idx: &idx),
                   let flat = client.items.image(for: item), let hi = hudImage(flat) {
                    let q = min(w.hw, w.hh) * 0.9
                    appendOverlayQuadUV(center: toOrigin(ic), right: oRight, up: oUp, hw: q, hh: q,
                                        layer: hi.layer, uv: hi.uv, tint: 16777215, v: &v, idx: &idx)
                }
                continue
            }
            // A field shows its value (or a "Name" placeholder); a button shows
            // its label, or NOTHING when the label is empty (tab background /
            // styled buttons -- the old "OK" fallback spammed the creative tabs) (#237).
            let text: String? = w.field.map { $0.value.isEmpty ? "Name" : $0.value } ?? w.button.map { $0.label }
            let textColor = w.button?.color   // fields render their editable value white
            if let text, !text.isEmpty, let t = formspecLabelLayer(text) {
                let th = min(w.hh * 1.3, cell * 0.30), tw = th * max(0.4, t.aspect)
                let tc = fr.center + fr.right * w.u + fr.up * w.v - toward * 0.007
                appendQuad(center: toOrigin(tc), right: oRight, up: oUp, hw: min(tw, w.hw * 0.95) * 0.5, hh: th * 0.5,
                           layer: t.layer, tint: textColor ?? 16777215, v: &v, idx: &idx)
            }
        }
        // Checkboxes (#237): a box (bright fill when checked) + label to the right.
        for cb in invCheckboxes {
            let checked = checkboxState[cb.name] ?? false
            let bc = fr.center + fr.right * cb.u + fr.up * cb.v - toward * 0.006
            appendQuad(center: toOrigin(bc), right: oRight, up: oUp, hw: cb.hw * 0.45, hh: cb.hh * 0.45,
                       layer: highlightLayer, tint: checked ? Self.packTint(90, 200, 90) : Self.packTint(50, 50, 60), v: &v, idx: &idx)
            if let t = formspecLabelLayer(cb.label) {
                let th = min(cb.hh * 1.1, cell * 0.28), tw = th * max(0.4, t.aspect)
                let lc = fr.center + fr.right * (cb.u + cb.hw * 0.7 + tw * 0.5) + fr.up * cb.v - toward * 0.006
                appendQuad(center: toOrigin(lc), right: oRight, up: oUp, hw: tw * 0.5, hh: th * 0.5,
                           layer: t.layer, tint: cb.color ?? 16777215, v: &v, idx: &idx)
            }
        }
        // The pointer dot and the held stack riding it are drawn by the renderer
        // from each frame's controller pose (PanelPointer); drawing them here
        // put a tick plus a handoff of lag between the controller and the dot.
        var heldIcon = -1
        if let held = invHeld, let list = listFor(loc: held.loc, name: held.list), held.index < list.count, let st = list[held.index],
           let icon = invIconModelLayer(iconKey(st)) { heldIcon = icon }
        player.setPanelPointer(PlayerState.PanelPointer(
            center: toOrigin(fr.center), right: oRight, up: oUp, toward: toOriginDir(toward),
            dotLayer: highlightLayer, dotHalf: 0.006 * scale, heldLayer: heldIcon, heldHalf: cell * 0.35 * scale))
        // Hover tooltip for a widget (enchant cost, effect name, #236): a text
        // plate near the cursor. Single line (the filled renderer), so a
        // multi-line tooltip shows its first, most useful line.
        if let tip = tipText, let cur = invCursor, let t = formspecLabelLayer(tip.text.split(separator: "\n").first.map(String.init) ?? tip.text) {
            let th: Float = 0.045, tw = th * max(0.4, t.aspect)
            let lc = cur + fr.up * (Self.invCell * 0.7) + toward * 0.02
            appendQuad(center: toOrigin(lc), right: oRight, up: oUp, hw: tw * 0.5 + 0.006, hh: th * 0.5 + 0.006,
                       layer: highlightLayer, tint: Self.packTint(20, 20, 25), v: &v, idx: &idx)
            appendQuad(center: toOrigin(lc + toward * 0.002), right: oRight, up: oUp, hw: tw * 0.5, hh: th * 0.5,
                       layer: t.layer, tint: tip.color ?? 16777215, v: &v, idx: &idx)
        }
        if let hi = invHover, let st = inventoryStack(invSlots[hi]), let nl = invNameLayer(st.name, stack: st) {
            let lc = fr.center + fr.up * (vMax + 0.16) + toward * 0.01
            let nh: Float = 0.05, nw = nh * max(0.4, nl.aspect)
            appendQuad(center: toOrigin(lc), right: oRight, up: oUp, hw: nw, hh: nh,
                       layer: nl.layer, tint: nl.color ?? 16777215, v: &v, idx: &idx)
        }
    }

    /// ProcessInfo.systemUptime read once per postEntities (an ObjC singleton
    /// fetch + message send per spinning entity otherwise, perf #311).
    private var frameUptime: TimeInterval = 0
    private func postEntities() {
        frameUptime = ProcessInfo.processInfo.systemUptime
        guard atlasBuilt else { return }
        frameHeadXform = player.headXform()   // one locked read for the whole pass (#250)
        // Snapshot the entity list once per tick and reuse it for both the model-
        // texture registration and the draw loop below, instead of filtering
        // objects.values into a fresh array twice (#185).
        let pe0 = perf.now()
        let ents = client.objects.snapshot()
        ensureModelTextures(ents)
        let pe1 = perf.now(); perf.add("e.snap", pe0, pe1)
        let s = player.snapshot()
        let eye = player.origin()   // origin-space (0,0,0) in node coords: the floor under you on device, the nominal eye in the sim
        let cy = cos(s.yaw), sy = sin(s.yaw)
        var billboards: [EntityInstance] = []
        var mv: [Float] = []; var mi: [UInt32] = []
        mv.reserveCapacity(lastModelVerts); mi.reserveCapacity(lastModelIdx)
        var bv: [Float] = []; var bi: [UInt32] = []   // use_texture_alpha mobs (blended pass)
        // Nametags to draw this frame (emitted into the overlay stream below,
        // which is declared after this loop).
        var nametagJobs: [(pos: SIMD3<Float>, text: String, color: UInt32)] = []
        // Entity texture strings that only need already-downloaded media (a
        // sprite sheet cell, a mob skin we have) get baked now; media still on
        // its way rebuilds when it lands (onMediaReady). Without this a texture
        // string added after the atlas built never got a layer.
        let entTiles = client.objects.tiles
        if entTiles.count != seenEntityTiles.count {
            let fresh = entTiles.subtracting(seenEntityTiles)
            seenEntityTiles = entTiles
            if !fresh.isEmpty {
                atlasNeedsRebuild = true
                let allHere = fresh.allSatisfy { t in NodeRegistry.imageNames(t).allSatisfy { client.media.bytes($0) != nil } }
                if allHere { rebuildAtlas() }
            }
        }
        // Only bone-attached children need to find their parent, and most ticks
        // have none: build the id -> index map lazily (indices, not Entity
        // copies) instead of a per-tick dictionary of ~60 structs (perf review).
        let anyBoneAttached = ents.contains { !$0.attachBone.isEmpty && $0.attachParent != 0 }
        let entIndexById: [Int: Int] = anyBoneAttached
            ? Dictionary(ents.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a }) : [:]
        var lightCur = WorldMap.BlockCursor()   // shared by the entity + particle light lookups (perf #312)
        var modelsDrawn = 0
        for var e in ents {
            if e.isPlayer {
                if e.name == client.playerName { continue }   // never draw ourselves
                if !playersSeen.contains(e.name) {
                    playersSeen.insert(e.name)
                    print("[player] \(e.name) at \(e.pos) visual=\(e.visual) mesh=\(e.mesh)"); fflush(stdout)
                }
            }
            // Bone attachment (#282): shields on a player's arm, spider eyes on
            // "body.head", the rover's held node. GenericCAO parents the child
            // scene node to the parent's joint node, so the child sits at
            // parent origin + yaw * visual_size/10 * (G_bone(frame) * offset),
            // offset in mesh units (the wire value; ActiveObjects stored it
            // /BS for the origin case). Falls back to the parent's origin when
            // the model or the bone isn't there.
            if !e.attachBone.isEmpty, let pi = entIndexById[e.attachParent], case let parent = ents[pi], parent.visual == "mesh",
               let pm = model(for: parent.mesh) {
                let frame = parent.animRange == nil ? 0 : parent.animFrame
                let ov = parent.boneOverrides.isEmpty ? [:] : parent.boneOverrides.mapValues { $0.current() }
                if let g = pm.jointGlobalMatrix(name: e.attachBone, frame: frame, overrides: ov) {
                    let p4 = g * SIMD4<Float>(e.attachOffset * ActiveObjects.BS, 1)
                    let vsz = parent.size.z != 0 ? parent.size.z : parent.size.x
                    var l = SIMD3<Float>(p4.x, p4.y, p4.z) * (SIMD3<Float>(parent.size.x, parent.size.y, vsz) * 0.1)
                    l = WorldMesher.pitchLocal(l, parent.roll)
                    l = WorldMesher.tiltLocal(l, parent.pitch)
                    let ca = cos(parent.yaw), sa = sin(parent.yaw)
                    e.pos = parent.pos + SIMD3(l.x * ca - l.z * sa, l.y, l.x * sa + l.z * ca)
                }
            }
            let node = SIMD3(Int(floor(e.pos.x)), Int(floor(e.pos.y)), Int(floor(e.pos.z)))   // our grid: containing node = floor
            // ObjectProperties.glow self-illuminates: raise each light bank to at
            // least `glow` (glow < 0 = full bright). Glow squid/blaze, dropped
            // light blocks, TNT minecart, burning mobs render lit in the dark.
            let base = Int(client.world.nodeLight(node, &lightCur))
            var light = Float(base)
            if e.glow < 0 { light = 255 }
            else if e.glow > 0 {
                let g = min(15, e.glow)
                light = Float((max(base >> 4, g) << 4) | max(base & 0x0F, g))
            }
            // Hit feedback (#100): tint the whole thing red while its PUNCHED
            // flash timer runs, standing in for the engine's damage-texture
            // overlay. Packed r + g*256 + b*65536; white = no tint.
            // Eric hates creepers: paint them hot pink and hiss (tnt_ignite, the
            // fuse sound) when one gets close. Hit-flash still wins.
            let isCreeper: Bool
            if let c = creeperCache[e.id] { isCreeper = c }
            else {
                isCreeper = e.mesh.lowercased().contains("creep") || e.name.lowercased().contains("creep")
                creeperCache[e.id] = isCreeper
            }
            // Damage flash colour follows damage_texture_modifier: the engine
            // default ^[brighten is a white wash (mobs), VoxeLibre players get
            // ^[colorize:red:130. The entity shader blends toward a coloured
            // tint, so near-white-pink reads as "brightened" (#306).
            // Only compute the flash colour on an actual hit -- the two substring
            // scans of damageTexMod ran for every entity every tick otherwise (perf).
            let tint: Float
            if e.hitFlash > 0 {
                tint = e.damageTexMod.contains("red") || e.damageTexMod.contains("colorize:#")
                    ? Float(255 + 64 * 256 + 64 * 65536) : Self.packTint(255, 236, 236)
            } else {
                tint = isCreeper ? Float(255 + 20 * 256 + 147 * 65536) : 16777215
            }
            // One-time identity log per mob: the pink creeper tint wasn't showing
            // on device, so surface each mob's real name/mesh + whether it matched.
            if loggedMobNames.insert(e.name).inserted {
                print("[mob] id=\(e.id) name=\(e.name) mesh=\(e.mesh) creeper=\(isCreeper) tint=\(Int(tint))"); fflush(stdout)
            }
            if isCreeper {
                let d = simd_distance(e.pos, s.feet)
                if d < 10, !creepersNear.contains(e.id) {
                    creepersNear.insert(e.id)
                    playSound(SoundSpec(id: -1, name: "tnt_ignite", gain: 1.0, type: 1, pos: e.pos,
                                        objectId: 0, loop: false, fade: 0, pitch: 1.0, ephemeral: true))
                    print("[creeper] hiss near \(e.id)"); fflush(stdout)
                } else if d > 12 { creepersNear.remove(e.id) }   // hysteresis so it can re-hiss
            }
            // Nametag (#118), like GenericCAO::updateNametag: only with text and
            // a non-zero alpha, floated above the collision box. Not for us
            // (skipped above). Other players always get a label even when the
            // server set no explicit nametag: desktop shows every player by login
            // name (#246). Players get a longer range than mobs since seeing who
            // is where matters more; mob labels past 32 nodes are just clutter.
            let tagText = (e.isPlayer && e.nametag.isEmpty) ? e.name : e.nametag
            let tagRange: Float = e.isPlayer ? 128 : 32
            if !tagText.isEmpty, e.name != "__builtin:item", (e.nametagColor >> 24) & 0xFF != 0, simd_distance(e.pos, s.feet) < tagRange {
                nametagJobs.append((pos: e.pos + SIMD3(0, e.cbMax.y + 0.35, 0),
                                    text: tagText, color: e.nametagColor))
            }
            // Real 3D model for nearby mesh-visual entities (other players
            // included: VoxeLibre's mcl_armor_character*.b3d); billboard otherwise.
            if e.visual == "mesh", !e.textures.isEmpty,
               let mesh = model(for: e.mesh), simd_distance(e.pos, s.feet) < mobRenderDist {
                let pm0 = perf.now()
                let drew = e.useTextureAlpha
                    ? appendModel(mesh, entity: e, eye: eye, cosY: cy, sinY: sy,
                                  playerYaw: s.yaw, light: light, tint: tint, v: &bv, idx: &bi)
                    : appendModel(mesh, entity: e, eye: eye, cosY: cy, sinY: sy,
                                  playerYaw: s.yaw, light: light, tint: tint, v: &mv, idx: &mi)
                perf.add("e.model", pm0, perf.now())
                if drew {
                    modelsDrawn += 1
                    continue   // else fall through to a billboard until skins download
                }
                // Mesh mob that couldn't draw (skins not resolved) -> white
                // billboard fallback (#72). One-shot log per name to see which
                // mobs and textures are missing without spamming.
                else if !mobMissLogged.contains(e.name) {
                    mobMissLogged.insert(e.name)
                    let tex = e.textures.joined(separator: ",")
                    let resolved = e.textures.filter { modelTexLayer[$0] != nil }.count
                    // For each non-blank spec, show which component PNGs are
                    // present/announced/failed, so a stuck composite skin
                    // (missing overlay, un-announced file) is diagnosable (#72).
                    let detail = e.textures.filter { !Self.isBlankSpec($0) }.map { spec -> String in
                        let comps = NodeRegistry.imageNames(spec).map { n in
                            "\(n):\(client.media.store[n] != nil ? "have" : (client.media.announced.contains(n) ? "wait" : "none"))"
                        }.joined(separator: "+")
                        return "\(spec){\(comps)}\(modelFailed.contains(spec) ? "FAILED" : "")"
                    }.joined(separator: " ")
                    print("[mobmiss] \(e.name) mesh=\(e.mesh) tex=[\(tex)] resolved=\(resolved)/\(e.textures.count) \(detail)"); fflush(stdout)
                }
            }
            // Item visuals ("wielditem"/"item": wield_item, else textures[0], is the
            // itemstring). Dropped items (__builtin:item) keep their VR-tuned
            // size + spin; every other item entity -- falling nodes, item
            // frames, held items on mobs/players -- draws at Luanti's size
            // (visual_size x 1.5 nodes: a falling node at 0.667 is a full block)
            // without the spin. Bone-attached ones land at the parent's position
            // plus offset (no bone tracking), which is close enough (#266).
            if e.visual == "wielditem" || e.visual == "item" {
                let dropStr = !e.wieldItem.isEmpty ? e.wieldItem : e.textures.first
                if let itemStr = dropStr, !itemStr.isEmpty, itemStr != "blank.png" {
                    let isDrop = e.name == "__builtin:item"
                    let vs = max(0.05, min(3, e.size.x * 1.5))
                    let cubeSz: Float = isDrop ? 0.22 : vs
                    let cardSz: Float = isDrop ? 0.18 : vs * 0.8
                    let modelSz: Float = isDrop ? 0.4 : vs
                    // One line per drop so a "can't see my mined block" report can
                    // be matched against what we actually emitted for it (#358).
                    let draw = itemDraw(itemStr)
                    if isDrop, loggedDropIds.insert(e.id).inserted {
                        let path: String
                        switch draw { case .model: path = "model"; case .cube: path = "cube"; case .card: path = "card"; case nil: path = "NONE (no layer yet)" }
                        print("[drop] draw id=\(e.id) item=\(itemStr) path=\(path) pos=\(e.pos) light=\(light)"); fflush(stdout)
                    }
                    switch draw {
                    case .model(let nid, let layer):
                        if let model = nodeMeshModel(for: nid) {
                            // A mesh-drawtype node (chest etc): its real model (#191).
                            appendItemModel(model, pos: e.pos, layer: layer,
                                            eye: eye, cosY: cy, sinY: sy, playerYaw: s.yaw,
                                            light: light, size: modelSz, v: &mv, idx: &mi)
                        }
                    case .cube(let layers):
                        // A cube node: a small spinning cube like Minecraft for drops,
                        // a still full-size block for falling sand/gravel (#191 sibling).
                        appendItemCube(faceLayers: layers, pos: e.pos,
                                       eye: eye, cosY: cy, sinY: sy, playerYaw: s.yaw, light: light,
                                       size: cubeSz, spin: isDrop, v: &mv, idx: &mi)
                    case .card(let layer, let uv):
                        // Tools/craftitems (and non-cube/non-mesh nodes): flat card.
                        appendItemQuads(pos: e.pos, layer: layer, uv: uv,
                                        eye: eye, cosY: cy, sinY: sy, light: light, size: cardSz, v: &mv, idx: &mi)
                    case nil: break
                    }
                }
                continue
            }
            // "cube" (TNT, end crystal, paintings) and "upright_sprite" (sign
            // text, item-frame maps, old-style players): real geometry at the
            // object origin, scaled by visual_size and turned by yaw, exactly
            // as GenericCAO::addToScene builds them (#287). Textures go through
            // the model path so modifier strings (sign glyph [combine) work.
            if e.visual == "cube" || e.visual == "upright_sprite" {
                let want = e.visual == "cube" ? 6 : 2
                var faces: [(layer: Int, uv: SIMD2<Float>)] = []
                for i in 0..<want {
                    // The engine fills missing cube slots with no_texture.png;
                    // reuse the last given texture instead so TNT with 3
                    // textures isn't half unknown-pink. Upright sprites use
                    // textures[1] for the back only when the server gave one.
                    let spec = i < e.textures.count ? e.textures[i]
                             : (e.visual == "cube" ? (e.textures.last ?? "") : "")
                    if spec.isEmpty || Self.isBlankSpec(spec) { faces.append((-1, SIMD2(1, 1))); continue }
                    if modelTexLayer[spec] == nil, assignModelTexture(spec) { modelTexturesDirty = true }
                    if let l = modelTexLayer[spec] { faces.append((l, modelTexUV[spec] ?? SIMD2(1, 1))) }
                    else { faces.append((-1, SIMD2(1, 1))) }
                }
                if faces.contains(where: { $0.layer >= 0 }) {
                    if e.visual == "cube" {
                        appendEntityCube(faces: faces, size: e.size, pos: e.pos, yaw: e.yaw + s.yaw,
                                         eye: eye, cosY: cy, sinY: sy, light: light, tint: tint, v: &mv, idx: &mi)
                    } else {
                        appendUprightSprite(faces: faces, size: e.size, pos: e.pos, yaw: e.yaw + s.yaw,
                                            eye: eye, cosY: cy, sinY: sy, light: light, tint: tint, v: &mv, idx: &mi)
                    }
                    continue
                }
                // Textures still downloading: fall through to the marker billboard.
            }
            // Camera-facing billboard: the "sprite" visual (burning flame, XP
            // orbs) and any mesh whose model hasn't loaded yet. The engine's
            // billboard is CENTRED on the origin at visual_size; a mesh stand-in
            // stays feet-anchored since that's where its model will land.
            let w = max(0.05, min(8, e.size.x))
            let h = max(0.05, min(8, e.size.y))
            // Sprite sheets show their current cell (XP orb, burning flame), not the whole strip.
            let texName = e.spriteCellTexture ?? e.textures.first
            let layer = texName.flatMap { atlas.tileLayer($0) } ?? atlas.markerLayer
            // EntityInstance.pos is the billboard's BOTTOM centre (Renderer builds
            // the quad upward from it), and the engine's sprite billboard is
            // centred on the object origin, so a true sprite drops half its
            // height. A mesh stand-in stays feet-anchored (its model will land there).
            let bpos = e.visual == "sprite" ? e.pos - SIMD3(0, h * 0.5, 0) : e.pos
            billboards.append(EntityInstance(pos: bpos, width: w, height: h, layer: Float(layer), light: light, tint: tint))
        }
        let pe2 = perf.now(); perf.add("e.loop", pe1, pe2)
        lastModelsDrawn = modelsDrawn
        defer { perf.add("e.rest", pe2, perf.now()) }
        // The pointed node under the gaze: feeds the highlight outline and the
        // dig crack below. There is deliberately no crosshair (#48): the outline
        // is the targeting cue, and a reticle at a guessed depth reads badly in
        // stereo.
        let aimOrigin = player.rayOrigin(), aimDir = player.aim()
        let aimHit = client.world.raycast(origin: aimOrigin, dir: aimDir, maxDist: currentReach, pointable: client.nodes.isPointable, boxes: pointBoxes)
        // Head-locked HUD is authored in a canonical head-local frame (origin at
        // the head, looking down -Z) and tagged headLocal, so the renderer can
        // re-anchor it to the CURRENT frame's head pose at draw time. Baking it
        // here against the session tick's (stale) gaze made it lag the camera and
        // ghost/double under reprojection while moving.
        let hudGaze = SIMD3<Float>(0, 0, -1)
        var hud: [EntityInstance] = []
        // Health hearts (lower-left), hunger (lower-right), breath (top), armor,
        // XP (bottom-centre): all placed on canonical-gaze-relative rays.
        // Not gated on HUD_SET_FLAGS healthbar/breathbar: VoxeLibre switches
        // the ENGINE bars off at join (flags 111101001) because it draws its
        // own via HUDADD statbars, and these vitals stand in for those. Only
        // wielditem/hotbar (postHandHud) follow the flags (#290).
        appendHealthHUD(origin: .zero, gaze: hudGaze, into: &hud)
        appendHungerHUD(origin: .zero, gaze: hudGaze, into: &hud)
        appendBreathHUD(origin: .zero, gaze: hudGaze, into: &hud)
        // Armor moved to a left-wrist gauntlet (#108, postHandHud/buildHandHud),
        // so it no longer draws as a peripheral column here.
        appendXpHUD(origin: .zero, gaze: hudGaze, into: &hud)
        // Hotbar is now wrist-anchored (postHandHud / buildHandHud), not head-locked.
        for i in hud.indices { hud[i].headLocal = true }
        billboards.append(contentsOf: hud)
        // Break-burst debris: small camera-facing billboards of the broken
        // node's tile, shrinking toward zero as they age out.
        for i in particles.indices {
            let p = particles[i]
            // Particle size is constant over its life unless the texture carries
            // a scale tween (Particle::updateVertices); the old shrink-to-zero
            // made every smoke puff collapse instead of just vanishing (#308).
            let k = max(0, min(1, p.age / (p.life + 0.1)))
            let sz = p.size * (p.scaleStart + (p.scaleEnd - p.scaleStart) * k)
            let pn = SIMD3(Int(floor(p.pos.x)), Int(floor(p.pos.y)), Int(floor(p.pos.z)))
            // Re-resolve the layer every frame from the texture name: the atlas
            // rebuilds during streaming and remaps layer indices, so a cached
            // index would point at whatever tile now sits there (#201/#202).
            // Fall back to the neutral marker (white), NEVER the spawn-time index:
            // if the texture isn't in the current atlas (evicted by a rebuild),
            // that stale index points at whatever took its slot -- that's how snow
            // turned into falling dirt on device (#256). A white blob is fine.
            // Layers are resolved by texture key once per atlas generation and
            // cached on the particle (the atlas is append-only, #atlas-append-only,
            // so an index only moves on a rebuild, which bumps atlasGeneration);
            // that was 1-2 String hashes per particle per tick (perf #312).
            if p.layerGen != atlasGeneration { resolveParticleLayers(i) }
            let layer = p.frameLayers.isEmpty || p.frameLen <= 0
                ? p.layer
                : p.frameLayers[Int(p.age / p.frameLen) % p.frameLayers.count]
            // glow floors both light nibbles (Particle::updateLight takes the
            // max of the node light and glow), so torch/lava sparks show at night.
            var light = client.world.nodeLight(pn, &lightCur)
            if p.glow > 0 { light = max(light >> 4, p.glow) << 4 | max(light & 0x0F, p.glow) }
            billboards.append(EntityInstance(pos: p.pos - SIMD3(0, sz * 0.5, 0),
                                             width: sz, height: sz,
                                             layer: Float(layer), light: Float(light)))
        }
        // Pointed-node highlight: a black selection box on whatever pointable
        // node the crosshair is on (every frame, not only while digging).
        if let hit = aimHit, highlightLayer >= 0 {
            appendHighlight(node: hit.under, layer: highlightLayer,
                            eye: eye, cosY: cy, sinY: sy, v: &mv, idx: &mi)
        }
        // Dig-crack overlay on the node being mined (advances with digElapsed).
        if let dn = digNode, digTime > 0, !crackTex.isEmpty {
            let frac = max(0, min(0.999, digElapsed / digTime))
            let stage = crackTex[Int(frac * Float(crackTex.count))]
            let light = Float(client.world.nodeLight(digAbove))
            appendCrack(node: dn, layer: stage.layer, uv: stage.uv,
                        eye: eye, cosY: cy, sinY: sy, light: light, v: &mv, idx: &mi)
        }

        // Modal UI goes into a SEPARATE overlay stream drawn on top of the world
        // (no depth test), so nearby terrain can't bury the keyboard/panel/menu.
        var ov: [Float] = []; var oi: [UInt32] = []
        if dead, deathTextLayer >= 0 {
            appendDeathText(layer: deathTextLayer, gaze: aimDir, cosY: cy, sinY: sy, v: &ov, idx: &oi)
        }
        appendChat(v: &ov, idx: &oi)
        appendStatusBanner(v: &ov, idx: &oi)
        appendXpLevel(v: &ov, idx: &oi)
        appendServerHUD(eye: eye, cosY: cy, sinY: sy, v: &ov, idx: &oi)
        // Entity nametags (#118): overlay (no depth, like the engine's
        // screen-space nametags), camera-facing, in origin space with the same
        // Z mirror the world gets.
        var tags = nametagJobs
        #if targetEnvironment(simulator)
        // Sim aid: the only other player is hundreds of nodes off, so float a
        // test label 3 nodes ahead. -vrdev.fakeNametag 1.
        if UserDefaults.standard.bool(forKey: "vrdev.fakeNametag") {
            let bf = player.bodyForward()
            tags.append((pos: s.feet + SIMD3(bf.x, 0, bf.z) * 3 + SIMD3(0, 0.9, 0), text: "Steve", color: 0xFFFF_FFFF))
        }
        #endif
        if !tags.isEmpty {
            let hx = frameHeadXform
            let hr = simd_normalize(SIMD3<Float>(hx.columns.0.x, hx.columns.0.y, hx.columns.0.z))
            let hu = simd_normalize(SIMD3<Float>(hx.columns.1.x, hx.columns.1.y, hx.columns.1.z))
            let scale = PlayerState.scale
            for t in tags {
                guard let tag = nametagLayer(t.text) else { continue }
                let rx = (t.pos.x - eye.x) * scale, ry = (t.pos.y - eye.y) * scale, rz = (t.pos.z - eye.z) * scale
                let op = SIMD3<Float>(rx * cy - rz * sy, ry, -(rx * sy + rz * cy))
                let r = Int((t.color >> 16) & 0xFF), g = Int((t.color >> 8) & 0xFF), b = Int(t.color & 0xFF)
                // Constant glyph HEIGHT; width follows the text aspect so a long
                // name isn't squished and a short one isn't stretched.
                let hh: Float = 0.075, hw = hh * max(0.4, tag.aspect)
                appendQuad(center: op, right: hr, up: hu, hw: hw, hh: hh,
                           layer: tag.layer, tint: Self.packTint(r, g, b), v: &ov, idx: &oi)
            }
        }
        // The pause menu goes after the XP level, server HUD and nametags: the
        // overlay has no depth test, so later quads paint over earlier ones and
        // the level digits used to sit on top of the menu panel (device shot).
        // The keyboard (bug-note dictation) and panels still draw over the menu.
        appendKogane(gaze: aimDir, cosY: cy, sinY: sy, v: &ov, idx: &oi)
        appendKeyboard(eye: eye, cosY: cy, sinY: sy, v: &ov, idx: &oi)
        appendInventoryPanel(eye: eye, cosY: cy, sinY: sy, billboards: &billboards, v: &ov, idx: &oi)
        // Split once here (tick thread) into world billboards + head-locked HUD so
        // the renderer reads two ready-made lists instead of filtering twice/frame.
        var worldB: [EntityInstance] = [], hudB: [EntityInstance] = []
        worldB.reserveCapacity(billboards.count)
        for b in billboards { if b.headLocal { hudB.append(b) } else { worldB.append(b) } }
        entityHandoff.post(world: worldB, hud: hudB)
        postHandHud()
        lastModelVerts = mv.count; lastModelIdx = mi.count   // seed next tick's reserve (#162)
        modelHandoff.post(mv, mi, overlayVerts: ov, overlayIndices: oi, blendVerts: bv, blendIndices: bi)
        if !doorDebugDone, !client.nodes.allNames().isEmpty {
            doorDebugDone = true
            // Only the wooden door + a fence gate: enough to see box geometry
            // and per-face atlas layers without spamming 170 lines.
            for (id, name) in client.nodes.allNames().sorted(by: { $0.value < $1.value })
            where name == "mcl_doors:wooden_door_b_1" || name == "mcl_doors:wooden_door_t_1"
               || name == "mcl_fences:fence_gate" || name == "mcl_doors:trapdoor" {
                let dt = client.nodes.drawtype(id)
                let kind = client.nodes.kind(id)
                let layers = (0..<6).map { atlas.layer(id: id, face: $0) }
                var boxStr = "none"
                if let b = client.nodes.boxes(id), let f = b.first {
                    boxStr = "min(\(f.min.x),\(f.min.y),\(f.min.z)) max(\(f.max.x),\(f.max.y),\(f.max.z)) n=\(b.count)"
                }
                print("[door] \(name) id=\(id) dt=\(dt) kind=\(kind) layers=\(layers) box=\(boxStr)"); fflush(stdout)
            }
        }
        modelDebugTimer += 1
        if modelDebugTimer % 900 == 0 {   // ~15 s: every 2 s was 840 lines a session
            // Reuse the `ents` snapshot from the top of postEntities (two more
            // full snapshots here were ~240 Entity copies every 2 s, perf #311).
            let live = Set(ents.map { $0.id })
            skinCache = skinCache.filter { live.contains($0.key) }
            let mob = ents.filter { $0.visual == "mesh" && !$0.isPlayer }
            let near = mob.filter { simd_distance($0.pos, s.feet) < 96 }
            let withLayer = near.filter { ($0.textures.first).map { modelTexLayer[$0] != nil } ?? false }
            let nearest = mob.map { simd_distance($0.pos, s.feet) }.min() ?? -1
            print("[model] ents=\(ents.count) mob=\(mob.count) near=\(near.count) withLayer=\(withLayer.count) nearest=\(Int(nearest)) skins=\(modelTexCount) verts=\(mv.count/9)"); fflush(stdout)
            // Vertical-placement probe for the sunk-mob bug (#67): the nearest
            // mob's pos.y, collision box, and the ground under it. If pos.y sits
            // at/above the ground, the model draws from pos.y up, so a sink means
            // the model's own feet are below its origin.
            if let m = near.min(by: { simd_distance($0.pos, s.feet) < simd_distance($1.pos, s.feet) }) {
                let gy = groundHeight(x: Int(floor(m.pos.x)), z: Int(floor(m.pos.z)), near: Int(floor(m.pos.y)))
                print("[mobY] \(m.name) mesh=\(m.mesh) pos.y=\(m.pos.y) cbMin.y=\(m.cbMin.y) cbMax.y=\(m.cbMax.y) feetY=\(m.pos.y + m.cbMin.y) ground=\(gy.map { String($0) } ?? "nil")"); fflush(stdout)
                // Facing check (#67): the mesh (front +Z) points at world
                // (-sin yaw, cos yaw). Compare to the direction to the player; a
                // hostile mob that faces you should have these roughly aligned.
                let faceDeg = m.yaw * 180 / .pi
                let toP = SIMD2(s.feet.x - m.pos.x, s.feet.z - m.pos.z)
                let toPDeg = atan2(-toP.x, toP.y) * 180 / .pi          // yaw that faces the player
                print("[mobYaw] \(m.mesh) yaw=\(Int(faceDeg)) toPlayer=\(Int(toPDeg)) vel=(\(m.vel.x),\(m.vel.z))"); fflush(stdout)
            }
        }
    }
    private var modelDebugTimer = 0
    private var doorDebugDone = false   // one-shot door drawtype/model probe (#71)
    private var mobMissLogged: Set<String> = []
    private var modelDropLogged: Set<String> = []   // mobs that fell back to a white billboard (#72)

    /// Head-locked health hearts in the lower-left periphery. Each heart is a
    /// small camera-facing billboard placed on a gaze-relative ray (fixed
    /// azimuth/elevation offsets from where the head looks), so the row travels
    /// with the head and stays low and to the left instead of centred. hp is
    /// 0..20; each heart shows two HP (full / half / dim empty).
    private func appendHealthHUD(origin: SIMD3<Float>, gaze: SIMD3<Float>,
                                 into billboards: inout [EntityInstance]) {
        // Follow the heart statbar's icon (poison green, wither black, frost
        // blue, regeneration) like vl_hudbars; plain red until one is known.
        let pair = client.healthIcon.flatMap { atlas.statusIconPairs[$0] }
        let full = pair?.full ?? atlas.healthFullLayer, half = pair?.half ?? atlas.healthHalfLayer
        appendStatColumn(origin: origin, gaze: gaze, az: -0.185, value: min(hp, 20),   // low row, left of centre (HUD B)
                         full: full, half: half, empty: atlas.healthEmptyLayer, into: &billboards)
        // HP above 20 (health boost) stacks extra rows above, 20 HP each, the
        // way vl_hudbars layers its bar; without them losing health above 20
        // showed no change at all.
        var rowElev: Float = 0
        var rest = hp - 20
        while rest > 0 && rowElev < 0.2 {
            rowElev += 0.05   // a full icon apart, like vl_hudbars' first (unsquished) layers
            appendStatColumn(origin: origin, gaze: gaze, az: -0.185, value: min(rest, 20),
                             full: full, half: half, empty: -1, elevOffset: rowElev, into: &billboards)
            rest -= 20
        }
        // Absorption (golden apple): gold hearts in a row above the rest, only
        // as many as there are, like vl_hudbars' absorption part.
        if client.absorption > 0, let gold = atlas.statusIconPairs["mcl_potions_icon_absorb.png"] {
            appendStatColumn(origin: origin, gaze: gaze, az: -0.185, value: client.absorption,
                             full: gold.full, half: gold.half, empty: -1, elevOffset: rowElev + 0.045, into: &billboards)
        }
    }

    /// XP bar (#107): a thin track along the bottom-centre of the peripheral
    /// HUD (where the desktop bar sits) with the green fill growing from the
    /// left. Only once there is any XP, like VoxeLibre's own HUD. The level
    /// digits are drawn in the overlay stream (appendXpLevel) since text lives
    /// in the model texture set, not the node atlas these billboards sample.
    private func appendXpHUD(origin: SIMD3<Float>, gaze: SIMD3<Float>,
                             into billboards: inout [EntityInstance]) {
        let (level, fraction) = xpDisplay()
        guard level > 0 || fraction > 0 else { return }
        let frac = max(0, min(1, fraction))
        let hudDist: Float = 1.35          // focal plane, was 1.7 (HUD P1/P9)
        // A flat row across the bottom of view at the same elevation as the
        // hearts / hunger rows. It used to bow (+0.35 rad/rad^2, the ends 1.5
        // degrees above the centre) and read as bent next to the level rows
        // (Eric, #313). Segments are camera-facing billboards along the row;
        // the green fill covers the left `fraction` of them, with the
        // straddling segment filled partway.
        let n = 12
        let azMin: Float = -0.28, azMax: Float = 0.28
        let baseElev: Float = -0.28, bowXp: Float = 0
        let segAz = (azMax - azMin) / Float(n)
        let segW = 2 * hudDist * tan(segAz * 0.5) * 1.08   // slight overlap kills gaps
        let height: Float = 0.02 * hudDist
        let (fwd, right, up) = stableFrame(gaze, horizFwd: player.bodyForward())
        for i in 0..<n {
            let az = azMin + (Float(i) + 0.5) * segAz
            let e = baseElev + bowXp * az * az
            let dir = simd_normalize(fwd + right * tan(az) + up * tan(e))
            let center = origin + dir * hudDist
            billboards.append(EntityInstance(pos: center - SIMD3(0, height * 0.5, 0),
                                             width: segW, height: height,
                                             layer: Float(atlas.xpTrackLayer), light: 255))
            // Fill fraction of this segment: full left of `frac`, partial across it.
            let p = max(0, min(1, frac * Float(n) - Float(i)))
            if p > 0.001 {
                let fw = segW * p
                let fdir = simd_normalize(fwd + right * tan(az) + up * tan(e))
                let fc = origin + fdir * (hudDist - 0.01) - right * ((segW - fw) * 0.5)
                billboards.append(EntityInstance(pos: fc - SIMD3(0, height * 0.5, 0),
                                                 width: fw, height: height,
                                                 layer: Float(atlas.xpFillLayer), light: 255))
            }
        }
    }

    /// The XP level digits, in XP green, just above the bar (overlay stream).
    private func appendXpLevel(v: inout [Float], idx: inout [UInt32]) {
        let (level, _) = xpDisplay()
        guard level > 0, highlightLayer >= 0 else { return }
        let text = String(level)
        if xpLevelLayer == -1 || xpLevelText != text {
            let px = Self.renderTextRGBA(text, canvas: ModelTextureHandoff.size, fontFrac: 0.30)
                ?? [UInt8](repeating: 0, count: ModelTextureHandoff.size * ModelTextureHandoff.size * 4)
            if xpLevelLayer >= 0 { updateModelLayer(xpLevelLayer, px) }
            else { xpLevelLayer = registerRGBALayer("#xplevel", px) }
            xpLevelText = text
        }
        let hx = frameHeadXform
        let headPos = SIMD3<Float>(hx.columns.3.x, hx.columns.3.y, hx.columns.3.z)
        let hr = simd_normalize(SIMD3<Float>(hx.columns.0.x, hx.columns.0.y, hx.columns.0.z))
        let hu = simd_normalize(SIMD3<Float>(hx.columns.1.x, hx.columns.1.y, hx.columns.1.z))
        let hf = -simd_normalize(SIMD3<Float>(hx.columns.2.x, hx.columns.2.y, hx.columns.2.z))
        // Same 1.7 m depth as the arc, centred just above it (arc dips to elev
        // -0.30 rad at az 0; digits ride at -0.22) so the bar and number never
        // drift apart the way the old two-anchor layout did.
        let dir = simd_normalize(hf + hu * tanf(-0.22))
        let center = headPos + dir * 1.7
        appendQuad(center: center, right: hr, up: hu, hw: 0.10, hh: 0.10,
                   layer: xpLevelLayer, tint: Self.packTint(128, 255, 32), v: &v, idx: &idx)
    }

    /// Head-locked hunger drumsticks in the lower-RIGHT periphery, mirroring the
    /// hearts (which sit lower-left). Each drumstick is a small camera-facing
    /// billboard on a gaze-relative ray. hunger is 0..20; each icon shows two
    /// food points (full / half / dim empty), so 10 drumsticks total.
    private func appendHungerHUD(origin: SIMD3<Float>, gaze: SIMD3<Float>,
                                 into billboards: inout [EntityInstance]) {
        let pair = client.hungerIcon.flatMap { atlas.statusIconPairs[$0] }   // food poisoning swaps the icon
        appendStatColumn(origin: origin, gaze: gaze, az: 0.185, value: hunger,   // low row, right of centre (HUD B)
                         full: pair?.full ?? atlas.hungerFullLayer, half: pair?.half ?? atlas.hungerHalfLayer,
                         empty: atlas.hungerEmptyLayer, into: &billboards)
    }

    /// Air bubbles across the top-centre while breath is below full, the way
    /// vl_hudbars shows its breath bar (autohide_breath): full bubbles don't
    /// show just for being underwater, and the bar stays up after surfacing
    /// while the server refills breath. Bubbles pop off from the right as
    /// breath drops (empty ones are hidden). breath is 0..20, 2 per bubble.
    private func appendBreathHUD(origin: SIMD3<Float>, gaze: SIMD3<Float>,
                                 into billboards: inout [EntityInstance]) {
        guard breath < 20 else { return }
        let hudDist: Float = 1.35          // focal plane, was 1.7 (HUD P1)
        let size: Float = 0.05 * hudDist
        let elev: Float = 0.30            // above the gaze (top of view)
        let step: Float = 0.055
        let az0 = -Float(9) * step / 2    // centred row of 10
        let (fwd, right, up) = stableFrame(gaze, horizFwd: player.bodyForward())
        let ey = tan(elev)
        for i in 0..<10 {
            let filled = breath - i * 2
            if filled <= 0 { continue }   // popped bubbles disappear
            let layer = filled >= 2 ? atlas.breathFullLayer : atlas.breathHalfLayer
            let dir = simd_normalize(fwd + right * tan(az0 + Float(i) * step) + up * ey)
            let center = origin + dir * hudDist
            billboards.append(EntityInstance(pos: center - SIMD3(0, size * 0.5, 0),
                                             width: size, height: size,
                                             layer: Float(layer), light: 255))
        }
    }

    /// A vertical 10-icon column of a 0..20 stat, head-locked at a fixed azimuth
    /// off the gaze (negative = left edge, positive = right edge). Icons stack
    /// top-to-bottom; 2 points each with full/half/empty. Kept out of the centre
    /// so the two bars don't overlap (they used to share one horizontal row).
    private func appendStatColumn(origin: SIMD3<Float>, gaze: SIMD3<Float>,
                                  az: Float, value: Int,
                                  full: Int32, half: Int32, empty: Int32, elevOffset: Float = 0,
                                  into billboards: inout [EntityInstance]) {
        // HUD layout B: a single low HORIZONTAL row (hearts left, hunger right)
        // in the comfortable lower band, instead of two tall corner columns that
        // read as crowded. `az` is the row centre; 10 icons run across it.
        let hudDist: Float = 1.35          // on the panel focal plane (HUD P1)
        let size: Float = 0.05 * hudDist
        let elev: Float = -0.30 + elevOffset   // low band, below the gaze (HUD P3/B)
        let hstep: Float = 0.032           // radians between icons, left to right
        let az0 = az - Float(9) * hstep / 2
        let (fwd, right, up) = stableFrame(gaze, horizFwd: player.bodyForward())
        for i in 0..<10 {
            let a = az0 + Float(i) * hstep
            // Gentle bowl: the row's ends dip slightly, matching the curved panel.
            let e = elev - 0.20 * (a - az) * (a - az)
            let dir = simd_normalize(fwd + right * tan(a) + up * tan(e))
            let center = origin + dir * hudDist
            let filled = value - i * 2
            let layer = filled >= 2 ? full : filled == 1 ? half : empty
            if layer < 0 { continue }            // empty: -1 draws no slot (absorption row)
            billboards.append(EntityInstance(pos: center - SIMD3(0, size * 0.5, 0),
                                             width: size, height: size,
                                             layer: Float(layer), light: 255))
        }
    }

    /// Fallback icon for a node-item whose ItemDef carries no inventory_image:
    /// the first non-empty face tile of the node with that name (a flat texture,
    /// good enough for the strip). nil if no such node is known.
    private func nodeIconTile(_ itemName: String) -> String? {
        let faces = client.nodes.faceTilesSnapshot()
        for (id, nm) in client.nodes.names where nm == itemName {
            if let tiles = faces[id], let t = tiles.first(where: { !$0.isEmpty }) { return t }
        }
        return nil
    }

    /// Parse (and cache) the custom model for every mesh-drawtype node whose
    /// file has arrived, keyed by content id for the mesher. A file that isn't
    /// downloaded yet is simply skipped and retried on the next remesh (like the
    /// mob-skin path — don't blacklist a not-yet-downloaded model).
    /// The parsed b3d/obj model for one mesh-drawtype node, if its media has
    /// downloaded and parsed. Shares nodeModelCache with the world mesher so the
    /// wield reuses whatever the terrain already loaded (#190).
    private var meshBoundsCache: [UInt16: (lo: SIMD3<Float>, hi: SIMD3<Float>)] = [:]
    /// A mesh-drawtype node model's AABB in our [g, g+1] node space (0..1), cached
    /// per content id. Used to aim/highlight a small mesh node by its model rather
    /// than a full cube when the server sent no selection box (#192). Facedir is
    /// ignored (these nodes are rarely rotated; the bounds are a close fallback).
    private func meshNodeBounds(_ id: UInt16) -> (lo: SIMD3<Float>, hi: SIMD3<Float>)? {
        if let c = meshBoundsCache[id] { return c }
        guard let m = nodeMeshModel(for: id), !m.positions.isEmpty else { return nil }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in m.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let box = (lo + 0.5, hi + 0.5)   // node-local centred ~[-0.5,0.5] -> [0,1]
        meshBoundsCache[id] = box
        return box
    }

    private func nodeMeshModel(for id: UInt16) -> B3DLoader.Mesh? {
        guard let file = client.nodes.meshNodes()[id] else { return nil }
        if let m = nodeModelCache[file] { return m }
        if nodeModelFailed.contains(file) { return nil }
        guard let data = client.media.store[file] else { return nil }
        let lower = file.lowercased()
        let mesh = lower.hasSuffix(".obj") ? OBJLoader.load(data)
                 : lower.hasSuffix(".b3d") ? B3DLoader.load(data) : nil
        if let mesh { nodeModelCache[file] = mesh } else { nodeModelFailed.insert(file) }
        return mesh
    }

    private func nodeModels() -> [UInt16: B3DLoader.Mesh] {
        var out: [UInt16: B3DLoader.Mesh] = [:]
        for (id, file) in client.nodes.meshNodes() {
            if let m = nodeModelCache[file] { out[id] = m; continue }
            if nodeModelFailed.contains(file) { continue }
            guard let data = client.media.store[file] else { continue }   // not downloaded yet
            let lower = file.lowercased()
            let mesh = lower.hasSuffix(".obj") ? OBJLoader.load(data)
                     : lower.hasSuffix(".b3d") ? B3DLoader.load(data) : nil
            if let mesh {
                nodeModelCache[file] = mesh; out[id] = mesh
                // A mesh-node model just arrived. Force a full rebuild this pass so
                // any block meshed before it (flower pots, lanterns placed earlier)
                // picks it up now instead of staying invisible until re-dirtied.
                fullRemesh = true
                print("[nodemesh] loaded \(file) (\(mesh.surfaces.count) surfaces)"); fflush(stdout)
            } else {
                nodeModelFailed.insert(file)
                print("[nodemesh] FAILED to parse \(file)"); fflush(stdout)
            }
        }
        return out
    }

    /// Parse+cache a model from the media store (nil cached as failed).
    #if targetEnvironment(simulator)
    /// Sim aid (-vrdev.spawnMob 1): drop a cow a few nodes in front of the fake
    /// camera so mob rendering, the model's ground placement (#67), a head-swivel
    /// bone override (#124) and a nametag (#118) can be eyeballed headlessly.
    /// Built as a real REMOVE_ADD + AO message so it runs the actual parse path;
    /// the poll loop downloads the .b3d and skin once the entity references them.
    /// One test mob: its Lua mesh, its textures array (brush order matters), the
    /// collisionbox top (for ground fit) and whether it walks/head-swivels.
    private struct SimMobSpec {
        let name: String, mesh: String, textures: [String], cbMaxY: Float
        var walk: SIMD2<Float>? = nil     // animation frame range, if any
        var headSwivel = false
        var yaw: Float = 180              // server yaw deg; 180 faces the camera
        var pitch: Float = 0             // server pitch deg; non-zero tilts the model (arrows, #128)
        var size = SIMD3<Float>(1, 1, 1)  // visual_size as the mob's Lua sends it (#286)
        var visual = "mesh"               // "cube" / "upright_sprite" exercise the non-mesh visuals (#287)
    }

    private func spawnSimMob() {
        let feet = player.snapshot().feet
        let bf = player.bodyForward()
        let right = SIMD3<Float>(-bf.z, 0, bf.x)   // camera-right, to line the mobs up
        func v3(_ w: PacketWriter, _ v: SIMD3<Float>) { w.f32(v.x).f32(v.y).f32(v.z) }
        let bs: Float = 10, shift: Float = 0.5

        // A spread of texture-tricky mobs so one screenshot surfaces any that
        // render blank/white (#72): multi-surface skeletons/zombies (some
        // surfaces map to blank/empty and must be dropped, not painted white),
        // the witch (single skin), the cow (walk + head-swivel, #82/#124).
        let mobs: [SimMobSpec] = [
            SimMobSpec(name: "Bessie", mesh: "mobs_mc_cow.b3d",
                       textures: ["mobs_mc_cow.png", "blank.png"], cbMaxY: 1.39,
                       walk: SIMD2(0, 40), headSwivel: true),
            // Distinct yaws so one screenshot shows facing from every side and a
            // mirror bug (yaw 90 and 270 looking identical) would jump out (#91).
            SimMobSpec(name: "Skeleton", mesh: "mobs_mc_skeleton.b3d",
                       textures: ["mcl_bows_bow_0.png", "mobs_mc_skeleton.png"], cbMaxY: 1.98, yaw: 0),
            // The horse skin is a base^markings composite (horse.lua) — the
            // #72-flagged case where an overlaid texture must resolve on the
            // model path, not render blank. Centred in the row so it is easy to
            // read headlessly.
            SimMobSpec(name: "Horse", mesh: "mobs_mc_horse.b3d",
                       textures: ["blank.png",
                                  "mobs_mc_horse_brown.png^mobs_mc_horse_markings_whitedots.png",
                                  "blank.png"], cbMaxY: 1.59, size: SIMD3(3, 3, 3)),
            SimMobSpec(name: "Zombie", mesh: "mobs_mc_zombie.b3d",
                       textures: ["mobs_mc_empty.png", "mobs_mc_zombie.png"], cbMaxY: 1.89, yaw: 90),
            SimMobSpec(name: "Witch", mesh: "vl_witch.b3d",
                       textures: ["vl_witch.png"], cbMaxY: 1.94, yaw: 270, size: SIMD3(2.2, 2.2, 2.2)),
            // A pitched arrow (#128): its shaft should tilt off horizontal. The
            // mobs above all have pitch 0, so they must look identical with this.
            SimMobSpec(name: "Arrow", mesh: "mcl_bows_arrow.obj",
                       textures: ["mcl_bows_arrow.png"], cbMaxY: 0.125, yaw: 180, pitch: 40, size: SIMD3(-1, 1, 1)),
            // A "cube" visual (mcl_tnt's primed TNT, 6 face textures) and an
            // "upright_sprite" (what sign text / item-frame maps use): both
            // sit on the origin, so with cbMaxY 0.5 the TNT should be half
            // sunk into the platform like a real primed TNT (origin = centre).
            SimMobSpec(name: "TNT", mesh: "", textures: ["default_tnt_top.png", "default_tnt_bottom.png",
                                                          "default_tnt_side.png", "default_tnt_side.png",
                                                          "default_tnt_side.png", "default_tnt_side.png"],
                       cbMaxY: 0.5, yaw: 30, visual: "cube"),
            SimMobSpec(name: "Sign", mesh: "", textures: ["default_tnt_side.png", "default_tnt_top.png"], cbMaxY: 1, yaw: 0,
                       size: SIMD3(1, 0.5, 1), visual: "upright_sprite"),
        ]
        // Local-only object ids for the sim lineup, taken from the top of the
        // u16 range and skipping ids the server has already handed out (its
        // counter had reached 60000+ on the dev world, so the old fixed 60000+i
        // clashed with live witches). These objects never leave the process.
        let usedIds = Set(client.objects.snapshot().map { $0.id })
        var nextSimObjectId = 65000
        func nextUnusedObjectId() -> Int { while usedIds.contains(nextSimObjectId) { nextSimObjectId += 1 }; defer { nextSimObjectId += 1 }; return nextSimObjectId }
        var mobIds: [String: Int] = [:]
        for (i, m) in mobs.enumerated() {
            let id = nextUnusedObjectId()
            mobIds[m.name] = id
            // Line them up 4 nodes ahead, 1.5 nodes apart across the view.
            let off = Float(i) - Float(mobs.count - 1) / 2
            // +1.2 lifts the lineup to near eye level of the floating player so the
            // sim's default (level) camera frames it without a pitch flag (#91).
            let target = SIMD3<Float>(feet.x + bf.x * 4 + right.x * off * 1.5, feet.y + 1.2,
                                      feet.z + bf.z * 4 + right.z * off * 1.5)
            let props = PacketWriter()
            props.u8(0).u8(4)                 // cmd SET_PROPERTIES, version 4
            props.u16(20).u8(1).u32(0)        // hp_max, physical, weight
            v3(props, SIMD3(-0.45, -0.01, -0.45)); v3(props, SIMD3(0.45, m.cbMaxY, 0.45))   // collisionbox
            v3(props, SIMD3(-0.45, -0.01, -0.45)); v3(props, SIMD3(0.45, m.cbMaxY, 0.45))   // selectionbox
            props.u8(1)                       // pointable
            props.string16(m.visual)
            v3(props, m.size)                 // visual_size
            props.u16(m.textures.count); for t in m.textures { props.string16(t) }
            props.s16(1).s16(1).s16(0).s16(0) // spritediv, initial_sprite_basepos
            props.u8(1).u8(1).f32(0)          // is_visible, footstep, automatic_rotate
            props.string16(m.mesh)
            props.u16(0)                      // colors
            props.u8(1).f32(0.6).u8(0).f32(0).u8(1)   // collide, stepheight, facedir, offset, backface
            props.string16(m.name).u32(0xFFFF_FFFF)   // nametag + colour

            let initData = PacketWriter()
            initData.u8(1).string16("sim:\(m.name)").u8(0).u16(id)
            v3(initData, (target - shift) * bs)        // position (server grid units)
            v3(initData, SIMD3(0, m.yaw, m.pitch))     // rotation deg (facing #91; the arc tilt rides rotation.z like vl_projectile, #305)
            initData.u16(20).u8(1).bytes32(props.data) // hp, one initial message
            let add = PacketWriter()
            add.u16(0).u16(1).u16(id).u8(0).bytes32(initData.data)
            client.objects.handleRemoveAdd(add.data)

            if m.headSwivel {
                let bone = PacketWriter()
                bone.u8(7).string16("head.control")
                v3(bone, .zero); v3(bone, SIMD3(0, 40, 0)); v3(bone, SIMD3(1, 1, 1))
                bone.f32(0).f32(0).f32(0).u8(0)   // relative rotation
                client.objects.handleMessages(PacketWriter().u16(id).bytes16(bone.data).data)
            }
            if let w = m.walk {
                let anim = PacketWriter().u8(6).f32(w.x).f32(w.y).f32(30).f32(0).u8(0)
                client.objects.handleMessages(PacketWriter().u16(id).bytes16(anim.data).data)
            }
        }
        // Item visuals (wielditem): a dropped node (dirt) and tool (pick) check
        // the node-cube fallback (#129) and the inventory-image path; a falling
        // gravel node (__builtin:falling_node, visual_size 0.667 = one full
        // block, no spin) checks the non-drop item entities (#266).
        let drops: [(item: String, name: String, size: Float)] = [
            ("mcl_core:dirt", "__builtin:item", 0.4), ("mcl_tools:pick_diamond", "__builtin:item", 0.4),
            ("mcl_core:gravel", "__builtin:falling_node", 0.667)]
        var dropIds: [Int] = []
        for (j, d) in drops.enumerated() {
            let itemStr = d.item
            let id = nextUnusedObjectId()
            dropIds.append(id)
            let off = Float(j) - Float(drops.count - 1) / 2
            let target = SIMD3<Float>(feet.x + bf.x * 3 + right.x * off * 1.2, feet.y + 0.3,
                                      feet.z + bf.z * 3 + right.z * off * 1.2)
            let props = PacketWriter()
            props.u8(0).u8(4).u16(1).u8(1).u32(0)
            v3(props, SIMD3(-0.2, -0.2, -0.2)); v3(props, SIMD3(0.2, 0.2, 0.2))
            v3(props, SIMD3(-0.2, -0.2, -0.2)); v3(props, SIMD3(0.2, 0.2, 0.2))
            props.u8(0)                       // pointable
            props.string16("wielditem")
            v3(props, SIMD3(d.size, d.size, d.size))   // visual_size
            props.u16(1).string16(itemStr)    // "textures" holds the itemstring
            props.s16(1).s16(1).s16(0).s16(0)
            props.u8(1).u8(0).f32(0)
            props.string16("")                // no mesh
            let initData = PacketWriter()
            initData.u8(1).string16(d.name).u8(0).u16(id)
            v3(initData, (target - shift) * bs)
            v3(initData, SIMD3(0, 0, 0))
            initData.u16(1).u8(1).bytes32(props.data)
            client.objects.handleRemoveAdd(PacketWriter().u16(0).u16(1).u16(id).u8(0).bytes32(initData.data).data)
        }
        // Bone attachment (#282): hang the pick off the zombie's right arm the
        // way vl_held_item / mcl_shields do (ATTACH_TO with a bone name). A
        // zero offset should put it exactly on the shoulder joint (checked:
        // it does); real mods add an offset in the bone's own frame.
        if let zombie = mobIds["Zombie"], dropIds.count > 1 {
            let att = PacketWriter().u8(8)   // AO_CMD_ATTACH_TO
            att.u16(zombie).string16("arm.right")
            v3(att, SIMD3(0, 0, 0)); v3(att, SIMD3(0, 0, 0)); att.u8(1)
            client.objects.handleMessages(PacketWriter().u16(dropIds[1]).bytes16(att.data).data)
        }
        print("[simmob] spawned \(mobs.count) mobs + \(drops.count) drops: \(mobs.map { $0.name }.joined(separator: ", "))"); fflush(stdout)
    }

    /// Sim aid (-vrdev.spawnBed 1): lay a row of beds (each is two mesh nodes,
    /// foot + head) on a stone floor in front of the fake camera, one per
    /// horizontal facedir 0..3, so bed mesh geometry, the foot/head seam and the
    /// 64x64 UV-sheet texture can be eyeballed headless (#131). Writes real nodes
    /// into the local world copy and forces a remesh.
    private func spawnSimBed() {
        let feet = player.snapshot().feet
        let bf = player.bodyForward()
        let right = SIMD3<Float>(-bf.z, 0, bf.x)
        func node(_ p: SIMD3<Float>) -> SIMD3<Int> {
            SIMD3(Int(floor(p.x)), Int(floor(p.y)), Int(floor(p.z)))
        }
        // facedir 0..3 -> step to the head node, matching WorldMesher.rotateFacedir
        // applied to +Z (i.e. minetest.facedir_to_dir): 0:+Z 1:+X 2:-Z 3:-X.
        func headDir(_ f: Int) -> SIMD3<Int> {
            switch f & 3 {
            case 1: return SIMD3(1, 0, 0)
            case 2: return SIMD3(0, 0, -1)
            case 3: return SIMD3(-1, 0, 0)
            default: return SIMD3(0, 0, 1)
            }
        }
        guard let foot = client.nodes.id(for: "mcl_beds:bed_red_bottom"),
              let head = client.nodes.id(for: "mcl_beds:bed_red_top"),
              let stone = client.nodes.id(for: "mcl_core:stone") else {
            print("[simbed] bed/stone node ids not found"); fflush(stdout); return
        }
        // A row of 4 beds (each foot+head), one per horizontal facedir 0..3, on a
        // stone floor a few nodes ahead. On the dev spawn the view is often busy;
        // walk to the row, or place them where you can see them on device.
        let base = node(SIMD3(feet.x + bf.x * 3, feet.y, feet.z + bf.z * 3))
        let rx = Int(right.x.rounded()), rz = Int(right.z.rounded())
        // Carve the air above/around the row so it's visible from above at the
        // busy spawn (look down with -vrdev.down 45 to see the bed TOP texture,
        // which is what the 64px atlas fix was for).
        for dx in -6...6 { for dz in -6...6 { for dy in 0...5 {
            client.world.setNode(SIMD3(base.x + dx, base.y + dy, base.z + dz), param0: WorldMap.CONTENT_AIR)
        }}}
        for f in 0..<4 {
            let off = (f - 2) * 3
            let origin = SIMD3(base.x + rx * off, base.y, base.z + rz * off)
            let dir = headDir(f)
            let footPos = origin, headPos = origin &+ dir
            // Stone floor one below each half so the bed isn't floating.
            client.world.setNode(SIMD3(footPos.x, footPos.y - 1, footPos.z), param0: stone)
            client.world.setNode(SIMD3(headPos.x, headPos.y - 1, headPos.z), param0: stone)
            client.world.setNode(footPos, param0: foot, param2: UInt8(f))
            client.world.setNode(headPos, param0: head, param2: UInt8(f))
        }
        fullRemesh = true; remeshCooldown = 0
        print("[simbed] placed 4 beds (facedir 0..3) at \(base)"); fflush(stdout)
    }

    /// Sim aid (-vrdev.spawnGlass 1): a 3x3 wall of red stained glass a few nodes
    /// ahead with a stone wall right behind it and a cleared tunnel between, so
    /// translucent glass (#143/#144) is checkable headless -- you should see the
    /// stone tinted red THROUGH the glass, not a holey or opaque pane.
    private func spawnSimGlass() {
        let feet = player.snapshot().feet
        let bf = player.bodyForward()
        let right = SIMD3<Float>(-bf.z, 0, bf.x)
        let fx = Int(bf.x.rounded()), fz = Int(bf.z.rounded())
        let rx = Int(right.x.rounded()), rz = Int(right.z.rounded())
        func node(_ p: SIMD3<Float>) -> SIMD3<Int> { SIMD3(Int(floor(p.x)), Int(floor(p.y)), Int(floor(p.z))) }
        guard let glass = client.nodes.id(for: "mcl_core:glass_red"),
              let back = client.nodes.id(for: "mcl_core:goldblock") ?? client.nodes.id(for: "mcl_core:stone") else {
            print("[simglass] glass/backing node ids not found"); fflush(stdout); return
        }
        // Carve a clear 3-wide, 3-tall, 3-deep pocket right in front of the eye so
        // the pane isn't buried at the busy spawn, put the glass close (2 nodes,
        // fills the view) and a bright gold wall right behind it -- through
        // translucent glass you should see gold tinted red, not a solid pane.
        let eye = node(SIMD3(feet.x, feet.y + 1, feet.z))
        // Build the fixed node list once so the re-asserts below paint the exact
        // same cells even if the (idle) sim player drifts a hair.
        var air: [SIMD3<Int>] = [], panes: [SIMD3<Int>] = [], backing: [SIMD3<Int>] = []
        for dy in 0..<3 { for dr in -1...1 {
            func at(_ ahead: Int) -> SIMD3<Int> {
                SIMD3(eye.x + fx * ahead + rx * dr, eye.y + dy, eye.z + fz * ahead + rz * dr)
            }
            for ahead in -1...1 { air.append(at(ahead)) }  // room around the eye
            panes.append(at(2))    // the pane, 2 ahead
            backing.append(at(3))  // bright backing to tint through it
        }}
        func paint() {
            for p in air { client.world.setNode(p, param0: WorldMap.CONTENT_AIR) }
            for p in panes { client.world.setNode(p, param0: glass) }
            for p in backing { client.world.setNode(p, param0: back) }
            fullRemesh = true; remeshCooldown = 0
        }
        paint()
        // The scene is painted on the first post-spawn tick, but the server is
        // still streaming the real blocks for this area and each BLOCKDATA
        // overwrites our local glass a beat later (which left the pane invisible
        // in headless captures). Re-assert over the first few seconds so the aid
        // wins against late-arriving streams.
        for delay in [1.0, 2.0, 3.5] { queue.asyncAfter(deadline: .now() + delay) { paint() } }
        print("[simglass] placed 3x3 red glass + gold backing ahead of \(eye)"); fflush(stdout)
    }

    /// Sim aid (-vrdev.spawnRails 1): lay a straight run, an L-corner, a T and a
    /// cross of rails on a stone floor in a carved pit, so the raillike
    /// connection tiles + rotation (#140) can be eyeballed from above
    /// (-vrdev.down 85). A corner should curve toward BOTH its neighbours; if
    /// the curve bends the wrong way it's the Z-mirror flip to fix in railGeom.
    private func spawnSimRails() {
        let feet = player.snapshot().feet
        let bf = player.bodyForward()
        func node(_ p: SIMD3<Float>) -> SIMD3<Int> { SIMD3(Int(floor(p.x)), Int(floor(p.y)), Int(floor(p.z))) }
        guard let rail = client.nodes.id(for: "mcl_minecarts:rail_v2"),
              let stone = client.nodes.id(for: "mcl_core:stone") else {
            print("[simrails] rail/stone node ids not found"); fflush(stdout); return
        }
        let base = node(SIMD3(feet.x + bf.x * 3, feet.y, feet.z + bf.z * 3))
        for dx in -8...8 { for dz in -8...8 { for dy in 0...5 {
            client.world.setNode(SIMD3(base.x + dx, base.y + dy, base.z + dz), param0: WorldMap.CONTENT_AIR)
        }}}
        // Grid layout (x runs right, z runs "back"/+Z). Neighbours drive the tile.
        func lay(_ pts: [(Int, Int)]) {
            for (px, pz) in pts {
                let p = SIMD3(base.x + px, base.y, base.z + pz)
                client.world.setNode(SIMD3(p.x, p.y - 1, p.z), param0: stone)   // floor under each
                client.world.setNode(p, param0: rail)
            }
        }
        lay([(-6, 0), (-5, 0), (-4, 0)])                 // straight run along +X
        lay([(0, 0), (1, 0), (0, 1)])                    // L-corner (arms +X and +Z from 0,0)
        lay([(4, 0), (3, 0), (5, 0), (4, 1)])            // T-junction at (4,0)
        lay([(0, 4), (1, 4), (-1, 4), (0, 5), (0, 3)])   // cross at (0,4)
        fullRemesh = true; remeshCooldown = 0
        print("[simrails] placed straight/corner/T/cross at \(base)"); fflush(stdout)
    }

    /// Sim aid (-vrdev.rideTest 1): place a vehicle AO a few nodes ahead and UP,
    /// then attach the local player to it, so riding (#139) can be verified
    /// headless -- the camera should snap up onto the vehicle instead of staying
    /// on the ground.
    private func spawnSimRide() {
        let feet = player.snapshot().feet
        let bf = player.bodyForward()
        let bs: Float = 10, id = 30200   // < 32767 so it fits the s16 attach parent
        func v3(_ w: PacketWriter, _ v: SIMD3<Float>) { w.f32(v.x).f32(v.y).f32(v.z) }
        // A visible marker AO (a wielditem showing a plank), 2 ahead and 3 up.
        let target = SIMD3<Float>(feet.x + bf.x * 2, feet.y + 3, feet.z + bf.z * 2)
        let props = PacketWriter()
        props.u8(0).u8(4).u16(1).u8(1).u32(0)
        v3(props, SIMD3(-0.4, -0.4, -0.4)); v3(props, SIMD3(0.4, 0.4, 0.4))
        v3(props, SIMD3(-0.4, -0.4, -0.4)); v3(props, SIMD3(0.4, 0.4, 0.4))
        props.u8(0)
        props.string16("wielditem")
        v3(props, SIMD3(0.8, 0.8, 0.8))
        props.u16(1).string16("mcl_core:sprucewood")
        props.s16(1).s16(1).s16(0).s16(0)
        props.u8(1).u8(0).f32(0)
        props.string16("")
        let initData = PacketWriter()
        initData.u8(1).string16("__builtin:item").u8(0).u16(id)
        v3(initData, (target - 0.5) * bs)
        v3(initData, SIMD3(0, 0, 0))
        initData.u16(1).u8(1).bytes32(props.data)
        client.objects.handleRemoveAdd(PacketWriter().u16(0).u16(1).u16(id).u8(0).bytes32(initData.data).data)
        // Attach the local player to the vehicle (AO cmd 8): s16 parent, bone,
        // v3f offset (BS units), v3f rotation. Sit 1 node above the boat.
        let lp = client.objects.localPlayerId
        let att = PacketWriter().u8(8).s16(id).string16("")
        v3(att, SIMD3(0, 1, 0) * bs); v3(att, .zero)
        client.objects.handleMessages(PacketWriter().u16(lp).bytes16(att.data).data)
        print("[simride] vehicle \(id) at \(target), attached player \(lp)"); fflush(stdout)
    }
    #endif

    /// The model-array texture spec for a dropped item (visual "wielditem"):
    /// the item's inventory_image, or, when that is empty (nodes rely on a
    /// generated cube icon), the node's top-face tile so dropped dirt/stone
    /// aren't invisible (#129). Same spec is baked and looked up, so they agree.
    private var wieldSilCache: [String: B3DLoader.Mesh] = [:]
    /// The wielded item's icon extruded into a 3D silhouette (desktop wieldmesh
    /// look), cached per icon tile. nil when the tile has no pixels, or is a solid
    /// square (a block/full icon gains nothing from extrusion and uses the cube /
    /// flat slab instead).
    private func wieldSilhouette(for tile: String) -> B3DLoader.Mesh? {
        if let m = wieldSilCache[tile] { return m.positions.isEmpty ? nil : m }
        guard wieldSilCache.count < 128,
              let px = TextureAtlas.evaluateModifiedFit(tile, media: client.media, canvas: 16)?.px else { return nil }
        let alpha = WieldMesh.alphaGrid(rgba: px, width: 16, height: 16, cells: 16)
        let mesh: B3DLoader.Mesh = (alpha.allSatisfy { $0 }) || (alpha.allSatisfy { !$0 })
            ? B3DLoader.Mesh(positions: [], uvs: [], indices: [], textureName: "", minBounds: .zero, maxBounds: .zero)
            : WieldMesh.extrudeIcon(alpha: alpha, width: 16, height: 16, thickness: 0.08)
        wieldSilCache[tile] = mesh
        return mesh.positions.isEmpty ? nil : mesh
    }

    /// Resolve (and cache) how an item entity's itemstring draws. These go into
    /// the model stream, which the renderer samples from the MODEL texture
    /// array, so node faces must be the upscaled model-layer copies
    /// (iconLayerForTile, like the 3D inventory icons), not node-atlas indices:
    /// an atlas index in this stream picks an unrelated skin/icon layer or falls
    /// off the end, and the drop draws as nothing (#358). Unresolved items
    /// aren't cached, so they pick up their layer once the texture lands.
    private func itemDraw(_ itemStr: String) -> ItemDraw? {
        if let d = itemDrawCache[itemStr] { return d }
        var d: ItemDraw?
        var provisional = false   // a mesh node's card stand-in until its model loads
        let nid = client.nodes.id(for: ItemRegistry.baseName(itemStr))
        if let nid, nid != WorldMap.CONTENT_AIR {
            let kind = client.nodes.kind(nid)
            let topTile = client.nodes.faceTile(nid, 0)
            if kind == .mesh {
                if nodeMeshModel(for: nid) != nil, let layer = topTile.flatMap(iconLayerForTile) {
                    d = .model(nid: nid, layer: layer)
                } else { provisional = true }
            } else if kind == .cube {
                let layers = (0..<6).map { (client.nodes.faceTile(nid, $0) ?? topTile).flatMap(iconLayerForTile) ?? -1 }
                if !layers.contains(-1) { d = .cube(layers) }
                else { return nil }   // a cube waits for its faces; never falls back to a card
            }
        }
        if d == nil, let spec = droppedItemSpec(itemStr), let layer = modelTexLayer[spec] {
            d = .card(layer: layer, uv: modelTexUV[spec] ?? SIMD2(1, 1))
        }
        if let d, !provisional { itemDrawCache[itemStr] = d }
        return d
    }

    private func droppedItemSpec(_ itemStr: String) -> String? {
        if let img = client.items.image(for: itemStr), !img.isEmpty { return img }
        if let nid = client.nodes.id(for: ItemRegistry.baseName(itemStr)), nid != WorldMap.CONTENT_AIR {
            return client.nodes.faceTile(nid, 0)
        }
        return nil
    }

    #if targetEnvironment(simulator)
    /// Sim aid (-vrdev.realHud 1): feed the REAL server HUDADD packets for the
    /// armor statbar and the XP level, through the actual parse path (not the
    /// -vrdev.fakeHud struct stub), so armor (#108) and XP (#107) can be
    /// reproduced headlessly the way they arrive on device.
    private func simulateServerHud() {
        // TOCLIENT_HUDADD layout (Client.handleHudAdd): u32 id, u8 type, 2xf32
        // pos, string16 name, 2xf32 scale, string16 text, u32 number, u32 item,
        // u32 dir, 2xf32 align, 2xf32 offset, 3xf32 world_pos, 2xf32 size.
        func hudAdd(id: Int, type: Int, text: String, number: Int, item: Int, dir: Int,
                    pos: SIMD2<Float>, align: SIMD2<Float>, off: SIMD2<Float>) {
            let w = PacketWriter().u32(id).u8(type)
            w.f32(pos.x).f32(pos.y).string16("").f32(1).f32(1).string16(text)
            w.u32(number).u32(item).u32(dir)
            w.f32(align.x).f32(align.y).f32(off.x).f32(off.y).f32(0).f32(0).f32(0).f32(0).f32(0)
            client.simulateServerPacket(op: Op.toclientHudAdd, payload: w.data)
        }
        // Armor statbar exactly as the device log showed it.
        hudAdd(id: 300, type: 2, text: "hbarmor_icon.png", number: 16, item: 20, dir: 0,
               pos: SIMD2(0.5, 1), align: SIMD2(-1, -1), off: SIMD2(-266, -110))
        // mcl_experience level readout: a text element in XP green (0x80FF20).
        hudAdd(id: 301, type: 1, text: "12", number: 0x80FF20, item: 0, dir: 0,
               pos: SIMD2(0.5, 1), align: SIMD2(0, 0), off: SIMD2(0, -96))
        print("[realhud] simulated armor statbar + xp level"); fflush(stdout)
    }
    #endif

    private func model(for name: String) -> B3DLoader.Mesh? {
        if let m = modelCache[name] { return m }
        if name.isEmpty || modelFailed.contains(name) { return nil }
        guard let data = client.media.store[name] else { return nil }   // not downloaded yet
        if let m = B3DLoader.load(data) { modelCache[name] = m; return m }
        modelFailed.insert(name); return nil
    }

    /// Assign a texture-array layer to each distinct mob skin as it appears,
    /// decode it full-res, and post the set when it grows.
    /// Decode an image spec (tile modifier or plain name) into the model texture
    /// array, once. Returns true if it added a new layer.
    private func assignModelTexture(_ spec: String) -> Bool {
        guard !spec.isEmpty, modelTexLayer[spec] == nil, !modelFailed.contains(spec) else { return false }
        // Full modifier string: base + '^' overlays + [colorize] (mob skins like
        // "horse_chestnut.png^horse_markings_white.png"). Wait (return false, no
        // blacklist) until the base PNG has downloaded; only give up if a
        // present base fails to decode.
        let imgs = NodeRegistry.imageNames(spec)
        guard !imgs.isEmpty else { modelFailed.insert(spec); return false }
        // Every PNG in the modifier must be present, not just the base: an
        // overlay (e.g. horse markings) downloads independently, and compositing
        // early would cache a base-only skin forever (the overlay never re-applies).
        guard imgs.allSatisfy({ client.media.store[$0] != nil }) else { return false }
        guard let img = TextureAtlas.evaluateModifiedFit(spec, media: client.media, canvas: ModelTextureHandoff.size) else {
            modelFailed.insert(spec); return false
        }
        modelTexLayer[spec] = modelTexCount; modelTexUV[spec] = img.uv
        modelTexData.append(img.px); modelTexNames.append(spec); modelTexCount += 1
        return true
    }

    private var modelTexturesDirty = false   // layers registered outside this function (inventory labels)
    private func ensureModelTextures(_ ents: [ActiveObjects.Entity]) {
        var changed = modelTexturesDirty
        modelTexturesDirty = false
        if crackTex.isEmpty, let data = client.media.store["crack_anylength.png"] {
            for (i, f) in TextureAtlas.decodeCrackFrames(data, canvas: ModelTextureHandoff.size).enumerated() {
                let name = "crack#\(i)"
                modelTexLayer[name] = modelTexCount; modelTexUV[name] = f.uv
                modelTexData.append(f.px); modelTexNames.append(name)
                crackTex.append((modelTexCount, f.uv)); modelTexCount += 1
                changed = true
            }
            if changed { print("[model] crack frames: \(crackTex.count)"); fflush(stdout) }
        }
        if deathTextLayer < 0, let px = Self.renderTextRGBA("YOU DIED", canvas: ModelTextureHandoff.size) {
            let name = "#deathtext"
            modelTexLayer[name] = modelTexCount; modelTexUV[name] = SIMD2(1, 1)
            modelTexData.append(px); modelTexNames.append(name)
            deathTextLayer = modelTexCount; modelTexCount += 1
            changed = true
            print("[death] text layer \(deathTextLayer)"); fflush(stdout)
        }
        // Kogane companion sprite + menu text, baked once into the model array.
        if koganeLayer < 0, let px = Self.renderKoganeRGBA(canvas: ModelTextureHandoff.size) {
            koganeLayer = registerRGBALayer("#kogane", px); changed = true
            print("[kogane] sprite layer \(koganeLayer)"); fflush(stdout)
        }
        if koganeClosedLayer < 0, let px = Self.renderKoganeRGBA(canvas: ModelTextureHandoff.size, closed: true) {
            koganeClosedLayer = registerRGBALayer("#koganeclosed", px); changed = true
        }
        if koganeTitleLayer < 0, let px = Self.renderTextRGBA("Kogane", canvas: ModelTextureHandoff.size, fontFrac: 0.17) {
            koganeTitleLayer = registerRGBALayer("#koganetitle", px); changed = true
        }
        if koganeOptionLayers.isEmpty {
            for (i, opt) in koganeOptions.enumerated() {
                if let px = Self.renderTextRGBA(opt, canvas: ModelTextureHandoff.size, fontFrac: 0.11) {
                    koganeOptionLayers.append(registerRGBALayer("#koganeopt\(i)", px)); changed = true
                }
            }
        }
        // A one-off solid-opaque layer for the pointed-node highlight box. The
        // box quads sample this (alpha 1, so they survive the fragment's alpha
        // cutout) and carry a black vertex tint, giving a flat black wireframe.
        if highlightLayer < 0 {
            let n = ModelTextureHandoff.size * ModelTextureHandoff.size * 4
            highlightLayer = modelTexCount
            modelTexLayer["__highlight"] = modelTexCount
            modelTexUV["__highlight"] = SIMD2(1, 1)
            modelTexData.append([UInt8](repeating: 255, count: n))
            modelTexNames.append("__highlight"); modelTexCount += 1
            changed = true
        }
        // Skip the entity texture scan unless a new texture appeared or media
        // just landed (#251): resolved specs return instantly and pending ones
        // only progress on media arrival, so a steady state re-parsed skins for
        // nothing every tick.
        let tilesCount = client.objects.tiles.count
        if modelTexRescan || tilesCount != lastModelTexTilesCount {
            modelTexRescan = false
            lastModelTexTilesCount = tilesCount
            for e in ents {
                if e.visual == "mesh" {
                    // A mob's model has one material per texture entry; resolve them
                    // all so each surface can be painted with its own skin. Blank
                    // materials (empty armor, absent mushrooms) get no layer and are
                    // skipped when drawn.
                    for t in e.textures where !Self.isBlankSpec(t) {
                        if assignModelTexture(t) { changed = true }
                    }
                } else if e.name == "__builtin:item", let itemStr = e.textures.first,
                          let spec = droppedItemSpec(itemStr) {
                    if assignModelTexture(spec) { changed = true }
                }
            }
        }
        // Rebuild when we've registered new layers, OR when the renderer's array
        // fell behind what we last posted -- a full rebuild it dropped/failed
        // (device memory pressure). Without the second check the count "latched":
        // the renderer's array stayed small, patches to the missing high indices
        // were dropped, and the newest layers (inventory icons) sampled out of
        // range -> discarded -> empty slots on device only (#254).
        let needFull = modelTexCount != modelTexPostedCount
                    || modelTextureHandoff.builtCount < modelTexPostedCount
        if changed || needFull {
            if needFull {
                // Layer count changed (new skin/label/count/crack/etc), or re-post
                // to catch the renderer up after a dropped rebuild.
                let out = (0..<modelTexCount).map {
                    ModelTexture(name: modelTexNames[$0], rgba: modelTexData[$0],
                                 uvScale: modelTexUV[modelTexNames[$0]] ?? SIMD2(1, 1))
                }
                modelTextureHandoff.post(full: out)
                modelTexPostedCount = modelTexCount
                modelTexDirty.removeAll()
            } else if !modelTexDirty.isEmpty {
                // Only existing layers' pixels changed: patch them in place.
                let patches = modelTexDirty.map { ModelTexPatch(index: $0, rgba: modelTexData[$0]) }
                modelTextureHandoff.post(patches: patches)
                modelTexDirty.removeAll()
            }
        }
    }

    /// A "material with nothing to show": empty armor slots, absent mushrooms,
    /// the invisible bow layer. These decode to a fully transparent image (or
    /// aren't served at all), so we neither give them a texture layer nor let
    /// their geometry count toward the auto-fit bounds.
    static func isBlankSpec(_ spec: String) -> Bool {
        let s = spec.lowercased()
        return s == "blank.png" || s.contains("_empty") || s == "empty.png"
    }

    /// Transform a model into origin space (auto-fit to the collisionbox, feet
    /// on the ground, facing the entity yaw) and append its triangles, painting
    /// each surface with the matching entry from the entity's textures array
    /// (surface k -> textures[brush]). Returns false when no surface has a
    /// resolved skin yet (textures still downloading) so the caller can billboard.
    @discardableResult
    private func appendModel(_ mesh: B3DLoader.Mesh, entity e: ActiveObjects.Entity,
                             eye: SIMD3<Float>, cosY: Float, sinY: Float,
                             playerYaw: Float, light: Float, tint: Float, v: inout [Float], idx: inout [UInt32]) -> Bool {
        // Resolve each surface to a texture layer; a surface with a blank or
        // not-yet-downloaded skin is dropped entirely (no geometry emitted).
        var draw: [(surface: B3DLoader.Surface, layer: Int, uv: SIMD2<Float>)] = []
        var droppedSpecs: [String] = []
        for surf in mesh.surfaces {
            let base = surf.brush >= 0 && surf.brush < e.textures.count
                     ? e.textures[surf.brush] : (e.textures.first ?? "")
            if Self.isBlankSpec(base) { continue }
            // Append the live texture-mod (burning/damage/status colorize, #228).
            // Compose the modified layer on demand; until it's ready, draw the
            // base so the mob never vanishes waiting for the overlay.
            var spec = base
            if !e.textureMod.isEmpty {
                let modded = base + e.textureMod
                if modelTexLayer[modded] != nil { spec = modded }
                else if assignModelTexture(modded) { modelTexturesDirty = true; spec = modded }
            }
            if let layer = modelTexLayer[spec] {
                draw.append((surf, layer, modelTexUV[spec] ?? SIMD2(1, 1)))
            } else if let layer = modelTexLayer[base] {
                draw.append((surf, layer, modelTexUV[base] ?? SIMD2(1, 1)))   // overlay not composed yet
            } else { droppedSpecs.append(base) }
        }
        // Diagnose a partly-textured model (e.g. a player whose armour shows but
        // whose body/skin is missing): log the unresolved, non-blank specs once
        // per entity name so the device log names exactly what to download.
        if !draw.isEmpty, !droppedSpecs.isEmpty, !modelDropLogged.contains(e.name) {
            modelDropLogged.insert(e.name)
            print("[modeldrop] \(e.name) mesh=\(e.mesh) drew=\(draw.count)/\(mesh.surfaces.count) missing=[\(droppedSpecs.joined(separator: ", "))]"); fflush(stdout)
        }
        // Fallback for white mobs (e.g. the horse): every surface mapped to a
        // blank/unresolved slot because the b3d brush index doesn't line up with
        // the mob's textures array. Rather than fall back to a white billboard,
        // paint ALL surfaces with the first non-blank skin we DID resolve.
        if draw.isEmpty {
            if let skin = e.textures.first(where: { !Self.isBlankSpec($0) && modelTexLayer[$0] != nil }),
               let layer = modelTexLayer[skin] {
                let uv = modelTexUV[skin] ?? SIMD2(1, 1)
                draw = mesh.surfaces.map { ($0, layer, uv) }
            }
        }
        guard !draw.isEmpty else { return false }

        let scale = PlayerState.scale
        // Model scale is what the engine does (GenericCAO::addToScene): the mesh
        // file's units are Irrlicht/BS units (10 per node) and the scene node is
        // scaled by visual_size, so nodes = units * visual_size / 10. Checked
        // against VoxeLibre: zombie 18 units at 1.0 = 1.8 (box 1.89), chicken
        // 6.6 = 0.66 (box 0.69), the chest lid entity spans -5..3.7 = the node
        // it sits in, the rover is 2.4 units at visual_size 10. The old
        // collisionbox height-fit got mobs roughly right but made the ghast
        // (visual_size 8) and dragon (3) a fraction of their size (#286).
        // A negative axis mirrors, sign included, exactly as setScale does
        // (the arrow OBJ has its shaft along +X with visual_size.x = -1).
        let vsz = e.size.z != 0 ? e.size.z : e.size.x
        let ms = SIMD3<Float>(e.size.x, e.size.y, vsz) * 0.1
        // Animated model: skin the bind positions at the entity's current frame.
        // Bounds/fit above stay on the bind pose so the size doesn't breathe.
        // Skin once per entity per distinct frame: a chest parked on its last
        // frame or a mob between server ticks reuses the previous result (#86).
        let positions: [SIMD3<Float>]
        if !mesh.joints.isEmpty, (mesh.isAnimated && e.animRange != nil) || !e.boneOverrides.isEmpty {
            // Frame quantisation is a distance LOD (perf review #5): up close,
            // 1/20-frame steps are invisible but an animating mob (~0.25
            // frame/tick) missed the skin cache every single tick; ~55 mesh mobs
            // in range made that a steady 1-3 ms of every tick. Beyond ~16 nodes
            // step whole frames (the animations are 15-25 fps, so it reads the
            // same), and beyond ~48 nodes step every other frame. Far mobs then
            // hit the cache most ticks instead of re-skinning.
            let dist = simd_length(e.pos - eye)
            let step: Float = dist > 48 ? 0.5 : (dist > 16 ? 1 : 20)
            let frame = e.animRange == nil ? 0 : (e.animFrame * step).rounded() / step
            // Bone overrides (head swivel) are part of the pose, so they key
            // the cache too; quantised so a settled head hits the cache.
            // Hash straight off the entity's override table (no mapValues copy,
            // no sorted array per tick, perf #311). Its iteration order is
            // stable for the same storage; a reorder only costs one cache
            // miss (a re-skin), never a wrong pose. The converted overrides are
            // only built on a miss.
            var bones = 0
            if !e.boneOverrides.isEmpty {
                var h = Hasher()
                for (name, ov) in e.boneOverrides {
                    let o = ov.current()
                    h.combine(name)
                    if let p = o.pos { h.combine(Int((p.x * 50).rounded())); h.combine(Int((p.y * 50).rounded())); h.combine(Int((p.z * 50).rounded())) }
                    if let r = o.rot { h.combine(Int((r.vector.x * 500).rounded())); h.combine(Int((r.vector.y * 500).rounded())); h.combine(Int((r.vector.z * 500).rounded())); h.combine(Int((r.vector.w * 500).rounded())) }
                    if let sc = o.scale { h.combine(Int((sc.x * 50).rounded())); h.combine(Int((sc.y * 50).rounded())); h.combine(Int((sc.z * 50).rounded())) }
                }
                bones = h.finalize()
            }
            if let c = skinCache[e.id], c.mesh == e.mesh, c.frame == frame, c.bones == bones {
                positions = c.positions
            } else {
                let ps0 = perf.now()
                let overrides = e.boneOverrides.isEmpty ? [:] : e.boneOverrides.mapValues { $0.current() }
                positions = mesh.skinnedPositions(frame: frame, overrides: overrides)
                skinCache[e.id] = (e.mesh, frame, bones, positions)
                perf.add("e.skin", ps0, perf.now())
                skinMisses += 1
            }
        } else {
            positions = mesh.positions
        }
        // The model hangs off the object ORIGIN (e.pos), not the collisionbox:
        // mob models put their feet at y=0 and the chest lid model spans the
        // node it lives in, so no anchoring is needed once the scale is right.
        // (e.pos is already in our grid: Client.gridShift moved it on the wire.)
        let rx = (e.pos.x - eye.x) * scale, ry = (e.pos.y - eye.y) * scale, rz = (e.pos.z - eye.z) * scale
        let op = SIMD3<Float>(rx * cosY - rz * sinY, ry, rx * sinY + rz * cosY)   // origin in origin space
        // Model orientation must turn with the world: positions go through
        // R(-playerYaw), so the model's own R(-e.yaw) composes to R(-(e.yaw + playerYaw)).
        // automatic_rotate spins the model at a constant rad/s (spawner dolls) (#231).
        let autoSpin = e.automaticRotate != 0
            ? e.automaticRotate * Float(frameUptime.truncatingRemainder(dividingBy: 3600))
            : 0
        let a = e.yaw + playerYaw + autoSpin
        let ca = cos(a), sa = sin(a)
        // Roll (rotation.z): a flying arrow's shaft (its long axis, +X in the
        // model) tips along its arc; vl_projectile writes the flight pitch into
        // rotation.z for exactly that reason (#305). Applied as a pre-rotation
        // in the model-local X-Y plane before yaw, so it is identity when 0 --
        // mobs (which never roll) are unchanged. Pitch (rotation.x) tilts in
        // the Y-Z plane (boats bobbing); both are zero for nearly everything.
        let roll = e.roll, pitch = e.pitch
        // Each surface emits its own copy of the vertices it uses so the texture
        // layer/uv can differ per surface (layer is a per-vertex attribute).
        if modelRemap.count < mesh.positions.count {
            modelRemap = [Int32](repeating: 0, count: mesh.positions.count)
            modelRemapSeen = [Int32](repeating: 0, count: mesh.positions.count)
        }
        for d in draw {
            let uv = d.uv
            modelRemapGen += 1; let gen = modelRemapGen
            let vb = UInt32(v.count / 9)
            var local: UInt32 = 0
            for i in d.surface.indices {
                let ik = Int(i)
                if modelRemapSeen[ik] != gen {
                    modelRemapSeen[ik] = gen; modelRemap[ik] = Int32(local); local += 1
                    let m = positions[ik]
                    let lp = WorldMesher.tiltLocal(WorldMesher.pitchLocal(m * ms, roll), pitch)
                    let lx = lp.x, ly = lp.y, lz = lp.z
                    let wx = lx * ca - lz * sa, wz = lx * sa + lz * ca
                    let t = mesh.uvs[ik]
                    // Element-wise appends: an array literal here allocated a
                    // throwaway [Float] per vertex, thousands/frame across mobs (#247).
                    v.append(op.x + wx * scale); v.append(op.y + ly * scale); v.append(-(op.z + wz * scale))
                    v.append(t.x * uv.x); v.append(t.y * uv.y); v.append(Float(d.layer))
                    v.append(1.0); v.append(light); v.append(tint)
                }
                idx.append(vb + UInt32(modelRemap[ik]))
            }
        }
        return true
    }

    /// A dropped item: two small crossed quads showing the item icon, in origin
    /// space (visible from any angle, no camera-facing needed). Icons are 16px
    /// in a 128px layer, so `uv` scales the 0..1 coords onto the sub-rect.
    private func appendItemQuads(pos: SIMD3<Float>, layer: Int, uv: SIMD2<Float>,
                                 eye: SIMD3<Float>, cosY: Float, sinY: Float, light: Float,
                                 size sz: Float = 0.18,
                                 v: inout [Float], idx: inout [UInt32]) {
        // A single camera-facing card (like Minecraft's dropped item), not crossed
        // quads: the X looked like a weird cross for node drops (#drop). Faces the
        // player horizontally, floats a little off the ground.
        let scale = PlayerState.scale
        let rx = (pos.x - eye.x) * scale, ry = (pos.y - eye.y) * scale, rz = (pos.z - eye.z) * scale
        let op = SIMD3<Float>(rx * cosY - rz * sinY, ry, -(rx * sinY + rz * cosY))   // Z mirrored like the world
        var dh = SIMD3<Float>(-op.x, 0, -op.z)                 // toward the camera (origin), horizontal
        let dl = (dh.x * dh.x + dh.z * dh.z).squareRoot()
        dh = dl > 1e-4 ? dh / dl : SIMD3(0, 0, -1)
        let right = SIMD3<Float>(dh.z, 0, -dh.x) * (sz * scale)
        let up = SIMD3<Float>(0, sz * 2 * scale, 0)
        let base = op - SIMD3(0, sz * scale, 0)                // centre the card on the item origin (e.pos)
        let corners = [base - right, base + right, base + right + up, base - right + up]
        let uvs = Self.quadUVsBL
        let vb = UInt32(v.count / 9)
        for k in 0..<4 {
            let p = corners[k]
            pushV(&v, p.x, p.y, p.z, uvs[k].0 * uv.x, uvs[k].1 * uv.y, Float(layer), 1.0, light, 16777215)
        }
        // Two-sided (cull .none in the model pass would show one side; add the twin
        // so it reads from behind too).
        pushQuad(&idx, vb)   // front winding
        idx.append(vb); idx.append(vb &+ 2); idx.append(vb &+ 1)   // + reversed twin
        idx.append(vb); idx.append(vb &+ 3); idx.append(vb &+ 2)
    }

    /// A dropped mesh-drawtype node (chest etc) drawn as its real b3d model, not
    /// a flat card. Matches appendModel's origin-space transform (op is NOT
    /// Z-mirrored, geometry rotates by R(-(spin+playerYaw))) so it stays
    /// world-locked as you turn, plus a gentle spin like a Minecraft drop.
    /// Textured with the node's single face-0 layer; model coords are node-local
    /// ~[-0.5,0.5], fit into a small drop cube (#191). Scale/height are a starting
    /// point to tune on device.
    /// A dropped cube node (dirt, stone, ...) drawn as a small 3D cube instead of
    /// a flat card, like a Minecraft dropped block. Same origin-space transform as
    /// Unit cube corners per face in the +Y,-Y,+X,-X,+Z,-Z order NodeRegistry
    /// uses; scaled by the half-extents at emit time. Hoisted so a dropped block
    /// or cube entity doesn't build seven arrays per tick (perf #311).
    private static let unitQuad: [SIMD2<Float>] = [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)]   // bl, br, tr, tl
    private static let unitCubeFaces: [[SIMD3<Float>]] = [
        [SIMD3(-1, 1, -1), SIMD3(-1, 1, 1), SIMD3(1, 1, 1), SIMD3(1, 1, -1)],       // +Y
        [SIMD3(-1, -1, 1), SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, -1, 1)],   // -Y
        [SIMD3(1, -1, 1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(1, 1, 1)],       // +X
        [SIMD3(-1, -1, -1), SIMD3(-1, -1, 1), SIMD3(-1, 1, 1), SIMD3(-1, 1, -1)],   // -X
        [SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1)],       // +Z
        [SIMD3(1, -1, -1), SIMD3(-1, -1, -1), SIMD3(-1, 1, -1), SIMD3(1, 1, -1)],   // -Z
    ]

    /// appendItemModel (world-locked + gentle spin); per-face node-atlas layers in
    /// the +Y,-Y,+X,-X,+Z,-Z order NodeRegistry uses (#191).
    private func appendItemCube(faceLayers: [Int], pos: SIMD3<Float>,
                                eye: SIMD3<Float>, cosY: Float, sinY: Float, playerYaw: Float,
                                light: Float, size sz: Float = 0.22, spin: Bool = true,
                                v: inout [Float], idx: inout [UInt32]) {
        guard faceLayers.count == 6 else { return }
        let scale = PlayerState.scale
        let h = sz * 0.5                                // default ~0.22-node dropped block
        let rx = (pos.x - eye.x) * scale, ry = (pos.y - eye.y) * scale, rz = (pos.z - eye.z) * scale
        let op = SIMD3<Float>(rx * cosY - rz * sinY, ry, rx * sinY + rz * cosY)
        // VoxeLibre item drops spin at automatic_rotate = pi/2 rad/s (90 deg/s);
        // falling nodes / frame items don't.
        let spinA = spin ? Float(frameUptime.truncatingRemainder(dividingBy: 1000)) * (Float.pi * 0.5) : 0
        let a = spinA + playerYaw
        let ca = cos(a), sa = sin(a)
        let uvs = Self.quadUVsBL
        let half = SIMD3<Float>(h, h, h)
        for fi in 0..<6 {
            let vb = UInt32(v.count / 9)
            let l = Float(faceLayers[fi])
            let f = Self.unitCubeFaces[fi]
            for k in 0..<4 {
                let c = f[k] * half
                // e.pos is the item's centre (symmetric collisionbox), so centre
                // the cube on op.y (no lift). Z is negated like every other world
                // emitter (appendModel/appendCrack) so the block stays pinned to
                // its world spot instead of mirroring across the player (#drop).
                let lx = c.x * scale, ly = c.y * scale, lz = c.z * scale
                let wx = lx * ca - lz * sa, wz = lx * sa + lz * ca
                pushV(&v, op.x + wx, op.y + ly, -(op.z + wz), uvs[k].0, uvs[k].1, l, 1.0, light, 16777215)
            }
            pushQuad(&idx, vb)
        }
    }

    /// The "cube" visual: a unit cube scaled by visual_size (per axis, so a
    /// painting at z = 1/32 is a slab), centred on the object origin, turned
    /// by yaw. Face order is createCubeMesh's: +Y, -Y, +X, -X, +Z, -Z, which
    /// is also the nodedef tile order. A face with layer < 0 is skipped.
    private func appendEntityCube(faces: [(layer: Int, uv: SIMD2<Float>)], size: SIMD3<Float>, pos: SIMD3<Float>,
                                  yaw: Float, eye: SIMD3<Float>, cosY: Float, sinY: Float,
                                  light: Float, tint: Float, v: inout [Float], idx: inout [UInt32]) {
        guard faces.count == 6 else { return }
        let scale = PlayerState.scale
        let hx = size.x * 0.5, hy = size.y * 0.5, hz = (size.z != 0 ? size.z : size.x) * 0.5
        let rx = (pos.x - eye.x) * scale, ry = (pos.y - eye.y) * scale, rz = (pos.z - eye.z) * scale
        let op = SIMD3<Float>(rx * cosY - rz * sinY, ry, rx * sinY + rz * cosY)
        let ca = cos(yaw), sa = sin(yaw)
        let uvs = Self.quadUVsBL
        let half = SIMD3<Float>(hx, hy, hz)
        for f in 0..<6 where faces[f].layer >= 0 {
            let vb = UInt32(v.count / 9)
            let l = Float(faces[f].layer), uv = faces[f].uv
            let fc = Self.unitCubeFaces[f]
            for k in 0..<4 {
                let c = fc[k] * half
                let lx = c.x * scale, ly = c.y * scale, lz = c.z * scale
                let wx = lx * ca - lz * sa, wz = lx * sa + lz * ca
                pushV(&v, op.x + wx, op.y + ly, -(op.z + wz), uvs[k].0 * uv.x, uvs[k].1 * uv.y, l, 1.0, light, tint)
            }
            pushQuad(&idx, vb)
        }
    }

    /// The "upright_sprite" visual: a visual_size.x by visual_size.y quad in
    /// the object's local XY plane, centred on the origin and turned by yaw
    /// (not camera-facing). textures[0] is the front; a second texture, when
    /// given, is a mirrored back quad. Entities draw without back-face
    /// culling, so one quad already shows from both sides when there is no
    /// distinct back texture.
    private func appendUprightSprite(faces: [(layer: Int, uv: SIMD2<Float>)], size: SIMD3<Float>, pos: SIMD3<Float>,
                                     yaw: Float, eye: SIMD3<Float>, cosY: Float, sinY: Float,
                                     light: Float, tint: Float, v: inout [Float], idx: inout [UInt32]) {
        let scale = PlayerState.scale
        let hx = size.x * 0.5, hy = size.y * 0.5
        let rx = (pos.x - eye.x) * scale, ry = (pos.y - eye.y) * scale, rz = (pos.z - eye.z) * scale
        let op = SIMD3<Float>(rx * cosY - rz * sinY, ry, rx * sinY + rz * cosY)
        let ca = cos(yaw), sa = sin(yaw)
        let uvs = Self.quadUVsBL
        // Front (face 0) and mirrored back (face 1): unit corners scaled by the
        // half-size, a hair apart in z so they don't z-fight (no per-call arrays).
        for face in 0..<2 where face < faces.count && faces[face].layer >= 0 {
            let vb = UInt32(v.count / 9)
            let l = Float(faces[face].layer), uv = faces[face].uv
            let sx: Float = face == 0 ? 1 : -1, zoff: Float = face == 0 ? -0.002 : 0.002
            for k in 0..<4 {
                let u = Self.unitQuad[k]
                let c = SIMD3<Float>(u.x * hx * sx, u.y * hy, 0)
                let lx = c.x * scale, ly = c.y * scale, lz = zoff * scale
                let wx = lx * ca - lz * sa, wz = lx * sa + lz * ca
                pushV(&v, op.x + wx, op.y + ly, -(op.z + wz), uvs[k].0 * uv.x, uvs[k].1 * uv.y, l, 1.0, light, tint)
            }
            pushQuad(&idx, vb)
        }
    }

    private func appendItemModel(_ m: B3DLoader.Mesh, pos: SIMD3<Float>, layer: Int,
                                 eye: SIMD3<Float>, cosY: Float, sinY: Float, playerYaw: Float,
                                 light: Float, size drop: Float = 0.4,
                                 v: inout [Float], idx: inout [UInt32]) {
        guard !m.positions.isEmpty else { return }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in m.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let ext = hi - lo
        let maxe = max(ext.x, max(ext.y, ext.z))
        guard maxe > 1e-4 else { return }
        let scale = PlayerState.scale                  // default: dropped items are ~0.4 node
        let fit = drop / maxe
        // Centre the model on the item origin in all three axes: e.pos is the
        // item's centre (symmetric collisionbox), so no hover-lift.
        let cx = (lo.x + hi.x) * 0.5, cy = (lo.y + hi.y) * 0.5, cz = (lo.z + hi.z) * 0.5
        let rx = (pos.x - eye.x) * scale, ry = (pos.y - eye.y) * scale, rz = (pos.z - eye.z) * scale
        let op = SIMD3<Float>(rx * cosY - rz * sinY, ry, rx * sinY + rz * cosY)   // centre in origin space
        let spin = Float(frameUptime.truncatingRemainder(dividingBy: 1000)) * (Float.pi * 0.5)
        let a = spin + playerYaw
        let ca = cos(a), sa = sin(a)
        let vb = UInt32(v.count / 9)
        let l = Float(layer)
        for k in 0..<m.positions.count {
            let mp = m.positions[k]
            let lx = (mp.x - cx) * fit, ly = (mp.y - cy) * fit, lz = (mp.z - cz) * fit
            let wx = lx * ca - lz * sa, wz = lx * sa + lz * ca
            let t = m.uvs[k]
            // Z negated like the world (appendModel), so the drop stays world-pinned.
            pushV(&v, op.x + wx, op.y + ly, -(op.z + wz), t.x, t.y, l, 1.0, light, 16777215)
        }
        for i in m.indices { idx.append(vb + i) }
    }

    // Cube faces (CCW, outward normal) in node-local 0..1, matching the world
    // mesher so the crack sits flush on the block. u,v per corner below.
    private static let crackFaces: [(n: SIMD3<Float>, c: [SIMD3<Float>])] = [
        (SIMD3(0, 1, 0),  [SIMD3(0,1,0), SIMD3(0,1,1), SIMD3(1,1,1), SIMD3(1,1,0)]),
        (SIMD3(0,-1, 0),  [SIMD3(0,0,1), SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(1,0,1)]),
        (SIMD3(0, 0, 1),  [SIMD3(0,0,1), SIMD3(1,0,1), SIMD3(1,1,1), SIMD3(0,1,1)]),
        (SIMD3(0, 0,-1),  [SIMD3(1,0,0), SIMD3(0,0,0), SIMD3(0,1,0), SIMD3(1,1,0)]),
        (SIMD3(1, 0, 0),  [SIMD3(1,0,1), SIMD3(1,0,0), SIMD3(1,1,0), SIMD3(1,1,1)]),
        (SIMD3(-1,0, 0),  [SIMD3(0,0,0), SIMD3(0,0,1), SIMD3(0,1,1), SIMD3(0,1,0)]),
    ]
    private static let crackUV: [(Float, Float)] = [(0,1), (1,1), (1,0), (0,0)]

    /// Draw the crack strip's current frame over all 6 faces of the node being
    /// dug, in origin space (matching appendModel), nudged out along each normal
    /// so it sits just proud of the block instead of z-fighting it.
    /// Rasterise a short white string centred in a transparent square via
    /// CoreText, for the death overlay (no glyph atlas needed for one label).
    /// Bake an SF Symbol (white, black outline like the text) into an RGBA
    /// canvas for a key/button label; nil if UIKit can't produce the glyph.
    static func renderSymbolRGBA(_ name: String, canvas: Int) -> [UInt8]? {
        #if canImport(UIKit)
        let cfg = UIImage.SymbolConfiguration(pointSize: CGFloat(canvas) * 0.5, weight: .bold)
        guard let img = UIImage(systemName: name, withConfiguration: cfg) else { return nil }
        // A tinted symbol's raw cgImage is still the untinted template, so
        // draw through UIKit (which honours the tint), then copy that bitmap
        // into the same CG layout the text baker uses.
        let side = CGFloat(canvas) * 0.62
        let rect = CGRect(x: (CGFloat(canvas) - side) / 2, y: (CGFloat(canvas) - side) / 2, width: side, height: side)
        let o = max(1.0, CGFloat(canvas) * 0.012)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = false
        let ui = UIGraphicsImageRenderer(size: CGSize(width: canvas, height: canvas), format: fmt).image { _ in
            for dx in [-o, 0, o] { for dy in [-o, 0, o] where !(dx == 0 && dy == 0) {
                img.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: rect.offsetBy(dx: dx, dy: dy))
            } }
            img.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: rect)
        }
        guard let cg = ui.cgImage else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                                  bytesPerRow: canvas * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
        guard let base = ctx.data else { return nil }
        var px = [UInt8](repeating: 0, count: canvas * canvas * 4)
        memcpy(&px, base, px.count)
        return px
        #else
        return nil
        #endif
    }

    static func renderTextRGBA(_ text: String, canvas: Int, fontFrac: CGFloat = 0.20) -> [UInt8]? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                                  bytesPerRow: canvas * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
        var size = CGFloat(canvas) * fontFrac
        func makeLine(_ sz: CGFloat) -> (CTLine, CGRect) {
            let f = CTFontCreateWithName("Helvetica-Bold" as CFString, sz, nil)
            let l = CTLineCreateWithAttributedString(NSAttributedString(string: text,
                attributes: [.font: f, .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1)]))
            return (l, CTLineGetImageBounds(l, ctx))
        }
        var (line, b) = makeLine(size)
        // Shrink to fit the canvas width so a long label isn't clipped.
        let maxW = CGFloat(canvas) * 0.9
        if b.width > maxW, b.width > 0 { size *= maxW / b.width; (line, b) = makeLine(size) }
        let px0 = (CGFloat(canvas) - b.width) / 2 - b.minX
        let py0 = (CGFloat(canvas) - b.height) / 2 - b.minY
        // Black outline (8 offsets) then white fill, so text reads on any colour.
        let o = max(1.0, CGFloat(canvas) * 0.012)
        let black = CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: [.font: CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil),
                         .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)]))
        for dx in [-o, 0, o] { for dy in [-o, 0, o] where !(dx == 0 && dy == 0) {
            ctx.textPosition = CGPoint(x: px0 + dx, y: py0 + dy); CTLineDraw(black, ctx)
        } }
        ctx.textPosition = CGPoint(x: px0, y: py0)
        CTLineDraw(line, ctx)
        guard let base = ctx.data else { return nil }
        var px = [UInt8](repeating: 0, count: canvas * canvas * 4)
        px.withUnsafeMutableBytes { _ = memcpy($0.baseAddress, base, canvas * canvas * 4) }
        return px
    }

    /// Server HUD text (wield name, titles, death/join banners) rendered at a
    /// CONSTANT glyph height. renderTextRGBA shrinks long lines to fit a square
    /// canvas, so a long subtitle came out tiny next to a short title. Here the
    /// text is stretched to fill the square (max resolution) and the caller
    /// un-stretches it by drawing the quad at the returned aspect (width/height),
    /// so glyphs are the same size no matter the line length. Returns nil if the
    /// text is empty/unrenderable.
    static func renderTextFilled(_ text: String, canvas: Int) -> (px: [UInt8], aspect: Float)? {
        guard !text.isEmpty else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                                  bytesPerRow: canvas * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
        // Measure at a reference size, then scale x/y independently to fill the
        // canvas (leaving a small margin so the outline isn't clipped).
        let ref: CGFloat = 64
        func line(_ color: CGColor) -> CTLine {
            let f = CTFontCreateWithName("Helvetica-Bold" as CFString, ref, nil)
            return CTLineCreateWithAttributedString(NSAttributedString(string: text,
                attributes: [.font: f, .foregroundColor: color]))
        }
        let white = line(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let b = CTLineGetImageBounds(white, ctx)
        guard b.width > 1, b.height > 1 else { return nil }
        let aspect = Float(b.width / b.height)
        let margin = CGFloat(canvas) * 0.08
        let sx = (CGFloat(canvas) - 2 * margin) / b.width
        let sy = (CGFloat(canvas) - 2 * margin) / b.height
        let black = line(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        let o = max(1.0, ref * 0.05)
        func draw(_ l: CTLine, _ dx: CGFloat, _ dy: CGFloat) {
            ctx.saveGState()
            ctx.scaleBy(x: sx, y: sy)
            // Position the (scaled) text so its bounds sit inside the margin.
            ctx.textPosition = CGPoint(x: (margin) / sx - b.minX + dx, y: (margin) / sy - b.minY + dy)
            CTLineDraw(l, ctx)
            ctx.restoreGState()
        }
        for dx in [-o, 0, o] { for dy in [-o, 0, o] where !(dx == 0 && dy == 0) { draw(black, dx, dy) } }
        draw(white, 0, 0)
        guard let base = ctx.data else { return nil }
        var px = [UInt8](repeating: 0, count: canvas * canvas * 4)
        px.withUnsafeMutableBytes { _ = memcpy($0.baseAddress, base, canvas * canvas * 4) }
        return (px, aspect)
    }

    /// Server HUD text elements (hud.cpp drawText): one row per '\n', each row
    /// sized by the font's line metrics rather than its own ink, so "one" and
    /// "Speed" come out at the same glyph size (ink-bound sizing scaled an
    /// all-lowercase string up to the full height). Rows are centred in the
    /// block. Returns the block aspect (width/height), the row count, and
    /// lineToCap = line height / cap height, so a caller that sizes text by cap
    /// height can scale the quad to keep capitals where they were.
    static func renderTextBlock(_ text: String, canvas: Int) -> (px: [UInt8], aspect: Float, lines: Int, lineToCap: Float)? {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(16).map { String($0.prefix(80)) }
        guard rows.contains(where: { !$0.isEmpty }) else { return nil }
        let ref: CGFloat = 64
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, ref, nil)
        let asc = CTFontGetAscent(font), desc = CTFontGetDescent(font)
        let lineH = asc + desc, capH = max(1, CTFontGetCapHeight(font))
        func line(_ s: String, _ c: CGColor) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c]))
        }
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1), black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        let widths = rows.map { CGFloat(CTLineGetTypographicBounds(line($0, white), nil, nil, nil)) }
        let w = max(1, widths.max() ?? 1), h = lineH * CGFloat(rows.count)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                                  bytesPerRow: canvas * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
        let margin = CGFloat(canvas) * 0.06
        let sx = (CGFloat(canvas) - 2 * margin) / w, sy = (CGFloat(canvas) - 2 * margin) / h
        let o = max(1.0, ref * 0.05)
        for (i, row) in rows.enumerated() where !row.isEmpty {
            let x = (w - widths[i]) / 2, y = h - CGFloat(i + 1) * lineH + desc   // CG origin is bottom-left
            for (c, offs) in [(black, [(-o, -o), (-o, 0), (-o, o), (0, -o), (0, o), (o, -o), (o, 0), (o, o)]), (white, [(0, 0)])] {
                let l = line(row, c)
                for (dx, dy) in offs {
                    ctx.saveGState(); ctx.scaleBy(x: sx, y: sy)
                    ctx.textPosition = CGPoint(x: margin / sx + x + dx, y: margin / sy + y + dy)
                    CTLineDraw(l, ctx); ctx.restoreGState()
                }
            }
        }
        guard let base = ctx.data else { return nil }
        var px = [UInt8](repeating: 0, count: canvas * canvas * 4)
        px.withUnsafeMutableBytes { _ = memcpy($0.baseAddress, base, canvas * canvas * 4) }
        return (px, Float(w / h), rows.count, Float(lineH / capH))
    }

    /// Word-wrapped multi-line text at a CONSTANT glyph height, for chat (#157):
    /// a single long line rendered to fit the band width came out tiny, so wrap
    /// it to `cols`-ish characters per line instead. Like renderTextFilled, the
    /// wrapped block is stretched to fill the square canvas and the caller
    /// un-stretches via the returned aspect (block width/height); `lines` lets
    /// the caller size the quad height by line count so glyphs stay uniform.
    static func renderWrappedFilled(_ text: String, canvas: Int, cols: Int) -> (px: [UInt8], aspect: Float, lines: Int)? {
        guard !text.isEmpty else { return nil }
        let ref: CGFloat = 48
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, ref, nil)
        // CoreText paragraph style (no UIKit): centre + word-wrap.
        var align = CTTextAlignment.center
        var brk = CTLineBreakMode.byWordWrapping
        let para: CTParagraphStyle = withUnsafeMutablePointer(to: &align) { ap in
            withUnsafeMutablePointer(to: &brk) { bp in
                var settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: ap),
                    CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size, value: bp),
                ]
                return CTParagraphStyleCreate(&settings, settings.count)
            }
        }
        let paraKey = kCTParagraphStyleAttributeName as NSAttributedString.Key
        func attr(_ color: CGColor) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, paraKey: para])
        }
        // Wrap to a width of ~cols average characters, then measure the block.
        let wrapW = CGFloat(cols) * ref * 0.55
        let fsW = CTFramesetterCreateWithAttributedString(attr(CGColor(red: 1, green: 1, blue: 1, alpha: 1)))
        let full = CFRange(location: 0, length: (text as NSString).length)
        let sz = CTFramesetterSuggestFrameSizeWithConstraints(fsW, full, nil,
                    CGSize(width: wrapW, height: .greatestFiniteMagnitude), nil)
        guard sz.width > 1, sz.height > 1 else { return nil }
        let lineH = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        let lineCount = max(1, Int((sz.height / lineH).rounded()))
        let aspect = Float(sz.width / sz.height)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                                  bytesPerRow: canvas * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
        let margin = CGFloat(canvas) * 0.06
        let sx = (CGFloat(canvas) - 2 * margin) / sz.width
        let sy = (CGFloat(canvas) - 2 * margin) / sz.height
        let o = max(1.0, ref * 0.05)
        func drawFrame(_ color: CGColor, _ dx: CGFloat, _ dy: CGFloat) {
            let fs = CTFramesetterCreateWithAttributedString(attr(color))
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: sz.width, height: sz.height), transform: nil)
            let frame = CTFramesetterCreateFrame(fs, full, path, nil)
            ctx.saveGState()
            ctx.scaleBy(x: sx, y: sy)
            ctx.translateBy(x: margin / sx + dx, y: margin / sy + dy)
            CTFrameDraw(frame, ctx)
            ctx.restoreGState()
        }
        for dx in [-o, 0, o] { for dy in [-o, 0, o] where !(dx == 0 && dy == 0) {
            drawFrame(CGColor(red: 0, green: 0, blue: 0, alpha: 1), dx, dy)
        } }
        drawFrame(CGColor(red: 1, green: 1, blue: 1, alpha: 1), 0, 0)
        guard let base = ctx.data else { return nil }
        var px = [UInt8](repeating: 0, count: canvas * canvas * 4)
        px.withUnsafeMutableBytes { _ = memcpy($0.baseAddress, base, canvas * canvas * 4) }
        return (px, aspect, lineCount)
    }

    /// A head-locked, camera-facing quad centred in the view, in origin space
    /// (metres) so it rides the model stream like the crack overlay. gaze is the
    /// world aim; rotate it into origin space by -yaw (cosY/sinY).
    private func appendDeathText(layer: Int, gaze: SIMD3<Float>, cosY: Float, sinY: Float,
                                 v: inout [Float], idx: inout [UInt32]) {
        // Head-locked: place the overlay as head * (forward*dist), centred and
        // upright in the view regardless of head pitch/roll (gaze/cosY/sinY
        // unused now that we use the real head frame).
        let hx = frameHeadXform
        let headPos = SIMD3<Float>(hx.columns.3.x, hx.columns.3.y, hx.columns.3.z)
        let right = simd_normalize(SIMD3<Float>(hx.columns.0.x, hx.columns.0.y, hx.columns.0.z))
        let up = simd_normalize(SIMD3<Float>(hx.columns.1.x, hx.columns.1.y, hx.columns.1.z))
        let fwd = -simd_normalize(SIMD3<Float>(hx.columns.2.x, hx.columns.2.y, hx.columns.2.z))
        let dist: Float = 0.7, hw: Float = 0.22, hh: Float = 0.22   // close so it clears nearby blocks
        let c = headPos + fwd * dist
        let corners = [c - right*hw + up*hh, c + right*hw + up*hh, c + right*hw - up*hh, c - right*hw - up*hh]
        let uvs = Self.quadUVsTL
        let vb = UInt32(v.count / 9)
        for k in 0..<4 {
            let p = corners[k]
            pushV(&v, p.x, p.y, p.z, uvs[k].0, uvs[k].1, Float(layer), 1.0, 255, 16777215)
        }
        pushQuad(&idx, vb)
    }

    /// Open the on-screen keyboard, prefilled, calling `done(text)` on Done.
    private func openKeyboard(prefill: String, saveOnDismiss: Bool = false, simple: Bool = false, done: @escaping (String) -> Void) {
        keyboardBuffer = prefill; keyboardDone = done; kbSaveOnDismiss = saveOnDismiss; kbHover = nil; kbCursor = nil
        kbSimple = simple
        // Force the text layer to re-rasterise to the fresh (usually empty) buffer:
        // it only redraws when dirty, so without this a reopened bug note kept
        // SHOWING the previous note's text even though keyboardBuffer was "" (Eric,
        // "still shows previous dictation"). The submit was already correct; only
        // the on-screen field lagged. (#332)
        kbBufferDirty = true
        // Start with a clean dictation slate: a previous note's transcript (or a
        // final result that landed just after it closed) was carrying over into
        // the next note's field (Eric). Stop any lingering recognizer, drop the
        // pending transcript, and reset the prefix to the fresh buffer.
        stopDictation()
        dictationPrefix = prefill; dictationCommitted = ""
        dictationLock.lock(); dictationInbox = nil; dictationLock.unlock()
        layoutKeyboard()
        let eye = player.rayOrigin()
        // Center on where the player is FACING (body/head forward), not the
        // controller aim: opening from the Kogane menu leaves the controller
        // pointed off to the side, which used to shove the board into a corner.
        var f = player.bodyForward(); f.y = 0
        let l = simd_length(f); f = l > 1e-3 ? f / l : SIMD3(0, 0, -1)
        let right = SIMD3<Float>(f.z, 0, -f.x)
        keyboardFrame = InvFrame(center: eye + f * 0.95 - SIMD3(0, 0.05, 0), right: right, up: SIMD3(0, 1, 0), fwd: f)
        keyboardOpen = true
        // The trigger/button that just picked "Bug note"/"Chat" in the Kogane menu
        // is still held this frame; seed the edge-trackers as pressed so the
        // keyboard doesn't read that same hold as a key click or a cancel and
        // slam shut immediately (#238: it opened and closed in one frame).
        kbPrevDig = true; kbPrevCancel = true
        print("[kbd] open"); fflush(stdout)
    }

    private func closeKeyboard() { stopDictation(); keyboardOpen = false; keyboardFrame = nil; keyboardDone = nil; kbCursor = nil; print("[kbd] closed"); fflush(stdout) }
    /// Done / save-on-dismiss: hand the text to the opener's completion. The
    /// completion has to be captured BEFORE closeKeyboard() nils it; the old
    /// `closeKeyboard(); keyboardDone?(t)` ordering meant every keyboard result
    /// (bug notes, sign text, chat) was silently dropped on device.
    private func submitKeyboard() {
        stopDictation()
        let t = keyboardBuffer, done = keyboardDone
        closeKeyboard()
        print("[kbd] submit \(t.count) chars"); fflush(stdout)
        done?(t)
    }

    private func layoutKeyboard() {
        if kbSimple {
            // Three fat targets under the transcript field: mic (toggle
            // dictation), clear, submit. Sized so the controller ray lands on
            // them without hunting.
            let y: Float = -0.06
            keyboardKeys = [Key(id: "mic",    u: -0.28, v: y, hw: 0.11, hh: 0.075),
                            Key(id: "clear",  u: 0,     v: y, hw: 0.11, hh: 0.075),
                            Key(id: "submit", u: 0.28,  v: y, hw: 0.11, hh: 0.075)]
            return
        }
        let rows = ["1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm/,."]
        let p: Float = 0.08   // key pitch (was 0.05: too small to read/aim in VR)
        var keys: [Key] = []
        for (r, row) in rows.enumerated() {
            let chars = Array(row)
            for (c, ch) in chars.enumerated() {
                let u = (Float(c) - Float(chars.count - 1) / 2) * p
                keys.append(Key(id: String(ch), u: u, v: (1.5 - Float(r)) * p, hw: p * 0.45))
            }
        }
        // bottom row: mic (dictation), space (wide), backspace, done
        let by = (1.5 - 4) * p
        keys.append(Key(id: "mic",   u: -3.6 * p, v: by, hw: p * 0.9))
        keys.append(Key(id: "space", u: -1.5 * p, v: by, hw: p * 1.5))
        keys.append(Key(id: "back",  u: 0.9 * p,  v: by, hw: p * 0.9))
        keys.append(Key(id: "done",  u: 2.6 * p,  v: by, hw: p * 0.9))
        keyboardKeys = keys
    }

    private func handleKeyboardInput(_ gi: GameInput.State) {
        guard let fr = keyboardFrame else { return }
        // Fold in any speech transcript that landed since last tick (dictation
        // callbacks run on the main queue). Live text is prefix + transcript.
        dictationLock.lock(); let heard = dictationInbox; dictationInbox = nil; dictationLock.unlock()
        // Only fold the transcript while actively dictating. A result that lands
        // after the user stopped (tapped a key, submitted, reopened the board)
        // must not clobber the field -- that was the carry-over between notes.
        if dictating, let heard {
            // The callback already assembled prefix + banked segments + the live
            // partial, so saying "period" (which finalizes a segment) can't wipe
            // what came before it.
            keyboardBuffer = heard
            kbBufferDirty = true
        }
        let (o, d) = inventoryRay()
        let n = fr.fwd
        kbHover = nil; kbCursor = nil
        let denom = simd_dot(d, n)
        if abs(denom) > 1e-4 {
            let t = simd_dot(fr.center - o, n) / denom
            if t > 0 && t < 3 {
                let hit = o + d * t
                let rel = hit - fr.center
                let u = simd_dot(rel, fr.right), v = simd_dot(rel, fr.up)
                // Targeting dot anywhere on the board, like the inventory panel.
                if abs(u) <= 0.5 && abs(v) <= 0.4 { kbCursor = hit }
                kbHover = keyboardKeys.firstIndex { abs($0.u - u) <= $0.hw && abs($0.v - v) <= $0.hh + 0.002 }
            }
        }
        let press = gi.dig && !kbPrevDig
        kbPrevDig = gi.dig
        // Right O / left grip cancels without submitting -- but only on a FRESH
        // press: edge-detect it so the menu/inventory button still held from
        // opening the keyboard doesn't cancel it on frame one (#238).
        let cancelHeld = gi.inventory || gi.menu
        let cancel = cancelHeld && !kbPrevCancel
        kbPrevCancel = cancelHeld
        if cancel {
            // Bug note: dismissing SAVES it (Eric: closing should submit, not
            // discard). Other keyboards (chat, sign, form fields) discard on
            // cancel as usual. Skip an empty note.
            if kbSaveOnDismiss, !keyboardBuffer.isEmpty { submitKeyboard(); return }
            closeKeyboard(); return
        }
        guard press, let hi = kbHover else { return }
        switch keyboardKeys[hi].id {
        case "mic": toggleDictation()
        case "done", "submit": submitKeyboard()
        case "clear": stopDictation(); keyboardBuffer = ""; dictationPrefix = ""; dictationCommitted = ""; kbBufferDirty = true
        // A manual edit ends dictation so the live transcript stops overwriting it.
        case "back": stopDictation(); if !keyboardBuffer.isEmpty { keyboardBuffer.removeLast(); kbBufferDirty = true }
        case "space": stopDictation(); keyboardBuffer.append(" "); kbBufferDirty = true
        default: stopDictation(); keyboardBuffer.append(keyboardKeys[hi].id); kbBufferDirty = true
        }
    }

    /// Toggle voice dictation. Start: remember the current text as the prefix,
    /// then stream the transcript after it. Stop: keep whatever was heard.
    private func toggleDictation() {
        if dictating { stopDictation(); return }
        dictationPrefix = keyboardBuffer; dictationCommitted = ""
        dictation.onTranscript = { [weak self] text, isFinal in
            guard let self else { return }
            // Assemble the field from three parts: what was typed before dictation,
            // every segment the recognizer has already finalized this session, and
            // the current live partial. When a segment finalizes (a pause, or a
            // punctuation word like "period"), bank it into `committed` so the next
            // segment starts fresh without erasing it. (These run on the main queue.)
            func join(_ a: String, _ b: String) -> String {
                a.isEmpty ? b : (b.isEmpty ? a : a + " " + b)
            }
            if isFinal { self.dictationCommitted = join(self.dictationCommitted, text) }
            let live = join(join(self.dictationPrefix, self.dictationCommitted), isFinal ? "" : text)
            self.dictationLock.lock(); self.dictationInbox = live; self.dictationLock.unlock()
        }
        dictation.onStop = { [weak self] err in
            self?.dictating = false
            if let err { print("[kbd] dictation stopped: \(err)"); fflush(stdout) }
        }
        dictating = true   // optimistic so the key lights immediately
        dictation.start { [weak self] ok, reason in
            guard let self else { return }
            if !ok { self.dictating = false; print("[kbd] dictation failed: \(reason ?? "?")"); fflush(stdout) }
            else { print("[kbd] dictation started"); fflush(stdout) }
        }
    }

    private func stopDictation() {
        guard dictating else { return }
        dictating = false
        dictation.stop()
    }

    /// Draw the keyboard: backdrop, the current text, and every key (label +
    /// hover highlight), head-anchored in its frame.
    private func appendKeyboard(eye: SIMD3<Float>, cosY: Float, sinY: Float, v: inout [Float], idx: inout [UInt32]) {
        guard keyboardOpen, let fr = keyboardFrame, highlightLayer >= 0 else { return }
        // The overlay buffer is ORIGIN space (eye at 0, yaw-rotated, Z-mirrored),
        // like the inventory panel. keyboardFrame is in node/world space, so every
        // point must be transformed or the board lands offset by the whole eye
        // position and never shows (#253). Same toOrigin/toOriginDir as the panel.
        let scale = PlayerState.scale
        func toOrigin(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let rx = (p.x - eye.x) * scale, ry = (p.y - eye.y) * scale, rz = (p.z - eye.z) * scale
            return SIMD3(rx * cosY - rz * sinY, ry, -(rx * sinY + rz * cosY))
        }
        func toOriginDir(_ d: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(d.x * cosY - d.z * sinY, d.y, -(d.x * sinY + d.z * cosY))
        }
        func at(_ u: Float, _ vv: Float) -> SIMD3<Float> { toOrigin(fr.center + fr.right * u + fr.up * vv) }
        let oR = toOriginDir(fr.right), oU = toOriginDir(fr.up)
        // backdrop (shorter for the simple board: one text row + one button row)
        let fieldV: Float = kbSimple ? 0.10 : 0.27
        if kbSimple {
            appendQuad(center: at(0, 0.02), right: oR, up: oU, hw: 0.46, hh: 0.19,
                       layer: highlightLayer, tint: Self.packTint(28, 30, 42), v: &v, idx: &idx)
        } else {
            appendQuad(center: at(0, 0.04), right: oR, up: oU, hw: 0.46, hh: 0.32,
                       layer: highlightLayer, tint: Self.packTint(28, 30, 42), v: &v, idx: &idx)
        }
        // Output field. The text used to be rendered square (renderTextRGBA)
        // and stretched onto a 6:1 quad, so glyphs were distorted and a long
        // dictated sentence shrank to a smear (Eric). Now: renderTextFilled
        // fills the canvas and reports the text's aspect, the quad is sized to
        // that aspect at a fixed readable height (no distortion), left-aligned
        // in the field, and when the text is wider than the field it shows the
        // TAIL so the words you just said are the ones you can read.
        // Rebake into the SAME layer: setting the index to a sentinel here used to
        // register a fresh "#kbbuf" layer per keystroke / dictation partial, which
        // grew the array and made ensureModelTextures re-upload every layer
        // (~75 MB per key with a busy inventory) besides leaking the old slice.
        if kbBufferLayer == -1 || kbBufferDirty {
            kbBufferDirty = false
            let fieldHH: Float = 0.042, fieldHW: Float = 0.42
            var shown = keyboardBuffer.isEmpty ? " " : keyboardBuffer
            // Drop leading characters until the rendered width fits the field.
            // Helvetica-Bold averages ~0.55 em per glyph, so width ~= chars*0.55
            // * height; solve for the char budget rather than re-render in a loop.
            let budget = max(4, Int((fieldHW / fieldHH) / 0.5))
            if shown.count > budget { shown = "\u{2026}" + String(shown.suffix(budget - 1)) }
            let r = Self.renderTextFilled(shown, canvas: ModelTextureHandoff.size)
            let px = r?.px ?? [UInt8](repeating: 0, count: ModelTextureHandoff.size * ModelTextureHandoff.size * 4)
            kbBufferAspect = r?.aspect ?? 1
            if kbBufferLayer >= 0 { updateModelLayer(kbBufferLayer, px) }
            else { kbBufferLayer = registerRGBALayer("#kbbuf", px) }
        }
        do {
            let fieldHH: Float = 0.042, fieldHW: Float = 0.42
            let hw = min(fieldHW, fieldHH * kbBufferAspect)
            // left-align: the quad's left edge sits at the field's left edge
            appendQuad(center: at(-fieldHW + hw, fieldV), right: oR, up: oU, hw: hw, hh: fieldHH,
                       layer: kbBufferLayer, tint: 16777215, v: &v, idx: &idx)
        }
        // keys
        for (i, k) in keyboardKeys.enumerated() {
            let hovered = kbHover == i
            // Mic key glows red while dictating so it reads as "recording".
            let cellTint: Float
            if k.id == "mic" && dictating { cellTint = Self.packTint(220, 60, 60) }
            else if hovered { cellTint = Self.packTint(232, 184, 64) }
            else { cellTint = Self.packTint(96, 98, 118) }
            appendQuad(center: at(k.u, k.v), right: oR, up: oU, hw: k.hw, hh: k.hh,
                       layer: highlightLayer, tint: cellTint, v: &v, idx: &idx)
            if keyLabelLayers[k.id] == nil {
                // The mic is an SF Symbol (a real microphone glyph), the rest text.
                let px: [UInt8]?
                if k.id == "mic" { px = Self.renderSymbolRGBA("mic.fill", canvas: ModelTextureHandoff.size) }
                else {
                    let label = k.id == "space" ? "space" : (k.id == "back" ? "<-" : (k.id == "done" ? "done" : (k.id == "clear" ? "Clear" : (k.id == "submit" ? "Submit" : k.id))))
                    px = Self.renderTextRGBA(label, canvas: ModelTextureHandoff.size, fontFrac: 0.46)
                }
                if let px { keyLabelLayers[k.id] = registerRGBALayer("#key_\(k.id)", px) }
            }
            if let layer = keyLabelLayers[k.id] {
                let lh = min(k.hh + 0.006, 0.06)
                appendQuad(center: at(k.u, k.v), right: oR, up: oU, hw: min(k.hw, kbSimple ? 0.09 : 0.058), hh: kbSimple ? lh : 0.04,
                           layer: layer, tint: hovered ? 0 : 16777215, v: &v, idx: &idx)
            }
        }
        // Targeting dot where the controller ray meets the board, drawn last so
        // it sits over the keys (same cue as the inventory cursor, Eric).
        if let cur = kbCursor {
            appendQuad(center: toOrigin(cur), right: oR, up: oU, hw: 0.007, hh: 0.007,
                       layer: highlightLayer, tint: 16777215, v: &v, idx: &idx)
        }
    }

    /// Record a chat line into the ring, baking its text into a reused model
    /// layer (so N messages never grow the texture array). sender empty = a
    /// system/announce line (shown as-is).
    /// Clear the visible chat lines (right stick click): the join/MOTD text can
    /// be dismissed at will instead of waiting out its ~9s life.
    private func dismissChat() {
        for i in chatRing.indices { chatRing[i].born = -1e9 }
    }

    private func addChat(sender: String, text: String) {
        let line = sender.isEmpty ? text : "\(sender): \(text)"
        if chatLayers.count < Self.chatSlots {   // allocate the ring once, lazily
            for i in chatLayers.count..<Self.chatSlots {
                let px = Self.renderTextRGBA(" ", canvas: ModelTextureHandoff.size, fontFrac: 0.14) ?? [UInt8](repeating: 0, count: ModelTextureHandoff.size * ModelTextureHandoff.size * 4)
                chatLayers.append(registerRGBALayer("#chat\(i)", px))
            }
            chatRing = Array(repeating: ("", -1e9, 1, 1), count: Self.chatSlots)
        }
        let slot = chatNext % Self.chatSlots
        chatNext += 1
        // Render wrapped at a CONSTANT glyph height (#157): the old square-canvas
        // renderer shrank a long line to fit, so it came out microscopic next to
        // a short one. renderWrappedFilled word-wraps to ~28 cols and returns the
        // block aspect + line count; appendChat sizes the quad from those so all
        // chat text is the same height and long lines just take more rows.
        var aspect: Float = 1, lines = 1
        if let r = Self.renderWrappedFilled(String(line.prefix(120)), canvas: ModelTextureHandoff.size, cols: 28) {
            updateModelLayer(chatLayers[slot], r.px)
            aspect = r.aspect; lines = r.lines
        }
        chatRing[slot] = (line, chatClock, aspect, lines)
        print("[chat] \(line)"); fflush(stdout)
    }

    /// Head-locked connection banner for a mid-session drop (launcher already
    /// gone). Draws only while connProblem is set; a red backdrop + white text
    /// centred just below the gaze so a reconnect/disconnect never reads as a
    /// silent frozen world.
    private func appendStatusBanner(v: inout [Float], idx: inout [UInt32]) {
        // Crisp filled renderer, not renderTextRGBA at a small fontFrac -- the
        // load/connect banner was the last blurry text path (#175).
        if noticeText != nil, noticeExpiry > 0, ProcessInfo.processInfo.systemUptime > noticeExpiry {
            noticeText = nil; noticeExpiry = 0
        }
        guard let msg = connProblem ?? noticeText ?? (terrainLoading ? "Loading terrain\u{2026}" : nil),
              highlightLayer >= 0,
              let t = formspecLabelLayer(String(msg.prefix(48))) else { return }
        let hx = frameHeadXform
        let headPos = SIMD3<Float>(hx.columns.3.x, hx.columns.3.y, hx.columns.3.z)
        let hr = simd_normalize(SIMD3<Float>(hx.columns.0.x, hx.columns.0.y, hx.columns.0.z))
        let hu = simd_normalize(SIMD3<Float>(hx.columns.1.x, hx.columns.1.y, hx.columns.1.z))
        let hf = -simd_normalize(SIMD3<Float>(hx.columns.2.x, hx.columns.2.y, hx.columns.2.z))
        // Well up in the UPPER visual field and pushed back so it doesn't sit over
        // the action (Eric: the "Bug note saved" banner was still too prominent).
        let center = headPos + hf * 1.5 + hu * 0.30
        // Backdrop is a short band; the text quad is SQUARE so the square text
        // canvas isn't squashed vertically (that made it a thin unreadable line).
        // The canvas margins are transparent, so only the centred text band shows.
        appendQuad(center: center, right: hr, up: hu, hw: 0.23, hh: 0.06,
                   layer: highlightLayer, tint: Self.packTint(140, 24, 24), v: &v, idx: &idx)
        // Constant glyph height, width from the text aspect (filled renderer),
        // capped to the band so a long notice stays inside the backdrop.
        let bh: Float = 0.075, bw = min(0.44, bh * max(0.4, t.aspect))
        appendQuad(center: center + hf * 0.001, right: hr, up: hu, hw: bw * 0.5, hh: bh * 0.5,
                   layer: t.layer, tint: 16777215, v: &v, idx: &idx)
    }

    /// Draw the recent, non-expired chat lines head-locked in the lower-left,
    /// stacked upward and fading over their last second.
    private func appendChat(v: inout [Float], idx: inout [UInt32]) {
        guard !chatLayers.isEmpty else { return }
        let hx = frameHeadXform
        let headPos = SIMD3<Float>(hx.columns.3.x, hx.columns.3.y, hx.columns.3.z)
        let hr = simd_normalize(SIMD3<Float>(hx.columns.0.x, hx.columns.0.y, hx.columns.0.z))
        let hu = simd_normalize(SIMD3<Float>(hx.columns.1.x, hx.columns.1.y, hx.columns.1.z))
        let hf = -simd_normalize(SIMD3<Float>(hx.columns.2.x, hx.columns.2.y, hx.columns.2.z))
        let life: Double = 9
        // Most-recent last: order by born so newer sits on top of the stack.
        let active = (0..<Self.chatSlots)
            .filter { chatClock - chatRing[$0].born < life }
            .sorted { chatRing[$0].born < chatRing[$1].born }
        // In front and in the upper visual field, newest on top and older lines
        // stacking downward. Text quads are square so the square text canvas isn't
        // squashed into a thin unreadable line (HUD P2).
        let ordered = active.reversed()   // newest first (top)
        var oy: Float = 0.36              // top edge well up in the upper field so a long MOTD/chat sits above the action, not over it (Eric)
        // An advancement arrives as a toast AND a chat line at the same moment,
        // and both live in the upper field: start the chat stack under the
        // toast's bottom edge while it shows (awardBox is last frame's, which is
        // fine for a 3 s toast). Converts the HUD pixel row to height on our plane.
        if let box = awardBox {
            let el = (Self.hudScreen.y / 2 - box.hi.y) * (2 * Self.hudHalfAngle.y / Self.hudScreen.y)
            oy = min(oy, tan(el) * 1.7 - 0.02)
        }
        for slot in ordered {
            let age = chatClock - chatRing[slot].born
            let fade = age > life - 1 ? Float(max(0, life - age)) : 1
            // Constant per-line glyph height: a message's quad height scales with
            // its wrapped line count, width with its aspect. Long lines wrap to
            // more rows instead of shrinking, so all chat text reads the same size
            // (#157). Cap the width at the band; only then shrink height.
            let perLine: Float = 0.030     // slightly smaller glyphs; ~1deg cap height at the 1.7 m plane (Eric)
            let hMax: Float = 0.44
            var th = perLine * Float(max(1, chatRing[slot].lines))
            var tw = th * max(0.1, chatRing[slot].aspect)
            if tw > hMax { th *= hMax / tw; tw = hMax }
            let center = headPos + hf * 1.7 + hu * (oy - th)   // top edge at oy; further out so a fresh MOTD isn't in your face (Eric)
            let tint = Self.packTint(Int(255 * fade), Int(255 * fade), Int(255 * fade))
            // backdrop sized to the block + aspect-correct text quad over it
            appendQuad(center: center, right: hr, up: hu, hw: max(tw + 0.02, 0.12), hh: th + 0.012,
                       layer: highlightLayer, tint: Self.packTint(Int(18*fade), Int(18*fade), Int(24*fade)), v: &v, idx: &idx)
            appendQuad(center: center + hf * 0.001, right: hr, up: hu, hw: tw, hh: th,
                       layer: chatLayers[slot], tint: tint, v: &v, idx: &idx)
            oy -= (2 * th + 0.03)   // next message below, with a gap
        }
    }

    /// The Kogane companion sprite (always, once baked) plus, when its menu is
    /// open, a head-locked panel with title, options, and a selection pointer.
    /// Everything rides the model-texture stream in origin space (eye at 0).
    private func appendKogane(gaze: SIMD3<Float>, cosY: Float, sinY: Float,
                              v: inout [Float], idx: inout [UInt32]) {
        guard koganeLayer >= 0, !dead else { return }   // hidden while dead (respawn owns the trigger)
        // Real head frame in origin space (identity in the sim). Overlays are
        // placed as head * localOffset, which makes them truly head-locked: at the
        // real head height and orientation, so they don't sit low or rotate.
        let hx = frameHeadXform
        let headPos = SIMD3<Float>(hx.columns.3.x, hx.columns.3.y, hx.columns.3.z)
        let hr = simd_normalize(SIMD3<Float>(hx.columns.0.x, hx.columns.0.y, hx.columns.0.z))
        let hu = simd_normalize(SIMD3<Float>(hx.columns.1.x, hx.columns.1.y, hx.columns.1.z))
        let hf = -simd_normalize(SIMD3<Float>(hx.columns.2.x, hx.columns.2.y, hx.columns.2.z))

        // Companion: body-anchored (forward-left of the body so you can turn to
        // look at it), at head height, offset from the real head position.
        let bf = player.bodyForward()
        let rightW = SIMD3<Float>(bf.z, 0, -bf.x)
        let offW = bf * Self.koganeFwd + rightW * Self.koganeSide + SIMD3<Float>(0, Self.koganeUp, 0)
        let cx = offW.x * cosY - offW.z * sinY
        let cz = -(offW.x * sinY + offW.z * cosY)   // mirrored like the world
        let bob = sin(koganeBob * 2.2) * 0.012
        let center = headPos + SIMD3<Float>(cx, offW.y + bob, cz)
        // Sprite billboards toward the head so it keeps facing you as you turn.
        let toEye = simd_normalize(headPos - center)
        var sRight = simd_cross(SIMD3<Float>(0, 1, 0), toEye)
        let srl = simd_length(sRight); sRight = srl > 1e-4 ? sRight / srl : hr
        let sUp = simd_normalize(simd_cross(toEye, sRight))
        _ = (center, sRight, sUp)   // computed for the sprite; silence unused when hidden
        if koganeSpriteVisible {
            let sprite = (koganeFocused && koganeClosedLayer >= 0) ? koganeLayer
                       : (koganeClosedLayer >= 0 ? koganeClosedLayer : koganeLayer)
            let half: Float = koganeFocused ? 0.062 : 0.046
            appendQuad(center: center, right: sRight, up: sUp, hw: half, hh: half,
                       layer: sprite, tint: 16777215, v: &v, idx: &idx)
        }

        guard koganeMenuOpen, highlightLayer >= 0 else { return }
        let gold = Self.packTint(232, 184, 64)
        // Head-locked panel: head * (right*ox + up*oy - fwd*dist). Centred, upright.
        func at(_ dist: Float, _ ox: Float, _ oy: Float) -> SIMD3<Float> {
            headPos + hf * dist + hr * ox + hu * oy
        }
        // Panel sized for the current option count (title + n rows), so nothing
        // runs off the backdrop.
        let n = koganeOptionLayers.count
        let rowStep: Float = 0.085
        let topOy: Float = Float(n - 1) * rowStep * 0.5      // rows centred about 0
        let titleOy = topOy + 0.10
        let backHalf = titleOy + 0.10
        appendQuad(center: at(0.60, 0, 0), right: hr, up: hu, hw: 0.26, hh: backHalf,
                   layer: highlightLayer, tint: Self.packTint(24, 22, 30), v: &v, idx: &idx)
        if koganeTitleLayer >= 0 {
            appendQuad(center: at(0.58, 0, titleOy), right: hr, up: hu, hw: 0.075, hh: 0.06,
                       layer: koganeTitleLayer, tint: gold, v: &v, idx: &idx)
        }
        for (i, layer) in koganeOptionLayers.enumerated() where layer >= 0 {
            let oy = topOy - Float(i) * rowStep
            if i == koganeSel {
                appendQuad(center: at(0.575, -0.19, oy), right: hr, up: hu,
                           hw: 0.012, hh: 0.012, layer: highlightLayer, tint: gold, v: &v, idx: &idx)
            }
            // Audio toggles show their state as a dot (green = on, grey = off).
            let label = i < koganeOptions.count ? koganeOptions[i] : ""
            if label == "Toggle music" || label == "Toggle sound" {
                let on = label == "Toggle music" ? VolumeSettings.shared.music > 0 : VolumeSettings.shared.sfx > 0
                appendQuad(center: at(0.575, 0.19, oy), right: hr, up: hu, hw: 0.02, hh: 0.02,
                           layer: highlightLayer, tint: on ? Self.packTint(60, 210, 90) : Self.packTint(70, 70, 78),
                           v: &v, idx: &idx)
            }
            appendQuad(center: at(0.58, 0, oy), right: hr, up: hu, hw: 0.11, hh: 0.055,
                       layer: layer, tint: i == koganeSel ? gold : 16777215, v: &v, idx: &idx)
        }
    }

    /// One camera-facing quad (origin space) into the model stream. tint is the
    /// packed rgb the model fragment multiplies the sampled texel by.
    private func appendQuad(center: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                            hw: Float, hh: Float, layer: Int, tint: Float,
                            v: inout [Float], idx: inout [UInt32]) {
        let corners = [center - right*hw + up*hh, center + right*hw + up*hh,
                       center + right*hw - up*hh, center - right*hw - up*hh]
        let uvs = Self.quadUVsTL
        let vb = UInt32(v.count / 9)
        for k in 0..<4 {
            let p = corners[k]
            pushV(&v, p.x, p.y, p.z, uvs[k].0, uvs[k].1, Float(layer), 1.0, 255, tint)
        }
        pushQuad(&idx, vb)
    }

    private static func packTint(_ r: Int, _ g: Int, _ b: Int) -> Float {
        Float(r + g * 256 + b * 65536)
    }

    /// A camera-facing frame (fwd, right, up) for head-locked HUD/text that never
    /// flips when you look straight up or down. For pitches under ~55 deg it
    /// reproduces the gaze exactly; steeper, it caps the pitch so `right` (from
    /// cross(fwd, worldUp)) never degenerates and the basis can't snap through
    /// the pole. `horizFwd` is the heading to fall back on at dead-vertical gaze
    /// (body forward in world space, or (0,0,-1) in origin space).
    private func stableFrame(_ dir: SIMD3<Float>, horizFwd: SIMD3<Float>)
        -> (fwd: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>) {
        let g = simd_normalize(dir)
        var h = SIMD3<Float>(g.x, 0, g.z)
        let hl = simd_length(h)
        h = hl > 1e-3 ? h / hl : horizFwd
        let maxSin: Float = 0.82                    // ~55 deg pitch cap
        let y = max(-maxSin, min(maxSin, g.y))
        let c = (1 - y * y).squareRoot()
        let fwd = SIMD3<Float>(h.x * c, y, h.z * c)
        let right = simd_normalize(simd_cross(fwd, SIMD3<Float>(0, 1, 0)))
        let up = simd_normalize(simd_cross(right, fwd))
        return (fwd, right, up)
    }

    /// Register an RGBA image as a new model-texture layer; returns its index.
    private func registerRGBALayer(_ name: String, _ px: [UInt8]) -> Int {
        // Reuse a layer freed by releasePanelIconLayers first: the pixels go up
        // as an in-place patch, no array growth, no full re-upload (#296).
        if let i = freeModelLayers.popLast() {
            modelTexLayer[name] = i; modelTexUV[name] = SIMD2(1, 1)
            modelTexNames[i] = name; modelTexData[i] = px
            modelTexDirty.insert(i); modelTexturesDirty = true
            return i
        }
        // Metal 2D texture arrays stop at 2048 slices; past that, point the
        // name at the last layer (a wrong picture) instead of aborting in
        // makeTexture. Logged once so a device capture explains the icons.
        if modelTexCount >= Self.maxTextureLayers {
            if !texLayerCapLogged { texLayerCapLogged = true; print("[tex] model texture array full (\(modelTexCount)); '\(name)' shares the last layer"); fflush(stdout) }
            modelTexLayer[name] = modelTexCount - 1; modelTexUV[name] = SIMD2(1, 1)
            return modelTexCount - 1
        }
        let layer = modelTexCount
        modelTexLayer[name] = layer
        modelTexUV[name] = SIMD2(1, 1)
        modelTexData.append(px)
        modelTexNames.append(name)
        modelTexCount += 1
        return layer
    }

    /// Draw the Kogane companion: a round golden shikigami with a face, on a
    /// transparent square canvas, for the model-texture array.
    static func renderKoganeRGBA(canvas: Int, closed: Bool = false) -> [UInt8]? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                                  bytesPerRow: canvas * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = CGFloat(canvas)
        ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))
        ctx.setLineJoin(.round); ctx.setLineCap(.round)
        // The Culling Game Kogane: a small white shikigami with a skull-shaped
        // head, a segmented (three-part) body, little wings, and a black tail
        // that curls. White fill, black outline (see JJK wiki reference).
        let black = CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)
        let white = CGColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1)
        let outline = s * 0.017
        func fill(_ c: CGColor) { ctx.setFillColor(c) }
        // Fill white + stroke a black outline for one path (the outline between
        // overlapping segments reads as the body's segmentation).
        func shell(_ rect: CGRect) {
            let p = CGPath(ellipseIn: rect, transform: nil)
            ctx.addPath(p); fill(white); ctx.fillPath()
            ctx.addPath(p); ctx.setStrokeColor(black); ctx.setLineWidth(outline); ctx.strokePath()
        }

        // Black tail: a thick curl sweeping out from the bottom to the right.
        // Drawn first so the body sits over its root.
        ctx.setStrokeColor(black); ctx.setLineWidth(s*0.055)
        ctx.move(to: CGPoint(x: s*0.50, y: s*0.20))
        ctx.addCurve(to: CGPoint(x: s*0.82, y: s*0.20),
                     control1: CGPoint(x: s*0.52, y: s*0.03),
                     control2: CGPoint(x: s*0.86, y: s*0.05))
        ctx.strokePath()
        fill(black); ctx.fillEllipse(in: CGRect(x: s*0.80, y: s*0.185, width: s*0.045, height: s*0.045))

        // Wings: small rounded pair high on the sides, behind the body.
        for dx: CGFloat in [-1, 1] {
            shell(CGRect(x: s*(0.50 + dx*0.31) - s*0.10, y: s*0.50, width: s*0.20, height: s*0.15))
        }

        // Body: three stacked segments, largest under the head, tapering down.
        shell(CGRect(x: s*(0.5-0.17), y: s*0.16, width: s*0.34, height: s*0.20))   // bottom
        shell(CGRect(x: s*(0.5-0.21), y: s*0.28, width: s*0.42, height: s*0.24))   // middle
        shell(CGRect(x: s*(0.5-0.25), y: s*0.42, width: s*0.50, height: s*0.28))   // upper

        // Skull head: a rounded dome on top.
        shell(CGRect(x: s*0.31, y: s*0.60, width: s*0.38, height: s*0.33))

        // Eye sockets. Open = round dark hollows with a glint (you're looking at
        // it); closed = shallow arcs (the focus cue while you're not).
        if closed {
            ctx.setStrokeColor(black); ctx.setLineWidth(s*0.022)
            for cxp: CGFloat in [0.43, 0.57] {
                ctx.addArc(center: CGPoint(x: s*cxp, y: s*0.75), radius: s*0.05,
                           startAngle: .pi*0.15, endAngle: .pi*0.85, clockwise: false)
                ctx.strokePath()
            }
        } else {
            fill(black)
            ctx.fillEllipse(in: CGRect(x: s*0.385, y: s*0.70, width: s*0.085, height: s*0.11))
            ctx.fillEllipse(in: CGRect(x: s*0.53, y: s*0.70, width: s*0.085, height: s*0.11))
            fill(white)   // glints
            ctx.fillEllipse(in: CGRect(x: s*0.405, y: s*0.755, width: s*0.022, height: s*0.03))
            ctx.fillEllipse(in: CGRect(x: s*0.55, y: s*0.755, width: s*0.022, height: s*0.03))
        }
        // Skull nose: a small dark triangle low-centre on the face.
        fill(black)
        ctx.move(to: CGPoint(x: s*0.50, y: s*0.635))
        ctx.addLine(to: CGPoint(x: s*0.475, y: s*0.675))
        ctx.addLine(to: CGPoint(x: s*0.525, y: s*0.675))
        ctx.closePath(); ctx.fillPath()
        guard let base = ctx.data else { return nil }
        var px = [UInt8](repeating: 0, count: canvas * canvas * 4)
        px.withUnsafeMutableBytes { _ = memcpy($0.baseAddress, base, canvas * canvas * 4) }
        return px
    }

    private func appendCrack(node n: SIMD3<Int>, layer: Int, uv: SIMD2<Float>, eye: SIMD3<Float>,
                             cosY: Float, sinY: Float, light: Float,
                             v: inout [Float], idx: inout [UInt32]) {
        let scale = PlayerState.scale
        let base = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
        // Wrap the crack over the node's real selection boxes so a slab/stair
        // cracks on its own surface, not a full cube floating in the air.
        let boxes = pointBoxes(n, client.world.nodeId(n)) ?? [(SIMD3(0, 0, 0), SIMD3(1, 1, 1))]
        for box in boxes {
            let span = box.hi - box.lo
            for f in WorldSession.crackFaces {
                let vb = UInt32(v.count / 9)
                for k in 0..<4 {
                    let local = box.lo + SIMD3(f.c[k].x * span.x, f.c[k].y * span.y, f.c[k].z * span.z)
                    let wp = base + local + f.n * 0.012          // slight outset (avoid z-fight)
                    let rx = (wp.x - eye.x) * scale, ry = (wp.y - eye.y) * scale, rz = (wp.z - eye.z) * scale
                    let p = SIMD3<Float>(rx * cosY - rz * sinY, ry, -(rx * sinY + rz * cosY))
                    let t = WorldSession.crackUV[k]
                    pushV(&v, p.x, p.y, p.z, t.0 * uv.x, t.1 * uv.y, Float(layer), 1.0, light, 16777215)
                }
                pushQuad(&idx, vb)
            }
        }
    }

    /// Append an axis-aligned box (6 faces) spanning [lo, hi] in world-node
    /// coords, transformed into origin space like appendCrack. `tint` is the
    /// packed vertex colour (0 = black); the sampled layer just needs alpha.
    private func appendBox(lo: SIMD3<Float>, hi: SIMD3<Float>, layer: Int, tint: Float, light: Float,
                           eye: SIMD3<Float>, cosY: Float, sinY: Float,
                           v: inout [Float], idx: inout [UInt32]) {
        let scale = PlayerState.scale
        let span = hi - lo
        for f in WorldSession.crackFaces {
            let vb = UInt32(v.count / 9)
            for k in 0..<4 {
                let c = f.c[k]
                let wp = lo + SIMD3(c.x * span.x, c.y * span.y, c.z * span.z)
                let rx = (wp.x - eye.x) * scale, ry = (wp.y - eye.y) * scale, rz = (wp.z - eye.z) * scale
                let p = SIMD3<Float>(rx * cosY - rz * sinY, ry, -(rx * sinY + rz * cosY))
                let t = WorldSession.crackUV[k]
                pushV(&v, p.x, p.y, p.z, t.0, t.1, Float(layer), 1.0, light, tint)
            }
            pushQuad(&idx, vb)
        }
    }

    /// Pointed-node selection box: the 12 edges of the node the crosshair is on,
    /// each a thin black cuboid, slightly inflated so it sits proud of the block
    /// (no z-fight) and reads from any angle (cull is off). tint 0 -> flat black.
    private func appendHighlight(node n: SIMD3<Int>, layer: Int, eye: SIMD3<Float>,
                                 cosY: Float, sinY: Float, v: inout [Float], idx: inout [UInt32]) {
        let inset: Float = 0.006   // proud of the block face
        let th: Float = 0.006      // edge half-thickness (thin wireframe)
        let light: Float = 255
        // Outline the node's actual selection boxes (slab/stair/nodebox), matching
        // what the raycast points at; nil = the full cube.
        let nb = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
        let boxes: [(lo: SIMD3<Float>, hi: SIMD3<Float>)]
        if let bx = pointBoxes(n, client.world.nodeId(n)) {
            boxes = bx.map { (nb + $0.lo, nb + $0.hi) }
        } else {
            boxes = [(nb, nb + SIMD3(1, 1, 1))]
        }
        for box in boxes {
            let lo = box.lo - SIMD3(inset, inset, inset), hi = box.hi + SIMD3(inset, inset, inset)
            for a in [lo.y, hi.y] { for b in [lo.z, hi.z] {   // X edges
                appendBox(lo: SIMD3(lo.x - th, a - th, b - th), hi: SIMD3(hi.x + th, a + th, b + th),
                          layer: layer, tint: 0, light: light, eye: eye, cosY: cosY, sinY: sinY, v: &v, idx: &idx)
            } }
            for a in [lo.x, hi.x] { for b in [lo.z, hi.z] {   // Y edges
                appendBox(lo: SIMD3(a - th, lo.y - th, b - th), hi: SIMD3(a + th, hi.y + th, b + th),
                          layer: layer, tint: 0, light: light, eye: eye, cosY: cosY, sinY: sinY, v: &v, idx: &idx)
            } }
            for a in [lo.x, hi.x] { for b in [lo.y, hi.y] {   // Z edges
                appendBox(lo: SIMD3(a - th, b - th, lo.z - th), hi: SIMD3(a + th, b + th, hi.z + th),
                          layer: layer, tint: 0, light: light, eye: eye, cosY: cosY, sinY: sinY, v: &v, idx: &idx)
            } }
        }
    }

    /// Spawn a short burst of small textured billboards at a just-broken node,
    /// using the node's face tile so the debris matches the block. They fly out,
    /// fall under gravity, and shrink to nothing over ~0.4s (stepParticles).
    /// A server-sent particle (TOCLIENT_SPAWN_PARTICLE): potion splashes, etc.
    /// Resolves the texture into the node atlas (baking it if new), and spawns it
    /// into the same billboard particle system as break debris. +0.5 puts the
    /// Luanti-centred position into our [g, g+1] mesh frame (like entities).
    private func spawnServerParticle(pos: SIMD3<Float>, vel: SIMD3<Float>, size: Float, life: Float, texture texture0: String,
                                     acc: SIMD3<Float> = .zero, collide: Bool = false, removeOnHit: Bool = false,
                                     look: Client.ParticleLook = Client.ParticleLook()) {
        guard particles.count < 400 else { return }   // don't let a spawner flood us
        var texture = texture0
        // node= particles (falling-block landing dust, mob landing puffs) draw
        // a tile of that node instead of a texture string:
        // ParticleManager::getNodeParticleParams picks a random face unless
        // node_tile names one. These used to be dropped entirely (#307).
        if look.nodeId > 0 {
            let faces = client.nodes.faceTilesSnapshot()[UInt16(look.nodeId)] ?? []
            let candidates = faces.filter { !$0.isEmpty }
            if look.nodeTile > 0, look.nodeTile - 1 < faces.count, !faces[look.nodeTile - 1].isEmpty {
                texture = faces[look.nodeTile - 1]
            } else if let t = candidates.randomElement() { texture = t }
            else { return }
        }
        guard let base = NodeRegistry.imageNames(texture).first else { return }
        // Tile animation: bake one atlas entry per frame through the same
        // modifiers node tiles use ([verticalframe:N:i / [sheet:WxH:x,y) and
        // flip between them by age; mcl_particles_smoke_anim.png (torches,
        // furnaces, campfires, TNT, spawners) drew as the whole 8-frame strip.
        var frameKeys: [String] = []
        var frameLen: Float = 0
        if look.animType != 0 {
            let memoKey = "\(texture)|\(look.animType)|\(look.animA)|\(look.animB)|\(look.animLength)"
            if let m = particleFrameMemo[memoKey] { frameKeys = m.keys; frameLen = m.len }
            else {
                if look.animType == 1, let png = client.media.bytes(base), let dim = Self.pngSize(png) {
                    let frameH = dim.x * Float(look.animB) / Float(max(1, look.animA))
                    let n = max(1, min(64, Int((dim.y / max(1, frameH)).rounded())))
                    if n > 1 {
                        frameKeys = (0..<n).map { "\(texture)^[verticalframe:\(n):\($0)" }
                        frameLen = max(0.02, look.animLength / Float(n))
                    }
                } else if look.animType == 2, look.animA * look.animB > 1 {
                    let w = look.animA, h = look.animB
                    frameKeys = (0..<(w * h)).map { "\(texture)^[sheet:\(w)x\(h):\($0 % w),\($0 / w)" }
                    frameLen = max(0.02, look.animLength)
                }
                // Only memoise once the PNG is here (a nil dim means "try again later").
                if look.animType != 1 || client.media.bytes(base) != nil {
                    if particleFrameMemo.count > 256 { particleFrameMemo.removeAll() }
                    particleFrameMemo[memoKey] = (frameKeys, frameLen)
                }
            }
        }
        if !frameKeys.isEmpty, particleAnimLogged.insert(texture).inserted {
            print("[particles] \(texture): \(frameKeys.count) frames @ \(frameLen)s"); fflush(stdout)
        }
        var needRebuild = false
        for key in frameKeys where atlas.tileLayer(key) == nil && !hotbarTiles.contains(key) {
            hotbarTiles.insert(key); needRebuild = true
        }
        var layer = atlas.tileLayer(texture) ?? atlas.tileLayer(base)
        if layer == nil {
            // Not baked yet: queue it for the next atlas build and draw the marker
            // this time. Rebuilding the atlas forces a full world remesh, so avoid
            // doing it per particle: if the PNG still has to download, the
            // media-arrival path (onMediaReady -> rebuildAtlas) bakes it for free;
            // only rebuild now when the PNG is already here and nothing else would.
            if !hotbarTiles.contains(texture) {
                hotbarTiles.insert(texture); needRebuild = true
            }
            layer = atlas.markerLayer
        }
        if needRebuild {
            atlasNeedsRebuild = true
            if client.media.bytes(base) == nil { client.media.request([base]) }
            else { rebuildAtlas() }
        }
        // Luanti size -> node-space: the engine's own 1/BS. (The 0.06 "VR
        // scale-down" that lived here was compensating for the spawner
        // positions being parsed at a tenth of their real distance, which is
        // what actually put rain in your face, #199.) Cap so a bad server value
        // can't fill the view.
        let sz = max(0.05, min(1.0, size * 0.1))
        let texKey = atlas.tileLayer(texture) != nil ? texture : base
        particles.append(BreakParticle(pos: pos, vel: vel, acc: acc, age: 0,
                                       life: max(0.1, min(6, life)), size: sz,
                                       collide: collide, removeOnHit: collide && removeOnHit,
                                       layer: layer ?? atlas.markerLayer, tex: texKey,
                                       frameKeys: frameKeys, frameLen: frameLen,
                                       glow: UInt8(max(0, min(15, look.glow))),
                                       drag: look.drag, jitterMin: look.jitterMin, jitterMax: look.jitterMax,
                                       bounce: look.bounce,
                                       scaleStart: (look.scaleStart.x + look.scaleStart.y) * 0.5,
                                       scaleEnd: (look.scaleEnd.x + look.scaleEnd.y) * 0.5))
    }

    private func spawnBreakParticles(at n: SIMD3<Int>, id: UInt16) {
        let faces = client.nodes.faceTilesSnapshot()
        guard let tile = faces[id]?.first(where: { !$0.isEmpty }),
              let layer = atlas.tileLayer(tile) else { return }
        let base = SIMD3<Float>(Float(n.x) + 0.5, Float(n.y) + 0.5, Float(n.z) + 0.5)
        let count = 12
        for _ in 0..<count {
            let jitter = SIMD3<Float>(.random(in: -0.3...0.3), .random(in: -0.3...0.3), .random(in: -0.3...0.3))
            let vel = SIMD3<Float>(.random(in: -1.6...1.6), .random(in: 1.2...3.2), .random(in: -1.6...1.6))
            particles.append(BreakParticle(pos: base + jitter, vel: vel, acc: SIMD3(0, -9, 0), age: 0,
                                           life: .random(in: 0.35...0.5), size: 0.13, layer: layer, tex: tile))   // dig debris falls
        }
        print("[particles] spawn \(count) at \(n) tile=\(tile)"); fflush(stdout)
    }

    /// Re-resolve a particle's atlas layer(s) from its texture keys; called
    /// when its cached generation is behind the atlas. Falls back to the still
    /// texture, then the neutral marker (never a stale index: that's how snow
    /// once turned into falling dirt, #256).
    private func resolveParticleLayers(_ i: Int) {
        let base = atlas.tileLayer(particles[i].tex) ?? atlas.markerLayer
        particles[i].layer = Int32(base)
        if !particles[i].frameKeys.isEmpty {
            particles[i].frameLayers = particles[i].frameKeys.map { Int32(atlas.tileLayer($0) ?? base) }
        }
        particles[i].layerGen = atlasGeneration
    }

    /// Animated-particle frame keys, memoised on (texture, animation params):
    /// deriving them cost a PNG header parse and N interpolated Strings per
    /// spawned particle, and torch/campfire smoke spawns continuously (perf #312).
    private var particleFrameMemo: [String: (keys: [String], len: Float)] = [:]

    /// Age the break particles: integrate gravity + velocity and drop the dead.
    /// Emit `count` particles from a spawner: each at a random point in the
    /// pos range (offset by the attached object, if any) with a random velocity,
    /// lifetime and size in their ranges. Reuses the break-particle system.
    private var spawnerDropLogged = false
    private func emitSpawnerParticles(_ sp: Client.ParticleSpawner, count: Int, age: Float = 0) {
        guard count > 0 else { return }
        // Per-emit budget: one spawner can't consume the whole 400 pool and
        // starve break particles / other spawners. Leave headroom; log once.
        let budget = max(0, 300 - particles.count)
        let n = min(count, budget)
        if n < count, !spawnerDropLogged {
            spawnerDropLogged = true
            print("[particles] spawner over budget (have \(particles.count)), dropping \(count - n)"); fflush(stdout)
        }
        guard n > 0 else { return }
        var origin = SIMD3<Float>(0, 0, 0)
        if sp.attachedId != 0 {
            // Attached to the local player (weather rain/snow): its AO pos is the
            // stale server position, so follow the live camera instead or the
            // downfall would sit at spawn. Other attachments use the object pos.
            if sp.attachedId == client.objects.localPlayerId {
                origin = player.snapshot().feet
            } else {
                guard let e = client.objects.entity(sp.attachedId) else { return }   // gone: skip this batch
                origin = e.pos
            }
        }
        func rnd(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(.random(in: min(a.x,b.x)...max(a.x,b.x)), .random(in: min(a.y,b.y)...max(a.y,b.y)), .random(in: min(a.z,b.z)...max(a.z,b.z)))
        }
        // TweenedParameter::blend: each range slides from its start to its end
        // over the spawner's life (a one-shot spawner has none, t stays 0).
        let t: Float = sp.time > 0 ? max(0, min(1, age / sp.time)) : 0
        func tw(_ a: SIMD3<Float>, _ b: SIMD3<Float>?) -> SIMD3<Float> { b.map { a + ($0 - a) * t } ?? a }
        func tw(_ a: Float, _ b: Float?) -> Float { b.map { a + ($0 - a) * t } ?? a }
        let pMin = tw(sp.posMin, sp.posMinEnd), pMax = tw(sp.posMax, sp.posMaxEnd)
        let vMin = tw(sp.velMin, sp.velMinEnd), vMax = tw(sp.velMax, sp.velMaxEnd)
        let aMin = tw(sp.accMin, sp.accMinEnd), aMax = tw(sp.accMax, sp.accMaxEnd)
        let eMin = tw(sp.expMin, sp.expMinEnd), eMax = tw(sp.expMax, sp.expMaxEnd)
        let sMin = tw(sp.sizeMin, sp.sizeMinEnd), sMax = tw(sp.sizeMax, sp.sizeMaxEnd)
        let useRadius = simd_length(sp.radiusMax) > 0 || simd_length(sp.radiusMin) > 0
        for _ in 0..<n {
            var pos = origin + rnd(pMin, pMax)
            if useRadius {
                // radius: a point on an ellipsoid of a radius picked in the range
                // around pos (lingering potion clouds, ParticleSpawner::spawnParticle).
                let rad = rnd(sp.radiusMin, sp.radiusMax)
                let theta = Float.random(in: 0..<(2 * .pi)), phi = acos(Float.random(in: -1...1))
                pos += SIMD3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta)) * rad
            }
            let vel = rnd(vMin, vMax)
            let acc = rnd(aMin, aMax)
            let life = Float.random(in: min(eMin, eMax)...max(eMin, eMax))
            let size = Float.random(in: min(sMin, sMax)...max(sMin, sMax))
            spawnServerParticle(pos: pos, vel: vel, size: size, life: max(0.1, life), texture: sp.texture, acc: acc,
                                collide: sp.collisionDetection, removeOnHit: sp.collisionRemoval, look: sp.look)
        }
    }

    /// Advance timed spawners: spread `amount` particles evenly over `time`
    /// seconds (Luanti's ParticleSpawner), then drop the spawner when done.
    private func stepSpawners(_ dt: Float) {
        guard !activeSpawners.isEmpty else { return }
        for (id, var sp) in activeSpawners {
            // An attached spawner whose object is gone: give it a grace period
            // (the object may just be out of range), then drop it so infinite
            // spawners don't leak.
            if sp.spec.attachedId != 0, client.objects.entity(sp.spec.attachedId) == nil {
                sp.gone += dt
                if sp.gone > 3 { activeSpawners.removeValue(forKey: id); continue }
                activeSpawners[id] = sp; continue
            }
            sp.gone = 0
            sp.age += dt
            if sp.spec.time > 0 {
                // Finite: spread amount over time, then done.
                let target = Int(Float(sp.spec.amount) * min(1, sp.age / sp.spec.time))
                if target > sp.emitted { emitSpawnerParticles(sp.spec, count: target - sp.emitted, age: sp.age); sp.emitted = target }
                if sp.age >= sp.spec.time { activeSpawners.removeValue(forKey: id); continue }
            } else {
                // Infinite (Luanti m_spawntime==0): amount is the per-second rate.
                // Carry the fractional remainder so slow rates still emit.
                let expected = Float(sp.spec.amount) * dt + sp.spawnRemainder
                let n = Int(expected)
                sp.spawnRemainder = expected - Float(n)
                if n > 0 { emitSpawnerParticles(sp.spec, count: n, age: sp.age) }
            }
            activeSpawners[id] = sp
        }
    }

    private func stepParticles(_ dt: Float) {
        guard !particles.isEmpty else { return }
        // Each particle carries the server's acceleration (dig-break particles set
        // their own gravity). Smoke/portal particles that shouldn't fall now don't.
        var cur = WorldMap.BlockCursor()
        // Does the point q sit in a walkable node? (A point test is enough for
        // sprites this small.)
        func solid(_ q: SIMD3<Float>) -> Bool {
            let n = SIMD3(Int(floor(q.x)), Int(floor(q.y)), Int(floor(q.z)))
            let id = client.world.nodeId(n, &cur)
            return id != WorldMap.CONTENT_AIR && id != WorldMap.CONTENT_IGNORE && phys.isWalkable(id)
        }
        for i in particles.indices {
            particles[i].age += dt
            // Particle::step: drag shrinks each velocity component toward zero,
            // jitter adds a random nudge every frame (both zero for most).
            if particles[i].drag != .zero {
                let v = particles[i].vel
                let av = abs(v) - abs(v) * particles[i].drag * dt
                particles[i].vel = SIMD3(copysign(av.x, v.x), copysign(av.y, v.y), copysign(av.z, v.z))
            }
            if particles[i].jitterMax != particles[i].jitterMin {
                let a = particles[i].jitterMin, b = particles[i].jitterMax
                particles[i].vel += SIMD3(.random(in: min(a.x,b.x)...max(a.x,b.x)), .random(in: min(a.y,b.y)...max(a.y,b.y)),
                                          .random(in: min(a.z,b.z)...max(a.z,b.z))) * dt
            }
            particles[i].vel += particles[i].acc * dt
            let next = particles[i].pos + particles[i].vel * dt
            // collisiondetection (Luanti particles.cpp via collisionMoveSimple):
            // a particle that would enter a walkable node stops on that axis
            // and keeps sliding on the others; with collision_removal it's gone;
            // with bounce the largest velocity component reflects. Weather flakes
            // spawn 20+ nodes overhead, so underground they start inside rock
            // and die on their first step, which keeps caves free of snow (#275).
            if particles[i].collide {
                // Swept: rain moves ~2 nodes per tick, so test the path in
                // half-node steps or it tunnels through a one-thick roof.
                let from = particles[i].pos, d = next - from
                let steps = max(1, Int(ceil(simd_length(d) / 0.5)))
                var hit = false
                for k in 1...steps where solid(from + d * (Float(k) / Float(steps))) { hit = true; break }
                if hit {
                    if particles[i].removeOnHit { particles[i].age = particles[i].life; continue }
                    let v = particles[i].vel, av = abs(v)
                    if particles[i].bounce > 0 {
                        var nv = v
                        if av.y > av.x && av.y > av.z { nv.y = -(v.y * particles[i].bounce) }
                        else if av.x > av.y && av.x > av.z { nv.x = -(v.x * particles[i].bounce) }
                        else if av.z > av.y && av.z > av.x { nv.z = -(v.z * particles[i].bounce) }
                        else { nv = -(v * particles[i].bounce) }
                        particles[i].vel = nv
                        continue
                    }
                    // Slide: keep whichever single-axis moves stay clear.
                    var p = from, nv = v
                    let tx = SIMD3(from.x + v.x * dt, from.y, from.z)
                    if v.x != 0 { if solid(tx) { nv.x = 0 } else { p.x = tx.x } }
                    let ty = SIMD3(p.x, from.y + v.y * dt, from.z)
                    if v.y != 0 { if solid(ty) { nv.y = 0 } else { p.y = ty.y } }
                    let tz = SIMD3(p.x, p.y, from.z + v.z * dt)
                    if v.z != 0 { if solid(tz) { nv.z = 0 } else { p.z = tz.z } }
                    particles[i].vel = nv; particles[i].pos = p
                    continue
                }
            }
            particles[i].pos = next
        }
        particles.removeAll { $0.age >= $0.life }
    }

    /// True if the node containing world point `p` is a liquid. Node cubes span
    /// [g, g+1] on every axis (matching the mesher), so floor maps a point to its
    /// node. Unloaded columns read as not-liquid.
    /// Luanti's ClientMap::renderPostFx: the node the camera is in paints its
    /// post_effect_color over the view; if post_effect_color_shaded, the rgb is
    /// scaled by the light there first. Alpha 0 = nothing drawn.
    private var postEffectLogged: Set<UInt16> = []
    private func postEffectAt(_ p: SIMD3<Float>) -> SIMD4<Float> {
        let n = SIMD3(Int(floor(p.x)), Int(floor(p.y)), Int(floor(p.z)))
        let id = client.world.nodeId(n)
        guard id != WorldMap.CONTENT_IGNORE, let fx = client.nodes.postEffect(id) else { return .zero }
        var c = fx.color
        if fx.shaded {
            let l = client.world.nodeLight(n)
            let light = Float(max(Int(l & 0x0F), Int(l >> 4))) / 15   // brighter of day/night nibble
            c = SIMD4(c.x * light, c.y * light, c.z * light, c.w)
        }
        if !postEffectLogged.contains(id) {
            postEffectLogged.insert(id)
            print("[water] post_effect \(client.nodes.name(id)) rgba=\(fx.color) shaded=\(fx.shaded) -> \(c)"); fflush(stdout)
        }
        return c
    }

    /// True when world point `p` is inside a fully-solid opaque node (Luanti's
    /// NDT_solidness == 2: a walkable cube that isn't a liquid or a see-through
    /// drawtype). Drives the in-a-wall black-out.
    private var headSolidFrames = 0
    private func headDeepInSolid(_ p: SIMD3<Float>) -> Bool {
        // Node containing p, then check p sits at least `margin` inside that
        // node's cube on every axis, so merely touching a face doesn't count.
        let n = SIMD3(Int(floor(p.x)), Int(floor(p.y)), Int(floor(p.z)))
        let id = client.world.nodeId(n)
        guard id != WorldMap.CONTENT_IGNORE, id != WorldMap.CONTENT_AIR else { return false }
        guard phys.isSolidCube(id) else { return false }   // glass/leaves/nodebox stay see-through
        let m: Float = 0.03
        let f = p - SIMD3(Float(n.x), Float(n.y), Float(n.z))
        return f.x > m && f.x < 1 - m && f.y > m && f.y < 1 - m && f.z > m && f.z < 1 - m
    }

    private func liquidAt(_ p: SIMD3<Float>) -> Bool {
        let n = SIMD3(Int(floor(p.x)), Int(floor(p.y)), Int(floor(p.z)))
        let id = client.world.nodeId(n)
        return id != WorldMap.CONTENT_IGNORE && phys.isLiquid(id)
    }

    // MARK: - Luanti-style collision (player AABB vs walkable node boxes)

    // Local player collisionbox / stepheight, from our own AO's ObjectProperties
    // (#272). VoxeLibre swaps them per state: normal +-0.312 x 1.8, swimming
    // 0.8 tall (so you fit through a one-node water gap). These start at the
    // engine's defaults and follow SET_PROPERTIES.
    private var playerHW: Float = 0.3               // Luanti player collisionbox +-0.3
    private var playerHeight: Float = 1.77          // ... 0 .. 1.77
    private var playerStep: Float = 0.6             // stepheight (slabs/stairs, not full blocks)

    /// The node the sneaking player is glued to (LocalPlayer::m_sneak_node) and
    /// the world-space bounding box of its collision boxes.
    private var sneakNode: (pos: SIMD3<Int>, box: AABB)?
    private var sneakScratch: [AABB] = []

    /// LocalPlayer::updateSneakNode: keep the current sneak node while the node
    /// just under the feet is still it (and walkable); otherwise pick, among
    /// that node and its 8 XZ neighbours, the nearest walkable one whose centre
    /// is within reach (0.55 + sneak_max) and that has nothing walkable in the
    /// player's height above it. Returns nil when there's nothing to glue to,
    /// which is what lets you walk off a fully unsupported spot like Luanti does.
    private func updateSneakNode(feet: SIMD3<Float>) -> (pos: SIMD3<Int>, box: AABB)? {
        var cur = WorldMap.BlockCursor()
        // "We want the top of the sneak node to be below the player's feet."
        var yMod: Float = 0.02
        if let sn = sneakNode { yMod = (sn.box.hi.y - Float(sn.pos.y)) - 0.02 }
        let current = SIMD3(Int(floor(feet.x)), Int(floor(feet.y - yMod)), Int(floor(feet.z)))
        if let sn = sneakNode, sn.pos == current, phys.isWalkable(client.world.nodeId(current, &cur)) { return sn }
        let sneakMax = playerHW * 2 * 0.49
        let allowed: Float = 0.5 + 0.05 + sneakMax
        let height = Int(ceil(playerHeight))
        var best: (pos: SIMD3<Int>, box: AABB)?
        var bestDist = Float.greatestFiniteMagnitude
        for d in Self.dir9Center {
            let p = current &+ d
            let id = client.world.nodeId(p, &cur)
            guard id != WorldMap.CONTENT_IGNORE, phys.isWalkable(id) else { continue }
            sneakScratch.removeAll(keepingCapacity: true)
            appendNodeSolidBoxes(p, into: &sneakScratch, cur: &cur)
            guard var box = sneakScratch.first else { continue }
            for b in sneakScratch.dropFirst() { box.lo = simd_min(box.lo, b.lo); box.hi = simd_max(box.hi, b.hi) }
            let cxz = (box.lo + box.hi) * 0.5
            let dx = feet.x - cxz.x, dz = feet.z - cxz.z
            let dist = dx * dx + dz * dz
            if dist > bestDist || abs(dx) > allowed || abs(dz) > allowed { continue }
            var clearAbove = true
            for y in 1...height {
                let a = client.world.nodeId(p &+ SIMD3(0, y, 0), &cur)
                if a == WorldMap.CONTENT_IGNORE || phys.isWalkable(a) { clearAbove = false; break }
            }
            if !clearAbove { continue }
            bestDist = dist; best = (p, box)
        }
        return best
    }
    private static let dir9Center: [SIMD3<Int>] = [
        SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1),
        SIMD3(1, 0, 1), SIMD3(-1, 0, 1), SIMD3(1, 0, -1), SIMD3(-1, 0, -1)]

    /// Max movement resistance among nodes the player box overlaps (water 1,
    /// lava 7, cobweb 14; 0 for normal nodes). Speed is divided by (1+this), so
    /// cobwebs nearly stop you and lava wades like molasses, from the server's
    /// move_resistance/liquid_viscosity rather than the drawtype (#211).
    private func overlapResistance(feet: SIMD3<Float>) -> Int {
        let hw = playerHW, h = playerHeight
        var best = 0
        var cur = WorldMap.BlockCursor()
        for x in Int(floor(feet.x - hw))...Int(floor(feet.x + hw)) {
            for y in Int(floor(feet.y))...Int(floor(feet.y + h)) {
                for z in Int(floor(feet.z - hw))...Int(floor(feet.z + hw)) {
                    best = max(best, phys.moveResistance(client.world.nodeId(SIMD3(x, y, z), &cur)))
                }
            }
        }
        return best
    }

    /// True if the player's collision box overlaps any climbable node (ladder,
    /// vine): drives ascend/descend and fall-arrest in the land physics (#209).
    private func overlapsClimbable(feet: SIMD3<Float>) -> Bool {
        // Luanti (localplayer.cpp) samples the player's CENTRE COLUMN at two
        // heights -- just below the feet (position - 0.2*BS) and mid-body
        // (position + 0.5*BS) -- NOT the whole body AABB. Scanning the full box
        // (the old code) let a ladder at head height with air at the feet flag
        // climbing, so you'd hover in mid-air under a ladder; it also arrested
        // falls when merely brushing a ladder wall edge, and overshot the top by
        // ~1.7 m before gravity resumed. Centre-column matches the engine. The
        // below-feet probe still hands you onto a ladder shaft through an open
        // trapdoor across the node boundary (#243/#209).
        let cx = Int(floor(feet.x)), cz = Int(floor(feet.z))
        var cur = WorldMap.BlockCursor()
        for y in [Int(floor(feet.y - 0.2)), Int(floor(feet.y + 0.5))] {
            if phys.isClimbable(client.world.nodeId(SIMD3(cx, y, cz), &cur)) { return true }
        }
        return false
    }

    /// True if the player's whole body box sits in a climbable node's column.
    /// Wider than overlapsClimbable's centre-column point samples: it catches a
    /// ladder whose lowest rung is a node above the feet (the igloo shaft, #331),
    /// where the +0.5 sample falls just short. Only consulted while JUMP is held
    /// so it can't cause the passive "hover under an overhead ladder" the point
    /// samples were narrowed to avoid -- you must actively press up to grab on.
    private func climbGrab(feet: SIMD3<Float>) -> Bool {
        // Reach a bit past the body: OUT ~0.35 horizontally so a ladder you're
        // pressed against (its thin plate can leave your centre a hair short of
        // its column) still counts, and UP one node -- pressing jump anticipates
        // the rise, letting you catch a ladder whose lowest rung sits a node
        // above your head (the igloo shaft base plugs the rungs above the floor,
        // #331). Still jump-gated, so it never grabs passively.
        let box = playerBox(feet)
        let loX = Int(floor(box.lo.x - 0.35)), loY = Int(floor(box.lo.y)), loZ = Int(floor(box.lo.z - 0.35))
        let hiX = Int(floor(box.hi.x + 0.35)), hiY = Int(floor(box.hi.y + 1.0)), hiZ = Int(floor(box.hi.z + 0.35))
        var cur = WorldMap.BlockCursor()
        for x in loX...hiX { for y in loY...hiY { for z in loZ...hiZ {
            if phys.isClimbable(client.world.nodeId(SIMD3(x, y, z), &cur)) { return true }
        } } }
        return false
    }

    private struct AABB {
        var lo: SIMD3<Float>, hi: SIMD3<Float>
        func overlaps(_ o: AABB) -> Bool {
            lo.x < o.hi.x && hi.x > o.lo.x && lo.y < o.hi.y && hi.y > o.lo.y && lo.z < o.hi.z && hi.z > o.lo.z
        }
    }

    private func playerBox(_ feet: SIMD3<Float>) -> AABB {
        AABB(lo: SIMD3(feet.x - playerHW, feet.y, feet.z - playerHW),
             hi: SIMD3(feet.x + playerHW, feet.y + playerHeight, feet.z + playerHW))
    }

    /// World-space collision boxes for the node at `n` (our [g, g+1] frame).
    /// Solidity is Luanti's `walkable` flag (clover, flowers etc. are not);
    /// nodebox drawtypes use their parsed, param2-rotated node_box (so a stair's
    /// low step is 0.5 tall and an open door is a thin box to the side); all
    /// other walkable nodes are the full cube.
    /// Selection boxes of the node at n in node-local 0..1 space, rotated by
    /// its facedir like the mesh (nil = full cube). Feeds the pointing raycast
    /// so a slab/stair/door is only hit where it actually is (#80).
    private func pointBoxes(_ n: SIMD3<Int>, _ id: UInt16) -> [(lo: SIMD3<Float>, hi: SIMD3<Float>)]? {
        guard let boxes = client.nodes.selectionBoxes(id), !boxes.isEmpty else {
            // A mesh-drawtype node with no server selection box (lantern, chain,
            // bell): aim/highlight the model's own bounds instead of the full cube
            // so the outline hugs the model and you can't hit empty air (#192).
            if client.nodes.kind(id) == .mesh, let box = meshNodeBounds(id) { return [box] }
            return nil
        }
        // A wallmounted selection box (torch, wall lever) ships 3 boxes; point at
        // only the one its param2 selects, else the union of all three reads as a
        // full cube around a thin torch (#253). Same pick as the mesher (#212).
        let picked = client.nodes.isWallmountedSelBox(id)
            ? WorldMesher.wallmountedBox(boxes, param2: client.world.nodeParam2(n))
            : boxes
        let fd = WorldMesher.meshFacedir(client.world.nodeParam2(n), client.nodes.paramType2(id))
        return picked.map { b in
            var lo = b.min, hi = b.max
            // wallmountedBox already applied the wall rotation; only rotate here
            // for non-wallmounted facedir boxes.
            if fd != 0, !client.nodes.isWallmountedSelBox(id) {
                let a = WorldMesher.rotateFacedir(b.min, fd), c = WorldMesher.rotateFacedir(b.max, fd)
                lo = simd_min(a, c); hi = simd_max(a, c)
            }
            return (lo + 0.5, hi + 0.5)   // node centre at 0.5 in our [g, g+1] grid
        }
    }

    // Append the node's solid collision boxes into `out` instead of returning a
    // fresh array, so the swept-region scan (~dozens of nodes, twice a physics
    // tick) doesn't allocate a small array per node (#187).
    /// Connected-nodebox arm directions (top, bottom, front, left, back, right),
    /// hoisted out of the per-node scan (perf #312).
    private static let connectDirs: [SIMD3<Int>] = [SIMD3(0,1,0), SIMD3(0,-1,0), SIMD3(0,0,-1),
                                                    SIMD3(-1,0,0), SIMD3(0,0,1), SIMD3(1,0,0)]
    /// Lock-free per-id node facts for collision; refreshed when NODEDEF changes.
    private var phys = NodeRegistry.PhysicsSnapshot.makeEmpty()
    private func refreshPhysicsSnapshot() {
        let v = client.nodes.version()
        if v != phys.version { phys = client.nodes.physicsSnapshot() }
    }

    private func appendNodeSolidBoxes(_ n: SIMD3<Int>, into out: inout [AABB], cur: inout WorldMap.BlockCursor, climbing: Bool = false) {
        let id = client.world.nodeId(n, &cur)
        // Climbable nodes (ladders, vines) never block horizontal movement, so
        // you can always walk INTO a ladder's node and stand pressed against it,
        // then climb -- as on desktop, where a ladder's thin wall plate leaves
        // its node walk-in-able. We skip its collision entirely rather than
        // colliding the plate, which under our Z-mirror could land on the room
        // side and wall you out of a Z-wall ladder (the igloo shaft, #331). The
        // solid node the ladder is bolted to still stops you at the wall. This
        // also lets you slide freely up/down a ladder while climbing (#243).
        if id != WorldMap.CONTENT_IGNORE, id != WorldMap.CONTENT_AIR, phys.isClimbable(id) { return }
        _ = climbing   // (kept in the signature; climbable skip is now unconditional)
        let base = SIMD3<Float>(Float(n.x), Float(n.y), Float(n.z))
        // Not-yet-loaded nodes are SOLID, as in collision.cpp ("Collide with
        // loaded CONTENT_IGNORE nodes": a full node box). Treating them as empty
        // let the player drop through ground the server hadn't streamed yet
        // and land in whatever cave was loaded below (#120). Standing on the top
        // of an unloaded block until it arrives, then settling onto the real
        // surface, is what the engine does too.
        if id == WorldMap.CONTENT_IGNORE { out.append(AABB(lo: base, hi: base + 1)); return }
        if id == WorldMap.CONTENT_AIR { return }
        guard phys.isWalkable(id) else { return }
        // Prefer collision_box (taller fence post, etc.) over the visual node_box
        // for physics; fall back to node_box when a node defines no collision_box
        // (#214). Any drawtype, like MapNode::getCollisionBoxes: a signlike ladder
        // is its wallmounted plate, a mesh chest its 14/16 box (#303).
        let coll = phys.collisionBox(id)
        if let raw = coll ?? phys.nodeBox(id), !raw.isEmpty {
            // A wallmounted node_box ships wall_top/bottom/side; only the one the
            // param2 selects exists physically (same pick as the mesher, #212).
            let boxes = (coll == nil && phys.isWallmounted(id))
                ? WorldMesher.wallmountedBox(raw, param2: client.world.nodeParam2(n)) : raw
            let fd = WorldMesher.meshFacedir(client.world.nodeParam2(n), phys.pt2(id))
            func toAABB(_ b: NodeRegistry.Box) -> AABB {
                var lo = b.min, hi = b.max
                if fd != 0 {
                    let a = WorldMesher.rotateFacedir(b.min, fd), c = WorldMesher.rotateFacedir(b.max, fd)
                    lo = simd_min(a, c); hi = simd_max(a, c)
                }
                return AABB(lo: base + lo + 0.5, hi: base + hi + 0.5)   // node centre at g+0.5
            }
            for b in boxes { out.append(toAABB(b)) }
            // Connected nodeboxes (fences/walls/panes): also collide the arms
            // toward neighbours in the connects_to set, matching the mesh, so you
            // can't walk through the rail between two connected posts. Use the
            // collision_box arms when it defines them, else the visual arms.
            let armSet = coll != nil ? phys.collisionConnectArms(id) : phys.connectArms(id)
            if let arms = armSet, let cset = phys.connectsTo(id) {
                for (di, off) in Self.connectDirs.enumerated() where di < arms.count {
                    if cset.contains(client.world.nodeId(n &+ off, &cur)) { for b in arms[di] { out.append(toAABB(b)) } }
                }
            }
            return
        }
        out.append(AABB(lo: base, hi: base + 1))
    }

    /// True if any node the box touches contributes a solid collision box.
    /// Fills a reused scratch so the eject probe (up to 20 calls in one tick)
    /// doesn't allocate a fresh array per step (perf #312).
    private var probeScratch: [AABB] = []
    private func anySolidBox(around box: AABB) -> Bool {
        probeScratch.removeAll(keepingCapacity: true)
        let lo = SIMD3(Int(floor(box.lo.x)), Int(floor(box.lo.y)), Int(floor(box.lo.z)))
        let hi = SIMD3(Int(floor(box.hi.x)), Int(floor(box.hi.y)), Int(floor(box.hi.z)))
        var cur = WorldMap.BlockCursor()
        for x in lo.x...hi.x { for y in lo.y...hi.y { for z in lo.z...hi.z {
            appendNodeSolidBoxes(SIMD3(x, y, z), into: &probeScratch, cur: &cur)
            if probeScratch.contains(where: { $0.overlaps(box) }) { return true }
        } } }
        return false
    }

    /// Solid boxes of every node the swept player box could touch.
    private func solidBoxes(around box: AABB, climbing: Bool = false) -> [AABB] {
        var out: [AABB] = []
        let lo = SIMD3(Int(floor(box.lo.x)), Int(floor(box.lo.y)), Int(floor(box.lo.z)))
        let hi = SIMD3(Int(floor(box.hi.x)), Int(floor(box.hi.y)), Int(floor(box.hi.z)))
        out.reserveCapacity((hi.x - lo.x + 1) * (hi.y - lo.y + 1) * (hi.z - lo.z + 1))
        var cur = WorldMap.BlockCursor()   // last-block cache; the scan hits ~1-2 blocks
        for x in lo.x...hi.x { for y in lo.y...hi.y { for z in lo.z...hi.z {
            appendNodeSolidBoxes(SIMD3(x, y, z), into: &out, cur: &cur, climbing: climbing)
        } } }
        return out
    }

    /// Move the player box by `delta` through the world's collision boxes.
    /// Sub-stepped like ClientEnvironment::step (clientenvironment.cpp:97-119):
    /// no single step moves more than 0.1 node on any axis. The per-step X/Z
    /// pass tests the END box only, so one long frame at sprint (or a knockback
    /// at 20 node/s) used to carry the box clean past a pane or a door.
    private func collideMove(feet f0: SIMD3<Float>, delta: SIMD3<Float>, grounded: Bool, climbing: Bool = false)
        -> (feet: SIMD3<Float>, hitFloor: Bool, hitCeil: Bool) {
        let maxAxis = max(abs(delta.x), abs(delta.y), abs(delta.z))
        let steps = max(1, min(64, Int((maxAxis / 0.1).rounded(.up))))
        if steps == 1 { return collideMoveStep(feet: f0, delta: delta, grounded: grounded, climbing: climbing) }
        let part = delta / Float(steps)
        var feet = f0, hitFloor = false, hitCeil = false, onGround = grounded
        for _ in 0..<steps {
            let r = collideMoveStep(feet: feet, delta: part, grounded: onGround, climbing: climbing)
            feet = r.feet
            if r.hitFloor { hitFloor = true; onGround = true }
            if r.hitCeil { hitCeil = true }
        }
        return (feet, hitFloor, hitCeil)
    }

    /// One sub-step: sweep the player box by `delta` one axis at a time (Y, then
    /// X, then Z), stopping at the first walkable box on each axis. A horizontal
    /// hit tries a step-up (Luanti collision.cpp: obstacle top above the feet but
    /// within stepHeight, with room to stand) so slabs/stairs are climbed and
    /// full blocks are not. Returns whether we're standing on something / hit a ceiling.
    private func collideMoveStep(feet f0: SIMD3<Float>, delta: SIMD3<Float>, grounded: Bool, climbing: Bool)
        -> (feet: SIMD3<Float>, hitFloor: Bool, hitCeil: Bool) {
        var feet = f0
        var hitFloor = false, hitCeil = false
        let a = playerBox(feet), b = playerBox(feet + delta)
        let swept = AABB(lo: simd_min(a.lo, b.lo) - 0.6, hi: simd_max(a.hi, b.hi) + 0.6)
        // While climbing, a climbable node doesn't collide (Luanti: you move
        // freely up/down a ladder). A walkable climbable like the igloo's
        // trapdoor_ladder otherwise landed the descent on itself, so you couldn't
        // pass down onto the ladder below (#243).
        let solids = solidBoxes(around: swept, climbing: climbing)
        // Already embedded (spawned/teleported into geometry, or swam up into an
        // overhang): don't fight it and don't fall forever -- hold height, and
        // allow horizontal movement only in a direction that doesn't push DEEPER
        // into the geometry, so you can walk/swim out but can't clip through a
        // wall (#167). Moving toward a wall would add an overlapping box; block
        // that axis, keep the axis that reduces or holds the overlap count.
        // Only a solid that rises ABOVE the step-up height counts as "embedding"
        // (a real wall you're stuck inside). A thin walkable nodebox you're
        // resting on -- carpet, a slab, a snow layer -- overlaps the feet box but
        // is steppable, so it must NOT trigger the limited-move/eject path, or you
        // can't walk from one carpet onto the next and spawn-on-carpet traps you
        // (the igloo bug, #242). Those fall through to the normal step-up below.
        let embedBox = playerBox(feet)
        if solids.contains(where: { $0.overlaps(embedBox) && $0.hi.y > feet.y + playerStep }) {
            func embeddedCount(_ f: SIMD3<Float>) -> Int {
                let box = playerBox(f); var n = 0
                for s in solids where s.overlaps(box) { n += 1 }
                return n
            }
            let base = embeddedCount(feet)
            var out = feet
            let tx = SIMD3(feet.x + delta.x, feet.y, feet.z)
            if embeddedCount(tx) <= base { out.x = tx.x }
            let tz = SIMD3(out.x, feet.y, feet.z + delta.z)
            if embeddedCount(tz) <= base { out.z = tz.z }
            // Fully walled in and no horizontal way out (spawned/teleported inside
            // real geometry, e.g. an igloo): eject straight up to the first clear
            // height so the player pops onto the surface instead of being stuck
            // for good (can't move, can't jump). Only when horizontal made no
            // progress, so a normal brush-past isn't disturbed. hitFloor=false so
            // gravity resettles onto the real surface next tick.
            // Eject ONLY when genuinely inside a full solid (spawn/teleport into
            // rock, or not-yet-streamed geometry). A thin nodebox grazing the box
            // -- an opening door in a 2-tall hallway -- must NOT eject, or it
            // shoots the player up through the ceiling onto the roof. Gate on the
            // node at mid-body being a full cube (or unstreamed-solid).
            let midNode = client.world.nodeId(SIMD3(Int(floor(feet.x)),
                Int(floor(feet.y + playerHeight * 0.5)), Int(floor(feet.z))))
            // Eject up ONLY when inside genuinely-streamed solid rock (spawn/
            // teleport into an igloo or stone, #242). If the surrounding terrain is
            // merely UNSTREAMED (IGNORE), do NOT eject: solidBoxes treats IGNORE as
            // full cubes, so a cave spawn (y=-50, nothing loaded yet) got shoved
            // skyward tick after tick, all the way to y=718 (#252). Hold height and
            // wait for the real cave to stream in, then gravity settles onto it.
            let insideSolid = midNode != WorldMap.CONTENT_IGNORE &&
                client.nodes.isWalkable(midNode) && client.nodes.kind(midNode) == .cube
            // Never while climbing: a ladder shaft bottom is a legitimate tight
            // spot, and the shaft above is where the player wants to stay (#303).
            if insideSolid, !climbing, embeddedCount(out) == base, base > 0 {
                var probe = out, yy = out.y
                let ceiling = out.y + 5   // don't teleport across the world
                while yy < ceiling {
                    yy += 0.25; probe.y = yy
                    let pb = playerBox(probe)
                    // Test the REAL column, not just `solids`: those were gathered
                    // around this tick's move and reach ~2.4 nodes up, so anything
                    // higher looked clear and a player under an igloo was lifted 3
                    // nodes a tick through solid rock into the room above (#303).
                    // Unstreamed nodes count as solid here too, so a not-yet-loaded
                    // ceiling holds the player instead of launching them.
                    if !solids.contains(where: { $0.overlaps(pb) }), !anySolidBox(around: pb) {
                        print("[eject] feet=\(feet) -> y=\(yy) mid=\(client.nodes.name(midNode))"); fflush(stdout)
                        return (SIMD3(out.x, yy, out.z), false, false)
                    }
                }
            }
            return (out, true, false)
        }
        let eps: Float = 1e-4
        // A box we are already inside by less than this, on the axis we're
        // moving along, still counts as a collision (collision.cpp inner_margin,
        // 0.2 node). Without it a teleport / MOVE_PLAYER_REL / respawn that lands
        // the feet a hair inside a slab, carpet or snow layer fell straight
        // through it when standing still (the step-up only rescues you once you
        // push the stick).
        let inner: Float = 0.2
        // --- Y: land on the highest top below, or stop under the lowest ceiling.
        // Test the whole vertical path (start box to end box), not just the end
        // box: a big step (first tick after spawn, a long frame) used to drop
        // the end box clean past a 1-node floor and land on whatever was under it.
        if delta.y != 0 {
            let start = playerBox(feet)
            feet.y += delta.y
            let end = playerBox(feet)
            let path = AABB(lo: simd_min(start.lo, end.lo), hi: simd_max(start.hi, end.hi))
            for s in solids where s.overlaps(path) {
                if delta.y < 0 {
                    // A floor is a top at (or a hair above) where the feet started.
                    if s.hi.y <= start.lo.y + inner { feet.y = max(feet.y, s.hi.y + eps); hitFloor = true }
                } else {
                    // A ceiling is an underside at (or a hair below) where the head started.
                    if s.lo.y >= start.hi.y - inner { feet.y = min(feet.y, s.lo.y - playerHeight - eps); hitCeil = true }
                }
            }
        }
        // --- X then Z, each with step-up, else slide up to the blocking face.
        // One pass over the candidate solids per axis: track whether anything
        // blocks, the highest top (for step-up), and the nearest blocking face,
        // instead of allocating filter/map arrays every physics tick (#187).
        for axis in [0, 2] {
            let d = axis == 0 ? delta.x : delta.z
            if d == 0 { continue }
            var trial = feet
            if axis == 0 { trial.x += d } else { trial.z += d }
            let tb = playerBox(trial)
            var blocked = false
            var top = -Float.greatestFiniteMagnitude
            var face: Float = d > 0 ? .greatestFiniteMagnitude : -.greatestFiniteMagnitude
            for s in solids where s.overlaps(tb) {
                blocked = true
                if s.hi.y > top { top = s.hi.y }
                let lo = axis == 0 ? s.lo.x : s.lo.z
                let hi = axis == 0 ? s.hi.x : s.hi.z
                if d > 0 { if lo < face { face = lo } } else { if hi > face { face = hi } }
            }
            if !blocked { feet = trial; continue }
            // Step-up like Luanti: 0.6 node while grounded (slabs/stairs walked
            // up with no jump), 0.2 node while airborne. The airborne step is the
            // key to clearing a FULL 1-node block: once a jump lifts the feet to
            // ~0.8, the ledge top (1.0) is within 0.2 and the player is admitted
            // onto it, instead of needing a frame to land at the razor-thin apex.
            let sh: Float = grounded ? playerStep : 0.2
            if top > feet.y, top - feet.y <= sh {
                var up = trial; up.y = top + eps
                if !solids.contains(where: { $0.overlaps(playerBox(up)) }) { feet = up; hitFloor = true; continue }
            }
            let blockedFace = d > 0 ? face - playerHW - eps : face + playerHW + eps
            if axis == 0 { feet.x = blockedFace } else { feet.z = blockedFace }
        }
        return (feet, hitFloor, hitCeil)
    }

    /// Highest solid (non-liquid) node in column (x,z) at or below near+3,
    /// scanning deep so the player snaps onto the surface even when spawned high
    /// above it; nil if the column isn't loaded there.
    private func groundHeight(x: Int, z: Int, near: Int, maxDrop: Int = 300) -> Int? {
        var cur = WorldMap.BlockCursor()   // vertical column: 16 y's share a block
        for y in stride(from: near + 3, through: near - maxDrop, by: -1) {
            let id = client.world.nodeId(SIMD3(x, y, z), &cur)
            if id == WorldMap.CONTENT_IGNORE { continue }   // unloaded — skip
            if id == WorldMap.CONTENT_AIR || client.nodes.isLiquid(id) { continue }
            // Don't stand on non-walkable decorations (grass tufts, flowers,
            // torches, rails, signs) -- you should pass through them, not step up.
            switch client.nodes.kind(id) {
            case .plant, .torch, .rail, .sign: continue
            default: return y
            }
        }
        return nil
    }

    /// Publish the wielded item + hotbar as node-atlas layers for the renderer to
    /// draw anchored to the hands (#66 wield item, #57 wrist hotbar). Resolves the
    /// same icon tiles the head-locked hotbar uses.
    private func postHandHud() {
        // Per-slot durability: wear rides the "main" list (the base-name hotbar
        // icons drop it), so a damaged tool in the hotbar shows a wear bar on its
        // ring cell too, not just when wielded (#106).
        let main = client.inventory["main"]
        var slots: [HandHudState.Icon?] = []
        for (i, tile) in hotbarIcons.enumerated() {
            guard let tile, let l = atlas.tileLayer(tile) else { slots.append(nil); continue }
            var wear: Float = 1
            if let m = main, i < m.count, let st = m[i], st.wear > 0 { wear = Float(65535 - st.wear) / 65535 }
            slots.append(.init(layer: l, uv: SIMD2(1, 1), wear: wear))
        }
        let wi = client.wieldIndex
        // Wield visual like desktop: a real 3D block for node items, else the flat
        // icon (extruded to a slab in the renderer).
        var wield: HandHudState.Wield?
        var wieldTile: String?   // icon tile for the item silhouette (nil for blocks)
        var wieldName = (wi >= 0 && wi < hotbar.count) ? hotbar[wi] : nil
        #if targetEnvironment(simulator)
        // -vrdev.wield <itemstring> forces the wielded item by name so the mesh
        // wield branch (chests/beds) and item silhouettes can be screenshotted
        // headless -- fakeWield only ever stubs a cube, so it never reached here.
        if let forced = UserDefaults.standard.string(forKey: "vrdev.wield"), !forced.isEmpty {
            wieldName = forced
        }
        #endif
        if let name = wieldName, let id = client.nodes.id(for: name), id != WorldMap.CONTENT_AIR {
            switch client.nodes.kind(id) {
            case .cube:
                wield = .block(faceLayers: (0..<6).map { atlas.layer(id: id, face: $0) })
            case .mesh:
                // Draw the actual model (chest etc), not a cube, once its .b3d has
                // downloaded; else fall through to the flat icon below.
                if let model = nodeMeshModel(for: id) {
                    wield = .mesh(model: model, layer: Int32(atlas.layer(id: id, face: 0)))
                }
            default:
                break
            }
        }
        if wield == nil, let ic = (wi >= 0 && wi < slots.count) ? slots[wi] : nil {
            wield = .item(layer: ic.layer, uv: ic.uv)
            wieldTile = (wi >= 0 && wi < hotbarIcons.count) ? hotbarIcons[wi] : nil
        }
        // Remaining durability of the wielded stack (wear rides the main list,
        // not the base-name hotbar), so the held tool can show a wear bar.
        var wieldWear: Float = 1
        if wi >= 0, let m = client.inventory["main"], wi < m.count, let st = m[wi], st.wear > 0 {
            wieldWear = Float(65535 - st.wear) / 65535
        }
        // Stack count on the hand (#158): a stack >1 (torches, blocks, food) bakes
        // its number into a model-texture layer; the renderer draws it near the
        // hand. Tools carry wear instead, and never stack, so there's no conflict.
        var wieldCountLayer: Int32 = -1, wieldCountAspect: Float = 1
        if wi >= 0, let m = client.inventory["main"], wi < m.count, let st = m[wi], st.count > 1,
           let r = hudTextLayer(id: -777, text: "\(st.count)") {
            wieldCountLayer = Int32(r.layer); wieldCountAspect = r.aspect
        }
        #if targetEnvironment(simulator)
        // The sim dev account has an empty inventory, so nothing wields. Stub a
        // wield item + a few hotbar cells so the wield pose, wrist ring, and wear
        // bar can be screenshotted headless. Use a REAL opaque node (not the slot
        // frame, whose transparent centre alpha-cutouts to nothing at cell size)
        // so the geometry is actually visible. -vrdev.fakeWield 1.
        if UserDefaults.standard.bool(forKey: "vrdev.fakeWield") {
            // First loaded cube node wins (dirt/grass/stone/cobble in practice).
            let fakeId = ["mcl_core:dirt_with_grass", "mcl_core:dirt", "mcl_core:stone",
                          "mcl_core:cobble", "default:dirt", "default:stone"]
                .compactMap { client.nodes.id(for: $0) }
                .first { client.nodes.kind($0) == .cube && $0 != WorldMap.CONTENT_AIR }
            // -vrdev.fakeWieldItem forces the item path (tools/craftitems) instead
            // of a block cube, to eyeball the pickaxe-style wield. Prefer a REAL
            // tool icon (transparent background) so the extruded silhouette shows
            // its shape headless; fall back to a node icon if none is baked yet.
            let forceItem = UserDefaults.standard.bool(forKey: "vrdev.fakeWieldItem")
            // Pick any baked item icon whose alpha extrudes to a real silhouette
            // (transparent background), preferring a pickaxe, so the sim shows a
            // shaped tool rather than a solid square.
            let toolIcon: (layer: Int32, tile: String)? = forceItem
                ? client.items.allImages()
                    .sorted { (a, b) in (a.contains("pick") ? 0 : 1, a) < (b.contains("pick") ? 0 : 1, b) }
                    .lazy
                    .compactMap { spec in self.atlas.tileLayer(spec).map { (Int32($0), spec) } }
                    .first(where: { self.wieldSilhouette(for: $0.1) != nil })
                : nil
            if let id = fakeId {
                if wield == nil {
                    if forceItem, let t = toolIcon {
                        wield = .item(layer: t.layer, uv: SIMD2(1, 1)); wieldTile = t.tile
                    } else if forceItem {
                        wield = .item(layer: atlas.layer(id: id, face: 0), uv: SIMD2(1, 1))
                    } else {
                        wield = .block(faceLayers: (0..<6).map { atlas.layer(id: id, face: $0) })
                    }
                }
                if slots.allSatisfy({ $0 == nil }) {
                    let icon = atlas.layer(id: id, face: 0)   // top face as a flat cell icon
                    // Vary wear across the fake cells so the per-slot wear bar (#106) shows headless.
                    let wears: [Float] = [1, 0.7, 0.35, 0.1]
                    for i in 0..<min(4, slots.count) { slots[i] = .init(layer: icon, uv: SIMD2(1, 1), wear: wears[i]) }
                }
            } else {
                // No cube node loaded yet: fall back to the (semi-visible) slot frame.
                if wield == nil { wield = .item(layer: atlas.hotbarSlotLayer, uv: SIMD2(1, 1)) }
                if slots.allSatisfy({ $0 == nil }) {
                    for i in 0..<min(4, slots.count) { slots[i] = .init(layer: atlas.hotbarSlotLayer, uv: SIMD2(1, 1)) }
                }
            }
            if wieldCountLayer < 0 { wieldWear = 0.4 }   // count and wear never coexist
        }
        #endif
        // Extrude the wielded tool's icon into a 3D silhouette (nil for blocks or
        // solid-square icons, which the cube/flat slab handle).
        let sil = wieldTile.flatMap { wieldSilhouette(for: $0) }
        var digging = digNode != nil            // drives the wield swing (#136)
        var armorForHud = armor
        #if targetEnvironment(simulator)
        if UserDefaults.standard.bool(forKey: "vrdev.fakeSwing") { digging = true }
        // Sim: stub a stack count so the hand count (#158) shows headless. The
        // fake wield is a block, so a count reads naturally (torch stack, blocks).
        if wieldCountLayer < 0, UserDefaults.standard.bool(forKey: "vrdev.fakeWield"),
           case .block? = wield, let r = hudTextLayer(id: -777, text: "64") {
            wieldCountLayer = Int32(r.layer); wieldCountAspect = r.aspect; wieldWear = 1
        }
        #endif
        #if targetEnvironment(simulator)
        if armorForHud == 0, UserDefaults.standard.bool(forKey: "vrdev.fakeWield") { armorForHud = 15 }
        #endif
        // Shade the wield item by the light where the player stands, like desktop:
        // a held torch in a dark cave shouldn't render full-bright and read as if
        // it lights the area (our client can't do held light; it's server-baked).
        // Fall back to full-bright while the eye node is unstreamed (IGNORE) so
        // the item isn't black at spawn/teleport before terrain arrives.
        var wieldLight: Float = 255
        let eyeP = player.hasHead() ? player.rayOrigin() : player.snapshot().feet + SIMD3(0, player.eyeHeight, 0)
        let eyeNode = SIMD3(Int(floor(eyeP.x)), Int(floor(eyeP.y)), Int(floor(eyeP.z)))
        if client.world.nodeId(eyeNode) != WorldMap.CONTENT_IGNORE {
            wieldLight = Float(client.world.nodeLight(eyeNode))
        }
        #if targetEnvironment(simulator)
        if UserDefaults.standard.bool(forKey: "vrdev.fakeWield") { wieldLight = 255 }  // keep headless wield visible
        #endif
        // HUD_SET_FLAGS: bit 8 wielditem (mcl_shields hides the hand while
        // blocking, the spyglass while zoomed), bit 1 hotbar (#290).
        let hudF = client.hudFlags
        handHudHandoff.post(HandHudState(wield: hudF & 8 != 0 ? wield : nil, digging: digging, wieldLight: wieldLight,
                                         wieldSilhouette: hudF & 8 != 0 ? sil : nil, wieldWear: wieldWear,
                                         wieldScale: wieldName.map { max(0.5, min(2.5, client.items.wieldScale(for: $0).x)) } ?? 1,
                                         wieldCountLayer: wieldCountLayer, wieldCountAspect: wieldCountAspect,
                                         hotbar: hudF & 1 != 0 ? slots : [], wieldIndex: wi,
                                         slotLayer: atlas.hotbarSlotLayer,
                                         selectLayer: atlas.hotbarSelectLayer,
                                         whiteLayer: atlas.markerLayer,
                                         armor: armorForHud,
                                         armorFullLayer: atlas.armorFullLayer,
                                         armorHalfLayer: atlas.armorHalfLayer,
                                         armorEmptyLayer: atlas.armorEmptyLayer))
    }

    /// A node changed at `p` (dig/place): re-mesh its mapblock and the six
    /// neighbour blocks, so a border face newly exposed or covered is picked up.
    /// Local dig prediction: turn the dug node into its node_dig_prediction target
    /// if it declares one (rare; most nodes dig to air), else remove it. Matches
    /// Luanti's predicted result so the right node/hole shows before the server
    /// round-trip (#178).
    private func applyDigPrediction(at p: SIMD3<Int>, id: UInt16) {
        let pred = client.nodes.digPrediction(id) ?? "air"
        if pred.isEmpty { return }   // explicit "": no prediction, the server's answer stands (#297)
        if let pid = client.nodes.id(for: pred), pid != WorldMap.CONTENT_AIR {
            client.world.setNode(p, param0: pid)
        } else {
            client.world.removeNode(p)
        }
    }

    private func markNodeDirty(_ p: SIMD3<Int>) {
        dirtyBlocks.insert(WorldMap.blockPos(p))
        for n in Self.neighborOffsets { dirtyBlocks.insert(WorldMap.blockPos(p &+ n)) }
        dirty = true
    }
    /// A whole mapblock arrived/changed (stream): re-mesh it and its neighbours.
    private func markBlockDirty(_ b: SIMD3<Int>) {
        dirtyBlocks.insert(b)
        for n in Self.neighborOffsets { dirtyBlocks.insert(b &+ n) }
        dirty = true
    }

    /// Snapshot the world on the session queue, then mesh + build Metal buffers
    /// on the mesher queue so neither the poll loop nor the render thread does
    /// the heavy work. `meshing` is cleared back on the session queue when done.
    /// Incremental: only dirty mapblocks are re-meshed; the cache is then
    /// concatenated into the combined buffer the renderer wants.
    private func scheduleRemesh(meshRef: SIMD3<Float>) {
        if !atlasBuilt && !client.nodes.faceTiles.isEmpty { rebuildAtlas() }
        guard atlasBuilt else { meshing = false; return }   // no atlas yet, nothing to draw
        let snap = client.world.snapshot()
        let atlas = self.atlas
        let nodes = client.nodes
        let models = nodeModels()   // content id -> parsed .obj/.b3d, media store read here
        // Co-post the atlas texture with this mesh when it grew, so the renderer
        // swaps both together (mesh was built against exactly these layers).
        // Keyed on a rebuild counter, NOT the layer count: adding an item icon
        // that is also a node face tile keeps the count identical but shifts every
        // layer after it, so the renderer kept the old texture while the mesh
        // was rebuilt against the new order (every block drew the wrong tile).
        let atlasLayers: [[UInt8]]? = atlasGeneration != lastPostedAtlasGen ? atlas.layers : nil
        if atlasLayers != nil { lastPostedAtlasGen = atlasGeneration }
        // Animated tile frames travel with the atlas (#137); captured on the
        // session queue so the mesher block doesn't touch the atlas cross-thread.
        let atlasAnim: [TextureAtlas.AnimLayer] = atlasLayers != nil ? atlas.animatedLayers : []
        // Capture + clear the dirty set for this pass (session queue). A new atlas
        // can shift which layer a tile resolves to for any block, so it forces a
        // full rebuild via fullRemesh (set in rebuildAtlas).
        let doFull = fullRemesh
        let dirtySet = dirtyBlocks
        fullRemesh = false
        dirtyBlocks.removeAll(keepingCapacity: true)

        mesherQueue.async { [weak self] in
            guard let self else { return }
            let live = Set(snap.blocks.keys)
            let rebuildAll = doFull || self.blockCache.isEmpty || self.cachedMeshRef != meshRef
            self.cachedMeshRef = meshRef

            @inline(__always)
            func mesh(_ bpos: SIMD3<Int>) -> BlockGeom {
                let m = WorldMesher.build(snap, atlas: atlas, nodes: nodes, origin: meshRef,
                                          scale: PlayerState.scale, models: models, only: [bpos])
                return ((m.opaque.vertices, m.opaque.solid, m.opaque.cutout), (m.liquid.vertices, m.liquid.indices))
            }

            // Re-mesh the changed blocks and hand them to the renderer as a
            // per-block DELTA (#183): a dig/place rebuilds only the touched
            // blocks and posts just those, instead of re-concatenating and
            // re-uploading every loaded block into one giant buffer every edit.
            // Block indices are already local (build ran with only:[bpos]), so
            // they go straight to the renderer's per-block draw with no rebasing.
            @inline(__always)
            func raw(_ g: BlockGeom) -> MeshHandoff.BlockRaw {
                MeshHandoff.BlockRaw(ov: g.opaque.v, solid: g.opaque.solid, cutout: g.opaque.cutout,
                                     lv: g.liquid.0, li: g.liquid.1)
            }
            var changedRaw: [SIMD3<Int>: MeshHandoff.BlockRaw] = [:]
            var removedBlocks: [SIMD3<Int>] = []
            if rebuildAll {
                self.blockCache.removeAll(keepingCapacity: true)
                for bpos in live {
                    let g = mesh(bpos); self.blockCache[bpos] = g; changedRaw[bpos] = raw(g)
                }
            } else {
                for bpos in dirtySet {
                    if live.contains(bpos) {
                        let g = mesh(bpos); self.blockCache[bpos] = g; changedRaw[bpos] = raw(g)
                    } else if self.blockCache[bpos] != nil {
                        self.blockCache[bpos] = nil; removedBlocks.append(bpos)   // block unloaded
                    }
                }
                // Drop stale cache entries for blocks the world unloaded. Collect
                // keys first (don't mutate the dict mid-iteration): a block can
                // unload while another loads, leaving a ghost entry.
                let stale = self.blockCache.keys.filter { !live.contains($0) }
                for k in stale { self.blockCache[k] = nil; removedBlocks.append(k) }
            }

            let posted = self.handoff.postDelta(changed: changedRaw, removed: removedBlocks,
                                                reset: rebuildAll, atlasLayers: atlasLayers, animated: atlasAnim)
            // First real geometry posted: tell the launcher the world is ready to
            // show, so it can drop its spinner and reveal the immersive space.
            // Solid OR cutout counts: after the #164 opaque/cutout split, a spawn
            // ringed by only solid cubes (stone/dirt, no plants/leaves/glass) has
            // an empty cutout stream, and gating on cutout alone left the loader
            // spinning forever there (regression of #74).
            let hasWorldGeom = changedRaw.values.contains { !$0.solid.isEmpty || !$0.cutout.isEmpty }
            if posted, hasWorldGeom {
                if !self.worldReadyLogged { self.worldReadyLogged = true; print("[session] world ready (first geometry posted) \(PerfStats.uptime())"); fflush(stdout) }
                DispatchQueue.main.async { [weak self] in
                    self?.appModel?.worldReady = true
                    self?.appModel?.connPhase = .playing
                }
            }
            self.queue.async {
                self.meshing = false
                // Device not ready yet: retry, and force a full re-post so the
                // delta we just dropped isn't lost (blockCache is already updated,
                // so a plain retry would have nothing dirty to re-send).
                if !posted { self.dirty = true; self.fullRemesh = true }
                // connProblem is session-queue state (setPhase writes it, the
                // status banner reads it), so clear the "Connecting/Reconnecting"
                // banner here, not on the mesher queue this block runs on.
                if posted, hasWorldGeom { self.connProblem = nil }
            }
        }
    }

    /// (Re)build the texture atlas from current node tiles + downloaded media,
    /// hand the layers to the renderer, and force a remesh so layer indices match.
    private func rebuildAtlas() {
        guard !client.nodes.faceTiles.isEmpty else { return }
        if atlasBuilt && client.media.store.count == lastAtlasStore && !atlasNeedsRebuild { return }   // nothing new
        atlasNeedsRebuild = false
        sinceMediaAtlas = 0   // reset the media-coalesce clock on any real rebuild (#188)
        lastAtlasStore = client.media.store.count
        // Coalesce: if a build is already running, ask it to run once more when it
        // lands (media/tiles may have grown since it started) instead of stacking
        // concurrent bakes.
        if atlasBuilding { atlasRebuildPending = true; return }
        atlasBuilding = true
        // Snapshot the inputs on the session queue. `nodes` is effectively
        // immutable after join (NODEDEF), same as the mesher reads it off-queue;
        // `media` we copy because poll keeps mutating its store as files arrive.
        let nodes = client.nodes
        let media = client.media.snapshot()
        let extra = Array(client.objects.tiles) + Array(hotbarTiles)
            + client.nodes.specialTilesSnapshot()   // plantlike_rooted plant tiles (kelp, coral)
            + client.nodes.overlayTilesSnapshot()   // tiles_overlay (grass-block side fringe)
        // Append-only rebuild: seed the new atlas from the current one so every
        // existing tile keeps its layer index and only new tiles get numbers.
        // Building from an empty atlas renumbered everything, and anything that
        // held an index across the swap sampled the wrong tile (#256/#201/#202/
        // #254). Seeding happens here on the session queue; `a` is then private
        // to the build thread until it's swapped back in below.
        let prev = atlas, dropTiles = atlasDropTiles
        atlasDropTiles.removeAll()
        #if DEBUG
        let prevIndex = prev.tileIndexSnapshot
        #endif
        atlasQueue.async { [weak self] in
            let a = TextureAtlas()
            let tBuild = CFAbsoluteTimeGetCurrent()
            a.seed(from: prev, dropping: dropTiles)
            a.build(nodes: nodes, media: media, extraTiles: extra)
            let buildMs = Int((CFAbsoluteTimeGetCurrent() - tBuild) * 1000)
            guard let self else { return }
            self.queue.async {
                #if DEBUG
                // Tripwire: the append-only invariant. Any prior tile whose index
                // moved is exactly the stale-index bug; fail loud in the sim
                // instead of waiting for snow to visibly turn into dirt.
                for (name, old) in prevIndex where !dropTiles.contains(name) {
                    let now = a.tileLayer(name).map(Int.init)
                    assert(now == old, "atlas remap: \(name) \(old) -> \(String(describing: now))")
                }
                #endif
                self.atlas = a
                self.atlasBuilt = true
                self.atlasGeneration += 1
                self.nodeIconCache.removeAll()   // a face may now have a real tile (was nil = no icon)
                // The atlas travels to the renderer WITH the next remesh
                // (scheduleRemesh), so the swapped texture always matches the
                // mesh's layer indices.
                // Only remesh when a tile a block actually uses moved layers.
                // Append-only means a rebuild that just added icon/mob/particle
                // tiles touches no existing face, so the full-world remesh (and
                // its buffer reset + residency storm) is pure waste -- the new
                // atlas still co-posts with the next delta (scheduleRemesh keys
                // the texture on atlasGeneration, not fullRemesh). A colour ->
                // real-pixel flip when media lands is the case that does remesh.
                let faceChanges = a.changedFaceIds.count
                print("[session] atlas: \(a.layerCount) layers, media=\(self.lastAtlasStore), faceChanges=\(faceChanges) build=\(buildMs)ms \(PerfStats.uptime())"); fflush(stdout)
                if faceChanges > 0 { self.fullRemesh = true }
                self.dirty = true   // always: carry the grown atlas to the renderer
                self.atlasBuilding = false
                // A rebuild was asked for mid-build (media/tiles grew since this
                // bake started): force it, since the dedup guard would otherwise
                // see the store count we already recorded and skip it.
                if self.atlasRebuildPending {
                    self.atlasRebuildPending = false
                    self.atlasNeedsRebuild = true
                    self.rebuildAtlas()
                }
            }
        }
    }
}
