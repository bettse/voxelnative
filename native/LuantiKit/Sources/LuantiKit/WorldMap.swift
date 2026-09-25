import Foundation
import simd

/// Streamed voxel world: 16^3 map blocks keyed by block position. Port of the
/// decode parts of world_map.gd (param0/1/2; metadata skipped for now).
public final class WorldMap {
    public static let BLOCK_SIZE = 16
    public static let NODES_PER_BLOCK = 4096
    public static let CONTENT_AIR: UInt16 = 126
    public static let CONTENT_IGNORE: UInt16 = 127
    public static let CONTENT_UNKNOWN: UInt16 = 125

    public final class MapBlock {
        public let pos: SIMD3<Int>
        // A block made by setNode() (prediction into an unloaded block) starts as
        // air, not content id 0 (which is a real node); decode replaces the arrays.
        public var param0 = [UInt16](repeating: WorldMap.CONTENT_AIR, count: WorldMap.NODES_PER_BLOCK)
        public var param1 = [UInt8](repeating: 0, count: WorldMap.NODES_PER_BLOCK)
        public var param2 = [UInt8](repeating: 0, count: WorldMap.NODES_PER_BLOCK)
        /// Seconds since the block was last "in use" (see `expire`); the
        /// engine's MapBlock usage timer.
        public var usage: Float = 0
        init(pos: SIMD3<Int>) { self.pos = pos }
    }

    public private(set) var blocks: [SIMD3<Int>: MapBlock] = [:]
    /// Node-metadata inventories (chests, furnaces, ...) keyed by world node pos,
    /// list name -> stacks. Parsed from BLOCKDATA so a container's contents are
    /// available without a separate request.
    public private(set) var nodeMeta: [SIMD3<Int>: [String: [Client.ItemStack?]]] = [:]
    public func nodeInventory(_ p: SIMD3<Int>, list: String = "main") -> [Client.ItemStack?]? {
        nodeMeta[p]?[list]
    }
    /// Seed a node's inventory list directly. Test/sim aid only (`-vrdev.fakeChest`
    /// fills a chest so the nodemeta render path can be checked headless); the
    /// live path fills nodeMeta from streamed BLOCKDATA and NODEMETA_CHANGED.
    public func setNodeInventoryForTest(_ p: SIMD3<Int>, list: String, _ stacks: [Client.ItemStack?]) {
        nodeMeta[p, default: [:]][list] = stacks
    }
    /// The `formspec` string in a node's metadata, if any. Furnaces (and other
    /// stations without an on_rightclick) rely on the client opening this on
    /// rightclick; real Luanti does this client-side.
    public private(set) var nodeFormspecs: [SIMD3<Int>: String] = [:]
    public func nodeFormspec(_ p: SIMD3<Int>) -> String? { nodeFormspecs[p] }

    /// Client-side placement param2 prediction, matching Luanti's game.cpp
    /// nodePlacement. `pt2` is the node's ContentParamType2 (3=facedir,
    /// 4=wallmounted, 9=colored_facedir, 10=colored_wallmounted, 13=4dir,
    /// 14=colored_4dir). `nodepos` is where the block lands, `neighborpos` the
    /// pointed node, `playerpos` the player's node coords. All in the same frame
    /// (differences are frame-independent). Colour bits and torch vertical-rotate
    /// are left to the server.
    public static func placementParam2(pt2: Int, nodepos: SIMD3<Int>, neighborpos: SIMD3<Int>, playerpos: SIMD3<Int>) -> UInt8 {
        switch pt2 {
        case 4, 10:   // wallmounted: mount to the face you pointed at
            let d = nodepos &- neighborpos
            let ax = abs(d.x), ay = abs(d.y), az = abs(d.z)
            if ay > Swift.max(ax, az) { return d.y < 0 ? 1 : 0 }
            else if ax > az { return d.x < 0 ? 3 : 2 }
            else { return d.z < 0 ? 5 : 4 }
        case 3, 9, 13, 14:   // facedir / 4dir: face the player
            let d = nodepos &- playerpos
            if abs(d.x) > abs(d.z) { return d.x < 0 ? 3 : 1 }
            else { return d.z < 0 ? 2 : 0 }
        default: return 0
        }
    }

