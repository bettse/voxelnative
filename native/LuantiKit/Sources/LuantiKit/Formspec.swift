import Foundation

/// Minimal formspec parsing: the element syntax the engine's GUIFormSpecMenu
/// (src/gui/guiFormSpecMenu.cpp) accepts, reduced to what the VR panel draws
/// (list[], label, image, button, field, background, container, tooltip,
/// checkbox). Anything else is ignored.
public enum Formspec {
    public struct List: Equatable {
        public let loc: String   // "current_player" or "nodemeta:x,y,z"
        public let list: String  // list name ("main", "fuel", "dst", ...)
        public let gx: Float, gy: Float
        public let cols: Int, rows: Int
        public let start: Int
        /// Slot-to-slot distance in form units: 1.25 in real coordinates;
        /// a legacy form's rows sit closer (15/13), see Legacy.
        public var pitch = SIMD2<Float>(1.25, 1.25)
    }

    /// Parse `list[<loc>;<name>;<x>,<y>;<w>,<h>{;<start>}]`. `context` resolves
    /// current_name/context to that node's nodemeta location.
    public static func parseLists(_ spec: String, context: SIMD3<Int>?) -> [List] {
        var out: [List] = []
        for chunk in spec.split(separator: "]") {
            guard let r = chunk.range(of: "list[") else { continue }
            let f = chunk[r.upperBound...].split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4 else { continue }
            var loc = f[0]
            if loc == "current_name" || loc == "context" {
                guard let c = context else { continue }
                loc = "nodemeta:\(c.x),\(c.y),\(c.z)"
            }
            let xy = f[2].split(separator: ","), wh = f[3].split(separator: ",")
            guard xy.count == 2, wh.count == 2,
                  let gx = Float(xy[0]), let gy = Float(xy[1]),
                  let cols = Int(wh[0].split(separator: ".").first.map(String.init) ?? ""),
                  let rows = Int(wh[1].split(separator: ".").first.map(String.init) ?? "") else { continue }
            let start = f.count >= 5 ? (Int(f[4]) ?? 0) : 0
            out.append(List(loc: loc, list: f[1], gx: gx, gy: gy, cols: cols, rows: rows, start: start))
        }
        return out
    }

    /// Parse the `listring[]` chain that drives shift-click quick-move order.
    /// Two forms, in document order (bare form refers to earlier list[] elements):
    ///   listring[<loc>;<list>]  appends that list to the ring.
    ///   listring[]              appends the last two list[] elements added so
    ///                           far (Luanti's shorthand), in that order.
    /// Returns the ring as ordered (loc, list) pairs; shift-clicking a slot moves
    /// its stack to the NEXT ring entry after the source list (wrapping). This is
    /// how a furnace routes fuel vs ingredient: the ring points player `main` at
    /// the server-side `distr` list, whose put-handler sorts by recipe (#208).
    public static func parseListrings(_ spec: String, context: SIMD3<Int>?) -> [(loc: String, list: String)] {
        func resolve(_ s: String) -> String? {
            if s == "current_name" || s == "context" {
                guard let c = context else { return nil }
                return "nodemeta:\(c.x),\(c.y),\(c.z)"
            }
            return s
        }
        var lists: [(loc: String, list: String)] = []   // list[] in document order
        var ring: [(loc: String, list: String)] = []
        for chunk in spec.split(separator: "]", omittingEmptySubsequences: false) {
            if let r = chunk.range(of: "listring[") {
                let inner = String(chunk[r.upperBound...])
                let f = inner.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
                if f.count >= 2, let loc = resolve(f[0]) {
                    ring.append((loc, f[1]))
                } else if inner.isEmpty, lists.count >= 2 {   // bare listring[]: last two list[]
                    ring.append(lists[lists.count - 2])
                    ring.append(lists[lists.count - 1])
                }
            } else if let r = chunk.range(of: "list[") {
                let f = chunk[r.upperBound...].split(separator: ";", omittingEmptySubsequences: false).map(String.init)
                if f.count >= 2, let loc = resolve(f[0]) { lists.append((loc, f[1])) }
            }
        }
        return ring
    }

