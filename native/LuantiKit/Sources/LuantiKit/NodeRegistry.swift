import Foundation
import os
import simd

/// Node definitions from TOCLIENT_NODEDEF: content id -> name, per-face tile
/// texture names, and a fallback colour classified from the name. Real textures
/// come from the media pipeline + TextureAtlas; the colour is used when a tile's
/// PNG isn't available or can't be decoded.
public final class NodeRegistry {
    // parseNodeDef runs on the network thread; the mesher and atlas read these
    // dictionaries on their own threads. Without this lock, a relaunch that
    // re-parses NODEDEF while a remesh is in flight corrupted the dictionary
    // and crashed with `objectForKey:` on a garbage tagged pointer. Readers
    // lock per call; the parse holds the lock once around the whole write.
    private let lock = OSAllocatedUnfairLock()
    public private(set) var names: [UInt16: String] = [:]
    /// Six face tile names (base image, modifiers stripped) per content id, in
    /// Luanti tile/wire order +Y,-Y,+X,-X,+Z,-Z (matches WorldMesher's Face.tile
    /// indices and the atlas faceLayers). Empty entry means "no texture, use colour".
    public private(set) var faceTiles: [UInt16: [String]] = [:]
    /// Base image name -> vertical-frames animation cycle seconds (#137: lava,
    /// fire, furnace). The atlas cycles these layers' pixels over time.
    public private(set) var tileAnimSecs: [String: Float] = [:]
    private var colorCache: [UInt16: SIMD3<Float>] = [:]
    /// How each content id should be meshed (from its drawtype).
    public enum RenderKind: UInt8 { case cube, plant, nodebox, torch, rail, allfaces, sign, mesh, skip, rooted, fire }
    private var kinds: [UInt16: RenderKind] = [:]
    // Custom model file (.obj/.b3d) and visual_scale for mesh-drawtype nodes.
    private var meshFiles: [UInt16: String] = [:]
    private var visualScales: [UInt16: Float] = [:]
    public func meshFile(_ id: UInt16) -> String? { lock.withLockUnchecked { meshFiles[id] } }
    public func visualScale(_ id: UInt16) -> Float { lock.withLockUnchecked { visualScales[id] ?? 1 } }
    /// content id -> model file for every mesh-drawtype node (for model loading).
    public func meshNodes() -> [UInt16: String] { lock.withLockUnchecked { meshFiles } }
    public func allNames() -> [UInt16: String] { lock.withLockUnchecked { names } }
    /// Model file names referenced by mesh nodes, so the media layer fetches them.
    public func meshFileNames() -> Set<String> { lock.withLockUnchecked { Set(meshFiles.values) } }
    private var liquids: Set<UInt16> = []
    // Light flags for the client-side relight on ADDNODE/REMOVENODE (#278):
    // the engine relights locally (Map::addNodeAndUpdate ->
    // voxalgo::update_lighting_nodes) and the server does NOT resend relit
    // blocks to the placing player, so without this a placed torch lit only
    // its own cell.
    private var lightPropagates: Set<UInt16> = []
    private var sunlightPropagates: Set<UInt16> = []
    private var lightSources: [UInt16: UInt8] = [:]
    /// glasslike / glasslike_framed(_optional) ids: meshed as cubes but see-
    /// through, so they never hide a neighbour's face (a stone wall behind a
    /// window used to lose its face and read as x-ray, #265). Luanti culls only
    /// the faces shared between two glass nodes of the same content.
    private var glasslike: Set<UInt16> = []
    private var lavas: Set<UInt16> = []
    /// True for lava (and other hot liquids): rendered opaque, warm, and self-lit
    /// instead of getting water's translucent blue treatment.
    public func isLava(_ id: UInt16) -> Bool { lock.withLockUnchecked { lavas.contains(id) } }
    private var drawtypes: [UInt16: Int] = [:]
    public func drawtype(_ id: UInt16) -> Int { lock.withLockUnchecked { drawtypes[id] ?? 0 } }
    /// Fully-solid opaque node (Luanti NDT_solidness == 2: only NDT_NORMAL and
    /// NDT_PLANTLIKE_ROOTED). Glass/leaves/nodebox/mesh are NOT solid here, so
    /// the head can see through them. Used for the in-a-wall black-out (#60).
    public func isSolidCube(_ id: UInt16) -> Bool {
        lock.withLockUnchecked { let dt = drawtypes[id] ?? 0; return (dt == 0 || dt == 17) && (walkables[id] ?? false) }
    }
    // Biome-palette tinting: param_type_2 (8=color, 9=colorfacedir, ...) and the
    // palette image name, per content id. param2 indexes the palette.
    private var paramType2s: [UInt16: Int] = [:]
    private var lightParamIds: Set<UInt16> = []   // ids with param_type == CPT_LIGHT
    // plantlike_rooted only: the plant texture (special_tiles[0]) drawn above the
    // solid base. Kept separate from faceTiles since only this drawtype uses it.
    private var specialTiles: [UInt16: String] = [:]
    // tiles_overlay per face (6 entries, "" = none), only for nodes that have
    // one: the engine draws it as a second layer over the base tile
    // (node_visuals.cpp), e.g. the grass fringe on a grass block's dirt sides.
    private var overlayTiles: [UInt16: [String]] = [:]
    // Per-face TileDef has_color: the tile keeps its own colour and skips the
    // node's palette tint (mapblock_mesh.cpp applies the tint only when the
    // tile has no colour of its own). Only stored for nodes where some face
    // sets it; VoxeLibre marks grass-block sides color="white".
    private var faceColorOverride: [UInt16: [Bool]] = [:]
    private var paletteNames: [UInt16: String] = [:]
    public private(set) var palettes: Set<String> = []   // palette image names to download
    public func paramType2(_ id: UInt16) -> Int { lock.withLockUnchecked { paramType2s[id] ?? 0 } }
    /// The plant texture for a plantlike_rooted node (nil for every other node).
    public func specialTile(_ id: UInt16) -> String? { lock.withLockUnchecked { specialTiles[id] } }
    /// All plantlike_rooted plant textures, so one atlas build bakes them (fed in
    /// as extraTiles the same way entity/hotbar tiles are).
    public func specialTilesSnapshot() -> [String] { lock.withLockUnchecked { Array(specialTiles.values) } }
    /// The 6 overlay tiles ("" for a face without one), nil when the node has none.
    public func overlayTiles(_ id: UInt16) -> [String]? { lock.withLockUnchecked { overlayTiles[id] } }
    /// Every overlay tile, so the atlas bakes them (fed in as extraTiles).
    public func overlayTilesSnapshot() -> [String] {
        lock.withLockUnchecked { overlayTiles.values.flatMap { $0 }.filter { !$0.isEmpty } }
    }
    /// Per face, true when the tile has its own colour (skip the palette
    /// tint); nil when no face does.
    public func faceColorOverrides(_ id: UInt16) -> [Bool]? { lock.withLockUnchecked { faceColorOverride[id] } }
    public func paletteName(_ id: UInt16) -> String? { lock.withLockUnchecked { paletteNames[id] } }

