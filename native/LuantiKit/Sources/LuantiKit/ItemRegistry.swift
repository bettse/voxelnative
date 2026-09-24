import Foundation
import simd

/// Item definitions from TOCLIENT_ITEMDEF: item name -> inventory image and
/// tool capabilities. Images texture dropped-item entities; tool capabilities
/// (together with a node's groups) give the time it takes to dig it.
public final class ItemRegistry {
    public struct GroupCap {
        public var uses: Int
        public var maxLevel: Int
        public var times: [Int: Float]   // group rating -> seconds
    }
    public struct ToolCaps {
        public var fullPunchInterval: Float = 1
        public var maxDropLevel: Int = 0
        public var groupCaps: [String: GroupCap] = [:]
    }

    public private(set) var inventoryImage: [String: String] = [:]
    public private(set) var descriptions: [String: String] = [:]
    /// Human-readable item name (first line of the description), for the inventory panel.
    public func description(for itemString: String) -> String {
        descriptionColored(for: itemString).text
    }
    /// Like `description(for:)` but keeps the item name's leading color as a
    /// packed tint, so a renamed/enchanted item shows in its own color instead
    /// of default white (the same strip-vs-parse gap that hid the chest label).
    public func descriptionColored(for itemString: String) -> (text: String, color: Float?) {
        let n = Self.baseName(itemString)
        let (d, color) = Self.parseEscapes(descriptions[n] ?? n, consumeColor: true, caller: "item-name")
        let line = d.split(separator: "\n").first.map(String.init) ?? n
        return (line, color)
    }

    /// Remove Minetest rich-text escape sequences (translation domains, colors)
    /// so item names don't render with garbage glyphs before them. Sequences
    /// start with ESC (0x1b): `\u{1b}(...)` is a parenthesised arg (e.g.
    /// `(T@mcl_core)`, `(c@#fff)`) — drop ESC and the balanced parens; any other
    /// `\u{1b}X` (like `\u{1b}E` end-translation) drops ESC and the next char.
    public static func stripEscapes(_ s: String) -> String {
        parseEscapes(s, consumeColor: false, caller: "stripEscapes").text
    }

    /// Parse Minetest in-band text escapes. Returns the cleaned text and the
    /// first foreground color `\x1b(c@#rgb)` as a packed tint (r + g*256 +
    /// b*65536), nil if none. `consumeColor` = the caller will render in that
    /// color; when false and a color is present we're DROPPING it, which is a
    /// bug (text renders default white) -- flagged via the escape diagnostic so
    /// every strip-without-parse shows up in the device log (Eric). Translation
    /// (T@domain) and E/F markers are always dropped (we can't translate; the
    /// stripped source text is what we render).
    public static func parseEscapes(_ s: String, consumeColor: Bool, caller: String = "?") -> (text: String, color: Float?) {
        guard s.contains("\u{1b}") else { return (s, nil) }
        var out = String(); out.reserveCapacity(s.count)
        var color: Float? = nil
        var it = s.makeIterator()
        while let c = it.next() {
            if c != "\u{1b}" { out.append(c); continue }
            guard let nxt = it.next() else { break }
            if nxt == "(" {
                var grp = ""
                while let p = it.next(), p != ")" { grp.append(p) }
                if grp.hasPrefix("c@") || grp.hasPrefix("b@") {
                    let parsed = packColor(String(grp.dropFirst(2)))
                    if grp.hasPrefix("c@"), consumeColor, color == nil {
                        color = parsed
                    } else if grp.hasPrefix("c@"), !consumeColor {
                        logStrippedColor(code: grp, caller: caller, sample: s)
                    }
                }
                // else: T@domain / other groups -> dropped (translation markers)
            }
            // else: ESC + single control char (E/F) -> dropped
        }
        return (out, color)
    }

    /// Pack "#rgb"/"#rrggbb" (or bare hex) into r + g*256 + b*65536; nil for a
    /// named color like "red" (can't render without a palette).
    private static func packColor(_ hex: String) -> Float? {
        var s = Substring(hex); if s.first == "#" { s = s.dropFirst() }
        func hx(_ a: Substring) -> Int { Int(a, radix: 16) ?? 0 }
        let valid = s.allSatisfy { $0.isHexDigit }
        guard valid else { return nil }
        let r: Int, g: Int, b: Int
        if s.count == 3 { let a = Array(s); r = hx(Substring(String(a[0])))*17; g = hx(Substring(String(a[1])))*17; b = hx(Substring(String(a[2])))*17 }
        else if s.count == 6 { r = hx(s.prefix(2)); g = hx(s.dropFirst(2).prefix(2)); b = hx(s.dropFirst(4).prefix(2)) }
        else { return nil }
        return Float(r + g*256 + b*65536)
    }