    /// Flatten `container[x,y]` ... `container_end[]` by baking the running
    /// offset into each contained element's leading `x,y` position, then dropping
    /// the container markers. Lets every parser stay container-unaware (the
    /// enchanting table wraps each option row in a container, which otherwise
    /// collapses all three at the panel origin, #234). Only elements whose FIRST
    /// param is `x,y` are shifted (button/image/label/field/item_image/box); a
    /// list[] (loc-first) inside a container is left as-is (VoxeLibre doesn't do that).
    public static func flattenContainers(_ spec: String) -> String {
        guard spec.contains("container") else { return spec }
        var curX: Float = 0, curY: Float = 0
        var stack: [(Float, Float)] = []
        var out = ""
        let parts = spec.split(separator: "]", omittingEmptySubsequences: false).map(String.init)
        for (i, part) in parts.enumerated() {
            let close = i < parts.count - 1 ? "]" : ""
            guard let br = part.lastIndex(of: "[") else { out += part; continue }
            var ni = br
            while ni > part.startIndex {
                let p = part.index(before: ni)
                let c = part[p]
                if c.isLetter || c.isNumber || c == "_" { ni = p } else { break }
            }
            let name = String(part[ni..<br])
            let prefix = String(part[part.startIndex..<ni])
            let params = String(part[part.index(after: br)...])
            if name == "container" {
                let xy = params.split(separator: ",")
                if xy.count >= 2, let x = Float(xy[0]), let y = Float(xy[1]) {
                    stack.append((curX, curY)); curX += x; curY += y
                }
                out += prefix   // drop the container[] marker itself
                continue
            }
            if name == "container_end" {
                if let (px, py) = stack.popLast() { curX = px; curY = py }
                out += prefix
                continue
            }
            var newParams = params
            if curX != 0 || curY != 0, let semi = params.firstIndex(of: ";") {
                let xy = params[..<semi].split(separator: ",")
                if xy.count == 2, let x = Float(xy[0]), let y = Float(xy[1]) {
                    newParams = "\(x + curX),\(y + curY)" + params[semi...]
                }
            }
            out += prefix + name + "[" + newParams + close
        }
        return out
    }

    /// A static text label at a formspec grid position. `color` is the packed
    /// tint (r + g*256 + b*65536) from a leading `\x1b(c@#rgb)` escape, nil for
    /// default white. Labels like the chest "Inventory" title ship a dark color
    /// that we used to strip, painting white text invisibly on a light panel (#254).
    public struct Label: Equatable {
        public let gx: Float, gy: Float
        public let text: String
        public let color: Float?
    }

    /// Parse `label[<x>,<y>;<text>]` (the text stations use to name themselves and
    /// their slots). Gives an otherwise-bare station UI something readable (#176).
    /// Guards against matching the `vertlabel[` suffix.
    public static func parseLabels(_ spec: String) -> [Label] {
        var out: [Label] = []
        for chunk in spec.split(separator: "]") {
            guard let r = chunk.range(of: "label[") else { continue }
            // "label[" must start the token, not be the tail of "vertlabel[".
            if r.lowerBound != chunk.startIndex,
               chunk[chunk.index(before: r.lowerBound)].isLetter { continue }
            let f = chunk[r.upperBound...].split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2 else { continue }
            let xy = f[0].split(separator: ",")
            guard xy.count == 2, let gx = Float(xy[0]), let gy = Float(xy[1]) else { continue }
            let (text, color) = cleanColored(f[1])
            if !text.isEmpty { out.append(Label(gx: gx, gy: gy, text: text, color: color)) }
        }
        return out
    }

    /// Editable text inputs (`field[x,y;w,h;name;label;default]` and
    /// `textarea[...]`). Returns (name, default) for each. Used for sign text.
    public static func parseFields(_ spec: String) -> [(name: String, value: String)] {
        var out: [(String, String)] = []
        for chunk in spec.split(separator: "]") {
            let c = String(chunk)
            let kind: String
            if let r = c.range(of: "field[") { kind = String(c[r.upperBound...]) }
            else if let r = c.range(of: "textarea[") { kind = String(c[r.upperBound...]) }
            else { continue }
            let f = kind.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            // field[pos;size;name;label;default] -> name at 2, default at 4; a
            // bare field[name;label;default] (no pos/size) has name at 0.
            if f.count >= 5 { out.append((f[2], f[4])) }
            else if f.count == 3 { out.append((f[0], f[2])) }
        }
        return out
    }

    /// A `background[]` / `background9[]` panel image. `fill` (background9, or
    /// background[...;auto_clip=true]) stretches over the whole formspec -- that's
    /// the global stone panel from the formspec prepend (#244).
    public struct Background: Equatable {
        public let gx: Float, gy: Float, w: Float, h: Float
        public let texture: String
        public let fill: Bool
    }

