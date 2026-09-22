import XCTest
@testable import LuantiKit

/// TOSERVER movement key bits (Client.moveControlBits). Luanti's key bitmask is
/// up=1, down=2, left=4, right=8, aux1(sprint)=32. mcl_sprint reads aux1+up and
/// sets physics_override.speed itself, so the client must send the bit, not
/// double-apply a local speed multiplier (#180).
final class ControlBitsTests: XCTestCase {
    private let up = 1, down = 2, left = 4, right = 8, aux1 = 32

    func testCardinalDirections() {
        XCTAssertEqual(Client.moveControlBits(dx: 0, dy: 1, sprint: false), up)
        XCTAssertEqual(Client.moveControlBits(dx: 0, dy: -1, sprint: false), down)
        XCTAssertEqual(Client.moveControlBits(dx: -1, dy: 0, sprint: false), left)
        XCTAssertEqual(Client.moveControlBits(dx: 1, dy: 0, sprint: false), right)
    }

    func testDiagonalCombinesTwoBits() {
        XCTAssertEqual(Client.moveControlBits(dx: -1, dy: 1, sprint: false), up | left)
        XCTAssertEqual(Client.moveControlBits(dx: 1, dy: -1, sprint: false), down | right)
    }

    func testSprintAddsAux1() {
        XCTAssertEqual(Client.moveControlBits(dx: 0, dy: 1, sprint: true), up | aux1)
        // Sprint with no stick input still sends aux1 alone (server gates on up).
        XCTAssertEqual(Client.moveControlBits(dx: 0, dy: 0, sprint: true), aux1)
    }

    func testDeadzoneSuppressesDrift() {
        XCTAssertEqual(Client.moveControlBits(dx: 0.05, dy: -0.05, sprint: false), 0)
        // Just past the deadzone registers.
        XCTAssertEqual(Client.moveControlBits(dx: 0, dy: 0.2, sprint: false), up)
    }
}