    // Debug-only dedup for the escape diagnostic; a race just risks a repeat log line.
    nonisolated(unsafe) private static var seenEscapeSamples = Set<String>()
    private static func logStrippedColor(code: String, caller: String, sample: String) {
        guard UserDefaults.standard.bool(forKey: "vrdev.escapeDiag") else { return }
        let clean = parseEscapes(sample, consumeColor: true, caller: "diag").text.prefix(24)
        let key = "\(code)|\(caller)|\(clean)"
        guard !seenEscapeSamples.contains(key) else { return }
        seenEscapeSamples.insert(key)
        print("[escape] stripped-not-parsed code=\(code) caller=\(caller) in '\(clean)'"); fflush(stdout)
    }
    /// Keyed by item name; "" is the bare hand.
    public private(set) var toolCaps: [String: ToolCaps] = [:]
    /// node_placement_prediction per item: the node the client may place
    /// locally before the server answers. "" means "don't predict" (the mod's
    /// on_place decides: doors, beds, torches, buckets...).
    public private(set) var placementPrediction: [String: String] = [:]
    /// sound_place per item (sound-group name; "" = none).
    public private(set) var placeSounds: [String: String] = [:]
    public private(set) var placeFailedSounds: [String: String] = [:]   // sound_place_failed
    /// range per item (nodes; the engine's default is 4).
    public private(set) var ranges: [String: Float] = [:]
    /// stack_max per item (max items in one slot), for client-side merge/place
    /// prediction. Minetest's default is 99 when an item didn't send one.
    public private(set) var stackMaxes: [String: Int] = [:]
    public func stackMax(_ itemString: String) -> Int { stackMaxes[Self.baseName(itemString)] ?? 99 }
    /// `usable` per item: the ItemDef has an on_use, so pressing the dig/attack
    /// button fires INTERACT_USE (throwables: egg, snowball, ender pearl, bow).
    public private(set) var usables: Set<String> = []
    /// Whether the wielded item throws/uses on the attack button (has on_use).
    public func isUsable(_ itemString: String) -> Bool { usables.contains(Self.baseName(itemString)) }
    /// Items in the `food`/`eatable` group, for the raise-to-mouth eat gesture.
    public private(set) var eatables: Set<String> = []
    public func isEatable(_ itemString: String) -> Bool { eatables.contains(Self.baseName(itemString)) }
    /// Armor pieces keyed by item name -> mcl_armor slot index (1 head, 2 torso,
    /// 3 legs, 4 feet), from the armor_head/torso/legs/feet groups. Used by the
    /// inventory shift-click quick-move to route a piece to its slot.
    public private(set) var armorSlots: [String: Int] = [:]
    public func armorSlot(_ itemString: String) -> Int? { armorSlots[Self.baseName(itemString)] }
    /// nil = item unknown to us (caller falls back), "" = don't predict.
    public func prediction(for itemString: String) -> String? { placementPrediction[Self.baseName(itemString)] }
    public func placeSound(for itemString: String) -> String? {
        guard let s = placeSounds[Self.baseName(itemString)], !s.isEmpty else { return nil }
        return s
    }
    public func placeFailedSound(for itemString: String) -> String? {
        guard let s = placeFailedSounds[Self.baseName(itemString)], !s.isEmpty else { return nil }
        return s
    }
    public func range(for itemString: String) -> Float? { ranges[Self.baseName(itemString)] }
    /// place_param2: the param2 a placed node gets BEFORE any facedir/wallmounted
    /// derivation (game.cpp nodePlacement; VoxeLibre crops, kelp, corals,
    /// lanterns). nil = derive from the placement as usual.
    public func placeParam2(for itemString: String) -> Int? { placeParam2s[Self.baseName(itemString)] }
    /// wield_scale from the ITEMDEF, (1,1,1) when unknown.
    public func wieldScale(for itemString: String) -> SIMD3<Float> { wieldScales[Self.baseName(itemString)] ?? SIMD3(1, 1, 1) }
    private var placeParam2s: [String: Int] = [:]
    private var wieldScales: [String: SIMD3<Float>] = [:]
    /// SoundSpec::serializeSimple: string16 name, then f32 gain/pitch/fade.
    private static func readSimpleSound(_ r: PacketReader) -> String {
        let name = r.string16()
        _ = r.f32(); _ = r.f32(); _ = r.f32()
        return name
    }
    public var count: Int { inventoryImage.count }