    /// Parse `background[x,y;w,h;tex{;auto_clip}]` and `background9[x,y;w,h;tex;draw_border{;middle}]`.
    public static func parseBackgrounds(_ spec: String) -> [Background] {
        var out: [Background] = []
        for chunk in spec.split(separator: "]") {
            let c = String(chunk)
            let nine: Bool, params: String
            if let r = c.range(of: "background9[") { nine = true; params = String(c[r.upperBound...]) }
            else if let r = c.range(of: "background[") { nine = false; params = String(c[r.upperBound...]) }
            else { continue }
            let f = params.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3 else { continue }
            let xy = f[0].split(separator: ","), wh = f[1].split(separator: ",")
            guard xy.count == 2, wh.count == 2,
                  let gx = Float(xy[0]), let gy = Float(xy[1]),
                  let w = Float(wh[0]), let h = Float(wh[1]) else { continue }
            let tex = f[2]
            // background9 always fills; a plain background fills when its auto_clip
            // (5th) field is true (that's how the prepend requests a full backdrop).
            let fill = nine || (f.count >= 4 && f[3] == "true")
            if !tex.isEmpty { out.append(Background(gx: gx, gy: gy, w: w, h: h, texture: tex, fill: fill)) }
        }
        return out
    }

    /// A static image element (`image[x,y;w,h;texture]`), e.g. the furnace fire
    /// gauge and cook-progress arrow, whose texture is a modifier chain (#223).
    public struct Image: Equatable {
        public let gx: Float, gy: Float, w: Float, h: Float
        public let texture: String
        public let isItem: Bool   // true: `texture` is an item name to draw as an icon (item_image[])
        public var count = 1      // item_image[]'s stack count, drawn like a slot's when > 1
    }

    /// Parse `image[x,y;w,h;texture]`. The texture field is taken whole (it may
    /// carry `^[lowpart:...`/`^[transform...` modifiers, which have no `;`).
    public static func parseImages(_ spec: String) -> [Image] {
        parseImageLike(spec, token: "image[", isItem: false)
    }

    /// Parse `item_image[x,y;w,h;itemname]` (beacon payment icons, trade hints).
    /// Same shape as image[] but the last field is an item name, drawn as an icon.
    public static func parseItemImages(_ spec: String) -> [Image] {
        parseImageLike(spec, token: "item_image[", isItem: true)
    }

    private static func parseImageLike(_ spec: String, token: String, isItem: Bool) -> [Image] {
        var out: [Image] = []
        for chunk in spec.split(separator: "]") {
            guard let r = chunk.range(of: token) else { continue }
            // The token must start the element, not be the tail of a longer one:
            // "image[" inside "item_image["/"background9[", or "item_image[" inside
            // "item_image_button[" (guarded by requiring a "]" or start before it,
            // and the split-on-"]" already bounds it; also reject a trailing letter).
            if r.lowerBound != chunk.startIndex {
                let before = chunk[chunk.index(before: r.lowerBound)]
                if before.isLetter || before == "_" { continue }
            }
            // Reject item_image_button[ when scanning for item_image[.
            let after = chunk[r.upperBound...]
            let f = after.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3 else { continue }
            let xy = f[0].split(separator: ","), wh = f[1].split(separator: ",")
            guard xy.count == 2, wh.count == 2,
                  let gx = Float(xy[0]), let gy = Float(xy[1]),
                  let w = Float(wh[0]), let h = Float(wh[1]) else { continue }
            // item_image[] takes an itemstring ("mcl_wool:white 18"): the name
            // alone resolves the icon; with the count attached, block icons
            // found nothing (the villager's wanted wool never drew).
            var tex = f[2], count = 1
            if isItem {
                let parts = tex.split(separator: " ")
                tex = parts.first.map(String.init) ?? ""
                if parts.count > 1, let n = Int(parts[1]) { count = n }
            }
            if !tex.isEmpty {
                var im = Image(gx: gx, gy: gy, w: w, h: h, texture: tex, isItem: isItem)
                im.count = count
                out.append(im)
            }
        }
        return out
    }

    /// An editable text field with its grid position and width, so a list-form
    /// (anvil rename, etc.) can draw a tappable box for it in the panel (#229).
    public struct Field: Equatable {
        public let gx: Float, gy: Float, w: Float
        public let name: String
        public let value: String
    }

    /// Parse `field[x,y;w,h;name;label;default]` (and `textarea[...]`) with
    /// position, for forms that mix item lists with a text input. A bare
    /// `field[name;label;default]` has no position, so it's skipped here (those
    /// are the pure text dialogs handled elsewhere).
    public static func parseFieldsPositioned(_ spec: String) -> [Field] {
        var out: [Field] = []
        for chunk in spec.split(separator: "]") {
            let c = String(chunk)
            let kind: String
            if let r = c.range(of: "field[") { kind = String(c[r.upperBound...]) }
            else if let r = c.range(of: "textarea[") { kind = String(c[r.upperBound...]) }
            else { continue }
            let f = kind.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5 else { continue }   // needs pos;size;name;label;default
            let xy = f[0].split(separator: ","), wh = f[1].split(separator: ",")
            guard xy.count == 2, let gx = Float(xy[0]), let gy = Float(xy[1]) else { continue }
            let w = (wh.first.flatMap { Float($0) }) ?? 3
            out.append(Field(gx: gx, gy: gy, w: w, name: f[2], value: clean(f[4])))
        }
        return out
    }

