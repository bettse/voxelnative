import XCTest
@testable import LuantiKit

/// ITEMDEF tail: node_placement_prediction, sound_place and range are
/// read after the tool-capabilities blob and groups, in
/// ItemDefinition::deSerialize order. Framing mirrors TOCLIENT_ITEMDEF.
final class ItemDefTailTests: XCTestCase {

    private func itemBlob(name: String, prediction: String, placeSound: String, range: Float, usable: Bool = false, description: String = "A block",
                          wieldScale: Float = 1, placeParam2: Int? = nil, fullTail: Bool = false) -> Data {
        let w = PacketWriter()
        w.u8(6).u8(1)                                    // version, type (node)
        w.string16(name).string16(description)
        w.string16("dirt.png").u8(0)                     // inventory_image + no animation
        w.string16("").u8(0)                             // wield_image + no animation
        w.f32(wieldScale).f32(wieldScale).f32(1).s16(64)  // wield_scale, stack_max
        w.u8(usable ? 1 : 0).u8(0)                       // usable, liquids_pointable
        w.bytes16(Data())                                // tool_capabilities: none
        w.u16(1).string16("cracky").s16(3)               // groups
        w.string16(prediction)                           // node_placement_prediction
        w.string16(placeSound).f32(1).f32(1).f32(0)      // sound_place (name, gain, pitch, fade)
        w.string16("").f32(1).f32(1).f32(0)              // sound_place_failed
        w.f32(range)
        if fullTail {
            // itemdef.cpp version 6, protocol > 43: palette_image, color, overlays,
            // short_description, sound_use, sound_use_air, place_param2 (has + value).
            w.string16("").u32(0).string16("").u8(0).string16("").u8(0).string16("")   // overlays carry an animation block
            w.string16("").f32(1).f32(1).f32(0); w.string16("").f32(1).f32(1).f32(0)
            if let p2 = placeParam2 { w.u8(1).u8(p2) } else { w.u8(0) }
            w.u8(0).u8(0)                                // wallmounted_rotate_vertical, touch_interaction
        }
        return w.data
    }

    /// place_param2 and wield_scale from the tail; a short (older-server)
    /// blob without the tail parses to "no place_param2" and scale 1.
    func testPlaceParam2AndWieldScale() {
        let reg = ItemRegistry()
        reg.parseItemDef(payload([
            itemBlob(name: "mcl_farming:wheat_seeds", prediction: "mcl_farming:wheat_1", placeSound: "", range: 4, placeParam2: 3, fullTail: true),
            itemBlob(name: "mcl_tools:pick_iron", prediction: "", placeSound: "", range: 4, wieldScale: 1.8, fullTail: true),
            itemBlob(name: "mcl_core:dirt", prediction: "mcl_core:dirt", placeSound: "", range: 4),   // no tail at all
        ]))
        XCTAssertEqual(reg.placeParam2(for: "mcl_farming:wheat_seeds"), 3)
        XCTAssertNil(reg.placeParam2(for: "mcl_tools:pick_iron"))
        XCTAssertNil(reg.placeParam2(for: "mcl_core:dirt"))
        XCTAssertEqual(reg.wieldScale(for: "mcl_tools:pick_iron 1").x, 1.8, accuracy: 1e-6)
        XCTAssertEqual(reg.wieldScale(for: "mcl_core:dirt").x, 1, accuracy: 1e-6)
        XCTAssertEqual(reg.prediction(for: "mcl_core:dirt"), "mcl_core:dirt", "the short blob still parses")
    }

    private func payload(_ blobs: [Data]) -> Data {
        let raw = PacketWriter().u8(0).u16(blobs.count)
        for b in blobs { raw.bytes16(b) }
        let comp = try! XCTUnwrap(Zstd.compress(raw.data))
        return PacketWriter().bytes32(comp).data
    }

    func testTailFieldsAreKept() {
        let reg = ItemRegistry()
        reg.parseItemDef(payload([
            itemBlob(name: "mcl_core:dirt", prediction: "mcl_core:dirt", placeSound: "default_place_node", range: 4),
            itemBlob(name: "mcl_doors:door", prediction: "", placeSound: "", range: 4),   // on_place decides
        ]))
        XCTAssertEqual(reg.prediction(for: "mcl_core:dirt 5"), "mcl_core:dirt")   // count stripped
        XCTAssertEqual(reg.placeSound(for: "mcl_core:dirt"), "default_place_node")
        XCTAssertEqual(reg.range(for: "mcl_core:dirt") ?? -1, 4, accuracy: 1e-6)
        XCTAssertEqual(reg.prediction(for: "mcl_doors:door"), "")           // explicit "don't predict"
        XCTAssertNil(reg.placeSound(for: "mcl_doors:door"))
        XCTAssertNil(reg.prediction(for: "unknown:item"))
        XCTAssertEqual(reg.image(for: "mcl_core:dirt"), "dirt.png")         // earlier fields unaffected
    }

