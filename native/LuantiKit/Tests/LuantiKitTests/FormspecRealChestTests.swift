import XCTest
@testable import LuantiKit

/// VoxeLibre's real chest form (mcl_chests/api.lua): translated + coloured
/// labels and 27 image[] slot backgrounds ahead of each list[]. The sim aid
/// used a simplified form and rendered fine while the device showed an empty
/// chest, so this pins the real wire text.
final class FormspecRealChestTests: XCTestCase {
    static let e = "\u{1b}"
    static let spec = "formspec_version[4]size[11.75,10.425]" +
        "label[0.375,0.375;\(e)(c@#313131)\(e)(T@mcl_chests)Chest\(e)E\(e)(c@#fff)]" +
        "image[0.325,0.7;1.1,1.1;mcl_formspec_itemslot.png]image[0.325,1.95;1.1,1.1;mcl_formspec_itemslot.png]" +
        "list[nodemeta:118,17,107;main;0.375,0.75;9,3;]" +
        "label[0.375,4.7;\(e)(c@#313131)\(e)(T@mcl_chests)Inventory\(e)E\(e)(c@#fff)]" +
        "image[0.325,5.05;1.1,1.1;mcl_formspec_itemslot.png]" +
        "list[current_player;main;0.375,5.1;9,3;9]" +
        "list[current_player;main;0.375,9.05;9,1;]" +
        "listring[nodemeta:118,17,107;main]listring[current_player;main]"

    func testLabelsStripTranslationAndColourEscapes() {
        let labels = Formspec.parseLabels(Self.spec)
        XCTAssertEqual(labels.map(\.text), ["Chest", "Inventory"])
    }

    func testListsAndImagesParse() {
        let lists = Formspec.parseLists(Self.spec, context: nil)
        XCTAssertEqual(lists.count, 3)
        XCTAssertEqual(lists[0].loc, "nodemeta:118,17,107")
        XCTAssertEqual(lists[1].start, 9)
        XCTAssertEqual(Formspec.parseImages(Self.spec).count, 3)
    }
}