    /// A button with its grid position, so list-forms can draw a tappable box.
    public struct PositionedButton: Equatable {
        public let gx: Float, gy: Float, w: Float
        public let name: String
        public let label: String
        public let exit: Bool   // button_exit closes the form after submitting
        public var texture: String = ""   // image_button[]'s icon texture (drawn instead of a plain plate, #233)
        public var itemName: String = ""  // item_image_button[]'s item, drawn as an icon (stonecutter recipes, #235)
        public var color: Float? = nil    // packed tint from a leading \x1b(c@#rgb) label color, nil for white (#254)
        public var h: Float = 1           // only the legacy-coordinate conversion needs it
    }

    /// Parse positioned buttons (`button[x,y;w,h;name;label]` and the
    /// image_button / *_exit variants). Bare positionless buttons are skipped.
    public static func parseButtonsPositioned(_ spec: String) -> [PositionedButton] {
        var out: [PositionedButton] = []
        for chunk in spec.split(separator: "]") {
            let c = String(chunk)
            let kind: String, exit: Bool, image: Bool
            // item_image_button[ ends in "image_button[" and "button[" -- it's a
            // different element (parsed by parseItemImageButtons), so skip any chunk
            // whose element is item_image_button (#235).
            if c.range(of: "item_image_button[") != nil { continue }
            if let r = c.range(of: "image_button_exit[") { kind = String(c[r.upperBound...]); exit = true; image = true }
            else if let r = c.range(of: "image_button[") { kind = String(c[r.upperBound...]); exit = false; image = true }
            else if let r = c.range(of: "button_exit[") { kind = String(c[r.upperBound...]); exit = true; image = false }
            else if let r = c.range(of: "button[") { kind = String(c[r.upperBound...]); exit = false; image = false }
            else { continue }
            let f = kind.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            // button[pos;size;name;label]; image_button inserts a texture field
            // before name. Need pos;size;...;name;label at minimum.
            guard f.count >= (image ? 5 : 4) else { continue }
            let xy = f[0].split(separator: ","), wh = f[1].split(separator: ",")
            guard xy.count == 2, let gx = Float(xy[0]), let gy = Float(xy[1]) else { continue }
            let w = (wh.first.flatMap { Float($0) }) ?? 2
            let (label, color) = cleanColored(f.last ?? "", caller: "button-label"), name = f[f.count - 2]
            // image_button[pos;size;texture;name;label]: the texture sits at f[2].
            let texture = image && f.count >= 5 ? f[2] : ""
            let h = (wh.count == 2 ? Float(wh[1]) : nil) ?? 1
            if !name.isEmpty { out.append(PositionedButton(gx: gx, gy: gy, w: w, name: name, label: label, exit: exit, texture: texture, color: color, h: h)) }
        }
        return out
    }

    /// Parse `item_image_button[x,y;w,h;itemname;name;label]` (stonecutter recipe
    /// buttons, craftguide). Returns buttons carrying the item to draw as an icon
    /// and the field name to submit on tap (#235).
    public static func parseItemImageButtons(_ spec: String) -> [PositionedButton] {
        var out: [PositionedButton] = []
        for chunk in spec.split(separator: "]") {
            guard let r = chunk.range(of: "item_image_button[") else { continue }
            let f = chunk[r.upperBound...].split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5 else { continue }   // pos;size;item;name;label
            let xy = f[0].split(separator: ","), wh = f[1].split(separator: ",")
            guard xy.count == 2, let gx = Float(xy[0]), let gy = Float(xy[1]) else { continue }
            let w = (wh.first.flatMap { Float($0) }) ?? 1
            let item = f[2].split(separator: " ").first.map(String.init) ?? "", name = f[3]   // itemstring: name only
            let (label, color) = cleanColored(f[4], caller: "item-image-button-label")
            let h = (wh.count == 2 ? Float(wh[1]) : nil) ?? 1
            if !name.isEmpty { out.append(PositionedButton(gx: gx, gy: gy, w: w, name: name, label: label, exit: false, texture: "", itemName: item, color: color, h: h)) }
        }
        return out
    }

