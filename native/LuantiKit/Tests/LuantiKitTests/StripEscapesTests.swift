import XCTest
@testable import LuantiKit

/// The server pushes item descriptions with Minetest rich-text escapes (the
/// wield-name popup from show_wielded_item is the visible case). stripEscapes
/// must drop them so the HUD text layer doesn't render garbage glyphs.
final class StripEscapesTests: XCTestCase {
    func testTranslationDomainStripped() {
        // ESC ( T @ mcl_core ) Cobblestone ESC ( E )
        let s = "\u{1b}(T@mcl_core)Cobblestone\u{1b}(E)"
        XCTAssertEqual(ItemRegistry.stripEscapes(s), "Cobblestone")
    }

    func testColorCodeStripped() {
        let s = "\u{1b}(c@#00ff00)Emerald Sword\u{1b}(c@#ffffff)"
        XCTAssertEqual(ItemRegistry.stripEscapes(s), "Emerald Sword")
    }

    func testPlainTextUntouched() {
        XCTAssertEqual(ItemRegistry.stripEscapes("Diamond Pickaxe"), "Diamond Pickaxe")
    }

    func testBareEscapeControlDropped() {
        // ESC E (end-translation) with no parens: drop ESC and the next char.
        XCTAssertEqual(ItemRegistry.stripEscapes("Bow\u{1b}E"), "Bow")
    }

    // parseEscapes: keep the color as a packed tint when the caller will use it.

    func testParseColor6Digit() {
        // #313131 is the chest "Inventory" label color that used to render as
        // invisible white on the light panel.
        let r = ItemRegistry.parseEscapes("\u{1b}(c@#313131)Inventory", consumeColor: true)
        XCTAssertEqual(r.text, "Inventory")
        XCTAssertEqual(r.color, Float(0x31 + 0x31*256 + 0x31*65536))
    }

    func testParseColor3Digit() {
        // #f00 expands each nibble x17 -> ff0000 (pure red).
        let r = ItemRegistry.parseEscapes("\u{1b}(c@#f00)Danger", consumeColor: true)
        XCTAssertEqual(r.text, "Danger")
        XCTAssertEqual(r.color, Float(255))
    }

    func testParseNamedColorIsNil() {
        // A named color (no palette) can't be rendered: text kept, color nil.
        let r = ItemRegistry.parseEscapes("\u{1b}(c@red)Danger", consumeColor: true)
        XCTAssertEqual(r.text, "Danger")
        XCTAssertNil(r.color)
    }

    func testConsumeColorFalseDropsColor() {
        // stripEscapes path: text cleaned, no color captured.
        let r = ItemRegistry.parseEscapes("\u{1b}(c@#313131)Inventory", consumeColor: false)
        XCTAssertEqual(r.text, "Inventory")
        XCTAssertNil(r.color)
    }

    func testParseFirstColorWins() {
        let r = ItemRegistry.parseEscapes("\u{1b}(c@#00ff00)A\u{1b}(c@#ff0000)B", consumeColor: true)
        XCTAssertEqual(r.text, "AB")
        XCTAssertEqual(r.color, Float(0x00 + 0xff*256 + 0x00*65536))
    }
}
