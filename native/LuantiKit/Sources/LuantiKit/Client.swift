import Foundation
import CryptoKit

/// A Luanti game-client session: the same join sequence the official desktop
/// client runs (src/client/client.cpp), reimplemented in Swift. Drives the
/// handshake over Connection, authenticates the player's own account with
/// SRP-6a (registering the name with FIRST_SRP on a server where it's new,
/// exactly like the desktop client's first join), then receives the world:
/// node/item definitions, media, map blocks, entities, HUD, inventories.
/// Originally ported via luanti_client.gd. No login UI here: give it a name
/// and password and call connect().
public final class Client {
    public let conn = Connection()
    public let world = WorldMap()
    public let nodes = NodeRegistry()
    public let items = ItemRegistry()
    public let objects = ActiveObjects()
    public private(set) lazy var media: MediaManager = MediaManager(send: { [weak self] op, data in self?.conn.sendMessage(op, data) })
    private var mediaRequested = false
    private var requestedEntityTiles: Set<String> = []
    private var requestedEntityMeshes: Set<String> = []
    private var initialMediaDone = false
    /// Process start, for the join-milestone "t=+Ns" stamps. The app sets it
    /// from its own launch time so the stamps share one origin.
    nonisolated(unsafe) public static var processStart = CFAbsoluteTimeGetCurrent()   // LuantiKit's own fallback; WorldSession.start() overwrites it with PerfStats.processStart
    public var wieldIndex = 0
    /// Select a hotbar slot (0..8) and tell the server (TOSERVER_PLAYERITEM).
    public func setWieldIndex(_ i: Int) {
        wieldIndex = i
        conn.sendMessage(Op.toserverPlayerItem, PacketWriter().u16(i).data)
    }
    /// First 9 "main" inventory slots (the hotbar), base item names or nil when
    /// empty, from TOCLIENT_INVENTORY. Drives the peripheral hotbar HUD.
    public private(set) var hotbar: [String?] = Array(repeating: nil, count: 9)
    /// One stack in an inventory list ("name count wear meta" itemstring parts).
    /// `meta` is the ItemStackMetadata key/value store: VoxeLibre keeps the
    /// anvil rename in "description", the bow's charge frame and enchant glint
    /// in "inventory_image", enchantments in "mcl_enchanting:enchantments",
    /// dyed armor/banner colour in "mcl_armor:color" etc. (#271).
    public struct ItemStack { public var name: String; public var count: Int; public var wear: Int
        public var meta: [String: String] = [:]
        public init(name: String, count: Int, wear: Int, meta: [String: String] = [:]) {
            self.name = name; self.count = count; self.wear = wear; self.meta = meta
        }
        /// Description override (anvil rename), else nil.
        public var customDescription: String? { meta["description"].flatMap { $0.isEmpty ? nil : $0 } }
        /// inventory_image override (bow charging frames, enchant glint), else nil.
        public var customImage: String? { meta["inventory_image"].flatMap { $0.isEmpty ? nil : $0 } }
    }