    /// A `checkbox[x,y;name;label;selected]` toggle.
    public struct Checkbox: Equatable {
        public let gx: Float, gy: Float
        public let name: String
        public let label: String
        public let selected: Bool
        public var color: Float? = nil   // packed tint from a leading label color, nil for white (#254)
    }

    /// Parse `checkbox[x,y;name;label;selected]` (the clear-inventory "Do not ask
    /// again" box, tuning options) (#237). y is the checkbox's vertical CENTER.
    public static func parseCheckboxes(_ spec: String) -> [Checkbox] {
        var out: [Checkbox] = []
        for chunk in spec.split(separator: "]") {
            guard let r = chunk.range(of: "checkbox[") else { continue }
            let f = chunk[r.upperBound...].split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3 else { continue }
            let xy = f[0].split(separator: ",")
            guard xy.count == 2, let gx = Float(xy[0]), let gy = Float(xy[1]) else { continue }
            let (label, color) = cleanColored(f[2], caller: "checkbox-label")
            let sel = f.count >= 4 && f[3] == "true"
            if !f[1].isEmpty { out.append(Checkbox(gx: gx, gy: gy, name: f[1], label: label, selected: sel, color: color)) }
        }
        return out
    }

    /// Parse the element form `tooltip[<element_name>;<text>]` into name -> text.
    /// The rectangle form `tooltip[x,y;w,h;text;...]` (first field is a position)
    /// is skipped. Used to show hover text (enchant cost, etc.) (#236).
    public static func parseTooltips(_ spec: String) -> [String: (text: String, color: Float?)] {
        var out: [String: (text: String, color: Float?)] = [:]
        for chunk in spec.split(separator: "]") {
            guard let r = chunk.range(of: "tooltip[") else { continue }
            let f = chunk[r.upperBound...].split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2 else { continue }
            // Rectangle form: first field is "x,y" (two numbers) -> skip.
            let xy = f[0].split(separator: ",")
            if xy.count == 2, Float(xy[0]) != nil, Float(xy[1]) != nil { continue }
            let (text, color) = cleanColored(f[1], caller: "tooltip")
            if !f[0].isEmpty, !text.isEmpty { out[f[0]] = (text, color) }
        }
        return out
    }

    /// A `tabheader[...]` tab strip. The player taps a caption to switch tab,
    /// which submits `name = "<1-based index>"` and the server re-sends the form
    /// on that tab (doc Help, tuning) (#339).
    public struct TabHeader: Equatable {
        public let name: String
        public let captions: [String]
        public let current: Int    // 1-based, as the field value the server expects
    }

    /// Parse `tabheader[<X>,<Y>{;<H>};<name>;<caption1>,<caption2>,...;<current>{;<transparent>;<border>}]`.
    /// The optional height field (a lone number after the position) shifts the
    /// name/captions/current along by one, so detect it and skip it.
    public static func parseTabHeader(_ spec: String) -> TabHeader? {
        for chunk in spec.split(separator: "]") {
            guard let r = chunk.range(of: "tabheader[") else { continue }
            var f = chunk[r.upperBound...].split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4 else { continue }
            f.removeFirst()                                  // drop the "X,Y" position
            // Optional height: a bare number where the name would be.
            if f.count >= 4, Float(f[0]) != nil { f.removeFirst() }
            guard f.count >= 3, !f[0].isEmpty else { continue }
            let caps = splitUnescapedCommas(f[1]).map { clean($0) }.filter { !$0.isEmpty }
            guard !caps.isEmpty else { continue }
            let cur = Int(f[2]) ?? 1
            return TabHeader(name: f[0], captions: caps, current: cur)
        }
        return nil
    }

    /// A `textlist[...]` scroll list (achievements, doc entries, announcements).
    /// Tapping a row submits `name = "CHG:<1-based index>"`, mirroring the engine
    /// (guiFormSpecMenu explode_textlist_event) so the server shows that entry.
    public struct TextList: Equatable {
        public let gx: Float, gy: Float, w: Float, h: Float
        public let name: String
        public let rows: [String]     // cleaned, color codes stripped
        public let selected: Int      // 1-based, 0 = none
    }