    /// An axis-aligned box in node-local space (Luanti's -0.5...0.5 range).
    public struct Box { public let min: SIMD3<Float>; public let max: SIMD3<Float> }
    /// Collision/visual boxes for nodebox and fencelike nodes (slabs, stairs,
    /// walls, fence posts). Empty/absent for everything else.
    private var nodeBoxes: [UInt16: [Box]] = [:]
    public func boxes(_ id: UInt16) -> [Box]? { lock.withLockUnchecked { nodeBoxes[id] } }
    // Connected nodeboxes (fences/walls/panes): the 6 connect arm box-lists
    // (top,bottom,front,left,back,right) and the set of content ids this node
    // connects to. The mesher/collision add an arm when the neighbour in that
    // direction is in the set.
    private var connectBoxes: [UInt16: [[Box]]] = [:]
    private var connectsTo: [UInt16: Set<UInt16>] = [:]
    public func connectArms(_ id: UInt16) -> [[Box]]? { lock.withLockUnchecked { connectBoxes[id] } }
    public func connectsToSet(_ id: UInt16) -> Set<UInt16>? { lock.withLockUnchecked { connectsTo[id] } }
    /// connect_sides bitmask (1 top, 2 bottom, 4 front -Z, 8 left -X, 16 back
    /// +Z, 32 right +X; 0 = unspecified). It belongs to the TARGET of a
    /// connection: a fence with front/back/left/right refuses a pane arm from
    /// above or below (NodeDefManager::nodeboxConnects) (#299).
    private var connectSidesMask: [UInt16: UInt8] = [:]
    public func connectSides(_ id: UInt16) -> UInt8 { lock.withLockUnchecked { connectSidesMask[id] ?? 0 } }
    /// nodedef `waving`: 1 = plants (only the top vertices sway), 2 = leaves
    /// (the whole node wobbles); 0 = still. Liquids (3) wave in their own
    /// pass already. Drives the shader wave class (#300).
    private var wavingClass: [UInt16: UInt8] = [:]
    public func waving(_ id: UInt16) -> UInt8 { lock.withLockUnchecked { wavingClass[id] ?? 0 } }