    func testDescriptionColorIsParsed() {
        // A renamed/enchanted item ships its display name with a leading color
        // escape. descriptionColored keeps it as a packed tint so the inventory
        // name popup renders in color instead of invisible white. The
        // plain description(for:) still returns just the stripped text.
        let reg = ItemRegistry()
        reg.parseItemDef(payload([
            itemBlob(name: "mcl_tools:sword", prediction: "", placeSound: "", range: 4,
                     description: "\u{1b}(c@#313131)Excalibur"),
            itemBlob(name: "mcl_core:dirt", prediction: "", placeSound: "", range: 4),
        ]))
        let colored = reg.descriptionColored(for: "mcl_tools:sword")
        XCTAssertEqual(colored.text, "Excalibur")
        XCTAssertEqual(colored.color, Float(0x31 + 0x31 * 256 + 0x31 * 65536))
        XCTAssertEqual(reg.description(for: "mcl_tools:sword"), "Excalibur")   // plain path stays clean
        XCTAssertNil(reg.descriptionColored(for: "mcl_core:dirt").color)       // no escape -> no color
    }

    func testUsableFlagIsParsed() {
        // A throwable (egg) has on_use -> usable=1; a plain block does not. The
        // client fires INTERACT_USE on the attack button for usable items.
        let reg = ItemRegistry()
        reg.parseItemDef(payload([
            itemBlob(name: "mcl_throwing:egg", prediction: "", placeSound: "", range: 4, usable: true),
            itemBlob(name: "mcl_core:dirt", prediction: "mcl_core:dirt", placeSound: "", range: 4),
        ]))
        XCTAssertTrue(reg.isUsable("mcl_throwing:egg"))
        XCTAssertTrue(reg.isUsable("mcl_throwing:egg 12"), "count suffix is stripped")
        XCTAssertFalse(reg.isUsable("mcl_core:dirt"))
        XCTAssertFalse(reg.isUsable("unknown:item"))
    }

    func testBlobEndingAtToolCapsStillKeepsTheImage() {
        // An item whose blob stops at tool_capabilities: image/description
        // still land; the tail is simply unknown (no prediction recorded).
        let w = PacketWriter()
        w.u8(6).u8(1).string16("x:y").string16("d").string16("y.png").u8(0).string16("").u8(0)
        w.f32(1).f32(1).f32(1).s16(64).u8(0).u8(0).bytes16(Data())
        let reg = ItemRegistry()
        reg.parseItemDef(payload([w.data]))
        XCTAssertEqual(reg.image(for: "x:y"), "y.png")
        XCTAssertNil(reg.prediction(for: "x:y"))
    }

    func testFoodGroupMarksEatable() {
        // A food item carries a `food` group; the raise-to-mouth eat gesture
        // fires only on eatables. A plain block is not eatable.
        let w = PacketWriter()
        w.u8(6).u8(2).string16("mcl_core:apple").string16("Apple")
        w.string16("apple.png").u8(0).string16("").u8(0)
        w.f32(1).f32(1).f32(1).s16(64).u8(0).u8(0).bytes16(Data())
        w.u16(2).string16("food").s16(2).string16("compostability").s16(65)   // groups incl. food
        w.string16("")                              // node_placement_prediction
        w.string16("").f32(1).f32(1).f32(0)         // sound_place
        w.string16("").f32(1).f32(1).f32(0)         // sound_place_failed
        w.f32(4)                                    // range
        let reg = ItemRegistry()
        reg.parseItemDef(payload([
            w.data,
            itemBlob(name: "mcl_core:dirt", prediction: "", placeSound: "", range: 4),
        ]))
        XCTAssertTrue(reg.isEatable("mcl_core:apple"))
        XCTAssertTrue(reg.isEatable("mcl_core:apple 3"), "count suffix stripped")
        XCTAssertFalse(reg.isEatable("mcl_core:dirt"), "the `cracky` group isn't food")
        XCTAssertFalse(reg.isEatable("unknown:item"))
    }

    func testArmorGroupsMapToSlots() {
        // Armor pieces carry armor_head/torso/legs/feet groups; shift-click
        // quick-move routes each to its slot 1..4. A plain item has none.
        func armorBlob(_ name: String, group: String) -> Data {
            let w = PacketWriter()
            w.u8(6).u8(3).string16(name).string16("Armor")          // type 3 (craftitem)
            w.string16("armor.png").u8(0).string16("").u8(0)
            w.f32(1).f32(1).f32(1).s16(1).u8(0).u8(0).bytes16(Data())
            w.u16(2).string16("armor").s16(1).string16(group).s16(1)   // groups: armor + the element
            w.string16("").string16("").f32(1).f32(1).f32(0)           // prediction, sound_place
            w.string16("").f32(1).f32(1).f32(0).f32(4)                 // sound_place_failed, range
            return w.data
        }
        let reg = ItemRegistry()
        reg.parseItemDef(payload([
            armorBlob("mcl_armor:helmet_iron", group: "armor_head"),
            armorBlob("mcl_armor:chestplate_iron", group: "armor_torso"),
            armorBlob("mcl_armor:leggings_iron", group: "armor_legs"),
            armorBlob("mcl_armor:boots_iron", group: "armor_feet"),
            itemBlob(name: "mcl_core:dirt", prediction: "", placeSound: "", range: 4),
        ]))
        XCTAssertEqual(reg.armorSlot("mcl_armor:helmet_iron"), 1)
        XCTAssertEqual(reg.armorSlot("mcl_armor:chestplate_iron"), 2)
        XCTAssertEqual(reg.armorSlot("mcl_armor:leggings_iron"), 3)
        XCTAssertEqual(reg.armorSlot("mcl_armor:boots_iron 1"), 4, "count suffix stripped")
        XCTAssertNil(reg.armorSlot("mcl_core:dirt"))
    }
}