    /// Parse `textlist[<X>,<Y>;<W>,<H>;<name>;<item1>,<item2>,...;<selected>;<transparent>]`.
    /// Items separate on unescaped commas (a `\,` stays literal) (#339).
    public static func parseTextlists(_ spec: String) -> [TextList] {
        var out: [TextList] = []
        for chunk in spec.split(separator: "]") {
            guard let r = chunk.range(of: "textlist[") else { continue }
            let f = chunk[r.upperBound...].split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4 else { continue }
            let xy = f[0].split(separator: ","), wh = f[1].split(separator: ",")
            guard xy.count == 2, wh.count == 2,
                  let gx = Float(xy[0]), let gy = Float(xy[1]),
                  let w = Float(wh[0]), let h = Float(wh[1]) else { continue }
            let rows = splitUnescapedCommas(f[3]).map { cleanColored($0, caller: "textlist").text }
            let sel = f.count >= 5 ? (Int(f[4]) ?? 0) : 0
            out.append(TextList(gx: gx, gy: gy, w: w, h: h, name: f[2], rows: rows, selected: sel))
        }
        return out
    }

    /// A read-only `hypertext[...]` block, reduced to plain wrapped-able lines
    /// (announcements, tuning help). Interactive `<action>` links are flattened
    /// to their visible text (#339).
    public struct Hypertext: Equatable {
        public let gx: Float, gy: Float, w: Float, h: Float
        public let lines: [String]
    }

    /// Parse `hypertext[<X>,<Y>;<W>,<H>;<name>;<tagged text>]`, stripping the
    /// `<tag>` markup down to readable text split on the `\n` the markup uses.
    public static func parseHypertexts(_ spec: String) -> [Hypertext] {
        var out: [Hypertext] = []
        for chunk in spec.split(separator: "]") {
            guard let r = chunk.range(of: "hypertext[") else { continue }
            let f = chunk[r.upperBound...].split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            // hypertext[<X>,<Y>;<W>,<H>;<name>;<text>] -> 4 fields (text is f[3]).
            guard f.count >= 4 else { continue }
            let xy = f[0].split(separator: ","), wh = f[1].split(separator: ",")
            guard xy.count == 2, wh.count == 2,
                  let gx = Float(xy[0]), let gy = Float(xy[1]),
                  let w = Float(wh[0]), let h = Float(wh[1]) else { continue }
            // The text may itself carry ";" if it was escaped; rejoin the tail.
            let raw = f[3...].joined(separator: ";")
            let plain = stripHypertextTags(clean(raw))
            let lines = plain.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            out.append(Hypertext(gx: gx, gy: gy, w: w, h: h, lines: lines))
        }
        return out
    }

    /// Flatten a non-inventory info form (achievements, announcements, doc Help)
    /// into positioned Labels the panel can render read-only: tab captions across
    /// the top (the current tab bracketed), each textlist row on its own line,
    /// and hypertext reduced to text lines. The VR panel has no scrolling yet, so
    /// long lists/text are capped with a "(+N more)" marker (#339). Coordinates
    /// are formspec grid units, matching label[]/list[] placement.
    public static func infoFormLabels(_ spec: String) -> [Label] {
        var out: [Label] = []
        if let t = parseTabHeader(spec) {
            for (i, cap) in t.captions.enumerated() {
                let mark = (i + 1 == t.current) ? "[ \(cap) ]" : cap
                out.append(Label(gx: 0.4 + Float(i) * 2.7, gy: 0.3, text: mark, color: nil))
            }
        }
        let maxRows = 12
        for tl in parseTextlists(spec) {
            for (i, row) in tl.rows.prefix(maxRows).enumerated() where !row.isEmpty {
                out.append(Label(gx: tl.gx + 0.2, gy: tl.gy + 0.6 + Float(i) * 0.5, text: row, color: nil))
            }
            if tl.rows.count > maxRows {
                out.append(Label(gx: tl.gx + 0.2, gy: tl.gy + 0.6 + Float(maxRows) * 0.5,
                                 text: "(+\(tl.rows.count - maxRows) more)", color: nil))
            }
        }
        let maxLines = 16
        for h in parseHypertexts(spec) {
            for (i, line) in h.lines.prefix(maxLines).enumerated() where !line.isEmpty {
                out.append(Label(gx: h.gx + 0.1, gy: h.gy + 0.3 + Float(i) * 0.4, text: line, color: nil))
            }
        }
        return out
    }

    /// True when a form has no item lists but does carry info widgets we render
    /// read-only (textlist/tabheader/hypertext) -- an achievements/announcements/
    /// Help dialog rather than a container or a text-editor form (#339).
    public static func isInfoForm(_ spec: String) -> Bool {
        parseTabHeader(spec) != nil || !parseTextlists(spec).isEmpty || !parseHypertexts(spec).isEmpty
    }

    /// A tappable region on an info form: its grid rect (formspec units, same
    /// coords infoFormLabels places its text at) plus the field name + value to
    /// submit when tapped. Tabs submit the 1-based tab index; a textlist row
    /// submits "CHG:<1-based index>", mirroring the engine's textlist event so
    /// the server shows that entry (#346).
    public struct InfoTarget: Equatable {
        public let gx: Float, gy: Float, w: Float, h: Float
        public let field: String, value: String
    }