    /// Strips any count/metadata after a space from an itemstring.
    public static func baseName(_ itemString: String) -> String {
        // Almost every itemstring is a bare name; skip the split (an array and
        // a String per call, twice per dropped item per tick).
        guard let sp = itemString.firstIndex(of: " ") else { return itemString }
        return String(itemString[..<sp])
    }

    public func image(for itemString: String) -> String? { inventoryImage[Self.baseName(itemString)] }

    /// Every non-empty inventory_image spec across all items, for pulling their
    /// PNGs up front. Tools/craftitems whose image isn't also a node tile are
    /// otherwise never in any media request, so their hotbar cell renders empty.
    public func allImages() -> Set<String> { Set(inventoryImage.values.filter { !$0.isEmpty }) }
    public func caps(for itemString: String) -> ToolCaps? { toolCaps[Self.baseName(itemString)] }

    /// Bare-hand capabilities. VoxeLibre's "" hand carries no groupcaps: the
    /// real digging hand is a per-skin mcl_meshhand:*_surv item the server puts
    /// in the player's "hand" inventory list. Until we parse that list, any
    /// survival meshhand works (they all share the same groupcaps).
    public func handCaps() -> ToolCaps? {
        if let h = toolCaps[""], !h.groupCaps.isEmpty { return h }
        let mesh = toolCaps.keys.filter { $0.hasPrefix("mcl_meshhand:") && $0.hasSuffix("_surv") }.sorted()
        for k in mesh { if let c = toolCaps[k], !c.groupCaps.isEmpty { return c } }
        return toolCaps[""]
    }

    /// Parse TOCLIENT_ITEMDEF: a zstd long-string wrapping version, count, then
    /// one length-prefixed ItemDefinition blob each. We read up to the
    /// tool_capabilities blob (ItemDefinition::deSerialize order).
    public func parseItemDef(_ payload: Data) {
        let outer = PacketReader(payload)
        let blob = outer.bytes32()
        guard let raw = Zstd.decompress(blob, maxSize: 32 * 1024 * 1024) else { return }
        let r = PacketReader(raw)
        _ = r.u8()                       // itemdef manager version (0)
        let count = r.u16()
        guard count > 0 && count < 65535 else { return }
        var images: [String: String] = [:]
        var descs: [String: String] = [:]
        var caps: [String: ToolCaps] = [:]
        for _ in 0..<count {
            let def = PacketReader(r.bytes16())
            _ = def.u8()                 // ItemDefinition version
            _ = def.u8()                 // item type
            let name = def.string16()
            let desc = def.string16()    // description
            let inv = def.string16()     // inventory_image (ItemImageDef: name + animation)
            Self.skipTileAnimation(def)
            _ = def.string16()           // wield_image
            Self.skipTileAnimation(def)
            let wieldScale = SIMD3<Float>(def.f32(), def.f32(), def.f32())   // wield_scale (VoxeLibre tools 1.8, shields 2)
            let stackMaxVal = Int(def.s16())   // stack_max (for client-side merge prediction)
            let usableFlag = def.u8() != 0   // has on_use (throwables, bow, food-ish)
            _ = def.u8()                 // liquids_pointable
            let tc = def.bytes16()       // tool_capabilities (nested binary; empty = none)
            // groups: u16 count x (string16 name, s16 rating). Then the fields
            // the place path wants (ItemDefinition::deSerialize order).
            let ng = def.u16()
            var eatable = false
            var armorSlot = 0
            if ng < 4096 { for _ in 0..<ng {
                let gname = def.string16(); let rating = def.s16()
                // VoxeLibre food carries a `food`/`eatable` group; the raise-to-mouth
                // eat gesture uses this to fire only on consumables.
                if rating != 0, gname == "food" || gname == "eatable" { eatable = true }
                // Armor groups -> mcl_armor slot index (shift-click quick-move).
                if rating != 0 { switch gname {
                    case "armor_head":  armorSlot = 1
                    case "armor_torso": armorSlot = 2
                    case "armor_legs":  armorSlot = 3
                    case "armor_feet":  armorSlot = 4
                    default: break
                } }
            } }
            let prediction = def.string16()             // node_placement_prediction
            let placeSound = Self.readSimpleSound(def)  // sound_place
            let placeFailed = Self.readSimpleSound(def)  // sound_place_failed
            let range = def.f32()
            let coreOK = !def.overrun   // everything up to range parsed; the tail below is optional
            // Tail (itemdef.cpp serialize, version 6, protocol > 43): palette_image,
            // color, inventory_overlay, wield_overlay, short_description, sound_use,
            // sound_use_air, then place_param2 as has-value u8 + u8, and
            // wallmounted_rotate_vertical / touch_interaction. Older servers end
            // earlier, so every read past range is guarded by `has`.
            _ = def.string16(); _ = def.u32()             // palette_image, color (unused by VoxeLibre)
            _ = def.string16(); Self.skipTileAnimation(def)   // inventory_overlay (ItemImageDef: name + animation)
            _ = def.string16(); Self.skipTileAnimation(def)   // wield_overlay
            _ = def.string16()                            // short_description
            var placeP2: Int? = nil
            if def.has(2) {
                _ = Self.readSimpleSound(def); _ = Self.readSimpleSound(def)   // sound_use, sound_use_air
                if def.has(1), def.u8() != 0, def.has(1) { placeP2 = def.u8() }
            }
            if def.overrun { placeP2 = nil }   // a short (older-server) tail: keep the core, drop the tail
            if !name.isEmpty { images[name] = inv; descs[name] = desc }
            if !tc.isEmpty, coreOK, let c = Self.parseToolCaps(PacketReader(tc)) { caps[name] = c }
            if !name.isEmpty, coreOK {
                placementPrediction[name] = prediction
                placeSounds[name] = placeSound
                placeFailedSounds[name] = placeFailed
                ranges[name] = range
                wieldScales[name] = wieldScale
                if let p2 = placeP2 { placeParam2s[name] = p2 }
                if usableFlag { usables.insert(name) }
                if eatable { eatables.insert(name) }
                if armorSlot != 0 { armorSlots[name] = armorSlot }
                if stackMaxVal > 0 { stackMaxes[name] = stackMaxVal }
            }
            if r.overrun { break }
        }
        inventoryImage.merge(images) { $1 }
        descriptions.merge(descs) { $1 }
        toolCaps.merge(caps) { $1 }
    }