    /// NodeDefManager::nodeboxConnects: `from` (a connected nodebox) grows an
    /// arm toward `to` on face `dir` (0 top .. 5 right, the arm order) when
    /// `to` is in its connects_to set AND (`to` is itself a connected nodebox
    /// that lists `from` back, or `to` declares no connect_sides, or the face
    /// is in `to`'s connect_sides). The facedir rotation table for rotated
    /// targets is skipped: VoxeLibre's fences/panes/chorus don't rotate.
    public func nodeboxConnects(from: UInt16, to: UInt16, dir: Int) -> Bool {
        lock.withLockUnchecked {
            guard let cset = connectsTo[from], cset.contains(to) else { return false }
            if connectBoxes[to] != nil { return connectsTo[to]?.contains(from) ?? false }
            let mask = connectSidesMask[to] ?? 0
            return mask == 0 || (mask & UInt8(1 << dir)) != 0
        }
    }
    // collision_box, kept separately from the visual node_box: a fence's collision
    // post is 1.5 nodes tall so you can't jump it, while its visual post is 1.0
    // (#214). Physics prefers these when present, else falls back to node_box.
    private var collisionBoxes: [UInt16: [Box]] = [:]
    private var collisionConnectBoxes: [UInt16: [[Box]]] = [:]
    public func collisionBoxesFor(_ id: UInt16) -> [Box]? { lock.withLockUnchecked { collisionBoxes[id] } }
    public func collisionConnectArms(_ id: UInt16) -> [[Box]]? { lock.withLockUnchecked { collisionConnectBoxes[id] } }
    private var dugSounds: [UInt16: String] = [:]   // node -> "dug" sound group name
    public func dugSound(_ id: UInt16) -> String? { lock.withLockUnchecked { dugSounds[id] } }
    /// Luanti's `walkable`: the node participates in player/object collision.
    /// Unknown ids (unloaded edge) default to solid so you can't fall out of the
    /// loaded region; a parsed node that lacked the flag reads as not solid.
    private var walkables: [UInt16: Bool] = [:]
    public func isWalkable(_ id: UInt16) -> Bool {
        // Air is never solid, defined or not: NODEDEF doesn't always carry an
        // "air" entry, and an unknown id otherwise reads as solid (unloaded).
        if id == WorldMap.CONTENT_AIR { return false }
        return lock.withLockUnchecked { walkables[id] ?? (names[id] == nil) }
    }
    /// Luanti's `climbable`: while the player box overlaps one, they can ascend/
    /// descend and their fall is arrested (ladders, vines).
    private var climbables: Set<UInt16> = []
    public func isClimbable(_ id: UInt16) -> Bool { lock.withLockUnchecked { climbables.contains(id) } }
    /// Nodes whose node_box is type="wallmounted": its 3 boxes are wall_top,
    /// wall_bottom, wall_side and exactly ONE is drawn, picked by the wallmounted
    /// param2 (buttons, floor heads). Without this they'd draw as all three at
    /// once (a plus-clump). See WorldMesher.wallmountedBox (#212).
    private var wallmountedBoxes: Set<UInt16> = []
    public func isWallmountedBox(_ id: UInt16) -> Bool { lock.withLockUnchecked { wallmountedBoxes.contains(id) } }
    /// Same, but for a wallmounted SELECTION box (torches, wall levers): the
    /// highlight/point path must pick one box by param2, else all three (top/
    /// bottom/side) draw and their union reads as a full cube (#253/torch).
    private var wallmountedSelBoxes: Set<UInt16> = []
    public func isWallmountedSelBox(_ id: UInt16) -> Bool { lock.withLockUnchecked { wallmountedSelBoxes.contains(id) } }
    /// Movement slowdown while the player box overlaps this node: max of
    /// move_resistance and liquid_viscosity (water 1, lava 7, cobweb 14). Speed
    /// is divided by (1 + resistance), so water stays ~0.5x and cobweb near-stops.
    private var resistances: [UInt16: Int] = [:]
    public func moveResistance(_ id: UInt16) -> Int { lock.withLockUnchecked { resistances[id] ?? 0 } }
    /// `buildable_to`: the node is replaceable (air, grass tufts, snow, water) so a
    /// placed block goes INTO it, not against it (#178). Air's id defaults true.
    private var buildableTos: [UInt16: Bool] = [:]
    public func isBuildableTo(_ id: UInt16) -> Bool { lock.withLockUnchecked { buildableTos[id] ?? (id == 0) } }
    /// Luanti's `rightclickable`: right-click runs on_rightclick (open door, use
    /// chest/button) instead of placing a node.
    private var rightclickables: [UInt16: Bool] = [:]
    private var pointables: [UInt16: Bool] = [:]
    private var liquidRanges: [UInt16: Int] = [:]
    private var selectionBoxes: [UInt16: [Box]] = [:]
    /// Boxes the pointing raycast tests (MapNode::getSelectionBoxes); nil = full cube.
    public func selectionBoxes(_ id: UInt16) -> [Box]? { lock.withLockUnchecked { selectionBoxes[id] ?? (kinds[id] == .nodebox ? nodeBoxes[id] : nil) } }
    private var liquidAltNames: [UInt16: (flowing: String, source: String)] = [:]
    /// liquid_range (1..8): how many levels a flowing liquid spreads; sets
    /// the surface height per param2 level (MapblockMeshGenerator::getLiquidNeighborhood).
    public func liquidRange(_ id: UInt16) -> Int { lock.withLockUnchecked { max(1, min(8, liquidRanges[id] ?? 8)) } }
    /// The (source, flowing) content ids of this liquid's family, so the mesher
    /// only joins surfaces with the SAME liquid (water doesn't blend into lava).
    public func liquidFamily(_ id: UInt16) -> (source: UInt16, flowing: UInt16)? {
        lock.withLockUnchecked {
            guard let alt = liquidAltNames[id] else { return nil }
            guard let s = idByName[alt.source], let f = idByName[alt.flowing] else { return nil }
            return (s, f)
        }
    }
    /// Luanti's PointabilityType: POINTABLE_NOT (0) nodes are skipped by the
    /// pointing raycast (water, air), so you can target a chest through water.
    public func isPointable(_ id: UInt16) -> Bool { lock.withLockUnchecked { pointables[id] ?? true } }
    private var postEffects: [UInt16: SIMD4<Float>] = [:]
    private var postEffectShaded: Set<UInt16> = []
    // use_texture_alpha = "blend" nodes (stained glass): drawn translucent.
    private var blended: Set<UInt16> = []
    private var clip: Set<UInt16> = []
    /// Whether this node's texture is alpha-blended (translucent) rather than
    /// opaque/alpha-cut. Drives the mesher's blended pass.
    public func isBlended(_ id: UInt16) -> Bool { lock.withLockUnchecked { blended.contains(id) } }
    /// Flat per-id light tables for WorldMap.relight (#278).
    public struct LightInfo {
        public let propagates: [Bool], sunlight: [Bool], source: [UInt8]
        @inline(__always) public func prop(_ id: UInt16) -> Bool { Int(id) < propagates.count ? propagates[Int(id)] : false }
        @inline(__always) public func sun(_ id: UInt16) -> Bool { Int(id) < sunlight.count ? sunlight[Int(id)] : false }
        @inline(__always) public func src(_ id: UInt16) -> UInt8 { Int(id) < source.count ? source[Int(id)] : 0 }
    }
    public func lightInfo() -> LightInfo {
        lock.withLockUnchecked {
            let maxId = max(Int(max(kinds.keys.max() ?? 0, lightSources.keys.max() ?? 0, lightPropagates.max() ?? 0)),
                            Int(WorldMap.CONTENT_AIR))   // air is always in the table, defined or not
            var p = [Bool](repeating: false, count: maxId + 1)
            var su = [Bool](repeating: false, count: maxId + 1)
            var so = [UInt8](repeating: 0, count: maxId + 1)
            for id in lightPropagates where Int(id) <= maxId { p[Int(id)] = true }
            for id in sunlightPropagates where Int(id) <= maxId { su[Int(id)] = true }
            for (id, v) in lightSources where Int(id) <= maxId { so[Int(id)] = v }
            // Air is always transparent to both banks.
            if Int(WorldMap.CONTENT_AIR) <= maxId { p[Int(WorldMap.CONTENT_AIR)] = true; su[Int(WorldMap.CONTENT_AIR)] = true }
            return LightInfo(propagates: p, sunlight: su, source: so)
        }
    }
    public func isGlasslike(_ id: UInt16) -> Bool { lock.withLockUnchecked { glasslike.contains(id) } }
    /// Whether this node's texture uses hard alpha-cutout (use_texture_alpha =
    /// "clip"); such faces stay in the discard pass, not the early-Z solid pass.
    public func isClip(_ id: UInt16) -> Bool { lock.withLockUnchecked { clip.contains(id) } }
    /// post_effect_color (rgba 0..1) drawn over the whole view while the camera
    /// is inside this node, plus whether Luanti scales it by the camera light.
    public func postEffect(_ id: UInt16) -> (color: SIMD4<Float>, shaded: Bool)? {
        lock.withLockUnchecked { postEffects[id].map { ($0, postEffectShaded.contains(id)) } }
    }
    public func isRightclickable(_ id: UInt16) -> Bool { lock.withLockUnchecked { rightclickables[id] ?? false } }
    private var digSounds: [UInt16: String] = [:]   // node -> "dig" sound group (while mining)
    public func digSound(_ id: UInt16) -> String? { lock.withLockUnchecked { digSounds[id] } }
    private var footstepSounds: [UInt16: String] = [:]   // node -> "footstep" sound group (walking on it)
    public func footstepSound(_ id: UInt16) -> String? { lock.withLockUnchecked { footstepSounds[id] } }
    // node_dig_prediction: the node this one turns INTO when dug (rare; most dig to
    // air). Lets the local dig prediction show the right result instead of a hole.
    private var digPredictions: [UInt16: String] = [:]
    public func digPrediction(_ id: UInt16) -> String? { lock.withLockUnchecked { digPredictions[id] } }

    public var count: Int { lock.withLockUnchecked { names.count } }
    public func name(_ id: UInt16) -> String { lock.withLockUnchecked { names[id] ?? "?" } }
    /// Reverse of `names`, for local place prediction (item name -> content id).
    private var idByName: [String: UInt16] = [:]
    public func id(for name: String) -> UInt16? { lock.withLockUnchecked { idByName[name] } }
    /// Item groups (e.g. VoxeLibre's handy_dig=3), used with the wielded tool's
    /// capabilities to compute dig time.
    private var nodeGroups: [UInt16: [String: Int]] = [:]
    public func groups(_ id: UInt16) -> [String: Int] { lock.withLockUnchecked { nodeGroups[id] ?? [:] } }

    /// Snapshot of the face-tile table for the atlas builder, which runs off
    /// the network thread. Swift dictionaries are copy-on-write, so this is a
    /// cheap O(1) grab that stays stable even if the parse reassigns.
    public func faceTilesSnapshot() -> [UInt16: [String]] { lock.withLockUnchecked { faceTiles } }
    /// Locked read of a tile's vertical-frame animation duration, for the atlas
    /// build (which runs off-thread while a relaunch may be re-parsing NODEDEF).
    public func animSecs(_ base: String) -> Float? { lock.withLockUnchecked { tileAnimSecs[base] } }

    /// The tile spec for one face of a node (0 = top), used to give a dropped
    /// node an icon (its inventory_image is empty). nil if the node has no tiles.
    public func faceTile(_ id: UInt16, _ face: Int) -> String? {
        lock.withLockUnchecked { faceTiles[id].flatMap { face < $0.count ? $0[face] : $0.first } }
    }