    /// Hit regions for an info form, kept in lockstep with infoFormLabels'
    /// placement so a tap lands on the visible text.
    public static func infoTargets(_ spec: String) -> [InfoTarget] {
        var out: [InfoTarget] = []
        // gy matches infoFormLabels exactly (it draws each line with gy as the
        // text's vertical CENTER), so the tap box lands on the visible text.
        if let t = parseTabHeader(spec) {
            for (i, cap) in t.captions.enumerated() {
                out.append(InfoTarget(gx: 0.4 + Float(i) * 2.7, gy: 0.3, w: max(1.2, Float(cap.count) * 0.28 + 0.6), h: 0.7,
                                      field: t.name, value: "\(i + 1)"))
            }
        }
        let maxRows = 12
        for tl in parseTextlists(spec) {
            for i in 0..<min(tl.rows.count, maxRows) where !tl.rows[i].isEmpty {
                out.append(InfoTarget(gx: tl.gx + 0.2, gy: tl.gy + 0.6 + Float(i) * 0.5, w: max(1.0, tl.w - 0.4), h: 0.5,
                                      field: tl.name, value: "CHG:\(i + 1)"))
            }
        }
        return out
    }

    /// Split on commas that aren't backslash-escaped (`\,`), then drop the
    /// escaping backslash. Shared by textlist items and tabheader captions.
    static func splitUnescapedCommas(_ s: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        var esc = false
        for ch in s {
            if esc { cur.append(ch); esc = false; continue }
            if ch == "\\" { esc = true; continue }
            if ch == "," { parts.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        parts.append(cur)
        return parts
    }

    /// Reduce hypertext markup (`<b>`, `<style ...>`, `<action ...>text</action>`,
    /// `<img .../>`, `<global .../>`) to its visible text. Tags are angle-bracket
    /// delimited; everything between `<` and the matching `>` is dropped.
    static func stripHypertextTags(_ s: String) -> String {
        var out = ""
        var depth = 0
        for ch in s {
            if ch == "<" { depth += 1; continue }
            if ch == ">" { if depth > 0 { depth -= 1 }; continue }
            if depth == 0 { out.append(ch) }
        }
        return out
    }

    /// Make a formspec field's raw text displayable: undo formspec_escape's
    /// backslashes (`\,` `\;` `\[` `\]` `\\`) and strip the control/translation
    /// escape sequences (`\x1b(T@domain)...\x1b(E)`, color codes). Without this a
    /// translator-wrapped label like the death screen's "Respawn" button showed
    /// up as raw escape characters (#151).
    public static func clean(_ s: String) -> String {
        ItemRegistry.stripEscapes(unescape(s))
    }
    /// Like `clean` but keeps the leading color escape as a packed tint, so a
    /// dark-colored label renders in its own color instead of default white (#254).
    public static func cleanColored(_ s: String, caller: String = "formspec-label") -> (text: String, color: Float?) {
        ItemRegistry.parseEscapes(unescape(s), consumeColor: true, caller: caller)
    }
    private static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = String(); out.reserveCapacity(s.count)
        var it = s.makeIterator()
        while let c = it.next() {
            if c == "\\", let n = it.next() { out.append(n) }   // drop the backslash, keep the escaped char
            else { out.append(c) }
        }
        return out
    }

    /// Is a list-less form a plain text editor (sign, command block), where the
    /// VR client should go straight to the keyboard? True for a `textarea`, or a
    /// `field` whose only buttons are exit buttons named "submit"/"done". The
    /// bed sleep form is NOT one: it carries a chat field plus "chatsubmit" and
    /// a "leave" button_exit, and opening the keyboard on it put a dictation
    /// pad in the sleeping player's face instead of a way to get up (#304).
    public static func isTextEditorForm(_ spec: String) -> Bool {
        if spec.contains("textarea[") { return true }
        guard spec.contains("field[") else { return false }
        let others = parseButtons(spec).filter { !["submit", "done", "ok"].contains($0.name.lowercased()) }
        return others.isEmpty
    }

    /// Buttons in a formspec: `button[x,y;w,h;name;label]` and its
    /// `button_exit` / `image_button` variants. Used to give button-only
    /// dialogs (the "Leave bed" sleep form) a way to be dismissed in VR.
    public static func parseButtons(_ spec: String) -> [(name: String, label: String)] {
        var out: [(String, String)] = []
        for chunk in spec.split(separator: "]") {
            let c = String(chunk)
            let kind: String
            if let r = c.range(of: "button_exit[") { kind = String(c[r.upperBound...]) }
            else if let r = c.range(of: "image_button_exit[") { kind = String(c[r.upperBound...]) }
            else if let r = c.range(of: "image_button[") { kind = String(c[r.upperBound...]) }
            else if let r = c.range(of: "button[") { kind = String(c[r.upperBound...]) }
            else { continue }
            let f = kind.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            // button[pos;size;name;label]; image_button adds a texture field
            // before name. Take the label as the last field, name just before it.
            guard f.count >= 2 else { continue }
            let label = clean(f.last ?? "")
            let name = f[f.count - 2]
            if !name.isEmpty { out.append((name, label)) }
        }
        return out
    }

    /// Luanti's old coordinate system, used by any form that doesn't open with
    /// formspec_version[2+] or set real_coordinates[true] (VoxeLibre's villager
    /// trade and brewing stand). Everything else here assumes real coordinates
    /// (1 unit = one slot image), so a legacy form is converted into those
    /// units once, after parsing. The rules follow guiFormSpecMenu.cpp's
    /// !real_coordinates paths: a position is padding + pos * spacing, list
    /// slots step by spacing, images are geom * imgsize, and backgrounds are
    /// geom * spacing shifted back by half the gap.
    public enum Legacy {
        public static let spacing = SIMD2<Float>(1.25, 15.0 / 13.0)
        public static let padding: Float = 0.375

        /// True when the form body (not the server prepend) uses legacy coordinates.
        public static func applies(to body: String) -> Bool {
            if body.contains("real_coordinates[true]") { return false }
            guard let r = body.range(of: "formspec_version[") else { return true }
            let digits = body[r.upperBound...].prefix { $0.isNumber }
            return (Int(digits) ?? 1) < 2
        }

        static func x(_ v: Float) -> Float { padding + v * spacing.x }
        static func y(_ v: Float) -> Float { padding + v * spacing.y }
        /// A width given in legacy units, for elements drawn edge to edge
        /// (buttons, fields): n cells minus the trailing gap.
        static func span(_ w: Float) -> Float { w * spacing.x - (spacing.x - 1) }

        public static func convert(_ l: List) -> List {
            var o = List(loc: l.loc, list: l.list, gx: x(l.gx), gy: y(l.gy), cols: l.cols, rows: l.rows, start: l.start)
            o.pitch = spacing
            return o
        }
        public static func convert(_ i: Image) -> Image {
            var o = Image(gx: x(i.gx), gy: y(i.gy), w: i.w, h: i.h, texture: i.texture, isItem: i.isItem)
            o.count = i.count
            return o
        }
        public static func convert(_ b: Background) -> Background {
            if b.fill { return b }
            return Background(gx: x(b.gx) - (spacing.x - 1) / 2, gy: y(b.gy) - (spacing.y - 1) / 2,
                              w: b.w * spacing.x, h: b.h * spacing.y, texture: b.texture, fill: b.fill)
        }
        /// Label y becomes the text's vertical center, like real-coordinate labels.
        public static func convert(_ l: Label) -> Label {
            Label(gx: x(l.gx), gy: padding + (l.gy + 7.0 / 30.0) * spacing.y, text: l.text, color: l.color)
        }
        /// The layout centers a button on gy + 0.5, so fold its legacy height
        /// into gy. Image buttons span their cells like images; plain buttons
        /// are centered in h image-heights.
        public static func convert(_ b: PositionedButton) -> PositionedButton {
            var o = b
            let image = !b.texture.isEmpty || !b.itemName.isEmpty
            let hh = image ? b.h * spacing.y - (spacing.y - 1) : b.h
            o = PositionedButton(gx: x(b.gx), gy: y(b.gy) + hh / 2 - 0.5, w: span(b.w), name: b.name, label: b.label,
                                 exit: b.exit, texture: b.texture, itemName: b.itemName, color: b.color, h: hh)
            return o
        }
        /// Legacy fields subtract the padding back out (getElementBasePos then
        /// pos -= padding) and center in their h; Field has no h, so assume one
        /// row, which puts the center at gy * spacing.y + 0.5 like the layout expects.
        public static func convert(_ f: Field) -> Field {
            Field(gx: f.gx * spacing.x, gy: f.gy * spacing.y, w: span(f.w), name: f.name, value: f.value)
        }
        /// Checkbox gy is the box center in real coordinates.
        public static func convert(_ c: Checkbox) -> Checkbox {
            var o = Checkbox(gx: x(c.gx), gy: y(c.gy) + 0.5, name: c.name, label: c.label, selected: c.selected)
            o.color = c.color
            return o
        }
    }
}
