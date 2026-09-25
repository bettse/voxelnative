import XCTest
@testable import LuantiKit

/// ACCESS_DENIED: the reason string AND the numeric AccessDeniedCode reach
/// the consumer, so a fast relaunch's "already connected" (code 8) is retried by
/// code even if the server sends a custom/localized reason.
final class AccessDeniedTests: XCTestCase {
    private func denied(_ payload: Data) -> (reason: String, code: Int) {
        let c = Client(name: "t", password: "")
        var got: (String, Int) = ("<none>", -99)
        c.onAccessDenied = { got = ($0, $1) }
        c.handleForTesting(Op.toclientAccessDenied, payload)
        return got
    }

    func testAlreadyConnectedCarriesCode8AndDefaultReason() {
        let d = denied(PacketWriter().u8(8).data)   // code 8, no custom reason
        XCTAssertEqual(d.code, 8)
        XCTAssertEqual(d.reason, "already connected with this name")
    }

    func testWrongPasswordCarriesCode0() {
        XCTAssertEqual(denied(PacketWriter().u8(0).data).code, 0)
    }

    func testCustomReasonIsKeptWithItsCode() {
        // A server can attach its own message; both the string and the code come
        // through (so the consumer decides retryable by code, not the string).
        let d = denied(PacketWriter().u8(8).string16("come back in a sec").data)
        XCTAssertEqual(d.code, 8)
        XCTAssertEqual(d.reason, "come back in a sec")
    }

    func testReconnectFlagAndEscapesInTheReason() {
        let c = Client(name: "t", password: "")
        var got = ""
        c.onAccessDenied = { r, _ in got = r }
        // Shutdown (11) with a translated reason and reconnect=1.
        c.handleForTesting(Op.toclientAccessDenied,
                           PacketWriter().u8(11).string16("\u{1b}(T@mcl)Server restarting\u{1b}E").u8(1).data)
        XCTAssertTrue(c.deniedReconnect)
        XCTAssertEqual(got, "Server restarting")
        // A kick (10) without the flag must not retry.
        c.handleForTesting(Op.toclientAccessDenied, PacketWriter().u8(10).string16("bye").u8(0).data)
        XCTAssertFalse(c.deniedReconnect)
        // Too many users always may retry.
        c.handleForTesting(Op.toclientAccessDenied, PacketWriter().u8(6).data)
        XCTAssertTrue(c.deniedReconnect)
    }
}