    /// Parse a TOCLIENT_NODEDEF payload: string32 zstd blob -> version, count,
    /// then per-node length-prefixed blobs.
    public func parseNodeDef(_ payload: Data) {
        let outer = PacketReader(payload)
        let blob = outer.bytes32()
        guard let raw = Zstd.decompress(blob, maxSize: 32 * 1024 * 1024) else { return }
        let r = PacketReader(raw)
        guard r.u8() >= 1 else { return }        // version
        let count = r.u16()
        let body = PacketReader(r.bytes32())
        // One lock hold around the whole write so readers never see a
        // half-parsed dictionary (and never race the buffer reallocation).
        lock.withLockUnchecked {
            for _ in 0..<count {
                let id = UInt16(body.u16())
                let nodeBlob = body.bytes16()
                parseNode(id, PacketReader(nodeBlob))
            }
            colorCache.removeAll()
            defsVersion += 1
        }
    }

    /// Bumped (under the lock) every time NODEDEF lands, so cached snapshots
    /// (physicsSnapshot) know when to refresh.
    private var defsVersion = 0
    public func version() -> Int { lock.withLockUnchecked { defsVersion } }

    /// Flat, lock-free copy of the per-id facts the player/particle collision
    /// path needs, indexed by content id. appendNodeSolidBoxes took the lock up
    /// to 8 times per scanned node (~40 nodes, twice a tick) plus once per
    /// swept particle step; that was ~100k lock acquisitions a second for
    /// values that only change on NODEDEF (perf #312). Unknown ids read as
    /// walkable (the unloaded-edge rule of isWalkable).
    public struct PhysicsSnapshot {
        public let version: Int
        public let walkable: [Bool]
        public let climbable: [Bool]
        public let paramType2: [Int]
        public let wallmounted: [Bool]
        public let boxes: [[Box]?]              // node_box (any drawtype)
        public let collision: [[Box]?]          // collision_box
        public let arms: [[[Box]]?]             // connected node_box arms
        public let collisionArms: [[[Box]]?]
        public let connects: [Set<UInt16>?]
        // Per-tick movement facts folded in so the physics path is lock-free like
        // collision already is (perf): move_resistance is sampled per node over
        // the whole player box every tick; liquid/slippery/solidCube a few times.
        public let resistance: [Int]
        public let liquid: [Bool]
        public let slippery: [Int]
        public let solidCube: [Bool]
        @inline(__always) public func moveResistance(_ id: UInt16) -> Int { Int(id) < resistance.count ? resistance[Int(id)] : 0 }
        @inline(__always) public func isLiquid(_ id: UInt16) -> Bool { Int(id) < liquid.count && liquid[Int(id)] }
        @inline(__always) public func slipperyLevel(_ id: UInt16) -> Int { Int(id) < slippery.count ? slippery[Int(id)] : 0 }
        @inline(__always) public func isSolidCube(_ id: UInt16) -> Bool { Int(id) < solidCube.count && solidCube[Int(id)] }
        @inline(__always) public func isWalkable(_ id: UInt16) -> Bool { Int(id) < walkable.count ? walkable[Int(id)] : true }
        @inline(__always) public func isClimbable(_ id: UInt16) -> Bool { Int(id) < climbable.count && climbable[Int(id)] }
        @inline(__always) public func pt2(_ id: UInt16) -> Int { Int(id) < paramType2.count ? paramType2[Int(id)] : 0 }
        @inline(__always) public func isWallmounted(_ id: UInt16) -> Bool { Int(id) < wallmounted.count && wallmounted[Int(id)] }
        @inline(__always) public func nodeBox(_ id: UInt16) -> [Box]? { Int(id) < boxes.count ? boxes[Int(id)] : nil }
        @inline(__always) public func collisionBox(_ id: UInt16) -> [Box]? { Int(id) < collision.count ? collision[Int(id)] : nil }
        @inline(__always) public func connectArms(_ id: UInt16) -> [[Box]]? { Int(id) < arms.count ? arms[Int(id)] : nil }
        @inline(__always) public func collisionConnectArms(_ id: UInt16) -> [[Box]]? { Int(id) < collisionArms.count ? collisionArms[Int(id)] : nil }
        @inline(__always) public func connectsTo(_ id: UInt16) -> Set<UInt16>? { Int(id) < connects.count ? connects[Int(id)] : nil }
        /// An empty snapshot (version -1) that reads every id as a plain solid
        /// cube, for the tick before NODEDEF has arrived.
        public static func makeEmpty() -> PhysicsSnapshot {
            PhysicsSnapshot(version: -1, walkable: [], climbable: [], paramType2: [], wallmounted: [],
                            boxes: [], collision: [], arms: [], collisionArms: [], connects: [],
                            resistance: [], liquid: [], slippery: [], solidCube: [])
        }
    }
    public func physicsSnapshot() -> PhysicsSnapshot {
        lock.withLockUnchecked {
            let maxId = Int(max(names.keys.max() ?? 0, WorldMap.CONTENT_AIR))
            let n = maxId + 1
            // Defined ids default to not-walkable unless flagged; undefined ids
            // (past the table or missing) stay solid like isWalkable.
            var w = [Bool](repeating: true, count: n)
            for (id, _) in names where Int(id) < n { w[Int(id)] = walkables[id] ?? false }
            w[Int(WorldMap.CONTENT_AIR)] = false   // see isWalkable: air has no NODEDEF entry here
            var c = [Bool](repeating: false, count: n)
            for id in climbables where Int(id) < n { c[Int(id)] = true }
            var p2 = [Int](repeating: 0, count: n)
            for (id, v) in paramType2s where Int(id) < n { p2[Int(id)] = v }
            var wm = [Bool](repeating: false, count: n)
            for id in wallmountedBoxes where Int(id) < n { wm[Int(id)] = true }
            var b = [[Box]?](repeating: nil, count: n)
            for (id, v) in nodeBoxes where Int(id) < n { b[Int(id)] = v }
            var cb = [[Box]?](repeating: nil, count: n)
            for (id, v) in collisionBoxes where Int(id) < n { cb[Int(id)] = v }
            var a = [[[Box]]?](repeating: nil, count: n)
            for (id, v) in connectBoxes where Int(id) < n { a[Int(id)] = v }
            var ca = [[[Box]]?](repeating: nil, count: n)
            for (id, v) in collisionConnectBoxes where Int(id) < n { ca[Int(id)] = v }
            var ct = [Set<UInt16>?](repeating: nil, count: n)
            for (id, v) in connectsTo where Int(id) < n { ct[Int(id)] = v }
            var rz = [Int](repeating: 0, count: n)
            for (id, v) in resistances where Int(id) < n { rz[Int(id)] = v }
            var lq = [Bool](repeating: false, count: n)
            for id in liquids where Int(id) < n { lq[Int(id)] = true }
            var sl = [Int](repeating: 0, count: n)
            for (id, g) in nodeGroups where Int(id) < n { sl[Int(id)] = g["slippery"] ?? 0 }
            var sc = [Bool](repeating: false, count: n)   // isSolidCube: normal/glasslike cube AND walkable
            for (id, dt) in drawtypes where Int(id) < n { sc[Int(id)] = (dt == 0 || dt == 17) && (walkables[id] ?? false) }
            return PhysicsSnapshot(version: defsVersion, walkable: w, climbable: c, paramType2: p2, wallmounted: wm,
                                   boxes: b, collision: cb, arms: a, collisionArms: ca, connects: ct,
                                   resistance: rz, liquid: lq, slippery: sl, solidCube: sc)
        }
    }

