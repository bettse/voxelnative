import XCTest
@testable import LuantiKit

/// Itemstring meta field: "name count wear \"\u{1}k\u{2}v\u{3}k2\u{2}v2\u{3}\"",
/// JSON-quoted on the wire (control chars as \uXXXX): ItemStackMetadata::serialize
/// writes ONE leading \u{1} then key\u{2}value\u{3} per pair.
final class ItemMetaTests: XCTestCase {
    func testMetaPairsParseFromTheJsonQuotedField() {
        let text = """
        List main 2
        Width 0
        Item mcl_tools:sword_iron 1 120 "\\u0001description\\u0002Old Faithful\\u0003mcl_enchanting:enchantments\\u0002return {sharpness=2}\\u0003"
        Item mcl_bows:bow 1 0 "\\u0001active\\u0002true\\u0003inventory_image\\u0002mcl_bows_bow_1.png\\u0003"
        EndInventoryList
        EndInventory
        """
        let (lists, _) = Client.parseInventoryLists(text, previous: [:])
        let main = lists["main"]!
        XCTAssertEqual(main[0]?.name, "mcl_tools:sword_iron")
        XCTAssertEqual(main[0]?.wear, 120)
        XCTAssertEqual(main[0]?.customDescription, "Old Faithful")
        XCTAssertEqual(main[0]?.meta["mcl_enchanting:enchantments"], "return {sharpness=2}")
        XCTAssertEqual(main[1]?.customImage, "mcl_bows_bow_1.png")
        XCTAssertEqual(main[1]?.meta["active"], "true")
    }

    func testNoMetaAndSpacesInDescription() {
        let text = "List main 1\nWidth 0\nItem mcl_core:apple 3 0 \"\\u0001description\\u0002Two words here\\u0003\"\nEndInventoryList\n"
        let main = Client.parseInventoryLists(text, previous: [:]).lists["main"]!
        XCTAssertEqual(main[0]?.count, 3)
        XCTAssertEqual(main[0]?.customDescription, "Two words here")
        let plain = Client.parseInventoryLists("List main 1\nWidth 0\nItem mcl_core:apple 3\nEndInventoryList\n", previous: [:]).lists["main"]!
        XCTAssertTrue(plain[0]!.meta.isEmpty); XCTAssertNil(plain[0]?.customDescription)
    }
}
