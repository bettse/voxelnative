import XCTest
@testable import LuantiKit

/// Opt-in integration test: joins the developer's own local dev server with a
/// fresh randomly-named account each run (the server holds a name until the
/// old peer times out) and waits for auth, spawn and a first mapblock. Skipped unless
/// LUANTI_DEV_SERVER=host:port is set (`make integration` from native/), so a
/// plain `swift test` stays green with no server around.
final class DevServerJoinTests: XCTestCase {
    func testJoinReachesSpawnAndStreamsABlock() throws {
        guard let target = ProcessInfo.processInfo.environment["LUANTI_DEV_SERVER"], !target.isEmpty else {
            throw XCTSkip("set LUANTI_DEV_SERVER=127.0.0.1:30000 to run against the dev server")
        }
        let parts = target.split(separator: ":")
        let host = String(parts.first ?? "127.0.0.1")
        let port = UInt16(parts.count > 1 ? parts[1] : "30000") ?? 30000

        // Fresh name each run: the server holds a name until the old peer times out.
        let c = Client(name: "test-" + String(UInt16.random(in: 0...0xFFFF), radix: 16), password: "test")
        var authed = false, spawned = false, blocks = 0, denied: String? = nil, dropped: String? = nil
        c.onAuthenticated = { _ in authed = true }
        c.onSpawn = { _, _, _ in spawned = true }
        c.onBlock = { _ in blocks += 1 }
        c.onAccessDenied = { d, _ in denied = d }
        c.onDisconnected = { dropped = $0 }
        c.connect(host: host, port: port)

        // Callbacks fire from poll(), so this loop is the whole client thread.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, denied == nil, dropped == nil, !(spawned && blocks > 0) {
            c.poll(0.02)
            Thread.sleep(forTimeInterval: 0.02)
        }
        // Our own DISCO reports back through onDisconnected from the network
        // queue, so read the flags before leaving.
        let droppedEarly = dropped
        c.onDisconnected = nil
        c.disconnect("test done")
        c.poll(0.02)

        XCTAssertNil(denied, "access denied")
        XCTAssertNil(droppedEarly, "dropped before spawn")
        XCTAssertTrue(authed, "no AUTH_ACCEPT within 30 s")
        XCTAssertTrue(spawned, "no MOVE_PLAYER (spawn) within 30 s")
        XCTAssertGreaterThan(blocks, 0, "no BLOCKDATA within 30 s")
        XCTAssertGreaterThan(c.nodes.count, 0, "NODEDEF not parsed")
    }
}