    /// Flat, lock-free copy of the per-id facts the mesher hits in its inner
    /// loop, indexed straight by content id. The mesher used to take the lock
    /// and hash a dictionary ~15-20 times per non-air node (kind, occludes,
    /// isBlended, per face x6), which on a full remesh of a few million nodes is
    /// seconds of CPU. Built once per WorldMesher.build under a single lock;
    /// the registry is effectively immutable after NODEDEF so a snapshot can't
    /// go stale mid-build. Unknown ids read as .cube (edge stays closed), same
    /// as kind()/occludes().
    public struct MeshSnapshot {
        public let kind: [RenderKind]        // by id; .cube for ids past the table
        public let occludes: [Bool]          // opaque cube, not liquid
        public let blended: [Bool]           // translucent (stained glass)
        public let glass: [Bool]             // glasslike drawtypes (see-through cubes, #265)
        public let emissive: [Bool]          // light_source > 0: skip directional face shading (content_mapblock shade_face)
        // Per-id overlay tiles (6 faces, nil when none) and per-face
        // colour-override flags -- folded in here so the hot mesh loop reads
        // them lock-free instead of taking a NodeRegistry lock per node (only a
        // few node types, e.g. grass blocks, have either).
        public let overlay: [[String]?]
        public let keepColor: [[Bool]?]
        @inline(__always) public func k(_ id: UInt16) -> RenderKind { Int(id) < kind.count ? kind[Int(id)] : .cube }
        @inline(__always) public func gl(_ id: UInt16) -> Bool { Int(id) < glass.count && glass[Int(id)] }
        @inline(__always) public func lit(_ id: UInt16) -> Bool { Int(id) < emissive.count && emissive[Int(id)] }
        public let pt2: [Int]                // param_type_2 per id (facedir/4dir/color/etc)
        // param_type == CPT_LIGHT: the node's param1 holds a light value. Smooth
        // lighting may only average such nodes; anything else (and any solid
        // drawtype) counts as an occluder, as mapblock_mesh.cpp getSmoothLightCombined
        // does, or a chest/rooted-plant's meaningless param1 = 0 darkens its neighbours.
        public let lightParam: [Bool]
        @inline(__always) public func cpt(_ id: UInt16) -> Bool { Int(id) < lightParam.count && lightParam[Int(id)] }
        public let clip: [Bool]              // clip cubes stay in the alpha-discard pass, not early-Z
        @inline(__always) public func ov(_ id: UInt16) -> [String]? { Int(id) < overlay.count ? overlay[Int(id)] : nil }
        @inline(__always) public func kc(_ id: UInt16) -> [Bool]? { Int(id) < keepColor.count ? keepColor[Int(id)] : nil }
        @inline(__always) public func p2t(_ id: UInt16) -> Int { Int(id) < pt2.count ? pt2[Int(id)] : 0 }
        @inline(__always) public func cl(_ id: UInt16) -> Bool { Int(id) < clip.count && clip[Int(id)] }
        @inline(__always) public func occ(_ id: UInt16) -> Bool { Int(id) < occludes.count ? occludes[Int(id)] : true }
        @inline(__always) public func bl(_ id: UInt16) -> Bool { Int(id) < blended.count && blended[Int(id)] }
    }
    // The mesher takes one of these per mesh() call, i.e. per dirty block: a
    // streaming pass is hundreds of blocks, so rebuild only when NODEDEF changed.
    private var meshSnapCache: (version: Int, snap: MeshSnapshot)?
    public func meshSnapshot() -> MeshSnapshot {
        lock.withLockUnchecked {
            if let c = meshSnapCache, c.version == defsVersion { return c.snap }
            let maxId = Int(kinds.keys.max() ?? 0)
            var k = [RenderKind](repeating: .cube, count: maxId + 1)
            var o = [Bool](repeating: true, count: maxId + 1)
            var b = [Bool](repeating: false, count: maxId + 1)
            for (id, kind) in kinds {
                k[Int(id)] = kind
                o[Int(id)] = kind == .cube && !liquids.contains(id) && !glasslike.contains(id)
            }
            for id in blended where Int(id) <= maxId { b[Int(id)] = true }
            var g = [Bool](repeating: false, count: maxId + 1)
            for id in glasslike where Int(id) <= maxId { g[Int(id)] = true }
            var em = [Bool](repeating: false, count: maxId + 1)
            for (id, v) in lightSources where Int(id) <= maxId && v > 0 { em[Int(id)] = true }
            var ov = [[String]?](repeating: nil, count: maxId + 1)
            for (id, v) in overlayTiles where Int(id) <= maxId { ov[Int(id)] = v }
            var kc = [[Bool]?](repeating: nil, count: maxId + 1)
            for (id, v) in faceColorOverride where Int(id) <= maxId { kc[Int(id)] = v }
            var p2 = [Int](repeating: 0, count: maxId + 1)
            for (id, v) in paramType2s where Int(id) <= maxId { p2[Int(id)] = v }
            var cl = [Bool](repeating: false, count: maxId + 1)
            for id in clip where Int(id) <= maxId { cl[Int(id)] = true }
            var lp = [Bool](repeating: false, count: maxId + 1)
            for id in lightParamIds where Int(id) <= maxId { lp[Int(id)] = true }
            let snap = MeshSnapshot(kind: k, occludes: o, blended: b, glass: g, emissive: em, overlay: ov, keepColor: kc, pt2: p2, lightParam: lp, clip: cl)
            meshSnapCache = (defsVersion, snap)
            return snap
        }
    }

    /// How to mesh this content id (defaults to cube for unknown ids like IGNORE
    /// so the loaded-region edges stay closed).
    public func kind(_ id: UInt16) -> RenderKind { lock.withLockUnchecked { kinds[id] ?? .cube } }
    public func isLiquid(_ id: UInt16) -> Bool { lock.withLockUnchecked { liquids.contains(id) } }
    /// Whether this node hides an adjacent opaque cube face (opaque cubes do;
    /// liquids don't, so submerged block faces show through the water).
    public func occludes(_ id: UInt16) -> Bool {
        lock.withLockUnchecked { (kinds[id] ?? .cube) == .cube && !liquids.contains(id) && !glasslike.contains(id) }
    }