    /// TileAnimationParams (protocol >= 51 puts one after each item image name).
    private static func skipTileAnimation(_ r: PacketReader) {
        switch r.u8() {
        case 1: _ = r.u16(); _ = r.u16(); _ = r.f32()   // vertical_frames
        case 2: _ = r.u8(); _ = r.u8(); _ = r.f32()     // sheet_2d
        default: break
        }
    }

    /// ToolCapabilities::deSerialize (version >= 4).
    private static func parseToolCaps(_ r: PacketReader) -> ToolCaps? {
        guard r.u8() >= 4 else { return nil }
        var t = ToolCaps()
        t.fullPunchInterval = r.f32()
        t.maxDropLevel = r.s16()
        let n = r.u32()
        guard n <= 4096 else { return nil }
        for _ in 0..<n {
            let group = r.string16()
            let uses = r.s16()
            let maxLevel = r.s16()
            let tn = r.u32()
            guard tn <= 4096 else { return nil }
            var times: [Int: Float] = [:]
            for _ in 0..<tn {
                let rating = r.s16()
                let time = r.f32()
                times[rating] = time
            }
            if r.overrun { return nil }
            t.groupCaps[group] = GroupCap(uses: uses, maxLevel: maxLevel, times: times)
        }
        return t
    }
}

/// Luanti's getDigParams (tool.cpp), minus wear: how long a tool takes to dig a
/// node, from the node's groups and the tool's groupcaps.
public enum DigParams {
    /// Seconds to dig, or nil when this tool can't dig the node at all.
    public static func digTime(groups: [String: Int], caps: ItemRegistry.ToolCaps?) -> Float? {
        params(groups: groups, caps: caps)?.time
    }

    /// tool.cpp getDigParams: the fastest groupcap that applies (its level
    /// allows the node's level), with the winning group name -- the engine
    /// uses that name to resolve a "__group" sound_dig to default_dig_<group>.
    /// nil = not diggable with these caps (the caller then tries the hand,
    /// as game.cpp handleDigging does).
    public static func params(groups: [String: Int], caps: ItemRegistry.ToolCaps?) -> (time: Float, group: String)? {
        // dig_immediate defaults to a fixed time unless the tool overrides it.
        if caps?.groupCaps["dig_immediate"] == nil {
            switch groups["dig_immediate"] ?? 0 {
            case 2: return (0.5, "dig_immediate")
            case 3: return (0, "dig_immediate")
            default: break
            }
        }
        guard let caps else { return nil }
        let level = groups["level"] ?? 0
        var best: (time: Float, group: String)?
        for (name, cap) in caps.groupCaps {
            let levelDiff = cap.maxLevel - level
            if levelDiff < 0 { continue }
            guard var time = cap.times[groups[name] ?? 0] else { continue }
            if levelDiff > 1 { time /= Float(levelDiff) }
            if best.map({ time < $0.time }) ?? true { best = (time, name) }
        }
        return best
    }
}