    /// Decode the itemstring's 4th field: a JSON-quoted string whose content is
    /// ItemStackMetadata::serialize's form, one leading "\u{1}" then
    /// "key\u{2}value\u{3}" per pair (src/itemstackmetadata.cpp,
    /// serializeJsonString). Anything malformed yields the pairs that did parse.
    static func parseItemMeta(_ quoted: Substring) -> [String: String] {
        var q = quoted.trimmingCharacters(in: .whitespaces)
        guard q.hasPrefix("\"") else { return [:] }
        q.removeFirst()
        if q.hasSuffix("\"") { q.removeLast() }
        // JSON unescape: \uXXXX, \", \\, \n, \t, \r, \/ .
        var out = ""; out.reserveCapacity(q.count)
        var it = q.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            guard let e = it.next() else { break }
            switch e {
            case "u":
                var hex = ""
                for _ in 0..<4 { if let h = it.next() { hex.append(h) } }
                if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            default: out.append(e)      // \" \\ \/
            }
        }
        var meta: [String: String] = [:]
        if out.hasPrefix("\u{1}") { out.removeFirst() }
        for pair in out.split(separator: "\u{3}", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "\u{2}", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            meta[String(kv[0])] = String(kv[1])
        }
        return meta
    }
    /// Every list from the last TOCLIENT_INVENTORY (main, craft, craftpreview,
    /// armor, ...), kept across KeepList lines. Drives the inventory panel.
    public private(set) var inventory: [String: [ItemStack?]] = [:]
    /// Sim/test only: seed a player inventory list so the panel's own grids
    /// (not just a container's) exercise the icon path headless. The sim dev
    /// account is empty, so nothing else fills this. Mirrors
    /// WorldMap.setNodeInventoryForTest.
    public func setPlayerInventoryForTest(list: String, _ stacks: [ItemStack?]) {
        inventory[list] = stacks
    }
    /// Detached inventories (creative list, ender chest, shared/mod containers)
    /// keyed by their server name, each name->lists. Referenced by a formspec's
    /// `detached:<name>` list location.
    public private(set) var detached: [String: [String: [ItemStack?]]] = [:]
    public func detachedInventory(_ name: String, list: String = "main") -> [ItemStack?]? { detached[name]?[list] }
    public var onInventoryLists: (() -> Void)?
    /// TOCLIENT_MOVEMENT (0x45): server walk/fast/crouch/jump/gravity (node units).
    public var onMovement: ((_ walk: Float, _ fast: Float, _ crouch: Float, _ jump: Float, _ gravity: Float) -> Void)?
    /// TOCLIENT_MOVEMENT liquid fields (movement_liquid_fluidity, _smooth,
    /// _sink): VoxeLibre sets sink=23 vs the engine's 10, i.e. you sink 2.3x
    /// faster in its water than in a default game (#274).
    public var onLiquidMovement: ((_ fluidity: Float, _ fluiditySmooth: Float, _ sink: Float) -> Void)?
    /// movement_acceleration_default in node/s^2 as the engine actually applies
    /// it: the setting is stored pre-multiplied by BS (player.cpp) and
    /// applyControl multiplies by BS again (localplayer.cpp:715), so the
    /// effective ground acceleration is the wire value x10 (VoxeLibre 2.4 -> 24).
    /// Only slippery nodes use it here (#269): elsewhere our stick speed is
    /// applied directly, but ice scales this by 1/(slippery+1) for its glide.
    public private(set) var accelDefault: Float = 30
    /// movement_speed_climb from MOVEMENT (ladders/vines; engine default 3,
    /// VoxeLibre's minetest.conf sets 2.35) (#299).
    public private(set) var speedClimb: Float = 3
    /// TOCLIENT_SHOW_FORMSPEC (0x44): a server dialog. formspec text + form name.
    public var onShowFormspec: ((_ formspec: String, _ formname: String) -> Void)?
    /// TOCLIENT_INVENTORY_FORMSPEC (0x42): the player's own inventory form
    /// (mcl_inventory's survival page with the offhand/armour slots, or the
    /// creative browser). Empty = the server never sent one (#281).
    public private(set) var inventoryFormspec = ""
    public var onInventoryFormspec: ((_ formspec: String) -> Void)?
    /// TOCLIENT_HUD_SET_FLAGS (0x4c) state, hud.h HUD_FLAG_*: 1 hotbar,
    /// 2 healthbar, 4 crosshair, 8 wielditem, 16 breathbar, 32 minimap,
    /// 64 minimap_radar, 128 basic_debug, 256 chat. Everything on by default.
    public private(set) var hudFlags: UInt32 = 0xFFFF_FFFF
    /// TOCLIENT_PRIVILEGES (0x41): the names the server granted us ("fly",
    /// "fast", "noclip", "interact", ...). The engine gates free_move on
    /// "fly" (Game::toggleFreeMove checks checkPrivilege) (#291).
    public private(set) var privileges: Set<String> = []
    public var onPrivileges: ((Set<String>) -> Void)?
    public var onHudFlags: ((UInt32) -> Void)?
    /// TOCLIENT_EYE_OFFSET (0x52): first-person camera offset in nodes (the
    /// wire is BS units; mcl_beds sends y -13 for the lying-down view).
    public var onEyeOffset: ((SIMD3<Float>) -> Void)?
    /// TOCLIENT_CHAT_MESSAGE (0x2f): type (0 raw,1 normal,2 announce,3 system), sender, text.
    public var onChat: ((_ type: Int, _ sender: String, _ text: String) -> Void)?
    /// TOCLIENT_SET_SKY (0x4f): a flat sky colour for non-"regular" skies
    /// (Nether/End), rgb 0..1, or nil to restore the procedural sky.
    /// Current server sky look (see SkyParams); `onSky` fires on every change.
    public private(set) var sky = SkyParams()
    public var onSky: ((SkyParams) -> Void)?
    /// A server-pushed media file (MEDIA_PUSH) has landed and been acked; the
    /// session can forget anything it baked from the old bytes.
    public var onMediaPushed: ((_ name: String) -> Void)?
    /// TOCLIENT_PLAYER_SPEED (0x2b): add a velocity impulse (knockback), node/s.
    public var onPlayerSpeed: ((SIMD3<Float>) -> Void)?
    /// TOCLIENT_MOVE_PLAYER_REL (0x5d): add a position delta (piston/elevator), nodes.
    public var onMovePlayerRel: ((SIMD3<Float>) -> Void)?
    /// TOSERVER_INVENTORY_ACTION: the raw serialized InventoryAction text
    /// ("Move <count> current_player <list> <i> current_player <list> <i>",
    /// "MoveSomewhere ...", "Drop ...", "Craft <count> current_player"). Count 0
    /// means the whole stack. No length prefix: Client::sendInventoryAction
    /// putRawString()s it.
    public func sendInventoryAction(_ text: String) {
        conn.sendMessage(Op.toserverInventoryAction, Data(text.utf8))
        print("[inv] -> \(text)"); fflush(stdout)
        predictInventoryAction(text)   // apply locally so the panel updates instantly (server echo reconciles)
    }

    /// One end of an inventory move: an inventory location (e.g. "current_player",
    /// "nodemeta:x,y,z", "detached:name"), a list name, and a slot index.
    public struct InvRef {
        public var loc: String, list: String, index: Int
        public init(_ loc: String, _ list: String, _ index: Int) { self.loc = loc; self.list = list; self.index = index }
    }

    /// The four InventoryAction serializations, exactly as
    /// inventorymanager.cpp's IMoveAction/IDropAction/ICraftAction parse them
    /// (space-separated, no length prefix). Built here (not inline in the UI) so
    /// a slip in the field order — which silently moves the wrong stack or drops
    /// an item — is caught by tests. Count 0 means the whole stack.
    public static func moveAction(count: Int, from: InvRef, to: InvRef) -> String {
        "Move \(count) \(from.loc) \(from.list) \(from.index) \(to.loc) \(to.list) \(to.index)"
    }
    /// MoveSomewhere (shift-click quick-move): the server picks the destination
    /// slots, so no to-index. Its apply loop runs WHILE count > 0, so a count of
    /// 0 moves nothing -- the opposite of a plain Move, where 0 means the whole
    /// stack. So map our "0 = all" convention to a count bigger than any stack;
    /// the server clamps it to what's actually in the source slot.
    public static func moveSomewhereAction(count: Int, from: InvRef, toLoc: String, toList: String) -> String {
        "MoveSomewhere \(count > 0 ? count : 9999) \(from.loc) \(from.list) \(from.index) \(toLoc) \(toList)"
    }
    public static func dropAction(count: Int, from: InvRef) -> String {
        "Drop \(count) \(from.loc) \(from.list) \(from.index)"
    }
    public static func craftAction(count: Int, craftLoc: String) -> String {
        "Craft \(count) \(craftLoc)"
    }

    // MARK: - Client-side inventory prediction
    //
    // Desktop Luanti keeps the "held" item as a source reference + amount and
    // applies each move to a LOCAL inventory copy immediately (then the server
    // echo reconciles), so the panel updates instantly and the held amount can't
    // drift from the real slot. These pure `apply*` helpers mirror
    // inventorymanager.cpp's IMoveAction/IDropAction merge/swap/clamp rules and
    // are unit-tested; the `perform*` methods send the action AND predict.
    // count == 0 means "the whole source stack".

    /// Move `count` from one slot to another within the same list dictionary,
    /// merging same items (clamped to stack_max), swapping different ones (only a
    /// whole-stack move can swap), or placing into an empty slot.
    public static func applyMove(_ lists: inout [String: [ItemStack?]],
                                 fromList: String, fromIdx: Int, toList: String, toIdx: Int,
                                 count: Int, stackMax: (String) -> Int) {
        guard let sArr = lists[fromList], fromIdx >= 0, fromIdx < sArr.count, let s = sArr[fromIdx] else { return }
        guard let dArr = lists[toList], toIdx >= 0, toIdx < dArr.count else { return }
        if fromList == toList && fromIdx == toIdx { return }
        let n = count == 0 ? s.count : Swift.min(count, s.count)
        guard n > 0 else { return }
        let d = dArr[toIdx]
        var newSrc: ItemStack?, newDst: ItemStack?
        if d == nil {
            newDst = ItemStack(name: s.name, count: n, wear: s.wear)
            newSrc = (s.count - n) <= 0 ? nil : ItemStack(name: s.name, count: s.count - n, wear: s.wear)
        } else if d!.name == s.name && d!.wear == s.wear {
            let moved = Swift.max(0, Swift.min(n, stackMax(s.name) - d!.count))
            newDst = ItemStack(name: d!.name, count: d!.count + moved, wear: d!.wear)
            let rem = s.count - moved
            newSrc = rem <= 0 ? nil : ItemStack(name: s.name, count: rem, wear: s.wear)
        } else {
            guard n == s.count else { return }   // partial move onto a different item is a no-op in Luanti
            newDst = ItemStack(name: s.name, count: s.count, wear: s.wear)
            newSrc = d
        }
        if fromList == toList {
            var arr = sArr; arr[fromIdx] = newSrc; arr[toIdx] = newDst; lists[fromList] = arr
        } else {
            lists[fromList]?[fromIdx] = newSrc; lists[toList]?[toIdx] = newDst
        }
    }

    /// Remove `count` from a slot (dropped into the world).
    public static func applyDrop(_ lists: inout [String: [ItemStack?]], fromList: String, fromIdx: Int, count: Int) {
        guard let arr = lists[fromList], fromIdx >= 0, fromIdx < arr.count, let s = arr[fromIdx] else { return }
        let n = count == 0 ? s.count : Swift.min(count, s.count)
        let rem = s.count - n
        lists[fromList]?[fromIdx] = rem <= 0 ? nil : ItemStack(name: s.name, count: rem, wear: s.wear)
    }

    /// Distribute `count` from a slot into another list: fill matching stacks
    /// first (clamped), then empty slots. Cross-list only (shift-click).
    public static func applyMoveSomewhere(_ lists: inout [String: [ItemStack?]],
                                          fromList: String, fromIdx: Int, toList: String,
                                          count: Int, stackMax: (String) -> Int) {
        guard fromList != toList else { return }
        guard let sArr = lists[fromList], fromIdx >= 0, fromIdx < sArr.count, let s = sArr[fromIdx] else { return }
        guard var dst = lists[toList] else { return }
        let want = count == 0 ? s.count : Swift.min(count, s.count)
        var remaining = want
        let mx = stackMax(s.name)
        for i in dst.indices where remaining > 0 {
            if let d = dst[i], d.name == s.name, d.wear == s.wear, d.count < mx {
                let moved = Swift.min(remaining, mx - d.count); dst[i]!.count += moved; remaining -= moved
            }
        }
        for i in dst.indices where remaining > 0 {
            if dst[i] == nil { let put = Swift.min(remaining, mx); dst[i] = ItemStack(name: s.name, count: put, wear: s.wear); remaining -= put }
        }
        lists[toList] = dst
        let moved = want - remaining
        let rem = s.count - moved
        lists[fromList]?[fromIdx] = rem <= 0 ? nil : ItemStack(name: s.name, count: rem, wear: s.wear)
    }

    /// Test-only: seed the local inventory so prediction can be exercised without
    /// a live server echo.
    func debugSetInventory(_ lists: [String: [ItemStack?]]) { inventory = lists }

    /// Parse an InventoryAction string and predict its effect on the local player
    /// inventory (current_player only for v1; other locations rely on the echo).
    /// Kept `internal` so tests can drive it directly. Craft is not predicted
    /// (needs recipes); the server echo fills craftresult a beat later.
    func predictInventoryAction(_ text: String) {
        let f = text.split(separator: " ").map(String.init)
        guard let verb = f.first else { return }
        let sm: (String) -> Int = { self.items.stackMax($0) }
        switch verb {
        case "Move" where f.count >= 8:
            // Move <count> <fromLoc> <fromList> <fromIdx> <toLoc> <toList> <toIdx>
            guard let c = Int(f[1]), let fi = Int(f[4]), let ti = Int(f[7]),
                  f[2] == "current_player", f[5] == "current_player" else { return }
            Client.applyMove(&inventory, fromList: f[3], fromIdx: fi, toList: f[6], toIdx: ti, count: c, stackMax: sm)
            onInventoryLists?()
        case "MoveSomewhere" where f.count >= 7:
            // MoveSomewhere <count> <fromLoc> <fromList> <fromIdx> <toLoc> <toList>
            guard let c = Int(f[1]), let fi = Int(f[4]),
                  f[2] == "current_player", f[5] == "current_player" else { return }
            Client.applyMoveSomewhere(&inventory, fromList: f[3], fromIdx: fi, toList: f[6], count: c, stackMax: sm)
            onInventoryLists?()
        case "Drop" where f.count >= 5:
            // Drop <count> <fromLoc> <fromList> <fromIdx>
            guard let c = Int(f[1]), let fi = Int(f[4]), f[2] == "current_player" else { return }
            Client.applyDrop(&inventory, fromList: f[3], fromIdx: fi, count: c)
            onInventoryLists?()
        default:
            break
        }
    }

    /// Player health 0..20 (VoxeLibre: 10 hearts, 2 hp each), from TOCLIENT_HP.
    public private(set) var hp: Int = 20
    /// Food points 0..20 (VoxeLibre: 10 drumsticks, 2 each). Hunger is NOT sent
    /// via TOCLIENT_HP; it rides the statbar HUD system (hudbars/mcl_hunger), so
    /// we track the hunger statbar's `number` field from the HUD packets.
    public private(set) var hunger: Int = 20
    /// 0.15 (night) .. 1.0 (noon), from TOCLIENT_TIME_OF_DAY.
    public private(set) var daylight: Float = 1.0
    private var timeOfDay: Float = 12000
    private var timeSpeed: Float = 0
    /// Fraction of the day, 0..1 (0.5 = noon).
    public var timeFraction: Float { timeOfDay / 24000 }
    private var srp: SRP?
    private var defsReady = false
    private var clientReadySent = false
    private var spawn = SIMD3<Float>(0, 20, 0)   // SERVER-frame node coords; updated by MOVE_PLAYER
    private var dayNightOverride: Float? = nil   // OVERRIDE_DAY_NIGHT_RATIO (cave/Nether/End)
    var protoVer = 0                              // negotiated protocol version (TOCLIENT_HELLO; test-settable)
    /// Luanti centres node g on g (it spans [g-0.5, g+0.5]); our mesh, physics
    /// and raycast draw node g at [g, g+1]. Every position crossing the wire is
    /// shifted here, once, so nothing downstream needs a +0.5 patch (#78):
    /// server -> us adds gridShift, us -> server subtracts it.
    public static let gridShift = SIMD3<Float>(0.5, 0.5, 0.5)
    // Invariant: only positions crossing the wire get +/- gridShift. A position
    // built locally (e.g. a node sound) must be authored in our [g,g+1] grid
    // directly (node centre = g+0.5), and a node index from an our-grid position
    // is floor(pos), never round(pos) (round sends g+0.5 to g+1).
    private var yaw: Float = 0, pitch: Float = 0
    private var posTimer: Double = 0
    /// Blocks the server streams within (PLAYERPOS wanted_range). Settable so a
    /// view-distance slider can trade draw distance for GPU/thermal load (#161).
    public var wantedRange = 8 { didSet { wantedRange = max(2, min(15, wantedRange)) } }
    private let name: String
    public var playerName: String { name }
    private let password: String
    /// Statbar HUD elements keyed by server-assigned id, tracked so a later
    /// TOCLIENT_HUDCHANGE (which addresses an element by id) can update the right
    /// one. We only keep statbar-type elements; each is (icon text, number).
    private var statbars: [Int: (text: String, number: Int)] = [:]
    /// Every HUD element's type by id, so a HUDCHANGE on a non-statbar element
    /// (the XP bar's texture swap) isn't dropped on the floor.
    private var hudTypes: [Int: Int] = [:]
    /// VoxeLibre XP (mcl_experience): an "image" element whose texture string
    /// carries the fill as ^[lowpart:<pct>: (only set via HUDCHANGE, the add
    /// has no text), and a "text" element in XP green (0x80FF20) holding the
    /// level ("" at level 0).
    private var xpBarId: Int? = nil
    private var xpLevelId: Int? = nil
    public private(set) var xpLevel = 0
    public private(set) var xpFraction: Float = 0   // 0..1 progress to the next level
    public var onXp: ((_ level: Int, _ fraction: Float) -> Void)?

    /// A server HUD element (HUDADD/HUDCHANGE), every field kept so the session
    /// can draw generic image/text/waypoint elements (#103: boss bars, potion
    /// effects, vignettes). Statbars and the XP pair also have dedicated paths.
    public struct HudElement: Equatable {
        public var type = 0                        // 0 image, 1 text, 2 statbar, 3 inventory, 4 waypoint, 5 image_waypoint, 6 compass, 7 minimap, 8 hotbar
        public var pos = SIMD2<Float>(0, 0)        // normalised screen position
        public var name = ""
        public var scale = SIMD2<Float>(1, 1)
        public var text = ""
        public var number = 0
        public var item = 0
        public var dir = 0
        public var align = SIMD2<Float>(0, 0)
        public var offset = SIMD2<Float>(0, 0)     // pixels
        public var worldPos = SIMD3<Float>(0, 0, 0) // nodes (server grid), for waypoints
        public var size = SIMD2<Float>(0, 0)
        public var zIndex = 0
        public var text2 = ""
        public var style = 0
        public init() {}
    }
    public private(set) var hudElements: [Int: HudElement] = [:]
    /// Bumped whenever hudElements changes (add/change/remove), so the renderer
    /// can cache its sorted view and skip re-sorting ~80 elements every frame.
    public private(set) var hudGeneration: Int = 0
    /// Ids the XP HUD path already draws, so the generic path skips them.
    public var xpHudIds: Set<Int> { Set([xpBarId, xpLevelId].compactMap { $0 }) }

    /// Fill percent from mcl_experience's bar texture, e.g.
    /// "(mcl_experience_bar_background.png^[lowpart:42:mcl_experience_bar.png)^[resize:40x1456^[transformR270".
    static func xpLowpart(_ tex: String) -> Int? {
        guard tex.contains("mcl_experience_bar"), let r = tex.range(of: "[lowpart:") else { return nil }
        return Int(tex[r.upperBound...].prefix { $0.isNumber })
    }
    /// The id of the hunger statbar (icon "hbhunger_icon.png"), if seen. Breath
    /// and other statbars are ignored; we match by icon name, not by order.
    private var hungerStatbarId: Int?
    /// The id of the breath/oxygen statbar (icon "hudbars_icon_breath.png").
    private var breathStatbarId: Int?
    /// The id of the armor statbar (icon "hbarmor_icon.png").
    private var armorStatbarId: Int?
    /// Armor points 0..20 (10 icons, 2 each), from the mcl_hbarmor statbar.
    public private(set) var armor: Int = 0
    /// Armor changed; arg is 0..20.
    public var onArmor: ((_ armor: Int) -> Void)?

    public var onAuthenticated: ((_ mapSeed: UInt64) -> Void)?
    /// (reason, code). code is AccessDeniedCode (8 = already-connected, etc); -1
    /// for client-side auth failures. The consumer decides retryable by code.
    public var onAccessDenied: ((String, Int) -> Void)?
    public var onDisconnected: ((String) -> Void)?
    /// A map block was decoded; arg is its block position.
    public var onBlock: ((SIMD3<Int>) -> Void)?
    /// A single node changed (ADDNODE/REMOVENODE): remesh now, not after the
    /// block-stream coalesce. Doors/switches only move when this lands.
    public var onNodeChanged: ((SIMD3<Int>) -> Void)?
    /// All requested media (textures) have arrived; time to (re)build the atlas.
    public var onMediaReady: (() -> Void)?
    /// Server placed/moved the player; arg is node position + (yaw,pitch) radians.
    public var onSpawn: ((_ pos: SIMD3<Float>, _ yaw: Float, _ pitch: Float) -> Void)?
    /// Server set the player's health (TOCLIENT_HP); arg is hp 0..20.
    public var onHP: ((_ hp: Int, _ damageEffect: Bool) -> Void)?
    /// Respawn after death. The legacy TOSERVER_RESPAWN (0x38) is null-handled by
    /// modern servers, so instead submit the builtin death formspec: the server
    /// respawns when it receives fields for "__builtin:death" with `quit` while
    /// the player is at 0 hp (builtin/game/death_screen.lua). Sending the legacy
    /// packet too is harmless for older servers.
    /// TOSERVER_NODEMETA_FIELDS (0x3b): submit a node formspec's fields (sign
    /// text, container quit, furnace buttons). Wire: v3s16 pos, string16
    /// formname, u16 count, then string16 name + string32 value per field.
    /// TOSERVER_CHAT_MESSAGE (0x32): a wide string (chat line or /command).
    public func sendChat(_ text: String) {
        guard !text.isEmpty else { return }
        conn.sendMessage(Op.toserverChatMessage, PacketWriter().wstring(text).data)
        print("[chat] -> \(text)"); fflush(stdout)
    }

    public func sendNodeFields(pos: SIMD3<Int>, formname: String = "", fields: [String: String]) {
        let w = PacketWriter()
        w.s16(pos.x).s16(pos.y).s16(pos.z)
        w.string16(formname)
        w.u16(fields.count)
        for (k, v) in fields { w.string16(k).string32(v) }
        conn.sendMessage(Op.toserverNodeMetaFields, w.data)
        print("[inv] node fields -> \(pos) \(fields.keys.sorted())"); fflush(stdout)
    }

    /// Submit fields for a player (non-node) formspec, e.g. the bed "Leave bed"
    /// button (formname "mcl_beds_form", field "leave"). Mirrors sendRespawn.
    /// TOSERVER_REMOVED_SOUNDS (0x3a): u16 count + s32 ids of server-handled
    /// sounds that finished on their own, so the server can drop its handle
    /// (Client::sendRemovedSounds; without it the server's playing_sounds map
    /// only shrinks on explicit stops). Ephemeral (id -1) sounds are never
    /// reported, matching the engine.
    public func sendRemovedSounds(_ ids: [Int]) {
        guard !ids.isEmpty else { return }
        let w = PacketWriter().u16(ids.count)
        for id in ids { w.u32(id & 0xFFFF_FFFF) }
        conn.sendMessage(Op.toserverRemovedSounds, w.data)
    }

    public func sendPlayerFields(formname: String, fields: [String: String]) {
        conn.sendMessage(Op.toserverInventoryFields, Client.inventoryFieldsPacket(formname: formname, fields: fields))
    }

    /// TOSERVER_INVENTORY_FIELDS body (string16 formname, u16 count, then
    /// string16 key + string32 value per field). Split out so tests can decode
    /// it: closing a named show_formspec form (a chest's "mcl_chests:...") sends
    /// this with quit, which is what fires the server's on_player_receive_fields
    /// (#130). A wrong packet here leaves chests visually open.
    static func inventoryFieldsPacket(formname: String, fields: [String: String]) -> Data {
        let w = PacketWriter()
        w.string16(formname)
        w.u16(fields.count)
        for (k, v) in fields { w.string16(k).string32(v) }
        return w.data
    }

    public func sendRespawn() {
        let w = PacketWriter()
        w.string16("__builtin:death")            // formname (must match what the server showed)
        w.u16(2)                                 // field count
        w.string16("btn_respawn").string32("")   // the Respawn button
        w.string16("quit").string32("true")      // button_exit closes -> quit
        conn.sendMessage(Op.toserverInventoryFields, w.data)
        conn.sendMessage(Op.toserverRespawn, Data())
    }
    /// Hunger changed (from the mcl_hunger statbar HUD element); arg is food
    /// points 0..20 (10 drumsticks, 2 each).
    public var onHunger: ((_ hunger: Int) -> Void)?
    /// Breath/oxygen changed (mcl_hunger/hudbars breath statbar); arg is 0..20
    /// (10 bubbles, 2 each). Full on land; drops while the head is underwater.
    public var onBreath: ((_ breath: Int) -> Void)?
    /// Server sent the inventory (TOCLIENT_INVENTORY); arg is the first 9 "main"
    /// slots (base item names or nil for empty). Only fires when the main list
    /// was actually (re)sent, so a KeepList doesn't wipe the hotbar.
    public var onInventory: ((_ main: [String?]) -> Void)?
    /// Server asked us to start a sound (TOCLIENT_PLAY_SOUND).
    public var onPlaySound: ((SoundSpec) -> Void)?
    /// One-shot particle from TOCLIENT_SPAWN_PARTICLE: position/velocity in node
    /// units, size (nodes), lifetime (s), and the texture spec. Used for potion
    /// splashes and other server particles.
    /// A particle spawner (TOCLIENT_ADD_PARTICLESPAWNER): emit `amount` particles
    /// spread over `time` seconds (time 0 = a one-shot burst), each with a random
    /// position/velocity in the given ranges. Positions are already in our grid.
    /// The look-related tail of ParticleParameters shared by one-shot particles
    /// and spawners (particles.cpp deSerialize / handleCommand_AddParticleSpawner):
    /// tile animation, glow, vertical, and the node= source (#307).
    public struct ParticleLook: Equatable {
        public var vertical = false
        public var collisionRemoval = false
        /// TileAnimation: 0 none, 1 vertical frames (a = aspect_w, b = aspect_h,
        /// length = whole-cycle seconds), 2 sheet_2d (a = frames_w, b = frames_h,
        /// length = per-frame seconds).
        public var animType = 0
        public var animA = 1
        public var animB = 1
        public var animLength: Float = 0
        public var glow = 0                    // 0..14 light floor (Particle::updateLight)
        public var objectCollision = false
        /// node=: draw a random tile of this node instead of `texture`
        /// (ParticleManager::getNodeParticleParams); 0 = not a node particle.
        public var nodeId = 0
        public var nodeTile = 0                // 0 = random face, else face index + 1
        // 5.6+ physics extras (Particle::step): per-axis drag, brownian jitter
        // range picked every frame, bounciness on collision.
        public var drag: SIMD3<Float> = .zero
        public var jitterMin: SIMD3<Float> = .zero
        public var jitterMax: SIMD3<Float> = .zero
        public var bounce: Float = 0
        // 5.9+ texture tweens over the particle's life (ParticleTexture):
        // size multiplier start->end; alpha is parsed for completeness but the
        // entity pass is alpha-tested, so it isn't drawn yet.
        public var scaleStart: SIMD2<Float> = SIMD2(1, 1)
        public var scaleEnd: SIMD2<Float> = SIMD2(1, 1)
        public var alphaStart: Float = 1
        public var alphaEnd: Float = 1
        public var blendMode = 0               // 0 alpha, 1 add, 2 sub, 3 screen, 4 clip
        public init() {}
    }

    public struct ParticleSpawner {
        public var look = ParticleLook()
        /// Tween end ranges (proto >= 42): the spawner blends each range from
        /// start to end over its `time`, so a ramping spawner (potion cloud
        /// thinning out) changes as it ages. nil = same as start.
        public var posMinEnd: SIMD3<Float>? = nil, posMaxEnd: SIMD3<Float>? = nil
        public var velMinEnd: SIMD3<Float>? = nil, velMaxEnd: SIMD3<Float>? = nil
        public var accMinEnd: SIMD3<Float>? = nil, accMaxEnd: SIMD3<Float>? = nil
        public var expMinEnd: Float? = nil, expMaxEnd: Float? = nil
        public var sizeMinEnd: Float? = nil, sizeMaxEnd: Float? = nil
        /// radius: particles spawn on the surface of an ellipsoid of these
        /// radii around pos (lingering potion clouds), zero = plain pos range.
        public var radiusMin: SIMD3<Float> = .zero
        public var radiusMax: SIMD3<Float> = .zero
        public let serverId: Int
        public let amount: Int
        public let time: Float                 // 0 = instantaneous burst
        public let posMin, posMax: SIMD3<Float>
        public let velMin, velMax: SIMD3<Float>
        public let accMin, accMax: SIMD3<Float>
        public let expMin, expMax: Float
        public let sizeMin, sizeMax: Float
        public let attachedId: Int             // 0 = world-anchored, else follow this object
        public let texture: String
        public let collisionRemoval: Bool
        /// collisiondetection: particles stop on walkable nodes (and with
        /// collision_removal, vanish there). Weather spawns flakes 20+ nodes
        /// above the player; underground that's inside rock, so honoring this
        /// is what keeps snow out of caves (#275).
        public let collisionDetection: Bool
        public init(serverId: Int, amount: Int, time: Float, posMin: SIMD3<Float>, posMax: SIMD3<Float>,
                    velMin: SIMD3<Float>, velMax: SIMD3<Float>, accMin: SIMD3<Float>, accMax: SIMD3<Float>,
                    expMin: Float, expMax: Float, sizeMin: Float, sizeMax: Float,
                    attachedId: Int, texture: String, collisionRemoval: Bool, collisionDetection: Bool = false) {
            self.serverId = serverId; self.amount = amount; self.time = time
            self.posMin = posMin; self.posMax = posMax; self.velMin = velMin; self.velMax = velMax
            self.accMin = accMin; self.accMax = accMax; self.expMin = expMin; self.expMax = expMax
            self.sizeMin = sizeMin; self.sizeMax = sizeMax
            self.attachedId = attachedId; self.texture = texture; self.collisionRemoval = collisionRemoval
            self.collisionDetection = collisionDetection
        }
    }
    public var onAddParticleSpawner: ((ParticleSpawner) -> Void)?
    public var onDeleteParticleSpawner: ((Int) -> Void)?
    public var onSpawnParticle: ((_ pos: SIMD3<Float>, _ vel: SIMD3<Float>, _ acc: SIMD3<Float>,
                                  _ size: Float, _ life: Float, _ texture: String, _ collide: Bool,
                                  _ look: ParticleLook) -> Void)?

    /// ServerParticleTexture::deSerialize (5.9+): u8 flags (bit0 animated,
    /// bits1-3 blend mode), alpha f32 tween (style u8, reps u16, beginning f32,
    /// start f32, end f32), scale v2f tween (same head, v2f start, v2f end),
    /// [string32 when !newPropertiesOnly], [animation when animated && !skip].
    static func readTextureTween(_ r: PacketReader, into look: inout ParticleLook, withString: Bool, withAnimation: Bool) {
        let flags = r.u8()
        look.blendMode = (flags >> 1) & 7
        _ = r.u8(); _ = r.u16(); _ = r.f32()
        look.alphaStart = r.f32(); look.alphaEnd = r.f32()
        _ = r.u8(); _ = r.u16(); _ = r.f32()
        look.scaleStart = SIMD2(r.f32(), r.f32()); look.scaleEnd = SIMD2(r.f32(), r.f32())
        if withString { _ = r.string32() }
        if withAnimation, flags & 1 != 0 { readTileAnimation(r, into: &look) }
    }

    /// TileAnimationParams::deSerialize: u8 type, then (u16 aspect_w, u16
    /// aspect_h, f32 length) for vertical frames or (u8 frames_w, u8 frames_h,
    /// f32 frame_length) for a sheet.
    static func readTileAnimation(_ r: PacketReader, into look: inout ParticleLook) {
        let t = r.u8()
        switch t {
        case 1: look.animType = 1; look.animA = max(1, r.u16()); look.animB = max(1, r.u16()); look.animLength = r.f32()
        case 2: look.animType = 2; look.animA = max(1, r.u8()); look.animB = max(1, r.u8()); look.animLength = r.f32()
        default: look.animType = 0
        }
    }
    /// Server asked us to stop a sound by its server id (TOCLIENT_STOP_SOUND).
    public var onStopSound: ((Int) -> Void)?
    /// Server asked us to fade a sound (TOCLIENT_FADE_SOUND): id, step/s, target gain.
    public var onFadeSound: ((_ id: Int, _ step: Float, _ gain: Float) -> Void)?
    /// Any server message we don't handle internally (media, defs, ...).
    public var onMessage: ((Int, Data) -> Void)?

    public init(name: String, password: String) {
        self.name = name
        self.password = password
        self.objects.localPlayerName = name
        conn.onConnected = { [weak self] _ in self?.sendInit() }
        conn.onMessage = { [weak self] op, payload in self?.handle(op, payload) }
        conn.onDisconnected = { [weak self] reason in self?.onDisconnected?(reason) }
    }

    public func connect(host: String, port: UInt16) {
        // Reset the join flags so a reconnect re-runs auth and re-sends
        // CLIENT_READY (else it'd never spawn). Cached nodes/media/world stay;
        // re-announced defs/media re-parse idempotently and cached files skip
        // the download. No-op on a first connect (flags already false).
        srp = nil
        clientReadySent = false
        defsReady = false
        mediaRequested = false
        initialMediaDone = false
        requestedEntityTiles.removeAll()
        requestedEntityMeshes.removeAll()
        media.reset()   // clear in-flight requests so a mid-download drop doesn't hang the reconnect (F2)
        conn.connect(host: host, port: port)
    }
    public func disconnect(_ reason: String = "client disconnect") { conn.disconnect(reason) }
    public func poll(_ delta: Double) {
        conn.poll(delta)
        drainDecodedBlocks()   // splice blocks decoded off-thread since last poll (#179/#180)
        // Advance the day locally between server updates (24000 units = a day).
        timeOfDay = (timeOfDay + timeSpeed * Float(delta) * (24000.0 / 86400.0)).truncatingRemainder(dividingBy: 24000)
        if timeOfDay < 0 { timeOfDay += 24000 }
        updateDaylight()
        if objects.isSolidNode == nil {
            objects.isSolidNode = { [world, nodes] p in
                let id = world.nodeId(p)
                return id != WorldMap.CONTENT_AIR && id != WorldMap.CONTENT_IGNORE && nodes.isSolidCube(id)
            }
        }
        objects.step(Float(delta))
        // Fetch textures for newly-seen entities (only after the initial node-tile
        // media finishes, so entity requests don't stall that batch's completion).
        let newTiles = initialMediaDone ? objects.tiles.subtracting(requestedEntityTiles) : []
        if !newTiles.isEmpty {
            requestedEntityTiles.formUnion(newTiles)
            var imgs = Set<String>()
            for t in newTiles { for n in NodeRegistry.imageNames(t) { imgs.insert(n) } }
            if !imgs.isEmpty { media.request(imgs) }
        }
        // Download mob model files (.b3d) the same way, once initial media is done.
        let newMeshes = initialMediaDone ? objects.meshes.subtracting(requestedEntityMeshes) : []
        if !newMeshes.isEmpty {
            requestedEntityMeshes.formUnion(newMeshes)
            media.request(newMeshes)
        }
        guard clientReadySent else { return }
        posTimer += delta
        if posTimer >= 0.1 { posTimer = 0; sendPlayerPos() }
    }

    /// TOSERVER_DAMAGE (0x35): fall damage is computed CLIENT-side in Luanti
    /// (clientenvironment.cpp) and reported as a u16 hp count; the server
    /// applies it as PlayerHPChangeReason FALL, gated on enable_damage and the
    /// player's immortal armor group (VoxeLibre also zeroes it for creative),
    /// so we don't predict the HP change locally -- TOCLIENT_HP follows (#264).
    public func sendDamage(_ hp: Int) {
        guard hp > 0 else { return }
        conn.sendMessage(Op.toserverDamage, PacketWriter().u16(min(hp, 0xFFFF)).data)
    }

    /// Set the player's position (node coords), look angles (radians) and
    /// velocity (nodes/s). The velocity rides along in PLAYERPOS like the
    /// desktop client's m_speed: the server stores it as the player's speed,
    /// which mods read through get_velocity() (fall-damage checks, elytra,
    /// swim/sprint animations) and which was always zero before (#270).
    public func setPose(pos: SIMD3<Float>, yaw: Float, pitch: Float, velocity: SIMD3<Float> = .zero) {
        spawn = pos - Client.gridShift; self.yaw = yaw; self.pitch = pitch; self.velocity = velocity
    }
    private var velocity = SIMD3<Float>.zero

    private func sendInit() {
        let w = PacketWriter()
        w.u8(Op.serializationVersion).u16(0)
        w.u16(Op.minProtocol).u16(Op.latestProtocol)
        w.string16(name)
        conn.sendMessage(Op.toserverInit, w.data)
    }

    /// Simulator/test seam: run one locally-built TOCLIENT packet through the
    /// same dispatcher the socket feeds, so the sim can exercise real server
    /// paths (HUD statbars, XP) headless and unit tests can drive handlers.
    /// Nothing leaves the process; there is no socket involved.
    public func simulateServerPacket(op: Int, payload: Data) { handle(op, payload) }

    /// Feed a decoded server message straight to the dispatcher, so packet
    /// handlers (e.g. ACCESS_DENIED) are unit-testable without a socket.
    func handleForTesting(_ op: Int, _ payload: Data) { handle(op, payload) }

    private func handle(_ op: Int, _ payload: Data) {
        switch op {
        case Op.toclientHello: handleHello(payload)
        case Op.toclientSrpBytesSB: handleSrpSB(payload)
        case Op.toclientAuthAccept: handleAuthAccept(payload)
        case Op.toclientAccessDenied: handleDenied(payload)
        case Op.toclientNodeDef: handleNodeDef(payload)
        case Op.toclientItemDef: items.parseItemDef(payload)
        case Op.toclientMovePlayer: handleMovePlayer(payload)
        case Op.toclientHP: handleHP(payload)
        case Op.toclientInventory: handleInventory(payload)
        case Op.toclientBlockData: handleBlockData(payload)
        case Op.toclientTimeOfDay: handleTimeOfDay(payload)
        case Op.toclientMovement: handleMovement(payload)
        case Op.toclientActiveObjectRemoveAdd: objects.handleRemoveAdd(payload)
        case Op.toclientActiveObjectMessages: objects.handleMessages(payload)
        case Op.toclientAddNode: handleAddNode(payload)
        case Op.toclientNodemetaChanged: handleNodemetaChanged(payload)
        case Op.toclientShowFormspec: handleShowFormspec(payload)
        case Op.toclientInventoryFormspec: handleInventoryFormspec(payload)
        case Op.toclientHudSetFlags: handleHudSetFlags(payload)
        case Op.toclientPrivileges: handlePrivileges(payload)
        case Op.toclientEyeOffset: handleEyeOffset(payload)
        case Op.toclientFov: handleFov(payload)
        case Op.toclientHudSetParam: handleHudSetParam(payload)
        case Op.toclientFormspecPrepend: handleFormspecPrepend(payload)
        case Op.toclientDetachedInventory: handleDetachedInventory(payload)
        case Op.toclientOverrideDayNightRatio: handleOverrideDayNightRatio(payload)
        case Op.toclientChatMessage: handleChatMessage(payload)
        case Op.toclientSetSky: handleSetSky(payload)
        case Op.toclientSetSun: handleSetSun(payload)
        case Op.toclientSetMoon: handleSetMoon(payload)
        case Op.toclientSetStars: handleSetStars(payload)
        case Op.toclientCloudParams: handleCloudParams(payload)
        case Op.toclientSetLighting: handleSetLighting(payload)
        case Op.toclientPlayerSpeed: handlePlayerSpeed(payload)
        case Op.toclientMovePlayerRel: handleMovePlayerRel(payload)
        case Op.toclientRemoveNode: handleRemoveNode(payload)
        case Op.toclientAnnounceMedia: handleAnnounceMedia(payload)
        case Op.toclientMedia: handleMedia(payload)
        case Op.toclientSpawnParticle: handleSpawnParticle(payload)
        case Op.toclientSpawnParticleBatch: handleSpawnParticleBatch(payload)
        case Op.toclientMediaPush: handleMediaPush(payload)
        case Op.toclientAddParticleSpawner: handleAddParticleSpawner(payload)
        case Op.toclientDeleteParticleSpawner: handleDeleteParticleSpawner(payload)
        case Op.toclientPlaySound: handlePlaySound(payload)
        case Op.toclientStopSound: handleStopSound(payload)
        case Op.toclientFadeSound: handleFadeSound(payload)
        case Op.toclientHudAdd: handleHudAdd(payload)
        case Op.toclientHudChange: handleHudChange(payload)
        case Op.toclientHudRm: handleHudRm(payload)
        default:
            // Nothing sets onMessage, so an unhandled opcode is dropped. Log
            // each opcode once so a genuinely-used-but-missing packet shows up
            // instead of silently vanishing.
            if loggedDrops.insert(op).inserted {
                print(String(format: "[drop] unhandled toclient opcode 0x%02X (%d bytes)", op, payload.count)); fflush(stdout)
            }
            onMessage?(op, payload)
        }
    }
    private var loggedDrops = Set<Int>()

    private func handleHello(_ payload: Data) {
        let r = PacketReader(payload)
        _ = r.u8(); _ = r.u16(); protoVer = r.u16()   // serialization, compression, protocol version
        print("[client] proto=\(protoVer)"); fflush(stdout)
        let mechs = r.u32()
        srp = SRP(username: name, password: password)
        // Client::startAuth (client.cpp): HELLO lists the mechanisms the server
        // accepts for this name. SRP = an account exists: send A with based_on=1
        // (verifier keyed on the lowercase name). FIRST_SRP = no account yet:
        // send salt + verifier and the is_empty flag so the server can enforce
        // disallow_empty_password. The password itself never leaves the device
        // (SRP.swift).
        if mechs & AuthMechanism.srp.rawValue != 0 {
            let A = srp!.startAuthentication()
            conn.sendMessage(Op.toserverSrpBytesA, PacketWriter().bytes16(A).u8(1).data)
        } else if mechs & AuthMechanism.firstSrp.rawValue != 0 {
            let sv = srp!.generateVerifier()
            let w = PacketWriter().bytes16(sv.salt).bytes16(sv.verifier).u8(password.isEmpty ? 1 : 0)
            conn.sendMessage(Op.toserverFirstSrp, w.data)
        } else {
            onAccessDenied?("server offers no supported auth mechanism (\(mechs))", -1)
        }
    }

    private func handleSrpSB(_ payload: Data) {
        let r = PacketReader(payload)
        let salt = r.bytes16(); let B = r.bytes16()
        guard let M = srp?.processChallenge(salt: salt, B: B) else {
            onAccessDenied?("SRP safety check failed", -1); return
        }
        conn.sendMessage(Op.toserverSrpBytesM, PacketWriter().bytes16(M).data)
    }

    private func handleAuthAccept(_ payload: Data) {
        let r = PacketReader(payload)
        _ = r.f32(); _ = r.f32(); _ = r.f32()   // v3f player pos (unused here)
        let mapSeed = UInt64(bitPattern: Int64(r.u64()))
        _ = r.f32()                              // recommended send interval
        srp = nil
        // Progress the join: language, then the server streams definitions.
        conn.sendMessage(Op.toserverInit2, PacketWriter().string16("en").data)
        onAuthenticated?(mapSeed)
    }

    private func handleDenied(_ payload: Data) {
        let r = PacketReader(payload)
        let code = r.u8()
        var reason = r.has(2) ? r.string16() : ""
        let reasons = ["wrong password", "unexpected data", "singleplayer server",
                       "unsupported version", "bad characters in name", "name not allowed",
                       "server full", "empty passwords not allowed",
                       "already connected with this name", "server error", "",
                       "server shutting down", "server crashed"]
        if reason.isEmpty && code < reasons.count { reason = reasons[code] }
        onAccessDenied?(reason, Int(code))
    }

    private func handleNodeDef(_ payload: Data) {
        nodes.parseNodeDef(payload)
        world.lightInfo = nodes.lightInfo()   // enables the client-side relight on node changes (#278)
        print("[client] NODEDEF: \(nodes.count) node types t=+\(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - Client.processStart))s"); fflush(stdout)
        defsReady = true
        onMessage?(Op.toclientNodeDef, payload)
        sendClientReadyIfNeeded()
        tryRequestMedia()
    }

    private func handleAnnounceMedia(_ payload: Data) {
        media.onComplete = { [weak self] in
            guard let self else { return }
            print("[client] media complete: \(self.media.store.count) files t=+\(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - Client.processStart))s"); fflush(stdout)
            self.initialMediaDone = true
            self.onMediaReady?()
        }
        media.parseAnnounce(payload)
        print("[client] ANNOUNCE_MEDIA: \(media.announced.count) files"); fflush(stdout)
        tryRequestMedia()
    }

    private func handleMedia(_ payload: Data) { media.parseMedia(payload) }

    /// TOCLIENT_PLAY_SOUND (0x3f). Wire format (see Client::handleCommand_PlaySound
    /// in luanti clientpackethandler.cpp):
    ///   s32 server_id, string16 name, f32 gain, u8 type (0 local/1 pos/2 object),
    ///   v3f pos (BS-space), u16 object_id, u8 loop, f32 fade, f32 pitch,
    ///   [u8 ephemeral], [f32 start_time]  (the last two are newer, optional).
    /// TOCLIENT_SPAWN_PARTICLE: one particle. We read the leading, stable fields
    /// of ParticleParameters (pos/vel/acc/expiration/size/collision/texture) and
    /// stop -- it's a standalone message, so the trailing animation/node/texture
    /// blocks can be ignored. Coords are NODE units, unlike entity packets:
    /// particles.cpp keeps m_pos in nodes and multiplies by BS only to render
    /// or collide. We used to divide by 10 here and in the spawner, which put
    /// VoxeLibre's weather (rain/snow boxes 20-25 nodes overhead, 50 wide,
    /// falling 15-20 node/s) in a 5-node box 2 nodes over your head at a tenth
    /// the speed -- the real cause of the "rain bars around the head" (#199).
    func handleSpawnParticle(_ payload: Data) { parseParticle(payload) }   // internal for tests

    /// TOCLIENT_MEDIA_PUSH (0x2C): string16 sha1 (20 raw bytes), string16 name,
    /// u8 cached, then u32 token (proto >= 40: the file is fetched through the
    /// normal media path and acked with HAVE_MEDIA once it lands) or string32
    /// data (older servers: inline, verified against the sha1).
    /// Client::handleCommand_MediaPush.
    func handleMediaPush(_ payload: Data) {
        let r = PacketReader(payload)
        let hash = r.bytes16()
        let name = r.string16()
        _ = r.u8()                                             // cached (we cache by sha1 regardless)
        guard hash.count == 20, Client.isSafeMediaName(name) else { return }
        let hex = MediaManager.hex(hash)
        if protoVer >= 40 {
            let token = r.u32()
            if r.overrun { return }
            media.onPushedReady = { [weak self] name, tokens in
                self?.sendHaveMedia(tokens)
                self?.onMediaPushed?(name)
            }
            media.push(name: name, sha1Hex: hex, token: token)
        } else {
            let data = r.bytes32()
            if r.overrun || data.isEmpty { return }
            guard Data(Insecure.SHA1.hash(data: data)) == hash else { return }   // SHA-1 doesn't match the name the server announced (corrupt transfer): drop
            media.accept(name: name, data: data)
        }
    }

    /// TEXTURENAME_ALLOWED_CHARS: ASCII letters, digits, "_", ".", "-" only, so a
    /// pushed name can never be a path.
    /// Reject server-supplied media names that could escape the cache directory
    /// ("..", separators, non-ASCII). The engine checks pushed file names the same
    /// way before writing them; we key the cache by sha1 anyway, but a buggy or
    /// hostile server shouldn't get to pick a path.
    static func isSafeMediaName(_ s: String) -> Bool {
        !s.isEmpty && !s.contains("..") && s.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-")
        }
    }

    /// TOCLIENT_SPAWN_PARTICLE_BATCH (0x64): a string32 of zstd data holding a
    /// run of string32 blobs, each one serialized ParticleParameters. The blobs
    /// are self-delimited, so each goes to the single-particle parser, which
    /// reads only the leading fields it needs (the tail varies by version).
    func handleSpawnParticleBatch(_ payload: Data) {
        let r = PacketReader(payload)
        let comp = r.bytes32()
        guard !r.overrun, let raw = Zstd.decompress(comp, maxSize: 8 * 1024 * 1024) else { return }
        let b = PacketReader(raw)
        var n = 0
        while b.has(4), n < 4096 {
            let blob = b.bytes32()
            if blob.isEmpty || b.overrun { break }
            parseParticle(blob); n += 1
        }
    }

    /// One ParticleParameters (particles.cpp deSerialize): pos, vel, acc,
    /// expiration, size, collision flag, texture, vertical, collision_removal,
    /// animation, glow, object_collision, then (5.3+) node param0/param2/tile.
    /// The 5.6+ drag/jitter/bounce and 5.9+ texture tail are still skipped.
    private func parseParticle(_ payload: Data) {
        let r = PacketReader(payload)
        func v3() -> SIMD3<Float> { SIMD3(r.f32(), r.f32(), r.f32()) }
        let pos = v3()                  // node units (see handleSpawnParticle)
        let vel = v3()
        let acc = v3()                  // node units/s^2
        let expiration = r.f32()
        let size = r.f32()
        let collide = r.u8() != 0       // collisiondetection
        let texture = r.string32()
        if r.overrun { return }
        var look = ParticleLook()
        look.vertical = r.u8() != 0
        look.collisionRemoval = r.u8() != 0
        Client.readTileAnimation(r, into: &look)
        look.glow = r.u8()
        look.objectCollision = r.u8() != 0
        if r.has(4) {
            look.nodeId = r.u16(); _ = r.u8(); look.nodeTile = r.u8()   // node.param0, node.param2, node_tile
        }
        if r.has(12 + 28 + 12) {
            // >= 5.6.0-dev: drag v3f, jitter RangedParameter v3f (min, max,
            // bias), bounce RangedParameter f32 (min, max, bias).
            look.drag = v3()
            look.jitterMin = v3(); look.jitterMax = v3(); _ = r.f32()
            let bmn = r.f32(), bmx = r.f32(); _ = r.f32()
            look.bounce = Float.random(in: min(bmn, bmx)...max(bmn, bmx))
        }
        if r.has(1 + 15 + 23) {
            // >= 5.9.0-dev: texture tweens (newPropertiesOnly, skipAnimation).
            Client.readTextureTween(r, into: &look, withString: false, withAnimation: false)
        }
        if r.overrun { look = ParticleLook() }   // a short legacy blob: keep the core fields
        onSpawnParticle?(pos + Client.gridShift, vel, acc, size, expiration, texture, collide, look)
    }

    /// TOCLIENT_ADD_PARTICLESPAWNER (proto >= 42, the tweened format). We read
    /// the leading tweenable ranges (enough for a visual burst) and ignore the
    /// trailing node/drag/jitter/attractor fields. TweenedParameter<T> on the
    /// wire = u8 style, u16 reps, f32 beginning, then start+end RangedParameter<T>
    /// (each = min, max, f32 bias); we take start.min/start.max as the range.
    func handleAddParticleSpawner(_ payload: Data) {
        let r = PacketReader(payload)
        func v3() -> SIMD3<Float> { SIMD3(r.f32(), r.f32(), r.f32()) }
        let tweened = protoVer == 0 || protoVer >= 42   // 0 = unknown, assume modern
        func skipTweenHead() { _ = r.u8(); _ = r.u16(); _ = r.f32() }   // style, reps, beginning
        // Modern (>=42): TweenedParameter = head + start RangedParameter (min,max,
        // bias) + end RangedParameter, and we take the start range. Legacy (<42):
        // just min, max (legacyDeSerialize) with no head/bias/end.
        // Each tweened range yields (start min, start max, end min, end max);
        // the legacy layout has no end values (the engine then uses start).
        func rangeV3() -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>?, SIMD3<Float>?) {
            if !tweened { let a = v3(), b = v3(); return (a, b, nil, nil) }
            skipTweenHead()
            let mn = v3(), mx = v3(); _ = r.f32()          // start min/max/bias
            let emn = v3(), emx = v3(); _ = r.f32()        // end min/max/bias
            return (mn, mx, emn, emx)
        }
        func rangeF() -> (Float, Float, Float?, Float?) {
            if !tweened { let a = r.f32(), b = r.f32(); return (a, b, nil, nil) }
            skipTweenHead()
            let mn = r.f32(), mx = r.f32(); _ = r.f32()
            let emn = r.f32(), emx = r.f32(); _ = r.f32()
            return (mn, mx, emn, emx)
        }
        let amount = r.u16()
        let time = r.f32()
        if time < 0 { return }   // Luanti rejects time<0 (PacketError); don't turn it into an infinite spawner
        let (pmn, pmx, pmnE, pmxE) = rangeV3()
        let (vmn, vmx, vmnE, vmxE) = rangeV3()
        let (amn, amx, amnE, amxE) = rangeV3()
        let (emn, emx, emnE, emxE) = rangeF()
        let (smn, smx, smnE, smxE) = rangeF()
        let collisionDetection = r.u8() != 0
        let texture = r.string32()
        let serverId = r.u32()
        var look = ParticleLook()
        look.vertical = r.u8() != 0
        let collisionRemoval = r.u8() != 0
        look.collisionRemoval = collisionRemoval
        let attachedId = r.u16()
        if r.overrun { return }
        // Tail (handleCommand_AddParticleSpawner): animation, glow,
        // object_collision, then node param0/param2/tile when present.
        Client.readTileAnimation(r, into: &look)
        look.glow = r.u8()
        look.objectCollision = r.u8() != 0
        if r.has(4) { look.nodeId = r.u16(); _ = r.u8(); look.nodeTile = r.u8() }
        var radiusMin = SIMD3<Float>.zero, radiusMax = SIMD3<Float>.zero
        if tweened, r.has(1 + 15 + 23) {
            // 5.6+ tail on the tweened layout: legacy-texture tweens (no
            // string), drag / jitter / bounce range tweens, attractor block,
            // radius range tween, then the texpool (ignored).
            Client.readTextureTween(r, into: &look, withString: false, withAnimation: true)
            let (dmn, dmx, _, _) = rangeV3(); look.drag = (dmn + dmx) * 0.5
            let (jmn, jmx, _, _) = rangeV3(); look.jitterMin = jmn; look.jitterMax = jmx
            let (bmn, bmx, _, _) = rangeF(); look.bounce = max(bmn, bmx)
            let attractorKind = r.u8()
            if attractorKind != 0 {
                _ = rangeF()                                   // attract strength tween
                skipTweenHead(); _ = v3(); _ = v3()            // attractor_origin tween
                _ = r.u16(); _ = r.u8()                        // attachment, kill flag
                if attractorKind != 1 { skipTweenHead(); _ = v3(); _ = v3(); _ = r.u16() }   // direction tween + attachment
            }
            let (rmn, rmx, _, _) = rangeV3()
            if !r.overrun { radiusMin = rmn; radiusMax = rmx }
        }
        if r.overrun { look = ParticleLook(); look.collisionRemoval = collisionRemoval; radiusMin = .zero; radiusMax = .zero }
        // World-anchored spawner positions are absolute node coords (shift into
        // our grid); an attached spawner's range is object-relative, so it takes
        // no shift (the object's own pos is already shifted).
        let g = attachedId == 0 ? Client.gridShift : SIMD3<Float>(0, 0, 0)
        // Positions/velocities/accelerations are node units on the wire (see
        // handleSpawnParticle); only the world-anchored position needs our grid shift.
        var sp = ParticleSpawner(
            serverId: serverId, amount: amount, time: time,
            posMin: pmn + g, posMax: pmx + g,
            velMin: vmn, velMax: vmx,
            accMin: amn, accMax: amx,
            expMin: emn, expMax: emx, sizeMin: smn, sizeMax: smx,
            attachedId: attachedId, texture: texture, collisionRemoval: collisionRemoval,
            collisionDetection: collisionDetection)
        sp.look = look
        sp.posMinEnd = pmnE.map { $0 + g }; sp.posMaxEnd = pmxE.map { $0 + g }
        sp.velMinEnd = vmnE; sp.velMaxEnd = vmxE
        sp.accMinEnd = amnE; sp.accMaxEnd = amxE
        sp.expMinEnd = emnE; sp.expMaxEnd = emxE
        sp.sizeMinEnd = smnE; sp.sizeMaxEnd = smxE
        sp.radiusMin = radiusMin; sp.radiusMax = radiusMax
        onAddParticleSpawner?(sp)
    }

    func handleDeleteParticleSpawner(_ payload: Data) {
        let r = PacketReader(payload)
        onDeleteParticleSpawner?(r.u32())
    }

    private func handlePlaySound(_ payload: Data) {
        let r = PacketReader(payload)
        let id = r.s32()
        let name = r.string16()
        let gain = r.f32()
        let type = r.u8()
        let px = r.f32(), py = r.f32(), pz = r.f32()   // BS units (nodes * 10)
        let objectId = r.u16()
        let loop = r.u8() != 0
        let fade = r.f32()
        let pitch = r.f32()
        let ephemeral = r.has(1) ? (r.u8() != 0) : false
        // start_time (f32) may follow; unused here.
        let spec = SoundSpec(id: id, name: name, gain: gain, type: type,
                             pos: SIMD3(px / 10, py / 10, pz / 10) + Client.gridShift,
                             objectId: objectId, loop: loop, fade: fade,
                             pitch: pitch, ephemeral: ephemeral)
        print("[sound] PLAY id=\(id) name=\(name) gain=\(gain) type=\(type) pos=\(spec.pos) obj=\(objectId) loop=\(loop) fade=\(fade) pitch=\(pitch) ephemeral=\(ephemeral)"); fflush(stdout)
        onPlaySound?(spec)
    }

    /// TOCLIENT_STOP_SOUND (0x40): s32 server_id.
    private func handleStopSound(_ payload: Data) {
        let r = PacketReader(payload)
        let id = r.s32()
        print("[sound] STOP id=\(id)"); fflush(stdout)
        onStopSound?(id)
    }

    /// TOCLIENT_FADE_SOUND (0x55): s32 sound_id, f32 step, f32 gain.
    private func handleFadeSound(_ payload: Data) {
        let r = PacketReader(payload)
        let id = r.s32()
        let step = r.f32()
        let gain = r.f32()
        print("[sound] FADE id=\(id) step=\(step) gain=\(gain)"); fflush(stdout)
        onFadeSound?(id, step, gain)
    }

    // HUD element type / stat constants (repos/luanti/src/hud_element.h).
    private static let hudElemImage = 0
    private static let hudElemText = 1
    private static let hudElemStatbar = 2
    private static let hudStatText = 3
    private static let hudStatNumber = 4

    /// TOCLIENT_HUDADD (0x49). Wire format (Client::handleCommand_HudAdd):
    ///   u32 server_id, u8 type, v2f pos, string16 name, v2f scale,
    ///   string16 text, u32 number, u32 item, u32 dir, v2f align, v2f offset,
    ///   v3f world_pos, v2f size (proto>=52; v2s32 otherwise), then optional
    ///   s16 z_index / string16 text2 / u32 style / u8 flags (read to end).
    /// VoxeLibre's hunger comes through here as a statbar whose `text` is the
    /// hunger icon ("hbhunger_icon.png"); `number` is the food value 0..20.
    func handleHudAdd(_ payload: Data) {
        let r = PacketReader(payload)
        let id = r.u32()
        var e = HudElement()
        e.type = r.u8()
        e.pos = SIMD2(r.f32(), r.f32())
        e.name = r.string16()
        e.scale = SIMD2(r.f32(), r.f32())
        e.text = r.string16()
        e.number = r.u32()
        e.item = r.u32()
        e.dir = r.u32()
        e.align = SIMD2(r.f32(), r.f32())
        e.offset = SIMD2(r.f32(), r.f32())
        e.worldPos = SIMD3(r.f32(), r.f32(), r.f32())
        if protoVer >= 52 { e.size = SIMD2(r.f32(), r.f32()) }
        else if r.has(8) { e.size = SIMD2(Float(r.s32()), Float(r.s32())) }   // v2s32 before 52
        if r.has(2) { e.zIndex = r.s16() }                                     // optional tail
        if r.has(2) { e.text2 = r.string16() }
        if r.has(4) { e.style = r.u32() }
        if r.overrun { return }
        let type = e.type, text = e.text, number = e.number, item = e.item, dir = e.dir
        hudElements[id] = e; hudGeneration &+= 1
        hudTypes[id] = type
        // mcl_experience's level readout: a text element in XP green. (Its bar
        // is an image whose texture only arrives by HUDCHANGE; see there.)
        if type == Client.hudElemText, number == 0x80FF20 {
            xpLevelId = id
            xpLevel = Int(text) ?? 0
            onXp?(xpLevel, xpFraction)
        }
        guard type == Client.hudElemStatbar else { return }
        statbars[id] = (text: text, number: number)
        refreshHealthParts()
        print("[hud] statbar add id=\(id) icon=\(text) number=\(number) item=\(item) dir=\(dir)"); fflush(stdout)
        // The hunger bar's icon is hbhunger_icon.png (mcl_hunger swaps it to a
        // poison/regen variant, all prefixed "hbhunger"), so match by prefix.
        if text.hasPrefix("hbhunger") {
            hungerStatbarId = id
            hunger = number
            print("[hud] hunger statbar id=\(id) icon=\(text) value=\(number)"); fflush(stdout)
            onHunger?(number)
        }
        if text.hasPrefix("hudbars_icon_breath") {
            breathStatbarId = id
            print("[hud] breath statbar id=\(id) value=\(number)"); fflush(stdout)
            onBreath?(number)
        }
        // Armor rides the same hudbars statbar (mcl_hbarmor), icon hbarmor_icon.png;
        // number is armor points 0..20 (10 icons, 2 each), like hunger.
        if text.hasPrefix("hbarmor") {
            armorStatbarId = id
            armor = number
            print("[hud] armor statbar id=\(id) value=\(number)"); fflush(stdout)
            onArmor?(number)
        }
    }

    /// TOCLIENT_HUDCHANGE (0x4b): u32 id, u8 stat, then one value whose type
    /// depends on stat (v2f / string16 / v3f / u32). We only care about the
    /// hunger statbar's NUMBER (stat 4) and TEXT (stat 3, icon swap).
    func handleHudChange(_ payload: Data) {
        let r = PacketReader(payload)
        let id = r.u32()
        let stat = r.u8()
        // Read the value once (types per Client::handleCommand_HudChange), keep
        // the generic record current, then feed the XP and statbar paths.
        var e = hudElements[id]
        var textVal: String? = nil
        var numVal: Int? = nil
        switch stat {
        case 0, 2, 7, 8:                                   // pos, scale, align, offset: v2f
            let v2 = SIMD2(r.f32(), r.f32())
            switch stat {
            case 0: e?.pos = v2
            case 2: e?.scale = v2
            case 7: e?.align = v2
            default: e?.offset = v2
            }
        case 1, 3, 12:                                     // name, text, text2: string16
            let s = r.string16()
            switch stat {
            case 1: e?.name = s
            case 3: e?.text = s; textVal = s
            default: e?.text2 = s
            }
        case 9:                                            // world_pos: v3f
            e?.worldPos = SIMD3(r.f32(), r.f32(), r.f32())
        case 10:                                           // size: v2f (v2s32 before proto 52)
            if protoVer >= 52 { e?.size = SIMD2(r.f32(), r.f32()) }
            else { e?.size = SIMD2(Float(r.s32()), Float(r.s32())) }
        default:                                           // number, item, dir, z_index, style: u32
            let n = r.u32()
            switch stat {
            case 4: e?.number = n; numVal = n
            case 5: e?.item = n
            case 6: e?.dir = n
            case 11: e?.zIndex = n >= 0x8000_0000 ? n - 0x1_0000_0000 : n   // signed on the wire
            case 13: e?.style = n
            default: break
            }
        }
        if r.overrun { return }
        if let e { hudElements[id] = e; hudGeneration &+= 1 }
        // XP (text/image elements): the level string, or the bar texture whose
        // [lowpart:N: is the fill.
        if let text = textVal, let t = hudTypes[id], t == Client.hudElemText || t == Client.hudElemImage {
            if id == xpLevelId {
                xpLevel = Int(text) ?? 0
                onXp?(xpLevel, xpFraction)
            } else if let pct = Client.xpLowpart(text) {
                xpBarId = id
                xpFraction = Float(min(100, max(0, pct))) / 100
                onXp?(xpLevel, xpFraction)
            }
            return
        }
        guard statbars[id] != nil else { return }
        defer { refreshHealthParts() }
        if let value = numVal {
            statbars[id]?.number = value
            if id == hungerStatbarId {
                if value != hunger { print("[hud] hunger \(hunger) -> \(value)"); fflush(stdout) }
                hunger = value
                onHunger?(value)
            }
            if id == breathStatbarId { onBreath?(value) }
            if id == armorStatbarId { armor = value; onArmor?(value) }
        }
        if let newText = textVal {
            statbars[id]?.text = newText
            if newText.hasPrefix("hbhunger") { hungerStatbarId = id }
            if newText.hasPrefix("hudbars_icon_breath") { breathStatbarId = id }
            if newText.hasPrefix("hbarmor") { armorStatbarId = id }
        }
    }

    /// The heart statbar's current icon (vl_hudbars swaps it for poison,
    /// wither, frost, regeneration) and the absorption amount, which rides a
    /// second statbar on the same heart background. hungerIcon likewise
    /// (food poisoning). Re-derived whenever a statbar changes.
    public private(set) var healthIcon: String? = nil
    public private(set) var absorption = 0
    public var hungerIcon: String? { hungerStatbarId.flatMap { statbars[$0]?.text } }
    private func refreshHealthParts() {
        var icon: String? = nil, absorb = 0
        for (id, sb) in statbars where hudElements[id]?.text2 == "hudbars_bgicon_health.png" {
            if sb.text == "mcl_potions_icon_absorb.png" { absorb = sb.number } else { icon = sb.text }
        }
        healthIcon = icon; absorption = absorb
    }

    /// TOCLIENT_HUDRM (0x4a): u32 id.
    func handleHudRm(_ payload: Data) {
        let r = PacketReader(payload)
        let id = r.u32()
        defer { refreshHealthParts() }
        statbars[id] = nil
        hudTypes[id] = nil
        if hudElements[id] != nil { hudElements[id] = nil; hudGeneration &+= 1 }
        if id == hungerStatbarId { hungerStatbarId = nil }
        if id == xpBarId { xpBarId = nil; xpFraction = 0; onXp?(xpLevel, 0) }
        if id == xpLevelId { xpLevelId = nil; xpLevel = 0; onXp?(0, xpFraction) }
    }

    /// Once we have both node tiles and the media announcement, request the
    /// subset of files the nodes actually reference (their face textures).
    private func tryRequestMedia() {
        guard !mediaRequested, !nodes.faceTiles.isEmpty, !media.announced.isEmpty else { return }
        mediaRequested = true
        var needed = Set<String>()
        for tiles in nodes.faceTiles.values { for t in tiles where !t.isEmpty { for n in NodeRegistry.imageNames(t) { needed.insert(n) } } }
        for t in nodes.overlayTilesSnapshot() { for n in NodeRegistry.imageNames(t) { needed.insert(n) } }
        // Biome palettes (grass/foliage tinting) aren't node tiles, so add them.
        for pal in nodes.palettes { for n in NodeRegistry.imageNames(pal) { needed.insert(n) } }
        // Custom model files for mesh-drawtype nodes (lanterns, chains, ...).
        for f in nodes.meshFileNames() { needed.insert(f) }
        // Item inventory images (tools/craftitems). Not node tiles, so the scan
        // above misses them and the hotbar cell would be empty. Expand each spec
        // to its base PNG names (they can carry ^ modifiers).
        for img in items.allImages() { for n in NodeRegistry.imageNames(img) { needed.insert(n) } }
        // Dig-crack overlay strip (not a node tile) for the break animation.
        needed.insert("crack_anylength.png")
        // Health heart icons for the peripheral HUD (not node tiles, so the
        // node-tile scan above never pulls them). Full + dim/empty background.
        needed.insert("hudbars_icon_health.png")
        needed.insert("hudbars_bgicon_health.png")
        // Hunger drumstick icons for the peripheral HUD (mcl_hunger statbar).
        needed.insert("hbhunger_icon.png")
        needed.insert("hbhunger_bgicon.png")
        // Breath/oxygen bubbles (shown while submerged).
        needed.insert("hudbars_icon_breath.png")
        needed.insert("hudbars_bgicon_breath.png")
        // Status-effect variants the game swaps into those rows (poison,
        // wither, frost, regen, absorption gold hearts, food poisoning).
        for n in TextureAtlas.healthStatusIcons + TextureAtlas.hungerStatusIcons { needed.insert(n) }
        // Armor icons (mcl_hbarmor statbar) for the armor HUD row.
        needed.insert("hbarmor_icon.png")
        needed.insert("hbarmor_bgicon.png")
        // Sound files (.ogg): the server announces but never bundles these into a
        // tile request, so pull them all up front so PLAY_SOUND can resolve them.
        let sounds = media.announcedSounds()
        needed.formUnion(sounds)
        print("[client] requesting \(needed.count) media files (\(sounds.count) sounds)"); fflush(stdout)
        media.request(needed)
    }

    /// TOCLIENT_NODEMETA_CHANGED (0x59): a longString of zlib-compressed
    /// NodeMetadataList (absolute positions). Updates the affected node
    /// inventories so open chests/furnaces/signs reflect live changes; fires
    /// onNodeChanged for each so the view can refresh.
    private func handleNodemetaChanged(_ payload: Data) {
        let r = PacketReader(payload)
        let comp = r.bytes32()
        guard let raw = Zlib.inflate(comp) else { return }
        for p in world.applyNodeMetaChanged(raw) { onNodeChanged?(p) }
    }

    private func handleAddNode(_ payload: Data) {
        let p = world.decodeAddNode(payload)
        onNodeChanged?(p)
    }

    private func handleRemoveNode(_ payload: Data) {
        let p = world.decodeRemoveNode(payload)
        onNodeChanged?(p)
    }

    /// Finish the join the way the engine does: once NODEDEF/ITEMDEF have landed
    /// the official client sends TOSERVER_CLIENT_READY with its version + formspec
    /// API version (Client::sendReady, src/client/client.cpp, called when the
    /// client leaves LC_Init). The server only spawns the player and starts
    /// streaming blocks after this.
    private func sendClientReadyIfNeeded() {
        guard defsReady, !clientReadySent else { return }
        clientReadySent = true
        let w = PacketWriter()
        w.u8(0).u8(1).u8(0).u8(0)                 // version major/minor/patch/reserved
        w.string16("voxelibre-vr 0.1")
        w.u16(Op.formspecApiVersion)
        conn.sendMessage(Op.toserverClientReady, w.data)
        sendPlayerPos()                            // announce our presence/range
        // Assert our wield slot on join (#57). Luanti has no server->client wield
        // packet -- the client is authoritative -- so the server keeps whatever
        // PLAYERITEM we last sent, which is stale across a reconnect. Without this,
        // a server-side on_use/on_place right after join could act on the wrong
        // held item until the first manual slot change. Re-sent on every reconnect
        // (clientReadySent resets), so client and server always agree from frame 1.
        conn.sendMessage(Op.toserverPlayerItem, PacketWriter().u16(wieldIndex).data)
    }

    func handleMovePlayer(_ payload: Data) {   // internal: exercised by CrashGuardTests
        let r = PacketReader(payload)
        let x = r.f32(), y = r.f32(), z = r.f32()  // BS units (nodes * 10)
        let p = r.f32(), yw = r.f32()
        // A non-finite coord (corrupt datagram, or a hostile server) would trap
        // the next Int(spawn.x * 1000) in playerPosBlockData 0.1s later. Drop it.
        guard x.isFinite, y.isFinite, z.isFinite, p.isFinite, yw.isFinite else {
            print("[client] MOVE_PLAYER dropped: non-finite value"); fflush(stdout); return
        }
        spawn = SIMD3(x / 10.0, y / 10.0, z / 10.0)
        pitch = p * .pi / 180
        yaw = yw * .pi / 180
        print("[client] MOVE_PLAYER -> \(spawn)"); fflush(stdout)
        onSpawn?(spawn + Client.gridShift, yaw, pitch)
        onMessage?(Op.toclientMovePlayer, payload)
    }

    /// TOCLIENT_HP (0x33): u16 hp, then (>= 5.6.0-dev) a u8 damage-effect flag.
    /// clientpackethandler.cpp handleCommand_HP gates the red flash + hurt sound
    /// on that flag, so a heal or a set_hp that isn't a hit doesn't flash the
    /// screen. Absent (older servers) = treat as a real hit, as before.
    /// VoxeLibre health runs 0..20 (10 hearts, 2 hp each).
    private func handleHP(_ payload: Data) {
        let r = PacketReader(payload)
        let newHp = r.u16()
        let damageEffect = r.has(1) ? r.u8() != 0 : true
        hp = newHp
        print("[client] HP=\(newHp) dmgEffect=\(damageEffect)"); fflush(stdout)
        onHP?(newHp, damageEffect)
    }

    /// TOCLIENT_INVENTORY (0x27). At proto > 51 the payload is a longString
    /// (u32 length + bytes) followed by a u8 skip-wield-animation flag; older
    /// servers send the text directly. Either way the text is Luanti's inventory
    /// serialization (Inventory::deSerialize): newline-separated lines,
    ///   "List <name> <size>" ... "Item <itemstring>" / "Empty" ... "EndInventoryList"
    ///   ... "EndInventory". We only care about the "main" list's first 9 slots.
    private func handleInventory(_ payload: Data) {
        // Try the longString framing first; if the length prefix is bogus (older
        // framing, where the bytes start with "List"), fall back to raw text.
        var text = PacketReader(payload).string32()
        if !text.contains("List") && !text.contains("EndInventory") {
            text = String(decoding: payload, as: UTF8.self)
        }
        parseInventoryText(text)
    }

    /// Inventory::deSerialize text -> `inventory` lists (+ hotbar, callbacks).
    /// Parse Luanti's Inventory serialization text (List/Item/Empty/EndInventoryList
    /// /EndInventory) into lists. `previous` supplies KeepList carry-over (a node
    /// metadata inventory passes [:], the player inventory passes its current
    /// lists). Shared by TOCLIENT_INVENTORY and node-metadata inventories so both
    /// read the exact same format.
    static func parseInventoryLists(_ text: String, previous: [String: [ItemStack?]]) -> (lists: [String: [ItemStack?]], sawMain: Bool) {
        var cur: String? = nil            // list being filled
        var stacks: [ItemStack?] = []
        var sawMain = false
        var lists = previous                 // KeepList keeps what we had
        func closeList() {
            if let name = cur { lists[name] = stacks; if name == "main" { sawMain = true } }
            cur = nil; stacks = []
        }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine[...]
            let head = line.prefix { $0 != " " }
            switch head {
            case "List":
                closeList()
                let fields = line.split(separator: " ")
                if fields.count >= 2 { cur = String(fields[1]) }
            case "KeepList":
                closeList()
            case "EndInventoryList", "EndInventory":
                closeList()
            case "Item" where cur != nil:
                // "Item <itemstring>": name [count [wear [meta]]]; name is JSON-quoted only if it needs escaping.
                let rest = line.dropFirst(head.count).drop { $0 == " " }
                // The meta (4th field) is a JSON string that can contain spaces,
                // so split only the first three tokens off (#271).
                let parts = rest.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                var name = parts.first.map(String.init) ?? ""
                if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 { name = String(name.dropFirst().dropLast()) }
                let count = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
                let wear = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
                let meta = parts.count > 3 ? Client.parseItemMeta(parts[3]) : [:]
                stacks.append(name.isEmpty ? nil : ItemStack(name: name, count: count, wear: wear, meta: meta))
            case "Empty" where cur != nil, "Keep" where cur != nil:
                stacks.append(nil)
            default:
                break
            }
        }
        closeList()
        return (lists, sawMain)
    }

    func parseInventoryText(_ text: String) {
        let (lists, sawMain) = Client.parseInventoryLists(text, previous: inventory)
        inventory = lists
        onInventoryLists?()
        // A KeepList (or an inventory without "main") leaves the hotbar untouched.
        guard sawMain, let main = lists["main"] else { return }
        var slots: [String?] = main.prefix(9).map { $0?.name }
        while slots.count < 9 { slots.append(nil) }
        hotbar = slots
        print("[client] INVENTORY main[0..9]=\(slots.map { $0 ?? "nil" }) lists=\(lists.keys.sorted())"); fflush(stdout)
        onInventory?(slots)
    }

    /// TOCLIENT_MOVEMENT: 12 f32 (accel default/air/fast, speed walk/crouch/fast/
    /// climb/jump, liquid fluidity/fluidity_smooth/sink, gravity). Luanti scales
    /// by BS for its BS-space physics; our world is 1 node = 1 unit, so we use the
    /// raw values. We apply the ones our model has (walk/fast/crouch/jump/gravity)
    /// and keep our custom liquid model.
    /// TOCLIENT_SHOW_FORMSPEC: longString formspec + string16 formname. An empty
    /// formspec closes the current one.
    private func handlePlayerSpeed(_ payload: Data) {
        let r = PacketReader(payload); let bs: Float = 10
        let v = SIMD3(r.f32(), r.f32(), r.f32()) / bs
        if r.overrun { return }
        onPlayerSpeed?(v)
    }
    private func handleMovePlayerRel(_ payload: Data) {
        let r = PacketReader(payload); let bs: Float = 10
        let d = SIMD3(r.f32(), r.f32(), r.f32()) / bs
        if r.overrun { return }
        onMovePlayerRel?(d)
    }

    /// TOCLIENT_DETACHED_INVENTORY (0x43): string16 name, u8 keep (0 = remove),
    /// u16 legacy-length (ignored), then the Inventory serialization text.
    private func handleDetachedInventory(_ payload: Data) {
        let r = PacketReader(payload)
        let name = r.string16()
        let keep = r.u8() != 0
        guard !name.isEmpty else { return }
        if !keep { detached.removeValue(forKey: name); onInventoryLists?(); return }
        _ = r.u16()                                   // legacy length, unused
        let text = String(decoding: r.rest(), as: UTF8.self)
        let (lists, _) = Client.parseInventoryLists(text, previous: [:])
        detached[name] = lists
        onInventoryLists?()
    }

    /// TOCLIENT_OVERRIDE_DAY_NIGHT_RATIO (0x50): u8 do_override, u16 ratio/65536.
    /// When set, the server pins the light level (dark caves, the End, the
    /// Nether) instead of it following time of day.
    /// TOCLIENT_SET_SKY (0x4f, proto>=39): bgcolor(argb) + type + clouds +
    /// fog tints + type-specific data. We apply the flat colour for non-regular
    /// skies (plain/skybox), which is what makes the Nether/End read as their
    /// own void instead of our blue day sky; "regular" restores the procedural
    /// sky. (Full skybox textures / per-time sky colours are a later pass.)
    // Sky packets (Client::handleCommand_HudSetSky & co). Each parses into a
    // copy of `sky`, bails on a short packet, then publishes.
    func handleSetSky(_ payload: Data) {
        let r = PacketReader(payload)
        var s = sky
        let bg = SkyParams.argb(r.u32())                  // bgcolor ARGB8
        let type = r.string16()
        if protoVer < 39 {
            // Old layout: u16 texture count + names, u8 clouds. No colours on
            // the wire; anything but "regular" is a flat bgcolor sky.
            s.skyboxTextures = []
            let n = r.u16(); for _ in 0..<n { let t = r.string16(); if type == "skybox" { s.skyboxTextures.append(t) } }
            s.clouds = r.u8() != 0
        } else {
            s.clouds = r.u8() != 0
            s.fogSunTint = SkyParams.argb(r.u32()); s.fogMoonTint = SkyParams.argb(r.u32())
            s.fogTintCustom = r.string16() == "custom"
            s.skyboxTextures = []
            if type == "skybox" {
                let n = r.u16(); for _ in 0..<n { s.skyboxTextures.append(r.string16()) }
            } else if type == "regular" {
                s.daySky = SkyParams.argb(r.u32());   s.dayHorizon = SkyParams.argb(r.u32())
                s.dawnSky = SkyParams.argb(r.u32());  s.dawnHorizon = SkyParams.argb(r.u32())
                s.nightSky = SkyParams.argb(r.u32()); s.nightHorizon = SkyParams.argb(r.u32())
                _ = r.u32()                               // indoors
            }
            // Optional tail, each piece present only when the packet is long
            // enough (Client::handleCommand_HudSetSky): body_orbit_tilt, then
            // fog distance/start, then the fog colour. Every SET_SKY resets
            // them (the engine starts from SkyboxDefaults each time).
            s.fogDistance = -1; s.fogStart = -1; s.fogColor = SIMD4(0, 0, 0, 0)
            if r.has(4) { _ = r.f32() }                          // body_orbit_tilt
            if r.has(6) { s.fogDistance = r.s16(); s.fogStart = r.f32() }
            if r.has(4) {
                let c = r.u32()
                s.fogColor = SIMD4(SkyParams.argb(c), Float((c >> 24) & 0xFF) / 255)
            }
        }
        if r.overrun { return }
        s.solid = type == "regular" ? nil : bg
        sky = s
        onSky?(s)
    }

    func handleSetSun(_ payload: Data) {
        let r = PacketReader(payload)
        var s = sky
        s.sunVisible = r.u8() != 0
        _ = r.string16(); _ = r.string16(); _ = r.string16()   // texture, tonemap, sunrise
        _ = r.u8()                                             // sunrise_visible
        s.sunScale = r.f32()
        if r.overrun { return }
        sky = s; onSky?(s)
    }

    func handleSetMoon(_ payload: Data) {
        let r = PacketReader(payload)
        var s = sky
        s.moonVisible = r.u8() != 0
        _ = r.string16(); _ = r.string16()                     // texture, tonemap
        s.moonScale = r.f32()
        if r.overrun { return }
        sky = s; onSky?(s)
    }

    func handleSetStars(_ payload: Data) {
        let r = PacketReader(payload)
        var s = sky
        s.starsVisible = r.u8() != 0
        s.starCount = r.u32()
        s.starColor = SkyParams.argb(r.u32())
        s.starScale = r.f32()
        // (day_opacity, star_seed tail: not used)
        if r.overrun { return }
        sky = s; onSky?(s)
    }

    func handleCloudParams(_ payload: Data) {
        let r = PacketReader(payload)
        var s = sky
        s.cloudDensity = r.f32()
        s.cloudColor = SkyParams.argb(r.u32())                 // color_bright
        _ = r.u32()                                            // color_ambient
        s.cloudHeight = r.f32()
        _ = r.f32()                                            // thickness
        s.cloudSpeed = SIMD2(r.f32(), r.f32())
        // (color_shadow tail: not used)
        if r.overrun { return }
        sky = s; onSky?(s)
    }

    func handleSetLighting(_ payload: Data) {
        let r = PacketReader(payload)
        var s = sky
        _ = r.f32()                                            // shadow_intensity
        if r.has(4) { s.saturation = r.f32() }                 // >= 5.7.0-dev
        // (exposure, volumetric, shadow tint, bloom tail: no post pipeline here)
        if r.overrun { return }
        sky = s; onSky?(s)
    }

    private func handleChatMessage(_ payload: Data) {
        let r = PacketReader(payload)
        let version = r.u8(); let type = r.u8()
        guard version == 1 else { return }
        let sender = r.wideString()
        let text = r.wideString()
        if r.overrun { return }
        // Chat carries the same rich-text escapes (color/translation) as item
        // descriptions; strip them so lines don't show garbage glyphs. We drop
        // color here because a chat line bakes one white text bitmap per line
        // (per-run color needs a colored-run rasterizer, a bigger change). The
        // escape diagnostic flags chat lines that actually carry color so we can
        // prioritize that work if it matters in practice.
        let s = ItemRegistry.parseEscapes(sender, consumeColor: false, caller: "chat-sender").text
        let t = ItemRegistry.parseEscapes(text, consumeColor: false, caller: "chat-text").text
        onChat?(type, s, t)
    }

    private func handleOverrideDayNightRatio(_ payload: Data) {
        let r = PacketReader(payload)
        let doOverride = r.u8() != 0
        let ratio = Float(r.u16()) / 65536
        if r.overrun { return }
        dayNightOverride = doOverride ? ratio : nil
        updateDaylight()
    }

    private func handleShowFormspec(_ payload: Data) {
        let r = PacketReader(payload)
        let formspec = r.string32()
        let formname = r.string16()
        // Log every formspec arrival (name + size) BEFORE any parse can drop it,
        // so a missing bed/sleep dialog can be told apart from one we received
        // but failed to render.
        print("[formspec] recv name='\(formname)' len=\(formspec.count) overrun=\(r.overrun)"); fflush(stdout)
        if r.overrun { return }
        onShowFormspec?(formspec, formname)
    }

    /// TOCLIENT_INVENTORY_FORMSPEC (0x42): string32 formspec, nothing else.
    /// Kept, not shown: the client opens it when the player asks for the
    /// inventory (Client::handleCommand_InventoryFormSpec only stores it).
    func handleInventoryFormspec(_ payload: Data) {
        let r = PacketReader(payload)
        let formspec = r.string32()
        if r.overrun { return }
        inventoryFormspec = formspec
        print("[formspec] inventory formspec len=\(formspec.count)"); fflush(stdout)
        onInventoryFormspec?(formspec)
    }

    /// TOCLIENT_PRIVILEGES: u16 count, string16 names (Client::handleCommand_Privileges).
    func handlePrivileges(_ payload: Data) {
        let r = PacketReader(payload)
        let n = r.u16()
        var privs = Set<String>()
        for _ in 0..<min(n, 256) { privs.insert(r.string16()) }
        if r.overrun { return }
        privileges = privs
        print("[privs] \(privs.sorted().joined(separator: ","))"); fflush(stdout)
        onPrivileges?(privs)
    }

    /// TOCLIENT_HUD_SET_FLAGS: u32 flags, u32 mask; only the masked bits change
    /// (Client::handleCommand_HudSetFlags). mcl_shields / the spyglass turn
    /// wielditem off while blocking or zoomed, beds hide the bars while asleep.
    func handleHudSetFlags(_ payload: Data) {
        let r = PacketReader(payload)
        let flags = UInt32(truncatingIfNeeded: r.u32()), mask = UInt32(truncatingIfNeeded: r.u32())
        if r.overrun { return }
        hudFlags = (hudFlags & ~mask) | (flags & mask)
        print("[hud] flags=\(String(hudFlags & 0x1FF, radix: 2)) mask=\(String(mask & 0x1FF, radix: 2))"); fflush(stdout)
        onHudFlags?(hudFlags)
    }

    /// TOCLIENT_FOV: f32 fov, bool is_multiplier, f32 transition_time
    /// (Client::handleCommand_Fov). VoxeLibre's mcl_fovapi sends these all the
    /// time: sprint x1.1, bow draw x0.8, swiftness/slowness potions, the
    /// spyglass an absolute 8 degrees. A headset's projection is fixed by its
    /// optics, so the client records the request and never re-projects (a
    /// zoomed VR world reads as motion sickness, not a spyglass). fov 0 means
    /// "back to the client default".
    public struct FovOverride: Equatable, Sendable {
        public var fov: Float = 0
        public var isMultiplier = false
        public var transition: Float = 0
    }
    public private(set) var fovOverride = FovOverride()
    func handleFov(_ payload: Data) {
        let r = PacketReader(payload)
        var f = FovOverride()
        f.fov = r.f32(); f.isMultiplier = r.u8() != 0
        if r.has(4) { f.transition = r.f32() }   // >= 5.3.0 servers
        if r.overrun { return }
        if f != fovOverride {
            print("[hud] fov \(f.fov)\(f.isMultiplier ? "x" : "deg") over \(f.transition)s (recorded; VR projection stays fixed)"); fflush(stdout)
        }
        fovOverride = f
    }

    /// TOCLIENT_HUD_SET_PARAM: u16 param, string16 value
    /// (Client::handleCommand_HudSetParam). 1 = hotbar item count as a 4-byte
    /// big-endian s32 in the string, 2 / 3 = hotbar background / selected-slot
    /// image names. VoxeLibre sets 9 / blank.png / mcl_inventory_hotbar_selected.png
    /// at join. The item count sizes our wrist hotbar; the images are recorded
    /// but the wrist ring draws its own frame.
    public private(set) var hotbarItemCount = 9    // engine default is 8, but our wrist ring has 9 slots; VoxeLibre sends 9
    public private(set) var hotbarImage = ""
    public private(set) var hotbarSelectedImage = ""
    func handleHudSetParam(_ payload: Data) {
        let r = PacketReader(payload)
        let param = r.u16()
        let vb = r.bytes16()
        let value = String(decoding: vb, as: UTF8.self)
        if r.overrun { return }
        switch param {
        case 1:
            let b = [UInt8](vb)
            guard b.count == 4 else { return }
            let n = Int(Int32(bitPattern: UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])))
            if n > 0 && n <= 32 { hotbarItemCount = n }   // HUD_HOTBAR_ITEMCOUNT_MAX
        case 2: hotbarImage = value
        case 3: hotbarSelectedImage = value
        default: break
        }
        print("[hud] param \(param) = \(param == 1 ? String(hotbarItemCount) : value)"); fflush(stdout)
    }

    /// TOCLIENT_EYE_OFFSET: v3f first-person, v3f third-person (+ v3f
    /// third-person-front on newer servers). Only the first-person one
    /// matters in a headset; it is added to the eye like Camera::update does.
    func handleEyeOffset(_ payload: Data) {
        let r = PacketReader(payload)
        let first = SIMD3<Float>(r.f32(), r.f32(), r.f32()) / 10   // BS -> nodes
        if r.overrun { return }
        print("[props] eye offset \(first)"); fflush(stdout)
        onEyeOffset?(first)
    }

    /// The server's per-player formspec prepend (TOCLIENT_FORMSPEC_PREPEND, 0x61):
    /// a string prepended to every formspec, carrying the global background9 stone
    /// panel + button styles + listcolors (VoxeLibre sets it once at join). We
    /// stash it so the panel renderer can draw the backdrop (#244).
    public private(set) var formspecPrepend = ""
    private func handleFormspecPrepend(_ payload: Data) {
        let r = PacketReader(payload)
        let s = r.string16()
        if r.overrun { return }
        formspecPrepend = s
        print("[formspec] prepend len=\(s.count)"); fflush(stdout)
    }

    private func handleMovement(_ payload: Data) {
        let r = PacketReader(payload)
        let accelDefault = r.f32(); _ = r.f32(); _ = r.f32()  // accel default/air/fast
        let walk = r.f32(), crouch = r.f32(), fast = r.f32()  // speed walk/crouch/fast
        let climb = r.f32()                                   // movement_speed_climb (VoxeLibre 2.35)
        let jump = r.f32()
        let fluidity = r.f32(), fluiditySmooth = r.f32(), sink = r.f32()   // liquid fluidity/smooth/sink
        let gravity = r.f32()
        if r.overrun { return }
        if accelDefault > 0 { self.accelDefault = accelDefault * 10 }   // see the property note
        if climb > 0 { self.speedClimb = climb }
        onMovement?(walk, fast, crouch, jump, gravity)
        onLiquidMovement?(fluidity, fluiditySmooth, sink)
    }

    private func handleTimeOfDay(_ payload: Data) {
        let r = PacketReader(payload)
        timeOfDay = Float(r.u16())
        if r.has(4) { timeSpeed = r.f32() }
        updateDaylight()
    }

    /// Luanti's time_to_daynight_ratio(smooth) / 1000: 0.175 at night, 1 by
    /// day, ramping over ~6125..4625 either side of noon. The shaders blend the
    /// param1 day/night banks with exactly this ratio, as ClientMap does.
    private func updateDaylight() {
        var t = timeOfDay
        if t > 12000 { t = 24000 - t }
        let table: [(Float, Float)] = [(4375, 175), (4625, 175), (4875, 250), (5125, 350), (5375, 500),
                                       (5625, 675), (5875, 875), (6125, 1000), (6375, 1000)]
        var ratio: Float = 1000
        if t <= 4625 { ratio = 175 }
        else if t >= 6125 { ratio = 1000 }
        else {
            for i in 1..<table.count where table[i].0 > t {
                let f = (t - table[i - 1].0) / (table[i].0 - table[i - 1].0)
                ratio = f * table[i].1 + (1 - f) * table[i - 1].1
                break
            }
        }
        daylight = dayNightOverride ?? (ratio / 1000)   // server override wins (caves/dimensions)
    }

    // BLOCKDATA decode (zstd + 4096-node parse) used to run inline on the session
    // queue during poll, stalling the 16ms tick during streaming -> laggy
    // dig/place and sprint rubber-banding (#179/#180). Now the heavy decode runs
    // on a background queue and the cheap world splice happens back on the session
    // queue when poll() drains the finished blocks.
    private let blockDecodeQueue = DispatchQueue(label: "voxel.blockdecode", qos: .userInitiated)
    private let decodedLock = NSLock()
    private var decodedBlocks: [WorldMap.DecodedBlock] = []

    private func handleBlockData(_ payload: Data) {
        blockDecodeQueue.async { [weak self] in
            guard let self, let d = WorldMap.decodeBlock(payload) else { return }
            self.decodedLock.lock(); self.decodedBlocks.append(d); self.decodedLock.unlock()
        }
    }

    /// Splice finished blocks into the map on the session queue (called from poll).
    /// Caps how many land per tick so a big backlog can't itself stall a tick.
    private func drainDecodedBlocks() {
        decodedLock.lock()
        guard !decodedBlocks.isEmpty else { decodedLock.unlock(); return }
        let batch = decodedBlocks.count <= 24 ? decodedBlocks : Array(decodedBlocks.prefix(24))
        decodedBlocks.removeFirst(batch.count)
        decodedLock.unlock()
        var acked: [SIMD3<Int>] = []
        for d in batch { world.insert(d); acked.append(d.bpos); onBlock?(d.bpos) }
        if !acked.isEmpty { sendGotBlocks(acked) }
    }

    private func sendGotBlocks(_ positions: [SIMD3<Int>]) {
        let w = PacketWriter()
        w.u8(positions.count)
        for p in positions { w.s16(p.x).s16(p.y).s16(p.z) }
        conn.sendMessage(Op.toserverGotBlocks, w.data)
    }

    /// TOSERVER_HAVE_MEDIA (0x41): u8 count + u32 tokens, acking pushed media
    /// (Client::sendHaveMedia). The server's dynamic_add_media callback waits
    /// on this, so a missing ack leaves mods thinking the push never landed.
    static func haveMediaPacket(_ tokens: [Int]) -> Data {
        let w = PacketWriter()
        w.u8(min(255, tokens.count))
        for t in tokens.prefix(255) { w.u32(t) }
        return w.data
    }
    func sendHaveMedia(_ tokens: [Int]) {
        guard !tokens.isEmpty else { return }
        conn.sendMessage(Op.toserverHaveMedia, Client.haveMediaPacket(tokens))
    }

    /// TOSERVER_DELETEDBLOCKS payloads for `positions`: u8 count + v3s16 each
    /// (same layout as GOTBLOCKS), split at 255 per packet because the count
    /// is a single byte, the way Client::step batches its sendlist.
    static func deletedBlocksPackets(_ positions: [SIMD3<Int>]) -> [Data] {
        var out: [Data] = []
        var i = 0
        while i < positions.count {
            let chunk = positions[i..<min(i + 255, positions.count)]
            let w = PacketWriter()
            w.u8(chunk.count)
            for p in chunk { w.s16(p.x).s16(p.y).s16(p.z) }
            out.append(w.data)
            i += chunk.count
        }
        return out
    }

    /// Age out blocks the player has left behind (WorldMap.expire) and tell the
    /// server which ones, so it marks them not-sent and streams them again if
    /// we come back. Call once a tick with the player's mapblock. Returns what
    /// was dropped so the caller can drop those meshes too.
    @discardableResult
    public func unloadUnusedBlocks(dt: Float, near: SIMD3<Int>) -> [SIMD3<Int>] {
        let gone = world.expire(dt: dt, near: near)
        for pkt in Client.deletedBlocksPackets(gone) { conn.sendMessage(Op.toserverDeletedBlocks, pkt) }
        return gone
    }

    /// Immediately drop every loaded block outside `radius` mapblocks of `near`,
    /// instead of the slow age-out, for a dimension change / long teleport: the
    /// place you left otherwise hangs in the void (stale geometry, no ground)
    /// while the new area streams in. `timeout: 0` with a nonzero `dt` ages every
    /// out-of-range block past its deadline in one call; in-range blocks reset.
    /// Tells the server (DELETEDBLOCKS) so it re-streams them if we return.
    @discardableResult
    public func purgeFarBlocks(near: SIMD3<Int>, radius: Int = 12) -> [SIMD3<Int>] {
        let gone = world.expire(dt: 1, near: near, radius: radius, timeout: 0)
        for pkt in Client.deletedBlocksPackets(gone) { conn.sendMessage(Op.toserverDeletedBlocks, pkt) }
        return gone
    }

    /// Wire format per Client::sendPlayerPos / writePlayerPos (src/client/client.cpp):
    /// pos/vel as v3s32*1000, pitch/yaw as s32 degrees*100, u32 pressed keys,
    /// u8 fov*80, u8 wanted_range. (Originally ported via player.gd player_pos_block().)
    func playerPosBlockData(keys: Int = 0) -> Data {   // internal for PlayerPosPacketTests
        let w = PacketWriter()
        func si(_ f: Float) -> Int { f.isFinite ? Int(f) : 0 }   // Int(NaN/Inf) traps
        w.s32(si(spawn.x * 1000)).s32(si(spawn.y * 1000)).s32(si(spawn.z * 1000))
        w.s32(si(velocity.x * 1000)).s32(si(velocity.y * 1000)).s32(si(velocity.z * 1000))
        w.s32(si(pitch * 180 / .pi * 100)).s32(si(yaw * 180 / .pi * 100))
        w.u32(keys)                                             // key/dig/place state
        w.u8(240)                                               // fov*80, wide cone so streaming fills as you look around
        w.u8(wantedRange)
        w.u8(0)
        w.f32(0).f32(0)                                         // unused tail
        return w.data
    }

    /// Report the place/RMB key as held in the PLAYERPOS control bits. VoxeLibre's
    /// eat is a HOLD: mcl_hunger ticks an eating delay (~1.6s) off control.RMB, not
    /// a one-shot INTERACT, so a single activate never finishes a bite. The
    /// raise-to-mouth gesture sets this while food is at the mouth (#173).
    public var placeHeld = false
    /// Sneak (control bit 6 / value 64) held. Mods read control.sneak for
    /// sneak-place and sneak-click behaviors, and the client uses sneak to force
    /// placement instead of a node's rightclick/formspec (#178).
    public var sneakHeld = false
    /// Directional + aux1 (sprint) control bits for PLAYERPOS, set each tick from
    /// the stick + sprint grip, exactly as the official client reports its keys
    /// (PlayerControl::getKeysPressed). The server derives the allowed speed from
    /// these (mcl_sprint checks aux1 + up), so a client that omits them is
    /// corrected back by MOVE_PLAYER (#180). Bits: up=1 down=2 left=4 right=8 aux1=32.
    public var moveKeys: Int = 0
    /// Dig/LMB (control bit 7 / value 128) held. Mods read control.LMB (e.g.
    /// mcl_playerplus for the swing pose others see).
    public var digHeld = false
    /// Jump (control bit 4 / value 16) held. Mounts read control.jump to make
    /// a horse jump, boats/minecarts to dismount, mcl_playerplus for the pose.
    public var jumpHeld = false
    var heldKeys: Int {   // internal for PlayerPosPacketTests
        moveKeys | (jumpHeld ? 16 : 0) | (sneakHeld ? 64 : 0) | (digHeld ? 128 : 0) | (placeHeld ? 256 : 0)
    }

    /// Map a stick vector + sprint flag to Luanti PlayerControl bits for `moveKeys`:
    /// up=1 down=2 left=4 right=8 aux1(sprint)=32. dy>0 is forward, dx>0 is right
    /// (WorldSession's frame). A small dead-zone keeps stick drift from latching a
    /// direction. mcl_sprint needs aux1 + up together, so a pure-strafe sprint sets
    /// aux1 without up, matching desktop (you only sprint moving forward).
    public static func moveControlBits(dx: Float, dy: Float, sprint: Bool, deadzone: Float = 0.1) -> Int {
        var bits = 0
        if dy > deadzone { bits |= 1 } else if dy < -deadzone { bits |= 2 }
        if dx < -deadzone { bits |= 4 } else if dx > deadzone { bits |= 8 }
        if sprint { bits |= 32 }
        return bits
    }

    private func sendPlayerPos() {
        conn.sendMessage(Op.toserverPlayerPos, playerPosBlockData(keys: heldKeys))
    }

    /// TOSERVER_INTERACT, mirroring Client::interact (src/client/client.cpp) and the
    /// InteractAction enum in src/network/networkprotocol.h: u8 action, u16 wield,
    /// bytes32(pointed thing), then the player-pos block.
    /// action: 0 start dig, 1 stop dig, 2 dig complete, 3 place, 4 use,
    /// 5 activate (rightclick air; pointed thing is always "nothing").
    public func sendInteract(action: Int, under: SIMD3<Int>?, above: SIMD3<Int>?) {
        conn.sendMessage(Op.toserverInteract, interactPacket(action: action, under: under, above: above))
    }

    /// INTERACT pointing at an OBJECT (a mob/player): action 0 = punch/attack,
    /// 3 = rightclick. pointed_thing type 2 carries the AO id.
    public func sendInteract(action: Int, objectId: Int) {
        conn.sendMessage(Op.toserverInteract, interactPacketObject(action: action, objectId: objectId))
    }

    func interactPacketObject(action: Int, objectId: Int) -> Data {
        let pt = PacketWriter()
        pt.u8(0).u8(2).u16(objectId)                // version, type: object, id
        let w = PacketWriter().u8(action).u16(wieldIndex).bytes32(pt.data)
        w.raw(playerPosBlockData(keys: 0))
        return w.data
    }

    /// The INTERACT body (split out so tests can decode it without a socket).
    func interactPacket(action: Int, under: SIMD3<Int>?, above: SIMD3<Int>?) -> Data {
        let pt = PacketWriter()
        pt.u8(0)                                    // pointed version
        if let u = under, let a = above {
            pt.u8(1)                                // type: node
            pt.s16(u.x).s16(u.y).s16(u.z)
            pt.s16(a.x).s16(a.y).s16(a.z)
        } else {
            pt.u8(0)                                // type: nothing
        }
        // Carry the held place/sneak bits through the interact too, so re-arming
        // the eat (activate) mid-hold doesn't momentarily read RMB as released
        // (#173) and the server sees sneak during a sneak-place (#178).
        let keys = (action == 2 ? 128 : 0) | (action == 3 ? 256 : 0) | heldKeys
        let w = PacketWriter().u8(action).u16(wieldIndex).bytes32(pt.data)
        w.raw(playerPosBlockData(keys: keys))
        return w.data
    }
}