    /// Parse one ContentFeatures blob far enough to capture name + main tiles.
    private func parseNode(_ id: UInt16, _ r: PacketReader) {
        guard r.u8() >= 13 else { return }       // ContentFeatures version
        let name = r.string16()
        if name.isEmpty { return }
        names[id] = name
        idByName[name] = id
        nodeGroups[id] = parseGroups(r)
        if r.u8() == 1 { lightParamIds.insert(id) } else { lightParamIds.remove(id) }   // param_type == CPT_LIGHT
        let pt2 = r.u8()                         // param_type_2
        paramType2s[id] = pt2
        let dt = r.u8()                          // drawtype
        drawtypes[id] = dt
        // drawtypes: 0 normal,1 airlike,2 liquid,3 flowingliquid,4 glasslike,
        // 5 allfaces,6 allfaces_optional,7 torchlike,8 signlike,9 plantlike,
        // 10 fencelike,11 raillike,12 nodebox,13 glasslike_framed,14 firelike,
        // 15 glasslike_framed_optional,16 mesh,17 plantlike_rooted
        switch dt {
        case 9:                     kinds[id] = .plant   // grass tufts, flowers, saplings
        case 17:                    kinds[id] = .rooted  // plantlike_rooted: solid base + plant on top (kelp, coral)
        case 5, 6:                  kinds[id] = .allfaces // leaves: draw internal faces too
        case 7:                     kinds[id] = .torch   // torches (centered crossed quads)
        case 11:                    kinds[id] = .rail    // rails (flat ground quad)
        case 14:                    kinds[id] = .fire    // firelike: flames on the floor + climbing adjacent walls
        case 8:                     kinds[id] = .sign    // signlike: flat wall-mounted quad (ladders, signs)
        case 16:                    kinds[id] = .mesh    // mesh: custom .obj/.b3d models
        case 1:                     kinds[id] = .skip    // airlike
        default:                    kinds[id] = .cube    // nodebox/fencelike promoted below once boxes parse
        }
        if dt == 4 || dt == 13 || dt == 15 { glasslike.insert(id) }   // glasslike(_framed[_optional])
        if dt == 2 || dt == 3 {                          // liquid / flowingliquid
            liquids.insert(id)
            if name.contains("lava") { lavas.insert(id) } // hot liquids glow, not translucent blue
        }
        let meshFile = r.string16()              // mesh model file (.obj/.b3d)
        let vscale = r.f32()                     // visual_scale
        if dt == 16 && !meshFile.isEmpty { meshFiles[id] = meshFile; visualScales[id] = vscale }
        if (dt == 9 || dt == 17) && vscale != 1 { visualScales[id] = vscale }   // plantlike(_rooted) visual_scale (#213)
        let tileCount = r.u8()
        guard tileCount >= 1 && tileCount <= 6 else { return }
        var tiles: [String] = [], tileColors: [Bool] = []
        for _ in 0..<tileCount { let t = parseTile(r); tiles.append(t.name); tileColors.append(t.hasColor) }
        // Expand to 6 faces: face i uses tiles[i] or the last provided tile.
        var faces = [String](repeating: "", count: 6)
        var keepColor = [Bool](repeating: false, count: 6)
        for i in 0..<6 { faces[i] = tiles[min(i, tiles.count - 1)]; keepColor[i] = tileColors[min(i, tiles.count - 1)] }
        // Glasslike (and framed, which draws as plain glasslike with the
        // default connected_glass=false) uses tile 0 on every face
        // (content_mapblock.cpp drawGlasslikeNode); VoxeLibre's glass lists
        // a second "detail" tile that only the framed renderer would use.
        if dt == 4 || dt == 13 || dt == 15 { faces = [String](repeating: tiles[0], count: 6); keepColor = [Bool](repeating: tileColors[0], count: 6) }
        faceTiles[id] = faces
        if keepColor.contains(true) { faceColorOverride[id] = keepColor } else { faceColorOverride[id] = nil }
        // A node whose every tile is blank.png is invisible in Luanti (e.g. the
        // placed chest node, whose visual is a separate animated entity). We
        // can't resolve blank.png^[resize] so it fell back to a grey cube; skip
        // rendering it instead. Applied at the end so nodebox promotion can't
        // un-skip it.
        let allBlank = faces.allSatisfy { NodeRegistry.imageNames($0).first == "blank.png" }

        // Walk to palette_name for every node (biome tinting); only nodebox/
        // fencelike keep going all the way to node_box.
        var overlays = [String](repeating: "", count: 6)  // tiles_overlay (fixed 6)
        for i in 0..<6 { overlays[i] = parseTileName(r) }
        if overlays.contains(where: { !$0.isEmpty }) { overlayTiles[id] = overlays } else { overlayTiles[id] = nil }
        let specialCount = r.u8()
        guard specialCount <= 6 else { return }
        var specials: [String] = []
        for _ in 0..<specialCount { specials.append(parseTileName(r)) } // tiles_special
        // plantlike_rooted draws its plant from special_tiles[0] (the base uses
        // the regular tiles). Only that drawtype needs it, so keep the map small.
        if dt == 17, let s = specials.first, !s.isEmpty { specialTiles[id] = s }
        _ = r.u8()                                       // alpha_legacy
        _ = r.u8(); _ = r.u8(); _ = r.u8()               // color rgb
        let palette = r.string16()                       // palette_name
        // Only colour-bearing param_type_2 values use the palette via param2.
        if !palette.isEmpty && (pt2 == 8 || pt2 == 9 || pt2 == 10 || pt2 == 12 || pt2 == 14) {
            paletteNames[id] = palette
            palettes.insert(palette)
        }
        if r.overrun { return }

        // These fields follow for EVERY node (not just nodeboxes). We parse the
        // whole tail so we can reach node_box AND the dug sound. The critical
        // render fields (tiles, kind, palette) are already stored above, so a
        // drift here can only lose the box/sound, never corrupt rendering.
        let wav = r.u8()                                 // waving: 1 plants (top sways), 2 leaves (whole node), 3 liquids
        if wav == 1 || wav == 2 { wavingClass[id] = UInt8(wav) }
        let cs = r.u8()                                  // connect_sides: which of THIS node's faces accept a connection
        if cs > 0 { connectSidesMask[id] = UInt8(cs) }
        let nConn = r.u16()
        guard nConn <= 4096 else { return }
        var connIds = Set<UInt16>()
        for _ in 0..<nConn { connIds.insert(UInt16(r.u16())) }   // connects_to ids
        if !connIds.isEmpty { connectsTo[id] = connIds }
        let pa = r.u8(), pr = r.u8(), pg = r.u8(), pb = r.u8()   // post_effect_color argb
        if pa != 0 { postEffects[id] = SIMD4(Float(pr), Float(pg), Float(pb), Float(pa)) / 255 }
        _ = r.u8()                                       // leveled
        if r.u8() != 0 { lightPropagates.insert(id) }    // light_propagates
        if r.u8() != 0 { sunlightPropagates.insert(id) } // sunlight_propagates
        let ls = r.u8()                                  // light_source (0..14)
        if ls > 0 { lightSources[id] = UInt8(min(14, ls)) }
        _ = r.u8()                                       // is_ground_content
        walkables[id] = r.u8() != 0                      // walkable: Luanti's collision-solid flag
        pointables[id] = r.u8() != 0                     // pointable (0 = POINTABLE_NOT)
        _ = r.u8()                                       // diggable
        if r.u8() != 0 { climbables.insert(id) }         // climbable (ladders, vines)
        buildableTos[id] = r.u8() != 0                   // buildable_to (replaceable)
        rightclickables[id] = r.u8() != 0                // rightclickable (door/chest/button: use, don't place)
        _ = r.u32()                                      // damage_per_second
        _ = r.u8()                                       // liquid_type
        let altFlowing = r.string16()                    // liquid_alternative_flowing
        let altSource = r.string16()                     // liquid_alternative_source
        if !altFlowing.isEmpty || !altSource.isEmpty { liquidAltNames[id] = (altFlowing, altSource) }
        let viscosity = Int(r.u8())                      // liquid_viscosity (legacy slowdown)
        if viscosity > 0 { resistances[id] = viscosity }
        _ = r.u8()                                       // liquid_renewable
        liquidRanges[id] = Int(r.u8())                   // liquid_range
        _ = r.u8()                                       // drowning
        _ = r.u8()                                       // floodable
        var connect: [[Box]]? = nil
        var nbType = 0
        let boxes = parseNodeBox(r, connect: &connect, type: &nbType)   // node_box
        if r.overrun { return }
        // Only nodebox/fencelike drawtypes actually render as boxes; other
        // drawtypes keep the kind set from their drawtype above.
        if !boxes.isEmpty {
            // Stored for every drawtype: MapNode::getCollisionBoxes uses node_box
            // for physics whenever collision_box is empty, whatever the node
            // looks like. VoxeLibre's ladder is signlike with a wallmounted
            // 1/16 plate, and colliding it as a full cube pinned players against
            // it when stepping off (#303). Rendering as boxes stays gated on the
            // nodebox/fencelike drawtypes below (kind); the mesher checks kind first.
            nodeBoxes[id] = boxes
            if nbType == 2 { wallmountedBoxes.insert(id) }   // wall_top/bottom/side; pick one by param2 (#212)
            if let connect { connectBoxes[id] = connect }   // connected: per-direction arms
            if dt == 12 || dt == 10 { kinds[id] = .nodebox }
        }
        if allBlank { kinds[id] = .skip }   // invisible node (blank tiles); entity supplies the visual
        var ignore: [[Box]]? = nil
        var ignoreType = 0
        // selection_box: what pointing hits (register.lua already copies node_box
        // into it for nodebox drawtypes). Empty/regular = the full cube.
        let sel = parseNodeBox(r, connect: &ignore, type: &ignoreType)
        if !sel.isEmpty {
            selectionBoxes[id] = sel
            if ignoreType == 2 { wallmountedSelBoxes.insert(id) }   // wall_top/bottom/side; pick by param2 when pointing
        }
        // collision_box: what the player/mobs physically bump into. Kept apart
        // from node_box so fences (1.5-tall collision post) stop a jump even
        // though they draw 1.0 tall (#214).
        var collConnect: [[Box]]? = nil
        var collType = 0
        // Allow the collision box to rise to 1.5 above centre (fence posts), so a
        // taller-than-visual post isn't clamped back down to the node top (#214).
        let coll = parseNodeBox(r, connect: &collConnect, type: &collType, yHi: 1.5)
        if !coll.isEmpty {   // any drawtype: chests/beds are mesh nodes with a collision_box
            collisionBoxes[id] = coll
            if let collConnect { collisionConnectBoxes[id] = collConnect }
        }
        if r.overrun { return }
        let footstep = readSoundSpec(r)                  // sound_footstep (played while walking on it)
        let dig = readSoundSpec(r)                       // sound_dig (looped while mining)
        let dug = readSoundSpec(r)                       // sound_dug (played on break)
        if r.overrun { return }
        if !footstep.isEmpty { footstepSounds[id] = footstep }
        if !dig.isEmpty { digSounds[id] = dig }
        if !dug.isEmpty { dugSounds[id] = dug }
        // Tail: legacy flags, node_dig_prediction, leveled_max, alpha,
        // move_resistance, liquid_move_physics, post_effect_color_shaded.
        _ = r.u8(); _ = r.u8()                           // legacy_facedir_simple, legacy_wallmounted
        // node_dig_prediction: the node this digs INTO. "air" (the default) =
        // remove locally; another name = swap; "" = predict NOTHING and wait
        // for the server (game.cpp; VoxeLibre's waterlogged mangrove roots).
        // Stored verbatim so "" survives; nil (pre-5.x server) means "air".
        digPredictions[id] = r.string16()
        _ = r.u8()                                       // leveled_max
        let alpha = r.u8()                               // AlphaMode: 0 BLEND, 1 CLIP, 2 OPAQUE
        let moveRes = Int(r.u8()); _ = r.u8()            // move_resistance, liquid_move_physics
        if !r.overrun, moveRes > viscosity { resistances[id] = moveRes }   // modern field wins when larger
        let shaded = r.u8()                              // post_effect_color_shaded
        if !r.overrun {
            if shaded != 0 { postEffectShaded.insert(id) }
            // use_texture_alpha = "blend": the texture's own alpha is drawn
            // translucent (stained glass), not alpha-cut. The mesher routes these
            // through the blended pass instead of the opaque cutout.
            if alpha == 0 { blended.insert(id) }
            // use_texture_alpha = "clip": the texture has hard alpha holes the
            // shader must discard (leaves are allfaces, but a cube node can be
            // clip too). The mesher keeps these in the alpha-cutout pass rather
            // than the early-Z solid pass (#164).
            if alpha == 1 { clip.insert(id) }
        }
    }

