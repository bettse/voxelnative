import XCTest
@testable import LuantiKit

/// TOSERVER_INVENTORY_FIELDS: closing a named show_formspec form (a chest's
/// "mcl_chests:chest_x_y_z") must send this with the formname + quit, or the
/// server's on_player_receive_fields never fires and the chest lid stays open
/// (#130). Layout mirrors serverpackethandler handleCommand_InventoryFields.
final class FormFieldsTests: XCTestCase {
    func testChestCloseCarriesFormnameAndQuit() {
        let d = Client.inventoryFieldsPacket(formname: "mcl_chests:chest_-545_35_26",
                                             fields: ["quit": "true"])
        let r = PacketReader(d)
        XCTAssertEqual(r.string16(), "mcl_chests:chest_-545_35_26", "formname must be the named form")
        XCTAssertEqual(r.u16(), 1)
        XCTAssertEqual(r.string16(), "quit")
        XCTAssertEqual(r.string32(), "true")
        XCTAssertFalse(r.overrun)
    }

    func testEmptyFieldsStillCarryFormname() {
        let d = Client.inventoryFieldsPacket(formname: "mcl_beds_form", fields: [:])
        let r = PacketReader(d)
        XCTAssertEqual(r.string16(), "mcl_beds_form")
        XCTAssertEqual(r.u16(), 0)
    }
}
