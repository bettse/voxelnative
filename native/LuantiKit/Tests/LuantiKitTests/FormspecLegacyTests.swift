import XCTest
@testable import LuantiKit

/// Forms without formspec_version[2+] use Luanti's old coordinates; the
/// villager trade form is one, and its grid spilled past its background.
final class FormspecLegacyTests: XCTestCase {
    let trade = "size[9,8.75]background[-0.19,-0.25;9.41,9.49;mobs_mc_trading_formspec_bg.png]" +
                "list[current_player;main;0,4.5;9,3;9]list[current_player;main;0,7.74;9,1;]"

    func testDetection() {
        XCTAssertTrue(Formspec.Legacy.applies(to: trade))
        XCTAssertTrue(Formspec.Legacy.applies(to: "formspec_version[1]size[8,9]"))
        XCTAssertFalse(Formspec.Legacy.applies(to: "formspec_version[4]size[11.75,10.425]"))
        XCTAssertFalse(Formspec.Legacy.applies(to: "size[8,9]real_coordinates[true]"))
    }

    func testTradeGridFitsInsideItsBackground() {
        let lists = Formspec.parseLists(trade, context: nil).map(Formspec.Legacy.convert)
        let bg = Formspec.Legacy.convert(Formspec.parseBackgrounds(trade)[0])
        for l in lists {
            let right = l.gx + Float(l.cols - 1) * l.pitch.x + 1
            let bottom = l.gy + Float(l.rows - 1) * l.pitch.y + 1
            XCTAssertLessThanOrEqual(right, bg.gx + bg.w, "\(l.list) spills right")
            XCTAssertLessThanOrEqual(bottom, bg.gy + bg.h, "\(l.list) spills below")
            XCTAssertGreaterThanOrEqual(l.gx, bg.gx)
        }
        // The three main rows end before the hotbar row starts.
        let mainBottom = lists[0].gy + 2 * lists[0].pitch.y + 1
        XCTAssertLessThan(mainBottom, lists[1].gy)
    }
}