    /// SoundSpec::serializeSimple: string16 name, then f32 gain/pitch/fade.
    /// The gain/pitch are kept per sound NAME (VoxeLibre defines them
    /// consistently per sound: sand footsteps at 0.045, wood at 0.3) so the
    /// client plays a node sound at the mod's volume, not 1.0 (#280).
    private func readSoundSpec(_ r: PacketReader) -> String {
        let name = r.string16()
        let gain = r.f32(), pitch = r.f32(); _ = r.f32()
        if !name.isEmpty, gain > 0 { soundGains[name] = (gain, pitch > 0 ? pitch : 1) }
        return name
    }
    private var soundGains: [String: (gain: Float, pitch: Float)] = [:]
    /// (gain, pitch) a node definition gave this sound name, else (1, 1).
    public func soundGain(_ name: String) -> (gain: Float, pitch: Float) {
        lock.withLockUnchecked { soundGains[name] ?? (1, 1) }
    }

    /// NodeBox::serialize: version, type, then boxes depending on type. We only
    /// keep the "fixed" list (for connected nodes, the center post) since we
    /// don't do neighbour-connection geometry yet.
    // `yHi` caps the box's top corner. Visual node_box stays in the cube (0.5),
    // but a collision_box legitimately rises above it (a fence post is taller so
    // you can't jump it), so that path passes a higher cap (#214).
    private func parseNodeBox(_ r: PacketReader, connect: inout [[Box]]?, type: inout Int, yHi: Float = 0.5) -> [Box] {
        guard r.u8() >= 6 else { return [] }             // NodeBox version
        let t = r.u8()   // 0 regular, 1 fixed, 2 wallmounted, 3 leveled, 4 connected
        type = Int(t)
        switch t {
        case 1, 3:  return readBoxes(r, yHi: yHi)         // fixed / leveled
        case 2:     return [readBox(r, yHi: yHi), readBox(r, yHi: yHi), readBox(r, yHi: yHi)]   // wall top/bottom/side
        case 4:
            // Connected serializes 15 box-lists: fixed, then connect_[top,bottom,
            // front,left,back,right], then 6 disconnected_*, disconnected,
            // disconnected_sides. Keep the fixed post + the 6 connect arms; the
            // rest must still be CONSUMED or the stream drifts into the sounds.
            let fixed = readBoxes(r, yHi: yHi)
            var arms: [[Box]] = []
            for _ in 0..<6 { arms.append(readBoxes(r, yHi: yHi)) }   // connect_ top,bottom,front,left,back,right
            for _ in 0..<8 { _ = readBoxes(r, yHi: yHi) }            // 6 disconnected_* + disconnected + disconnected_sides
            connect = arms
            return fixed
        default:    return []                            // regular -> full cube fallback
        }
    }