    public static func index(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * 16 + y) * 16 + x }
    public static func blockPos(_ n: SIMD3<Int>) -> SIMD3<Int> {
        // floor(a/16) == arithmetic right shift by 4 for signed Int (Swift `>>`
        // rounds toward -inf), matching the `& 15` in-block index. This is the
        // hottest primitive (every node lookup), so avoid the float divide.
        SIMD3(n.x >> 4, n.y >> 4, n.z >> 4)
    }

    /// Content id at a node position; CONTENT_IGNORE if the block isn't loaded.
    public func nodeId(_ p: SIMD3<Int>) -> UInt16 {
        guard let b = blocks[WorldMap.blockPos(p)] else { return WorldMap.CONTENT_IGNORE }
        return b.param0[WorldMap.index(p.x & 15, p.y & 15, p.z & 15)]
    }

    /// One-entry last-block cache for scanning a contiguous node range (the
    /// physics collision/climb/ground scans hit the same one or two MapBlocks),
    /// so a run of lookups skips the per-call dictionary hash. Caller-owned so it
    /// stays single-threaded (the tick), no cross-thread races on the cache.
    /// MapBlock is a class, so caching the reference is a pointer copy.
    public struct BlockCursor {
        var bp = SIMD3<Int>(Int.min, Int.min, Int.min)
        var block: MapBlock?
        public init() {}
    }
    public func nodeId(_ p: SIMD3<Int>, _ c: inout BlockCursor) -> UInt16 {
        let bp = WorldMap.blockPos(p)
        if bp != c.bp { c.bp = bp; c.block = blocks[bp] }
        guard let b = c.block else { return WorldMap.CONTENT_IGNORE }
        return b.param0[WorldMap.index(p.x & 15, p.y & 15, p.z & 15)]
    }

    /// nodeLight with the same one-entry block cursor as nodeId: entity and
    /// particle loops hit the same few blocks over and over.
    public func nodeLight(_ p: SIMD3<Int>, _ c: inout BlockCursor) -> UInt8 {
        let bp = WorldMap.blockPos(p)
        if bp != c.bp { c.bp = bp; c.block = blocks[bp] }
        guard let b = c.block else { return 0x0F }
        return b.param1[WorldMap.index(p.x & 15, p.y & 15, p.z & 15)]
    }

    /// param1 light byte (low nibble = day/sky light, high nibble = night/torch
    /// light), each 0..15. Unloaded columns read as full daylight so the edge of
    /// the loaded region isn't black.
    public func nodeLight(_ p: SIMD3<Int>) -> UInt8 {
        guard let b = blocks[WorldMap.blockPos(p)] else { return 0x0F }
        return b.param1[WorldMap.index(p.x & 15, p.y & 15, p.z & 15)]
    }

    static let sixDirs = [SIMD3(1,0,0), SIMD3(-1,0,0), SIMD3(0,1,0),
                          SIMD3(0,-1,0), SIMD3(0,0,1), SIMD3(0,0,-1)]

    /// param2 byte (0 if the block isn't loaded). For flowing liquids the low 3
    /// bits are the liquid level, which sets the surface height.
    public func nodeParam2(_ p: SIMD3<Int>) -> UInt8 {
        guard let b = blocks[WorldMap.blockPos(p)] else { return 0 }
        return b.param2[WorldMap.index(p.x & 15, p.y & 15, p.z & 15)]
    }

    /// A block decoded off the hot path: everything but the world mutation. The
    /// heavy work (zstd decompress + 4096-node parse) runs on a background queue;
    /// `insert` then splices it into the map on the session queue.
    public struct DecodedBlock {
        public let bpos: SIMD3<Int>
        let block: MapBlock
        let meta: [SIMD3<Int>: [String: [Client.ItemStack?]]]
        let formspecs: [SIMD3<Int>: String?]   // value nil = clear
    }

    /// Pure decode of a TOCLIENT_BLOCKDATA payload -- no `self`, safe to run on a
    /// background thread. Returns nil for a truncated/corrupt stream.
    public static func decodeBlock(_ payload: Data) -> DecodedBlock? {
        let r = PacketReader(payload)
        let bpos = SIMD3(r.s16(), r.s16(), r.s16())
        var comp = r.rest()
        if comp.count > 1 { comp = comp.subdata(in: comp.startIndex..<(comp.endIndex - 1)) } // drop network byte
        guard let raw = Zstd.decompress(comp) else { return nil }
        let d = PacketReader(raw)
        _ = d.u8()                 // flags
        _ = d.u16()                // lighting_complete
        let contentWidth = d.u8()
        let paramsWidth = d.u8()
        guard paramsWidth == 2, contentWidth == 1 || contentWidth == 2 else { return nil }
        let n = WorldMap.NODES_PER_BLOCK
        let b = MapBlock(pos: bpos)
        if contentWidth == 2 {
            let bytes = [UInt8](d.raw(n * 2))
            guard bytes.count == n * 2 else { return nil }
            for i in 0..<n { b.param0[i] = (UInt16(bytes[i * 2]) << 8) | UInt16(bytes[i * 2 + 1]) }
        } else {
            let bytes = [UInt8](d.raw(n))
            guard bytes.count == n else { return nil }
            for i in 0..<n { b.param0[i] = UInt16(bytes[i]) }
        }
        b.param1 = [UInt8](d.raw(n))
        b.param2 = [UInt8](d.raw(n))
        // A truncated/corrupt stream that ends after param0 leaves these empty;
        // storing the block would then index up to 4095 into a 0-element array
        // on the next light/param2/mesh read. Drop the block instead.
        guard b.param1.count == n, b.param2.count == n else { return nil }
        // Node metadata (chest/furnace/sign inventories, formspec) follows the
        // bulk node data. Best-effort; a shortfall just leaves containers empty.
        let (meta, fs) = parseNodeMeta(d, bpos: bpos)
        return DecodedBlock(bpos: bpos, block: b, meta: meta, formspecs: fs)
    }

    /// Splice a decoded block into the map. Session-queue only (mutates state the
    /// mesher/physics read). Returns the block position.
    @discardableResult
    public func insert(_ d: DecodedBlock) -> SIMD3<Int> {
        blocks[d.bpos] = d.block
        for (k, v) in d.meta { nodeMeta[k] = v }
        for (k, v) in d.formspecs { nodeFormspecs[k] = v }
        return d.bpos
    }

    /// Decode + insert in one call (tests, and any synchronous caller).
    @discardableResult
    public func decodeBlockData(_ payload: Data) -> SIMD3<Int>? {
        guard let d = WorldMap.decodeBlock(payload) else { return nil }
        return insert(d)
    }

    /// NodeMetadataList::deSerialize (network form): u8 version, u16 count, then
    /// per node a packed u16 position, the string vars, and an Inventory text
    /// blob terminated by "EndInventory\n".
    static func parseNodeMeta(_ d: PacketReader, bpos: SIMD3<Int>, absolute: Bool = false)
        -> (meta: [SIMD3<Int>: [String: [Client.ItemStack?]]], formspecs: [SIMD3<Int>: String?]) {
        var meta: [SIMD3<Int>: [String: [Client.ItemStack?]]] = [:]
        var formspecs: [SIMD3<Int>: String?] = [:]
        guard d.has(1) else { return (meta, formspecs) }
        let version = d.u8()
        guard version != 0, version <= 2 else { return (meta, formspecs) }   // 0 = none; >2 unknown, stop
        let count = d.u16()
        guard count <= 4096 else { return (meta, formspecs) }
        let base = SIMD3(bpos.x * 16, bpos.y * 16, bpos.z * 16)
        for _ in 0..<count {
            let wp: SIMD3<Int>
            if absolute {
                guard d.has(6) else { return (meta, formspecs) }
                wp = SIMD3(d.s16(), d.s16(), d.s16())
            } else {
                guard d.has(2) else { return (meta, formspecs) }
                let p16 = d.u16()
                wp = SIMD3(base.x + (p16 & 15), base.y + ((p16 >> 4) & 15), base.z + (p16 >> 8))
            }
            let numVars = d.u32()
            guard numVars <= 65536 else { return (meta, formspecs) }
            var formspec = ""
            for _ in 0..<numVars {
                let name = d.string16()          // var name
                let value = d.string32()         // var value
                if version >= 2 { _ = d.u8() }   // private flag
                if name == "formspec" { formspec = value }
            }
            let text = WorldMap.readInventoryBlob(d)
            if d.overrun { return (meta, formspecs) }
            let (lists, _) = Client.parseInventoryLists(text, previous: [:])
            if !lists.isEmpty { meta[wp] = lists }
            formspecs[wp] = formspec.isEmpty ? String?.none : formspec   // nil = clear
        }
        return (meta, formspecs)
    }

    /// Read the raw Inventory text (Inventory::serialize) from the stream up to
    /// and including the terminating "EndInventory\n", so the cursor lands on
    /// the next node's record.
    /// TOCLIENT_NODEMETA_CHANGED: an inflated NodeMetadataList with absolute
    /// node positions. Returns the world positions whose inventories changed so
    /// the caller can remesh/refresh any open container.
    @discardableResult
    public func applyNodeMetaChanged(_ inflated: Data) -> [SIMD3<Int>] {
        let before = Set(nodeMeta.keys)
        let (meta, fs) = WorldMap.parseNodeMeta(PacketReader(inflated), bpos: .zero, absolute: true)
        for (k, v) in meta { nodeMeta[k] = v }
        for (k, v) in fs { nodeFormspecs[k] = v }
        return Array(Set(nodeMeta.keys).subtracting(before))
    }

    private static func readInventoryBlob(_ d: PacketReader) -> String {
        var out = ""
        let terminator = "EndInventory\n"
        while d.has(1) {
            out.append(Character(UnicodeScalar(UInt8(d.u8()))))
            if out.hasSuffix(terminator) { break }
        }
        return out
    }

    /// Set a single node's params (used by ADDNODE and local prediction).
    public func setNode(_ p: SIMD3<Int>, param0: UInt16, param1: UInt8 = 0, param2: UInt8 = 0) {
        let bp = WorldMap.blockPos(p)
        let i = WorldMap.index(p.x & 15, p.y & 15, p.z & 15)
        let oldLight = blocks[bp]?.param1[i] ?? 0
        // Copy-on-write: replace the whole block rather than mutating its arrays
        // in place, so a snapshot handed to the background mesher never sees a
        // block change under it (decodeBlockData already replaces wholesale).
        let nb = MapBlock(pos: bp)
        if let old = blocks[bp] { nb.param0 = old.param0; nb.param1 = old.param1; nb.param2 = old.param2 }
        nb.param0[i] = param0; nb.param1[i] = param1; nb.param2[i] = param2
        blocks[bp] = nb
        if let info = lightInfo { relight(p, oldLight: oldLight, given: param1, info: info) }
    }

    /// Light tables from the node registry; set once NODEDEF is in. While nil
    /// (tests, pre-nodedef) setNode stores the packet's param1 as-is.
    public var lightInfo: NodeRegistry.LightInfo?
    /// Blocks whose light changed in a relight, for the session to remesh.
    public var onRelit: ((Set<SIMD3<Int>>) -> Void)?

    /// Client-side relight after one node changed at `p`. Mirrors
    /// voxalgo::update_lighting_nodes for a single node: first UNLIGHT what the
    /// old node lit (walk outward removing every neighbour whose light is
    /// weaker than the light it got from us, noting the brighter frontier),
    /// then SPREAD again from that frontier plus the new node's own light
    /// source / sunlight. Both banks: low nibble day (sunlight, which keeps 15
    /// going straight down through transparent nodes), high nibble night
    /// (artificial, always -1 per step). Bounded to loaded blocks and a node
    /// budget so a bad packet can't spin. Block copies are batched (one copy per
    /// touched block, not per node write).
    public func relight(_ p: SIMD3<Int>, oldLight: UInt8, given: UInt8 = 0, info: NodeRegistry.LightInfo) {
        // Hot loop notes (perf review): neighbours are almost always in the
        // same mapblock as the node being visited, so a one-entry cursor
        // answers ~90% of lookups without hashing; id and light for a cell come
        // from ONE lookup; and a block is only copied (and later remeshed) if
        // a light value actually changes in it.
        var edited: [SIMD3<Int>: MapBlock] = [:]
        var curBP = SIMD3<Int>(Int.min, Int.min, Int.min)
        var curBlock: MapBlock?
        @inline(__always) func block(_ q: SIMD3<Int>) -> MapBlock? {
            let bp = WorldMap.blockPos(q)
            if bp == curBP { return curBlock }
            curBP = bp; curBlock = edited[bp] ?? blocks[bp]
            return curBlock
        }
        /// The editable copy of q's block (made on first write).
        @inline(__always) func editable(_ q: SIMD3<Int>) -> MapBlock? {
            let bp = WorldMap.blockPos(q)
            if let b = edited[bp] { if bp == curBP { curBlock = b }; return b }
            guard let old = blocks[bp] else { return nil }
            let nb = MapBlock(pos: bp); nb.param0 = old.param0; nb.param1 = old.param1; nb.param2 = old.param2
            edited[bp] = nb
            if bp == curBP { curBlock = nb }
            return nb
        }
        /// (content id, packed light) of a cell, nil if its block isn't loaded.
        @inline(__always) func cell(_ q: SIMD3<Int>) -> (id: UInt16, light: UInt8)? {
            guard let b = block(q) else { return nil }
            let i = WorldMap.index(q.x & 15, q.y & 15, q.z & 15)
            return (b.param0[i], b.param1[i])
        }
        /// Write one bank's nibble; a no-op (no block copy) when it already holds v.
        func setBank(_ q: SIMD3<Int>, day: Bool, _ v: UInt8) {
            guard let b = block(q) else { return }
            let i = WorldMap.index(q.x & 15, q.y & 15, q.z & 15)
            let cur = b.param1[i]
            let nv: UInt8 = day ? (cur & 0xF0) | (v & 0x0F) : (cur & 0x0F) | (v << 4)
            if nv == cur { return }
            guard let e = editable(q) else { return }
            e.param1[i] = nv
        }
        let dirs = WorldMap.sixDirs
        let up = SIMD3(0, 1, 0), down = SIMD3(0, -1, 0)
        let id = cell(p)?.id ?? WorldMap.CONTENT_AIR
        for day in [true, false] {
            // Per-bank budget: a sunlit column unlight on the day bank must not
            // starve the night bank (the torch you just placed).
            var budget = 20_000
            func bank(_ l: UInt8) -> UInt8 { day ? l & 0x0F : l >> 4 }
            let oldL = bank(oldLight)
            // Unlight from p with its old value.
            var frontier: [SIMD3<Int>] = []
            var queue: [(SIMD3<Int>, UInt8)] = [(p, oldL)]
            queue.reserveCapacity(256); frontier.reserveCapacity(64)
            setBank(p, day: day, 0)
            var qi = 0
            while qi < queue.count, budget > 0 {
                let (q, l) = queue[qi]; qi += 1; budget -= 1
                guard l > 0 else { continue }
                for d in dirs {
                    let n = q &+ d
                    guard let c = cell(n) else { continue }
                    let nl = bank(c.light)
                    if nl == 0 { continue }
                    // Lit by us: dimmer than our value, or the same 15 straight
                    // below us in a sunlight column.
                    let sunColumn = day && l == 15 && d == down && nl == 15
                    if nl < l || sunColumn {
                        setBank(n, day: day, 0); queue.append((n, nl))
                    } else {
                        frontier.append(n)
                    }
                }
            }
            // The new node's own light: its light_source, sunlight from a lit
            // node above, or whatever the server's ADDNODE said (the engine
            // zeroes that, but at a loaded-area edge the server knows more than
            // we can derive, so keep the brighter).
            // light_source lights BOTH banks (voxelalgorithms.cpp update_lighting_nodes
            // sets new_light = light_source for each bank; MapNode::getLight is
            // max(light_source, raw) either way). Applying it to the night bank
            // only left a torch placed at noon unlit until the block reloaded:
            // by day the shader reads the day bank.
            var own: UInt8 = max(bank(given), info.src(id))
            if day, info.sun(id), let above = cell(p &+ up), bank(above.light) == 15 { own = 15 }
            if own > 0 { setBank(p, day: day, own); frontier.append(p) }
            // A node that now lets light through gets lit from its neighbours.
            if info.prop(id) || info.sun(id) { for d in dirs { frontier.append(p &+ d) } }
            // Spread from the frontier.
            var spread = frontier
            spread.reserveCapacity(256)
            var si = 0
            while si < spread.count, budget > 0 {
                let q = spread[si]; si += 1; budget -= 1
                guard let qc = cell(q) else { continue }
                let ql = bank(qc.light)
                guard ql > 0 else { continue }
                for d in dirs {
                    let n = q &+ d
                    guard let c = cell(n) else { continue }
                    guard info.prop(c.id) || (day && info.sun(c.id)) else { continue }
                    let nv: UInt8 = (day && ql == 15 && d == down && info.sun(c.id)) ? 15 : ql - 1
                    if nv > bank(c.light) { setBank(n, day: day, nv); spread.append(n) }
                }
            }
        }
        guard !edited.isEmpty else { return }
        var touched = Set<SIMD3<Int>>()
        for (bp, b) in edited {
            blocks[bp] = b
            touched.insert(bp)
            for d in dirs { touched.insert(bp &+ d) }   // faces on the block edge read neighbour light
        }
        onRelit?(touched)
    }

    /// A cheap immutable copy of the block table for off-thread meshing. The
    /// dictionary is copy-on-write and every writer replaces whole blocks, so
    /// the snapshot's MapBlocks never change after this returns.
    public func snapshot() -> WorldSnapshot { WorldSnapshot(blocks: blocks) }

    /// Client-side unload, after Map::timerUpdate. Blocks never left memory
    /// before this, so a long session kept every block the server ever sent.
    /// A block "in use" (within `radius` mapblocks of the player, which is how
    /// the engine's mesher/renderer keep touching nearby blocks) has its usage
    /// timer reset each tick; every other block ages and is dropped once it has
    /// sat unused for `timeout` seconds. A hard `limit` then evicts the
    /// longest-unused blocks first (never one in use), so walking a long way
    /// can't grow memory without bound. Returns what was dropped so the caller
    /// can tell the server (TOSERVER_DELETEDBLOCKS) and drop the meshes.
    /// Defaults are the engine's: 600 s and 7500 blocks (~120 MB).
    @discardableResult
    public func expire(dt: Float, near: SIMD3<Int>, radius: Int = 12,
                       timeout: Float = 600, limit: Int = 7500) -> [SIMD3<Int>] {
        var evicted: [SIMD3<Int>] = []
        for (p, b) in blocks {
            let dx = abs(p.x - near.x), dy = abs(p.y - near.y), dz = abs(p.z - near.z)
            if max(dx, max(dy, dz)) <= radius {
                b.usage = 0
            } else {
                b.usage += dt
                if b.usage > timeout { evicted.append(p) }
            }
        }
        let over = blocks.count - evicted.count - limit
        if over > 0 {
            let gone = Set(evicted)
            let byAge = blocks.values
                .filter { !gone.contains($0.pos) && $0.usage > 0 }
                .sorted { $0.usage > $1.usage }
            for b in byAge.prefix(over) { evicted.append(b.pos) }
        }
        guard !evicted.isEmpty else { return [] }
        for p in evicted { blocks[p] = nil }
        let goneSet = Set(evicted)
        for k in nodeMeta.keys where goneSet.contains(WorldMap.blockPos(k)) { nodeMeta[k] = nil }
        for k in nodeFormspecs.keys where goneSet.contains(WorldMap.blockPos(k)) { nodeFormspecs[k] = nil }
        return evicted
    }

    public func removeNode(_ p: SIMD3<Int>) {
        // A dug cell becomes air. With the node registry's light tables the
        // relight in setNode fills it properly; before NODEDEF fall back
        // to the brightest neighbour minus one so a hole isn't pitch black.
        if lightInfo != nil { setNode(p, param0: WorldMap.CONTENT_AIR, param1: 0); return }
        let nb = neighborLight(p)
        let day = UInt8(max(0, Int(nb & 0x0F) - 1))
        let night = UInt8(max(0, Int(nb >> 4) - 1))
        setNode(p, param0: WorldMap.CONTENT_AIR, param1: day | (night << 4))
    }

    public func decodeAddNode(_ payload: Data) -> SIMD3<Int> {
        let r = PacketReader(payload)
        let p = SIMD3(r.s16(), r.s16(), r.s16())
        let param0 = UInt16(r.u16() & 0xFFFF); let param1 = UInt8(r.u8() & 0xFF); let param2 = UInt8(r.u8() & 0xFF)
        setNode(p, param0: param0, param1: param1, param2: param2)
        return p
    }

    public func decodeRemoveNode(_ payload: Data) -> SIMD3<Int> {
        let r = PacketReader(payload)
        let p = SIMD3(r.s16(), r.s16(), r.s16())
        removeNode(p)
        return p
    }

    public struct RayHit {
        public let under: SIMD3<Int>; public let above: SIMD3<Int>
        public var dist: Float = 0   // along the (normalised) ray to where it enters `under`
    }

    /// Voxel ray walk (Amanatides & Woo) in node space. Returns the first solid
    /// node hit (`under`) and the air node just before it (`above`, the place
    /// target). `origin`/`dir` are in node coordinates.
    /// `pointable` follows Luanti's pointing raycast: nodes it returns false
    /// for (water, air) are passed through instead of stopping the ray.
    /// `boxes` returns a node's selection boxes in node-local 0..1 space (nil =
    /// the full cube): a slab is only hit where its box is, and `above` is the
    /// neighbour across the box face the ray entered (RaycastState::getIntersection).
    public func raycast(origin: SIMD3<Float>, dir: SIMD3<Float>, maxDist: Float,
                        pointable: (UInt16) -> Bool = { _ in true },
                        boxes: (SIMD3<Int>, UInt16) -> [(lo: SIMD3<Float>, hi: SIMD3<Float>)]? = { _, _ in nil }) -> RayHit? {
        let len = (dir.x*dir.x + dir.y*dir.y + dir.z*dir.z).squareRoot()
        let d = len > 1e-8 ? dir / len : SIMD3<Float>(0, 0, -1)
        var pos = SIMD3(Int(floor(origin.x)), Int(floor(origin.y)), Int(floor(origin.z)))
        let step = SIMD3(d.x > 0 ? 1 : -1, d.y > 0 ? 1 : -1, d.z > 0 ? 1 : -1)
        func tvals(_ axis: Int) -> (tMax: Float, tDelta: Float) {
            let dd = d[axis]
            if abs(dd) < 1e-8 { return (.infinity, .infinity) }
            let next = Float(pos[axis] + (step[axis] > 0 ? 1 : 0))
            return ((next - origin[axis]) / dd, abs(1.0 / dd))
        }
        var tMax = SIMD3<Float>(tvals(0).tMax, tvals(1).tMax, tvals(2).tMax)
        let tDelta = SIMD3<Float>(tvals(0).tDelta, tvals(1).tDelta, tvals(2).tDelta)
        let start = pos
        var prev = pos
        var t: Float = 0
        var guardCount = 0
        while t <= maxDist && guardCount < 256 {
            guardCount += 1
            let id = nodeId(pos)
            // The start cell counts too, like the engine's first iteration
            // (environment.cpp): with your head in a ladder, vine or a door's top
            // half, that's what you're pointing at, not the wall behind it.
            if id != WorldMap.CONTENT_IGNORE && id != WorldMap.CONTENT_AIR && pointable(id) {
                let cube: [(lo: SIMD3<Float>, hi: SIMD3<Float>)] = [(SIMD3(0, 0, 0), SIMD3(1, 1, 1))]
                guard let bx = boxes(pos, id) ?? (pos == start ? cube : nil) else {
                    return RayHit(under: pos, above: prev, dist: t)
                }
                // Partial node: slab-test each box; the nearest entry face gives `above`.
                let base = SIMD3<Float>(Float(pos.x), Float(pos.y), Float(pos.z))
                var best: (t: Float, axis: Int, sign: Int)? = nil
                for b in bx {
                    var tEnter: Float = -.infinity, tExit: Float = .infinity
                    var axis = 0, sign = 0
                    var ok = true
                    for a in 0..<3 {
                        let lo = base[a] + b.lo[a], hi = base[a] + b.hi[a]
                        if abs(d[a]) < 1e-8 {
                            if origin[a] < lo || origin[a] > hi { ok = false; break }
                            continue
                        }
                        var t0 = (lo - origin[a]) / d[a], t1 = (hi - origin[a]) / d[a]
                        var s = -1
                        if t0 > t1 { swap(&t0, &t1); s = 1 }
                        if t0 > tEnter { tEnter = t0; axis = a; sign = s }
                        tExit = min(tExit, t1)
                        if tEnter > tExit { ok = false; break }
                    }
                    guard ok, tExit >= 0, tEnter <= maxDist else { continue }
                    if best == nil || tEnter < best!.t { best = (max(tEnter, 0), axis, sign) }
                }
                if let best {
                    var above = pos
                    if best.t <= 0 {
                        // The ray starts inside the box: no entry face, so place
                        // back toward the eye along the ray's main axis.
                        let ax = abs(d.x) >= abs(d.y) && abs(d.x) >= abs(d.z) ? 0 : (abs(d.y) >= abs(d.z) ? 1 : 2)
                        above[ax] -= step[ax]
                    } else {
                        above[best.axis] += best.sign
                    }
                    return RayHit(under: pos, above: above, dist: best.t)
                }
                // Ray misses every box of this node: keep walking.
            }
            prev = pos
            if tMax.x < tMax.y && tMax.x < tMax.z { pos.x += step.x; t = tMax.x; tMax.x += tDelta.x }
            else if tMax.y < tMax.z { pos.y += step.y; t = tMax.y; tMax.y += tDelta.y }
            else { pos.z += step.z; t = tMax.z; tMax.z += tDelta.z }
        }
        return nil
    }
}

