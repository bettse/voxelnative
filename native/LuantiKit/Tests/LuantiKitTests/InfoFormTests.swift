import XCTest
@testable import LuantiKit

/// Parsers for the non-inventory info-form widgets VoxeLibre actually uses:
/// tabheader (doc Help), textlist (achievements, announcements) and hypertext
/// (announcements, tuning). These feed the read-only info panel (#339).
final class InfoFormTests: XCTestCase {

    func testTabHeaderStandard() {
        // The real doc Help header (mods/HELP/doc/doc/init.lua).
        let t = Formspec.parseTabHeader("tabheader[0,0;doc_header;Category list,Entry list,Entry;2;false;false]")
        XCTAssertEqual(t?.name, "doc_header")
        XCTAssertEqual(t?.captions, ["Category list", "Entry list", "Entry"])
        XCTAssertEqual(t?.current, 2)
    }

    func testTabHeaderHeightVariant() {
        // tabheader[X,Y;H;name;captions;current] -- the optional height field
        // (a bare number) shifts everything along by one.
        let t = Formspec.parseTabHeader("tabheader[0,0;1.5;tab;A,B;1]")
        XCTAssertEqual(t?.name, "tab")
        XCTAssertEqual(t?.captions, ["A", "B"])
        XCTAssertEqual(t?.current, 1)
    }

    func testTextlistRowsAndEscapedComma() {
        // The awards list (mods/HUD/awards/api.lua): an item title can contain an
        // escaped comma, which must stay one row, not split into three.
        let lists = Formspec.parseTextlists(
            "textlist[4.75,0;6,5;awards;Acquire Hardware,Diamonds\\, Diamonds\\, Diamonds,The End?;1;false]")
        XCTAssertEqual(lists.count, 1)
        XCTAssertEqual(lists.first?.name, "awards")
        XCTAssertEqual(lists.first?.rows, ["Acquire Hardware", "Diamonds, Diamonds, Diamonds", "The End?"])
        XCTAssertEqual(lists.first?.selected, 1)
        XCTAssertEqual(lists.first?.gx, 4.75)
    }

    func testHypertextStripsTagsAndSplitsLines() {
        // 4-field form (pos;size;name;text); tags flatten to their visible text.
        let h = Formspec.parseHypertexts("hypertext[0.5,3;4,2;desc;<b>Acquire Hardware</b>\nSmelt an <i>iron</i> ingot.]")
        XCTAssertEqual(h.count, 1)
        XCTAssertEqual(h.first?.lines, ["Acquire Hardware", "Smelt an iron ingot."])
    }

    func testIsInfoFormVsContainer() {
        XCTAssertTrue(Formspec.isInfoForm("size[11,5]textlist[4.75,0;6,5;awards;A,B;1;false]"))
        XCTAssertTrue(Formspec.isInfoForm("tabheader[0,0;t;A,B;1;false;false]"))
        // A furnace (item lists, no info widgets) is NOT an info form.
        XCTAssertFalse(Formspec.isInfoForm("size[9,9]list[context;src;3.5,0.75;1,1;]label[0,0;Furnace]"))
    }

    func testInfoFormLabelsFlattensEverything() {
        let spec = "size[11,5]tabheader[0,0;tab;Adv,Goals;1;false;false]" +
                   "textlist[4.75,0;6,5;awards;One,Two;1;false]" +
                   "hypertext[0.5,3;4,2;desc;<b>Title</b>\nBody line.]"
        let labels = Formspec.infoFormLabels(spec)
        let texts = labels.map { $0.text }
        // Current tab bracketed, others plain.
        XCTAssertTrue(texts.contains("[ Adv ]"))
        XCTAssertTrue(texts.contains("Goals"))
        // Each list row on its own line.
        XCTAssertTrue(texts.contains("One"))
        XCTAssertTrue(texts.contains("Two"))
        // Hypertext lines, tags stripped.
        XCTAssertTrue(texts.contains("Title"))
        XCTAssertTrue(texts.contains("Body line."))
    }

    func testInfoTargetsFieldsAndValues() {
        // Tab taps submit the 1-based index; textlist row taps submit CHG:<idx>.
        let spec = "size[11,5]tabheader[0,0;tabs;Adv,Goals,Chal;1;false;false]" +
                   "textlist[4.75,0;6,5;awards;One,Two,Three;1;false]"
        let ts = Formspec.infoTargets(spec)
        XCTAssertEqual(ts.filter { $0.field == "tabs" }.map { $0.value }, ["1", "2", "3"])
        XCTAssertEqual(ts.filter { $0.field == "awards" }.map { $0.value }, ["CHG:1", "CHG:2", "CHG:3"])
        // First row's gy must match infoFormLabels' first-row placement (tl.gy+0.6)
        // so the invisible tap box sits on the drawn text.
        XCTAssertEqual(ts.first { $0.field == "awards" }?.gy ?? -1, 0.6, accuracy: 0.001)
        // Empty rows produce no target.
        let ts2 = Formspec.infoTargets("textlist[0,1;6,5;l;A,,B;0;false]")
        XCTAssertEqual(ts2.filter { $0.field == "l" }.map { $0.value }, ["CHG:1", "CHG:3"])
    }

    func testTextlistCapsLongListWithMoreMarker() {
        let rows = (1...20).map { "Row\($0)" }.joined(separator: ",")
        let labels = Formspec.infoFormLabels("textlist[0,1;6,5;l;\(rows);1;false]")
        XCTAssertTrue(labels.contains { $0.text == "Row1" })
        XCTAssertTrue(labels.contains { $0.text.contains("more") })   // "(+8 more)" for 20 rows capped at 12
        XCTAssertFalse(labels.contains { $0.text == "Row20" })
    }
}