    private func readBoxes(_ r: PacketReader, yHi: Float = 0.5) -> [Box] {
        let n = r.u16()
        guard n <= 256 else { return [] }
        var out: [Box] = []
        for _ in 0..<n {
            let b = readBox(r, yHi: yHi)
            if r.overrun { return [] }
            out.append(b)
        }
        return out
    }

    private func readBox(_ r: PacketReader, yHi: Float = 0.5) -> Box {
        // Luanti serializes node_box corners in BS units (1 node = BS = 10.0, see
        // constants.h / the wall_top default at nodedef.cpp:34), so divide back
        // to node units (-0.5..0.5). Without this a full box's ±5 just happened
        // to clamp to ±0.5, but a partial face like a door's -3.125 clamped to
        // -0.5 and collapsed the box to zero thickness -> invisible door.
        let bs: Float = 10.0
        let a = SIMD3<Float>(r.f32(), r.f32(), r.f32()) / bs
        let b = SIMD3<Float>(r.f32(), r.f32(), r.f32()) / bs
        // Clamp to the node cube; a stray box outside it would smear across
        // neighbours. min/max because Luanti doesn't guarantee ordering.
        let loBound = SIMD3<Float>(-0.5, -0.5, -0.5), hiBound = SIMD3<Float>(0.5, yHi, 0.5)
        let lo = simd_clamp(simd_min(a, b), loBound, hiBound)
        let hi = simd_clamp(simd_max(a, b), loBound, hiBound)
        return Box(min: lo, max: hi)
    }

    private func parseGroups(_ r: PacketReader) -> [String: Int] {
        let n = r.u16()
        var g: [String: Int] = [:]
        for _ in 0..<n {
            let name = r.string16()
            let rating = r.s16()
            g[name] = rating
        }
        return g
    }

    /// TileDef: version, name, animation, flags, [color], [scale], [align].
    /// Returns the tile's modifier string and whether it carries its own
    /// colour (has_color; the RGB itself is dropped, VoxeLibre only ever sends
    /// white, meaning "don't palette-tint this face").
    private func parseTile(_ r: PacketReader) -> (name: String, hasColor: Bool) {
        guard r.u8() >= 6 else { return ("", false) }     // TileDef version
        let name = r.string16()
        let animSecs = parseTileAnimation(r)
        let flags = r.u16()
        let hasColor = flags & 8 != 0
        if hasColor { _ = r.u8(); _ = r.u8(); _ = r.u8() }  // color rgb
        if flags & 16 != 0 { _ = r.u8() }        // scale
        if flags & 32 != 0 { _ = r.u8() }        // align_style
        // Remember a vertical-frames animation by its base image so the atlas can
        // cycle it (lava/fire/furnace). Keyed by the base image, not the full
        // modifier string, since a plain animated tile is just its image.
        if let secs = animSecs, let base = Self.imageNames(name).first { tileAnimSecs[base] = secs }
        return (name, hasColor)
    }
    private func parseTileName(_ r: PacketReader) -> String { parseTile(r).name }

    /// vertical_frames total-cycle seconds, or nil for a static / sheet tile.
    private func parseTileAnimation(_ r: PacketReader) -> Float? {
        switch r.u8() {
        case 1: _ = r.u16(); _ = r.u16(); return r.f32()   // vertical_frames: aspect_w, aspect_h, length
        case 2: _ = r.u8(); _ = r.u8(); _ = r.f32(); return nil  // sheet_2d (unsupported)
        default: return nil
        }
    }

    /// Every image file referenced by a tile modifier string (base + overlays),
    /// so the media layer knows what to download.
    // Hot: called per HUD element per tick, per particle spawn, and ~1500x per
    // atlas build. Used to allocate a 65-char Set and lowercase every token on
    // each call; the charset is static now and the .png check is case-folded
    // per byte, so this is allocation-free apart from the result.
    private static let imageNameChars: Set<Character> =
        Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
    @inline(__always) private static func isPNG(_ s: String) -> Bool {
        let u = s.utf8
        guard u.count >= 4 else { return false }
        var it = u.reversed().makeIterator()
        // ".png" reversed, case-insensitive: g n p .
        guard let g = it.next(), g | 0x20 == 0x67, let n = it.next(), n | 0x20 == 0x6E,
              let p = it.next(), p | 0x20 == 0x70, let d = it.next(), d == 0x2E else { return false }
        return true
    }
    public static func imageNames(_ tile: String) -> [String] {
        var out: [String] = []
        var cur = ""
        func flush() { if isPNG(cur) { out.append(cur) }; cur = "" }
        for ch in tile { if imageNameChars.contains(ch) { cur.append(ch) } else { flush() } }
        flush()
        return out
    }

    // --- fallback colour (used when a tile has no usable texture) ---

    public func color(_ id: UInt16) -> SIMD3<Float> {
        lock.withLockUnchecked {
            if let c = colorCache[id] { return c }
            let c = NodeRegistry.classify(names[id] ?? "")
            colorCache[id] = c
            return c
        }
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
        SIMD3(Float(r) / 255, Float(g) / 255, Float(b) / 255)
    }

    static func classify(_ name: String) -> SIMD3<Float> {
        let n = name.lowercased()
        func has(_ s: String) -> Bool { n.contains(s) }
        switch true {
        case has("lava"):                             return rgb(207, 90, 20)
        case has("water"):                            return rgb(52, 110, 196)
        case has("snow"), has("ice"):                 return rgb(232, 240, 247)
        case has("sand"):                             return rgb(219, 205, 148)
        case has("grass"), has("leaves"), has("leaf"),
             has("cactus"), has("fern"), has("vine"): return rgb(96, 160, 60)
        case has("dirt"), has("soil"), has("mud"):    return rgb(122, 86, 56)
        case has("wood"), has("tree"), has("log"),
             has("plank"), has("bark"):               return rgb(150, 111, 62)
        case has("coal"), has("obsidian"):            return rgb(40, 40, 46)
        case has("iron"), has("ore"):                 return rgb(150, 140, 130)
        case has("gold"):                             return rgb(220, 190, 70)
        case has("diamond"):                          return rgb(110, 200, 210)
        case has("gravel"):                           return rgb(130, 124, 120)
        case has("cobble"), has("stone"), has("rock"),
             has("andesite"), has("granite"),
             has("diorite"), has("brick"):            return rgb(122, 122, 128)
        default:                                      return rgb(150, 150, 150)
        }
    }
}