/// Read-only view of a voxel world, so the mesher can run over either the live
/// WorldMap or an off-thread snapshot of it.
public protocol WorldView {
    var blocks: [SIMD3<Int>: WorldMap.MapBlock] { get }
    func nodeId(_ p: SIMD3<Int>) -> UInt16
    func nodeLight(_ p: SIMD3<Int>) -> UInt8
    func nodeParam2(_ p: SIMD3<Int>) -> UInt8
}

extension WorldMap: WorldView {}

/// Neighbour-based lighting, derived purely from `nodeLight`, so it works over
/// the live map or an off-thread snapshot alike.
public extension WorldView {
    /// Brightest light reaching this cell from its 6 face neighbours, kept per
    /// nibble (low = day/sky, high = night/torch).
    func neighborLight(_ p: SIMD3<Int>) -> UInt8 {
        var day: UInt8 = 0, night: UInt8 = 0
        for d in WorldMap.sixDirs {
            let l = nodeLight(p &+ d)
            day = max(day, l & 0x0F); night = max(night, l >> 4)
        }
        return day | (night << 4)
    }

    /// Light for a node that doesn't fully occupy its cell (door, plant, torch,
    /// rail, sign, mesh): the max of its own param1 and its neighbours', per
    /// nibble. A swapped-open door leaf has ~0 own light, so without this it
    /// renders black even in a lit doorway.
    func nodeLightLit(_ p: SIMD3<Int>) -> UInt8 {
        let own = nodeLight(p), nb = neighborLight(p)
        return max(own & 0x0F, nb & 0x0F) | (max(own >> 4, nb >> 4) << 4)
    }
}

/// Immutable snapshot of a WorldMap's blocks for background meshing. Holds the
/// same MapBlock references; safe because every writer replaces blocks wholesale.
public struct WorldSnapshot: WorldView {
    public let blocks: [SIMD3<Int>: WorldMap.MapBlock]
    public init(blocks: [SIMD3<Int>: WorldMap.MapBlock]) { self.blocks = blocks }

    public func nodeId(_ p: SIMD3<Int>) -> UInt16 {
        guard let b = blocks[WorldMap.blockPos(p)] else { return WorldMap.CONTENT_IGNORE }
        return b.param0[WorldMap.index(p.x & 15, p.y & 15, p.z & 15)]
    }
    public func nodeLight(_ p: SIMD3<Int>) -> UInt8 {
        guard let b = blocks[WorldMap.blockPos(p)] else { return 0x0F }
        return b.param1[WorldMap.index(p.x & 15, p.y & 15, p.z & 15)]
    }
    public func nodeParam2(_ p: SIMD3<Int>) -> UInt8 {
        guard let b = blocks[WorldMap.blockPos(p)] else { return 0 }
        return b.param2[WorldMap.index(p.x & 15, p.y & 15, p.z & 15)]
    }
}
