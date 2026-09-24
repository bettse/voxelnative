import XCTest
@testable import LuantiKit

/// the atlas build runs off the tick queue and reads the media store, while
/// poll keeps mutating that store as files land. snapshot() hands the builder its
/// own copy so the two never touch the same dict, and later writes to the live
/// store don't leak into an in-flight bake.
final class MediaSnapshotTests: XCTestCase {
    func testSnapshotIsAnIndependentCopy() {
        let m = MediaManager(send: { _, _ in })
        m.storeForTesting("a.png", Data([1, 2, 3]))

        let snap = m.snapshot()
        XCTAssertEqual(snap.bytes("a.png"), Data([1, 2, 3]))

        // Mutating the live store after the snapshot must not change the snapshot
        // (this is the whole point: an in-flight bake sees a stable world).
        m.storeForTesting("b.png", Data([9]))
        XCTAssertNil(snap.bytes("b.png"))
        XCTAssertEqual(m.bytes("b.png"), Data([9]))
    }

    func testSnapshotHasNoOpSend() {
        // The copy must never request media (no live connection behind it).
        let snap = MediaManager(send: { _, _ in }).snapshot()
        snap.request(["x.png"])   // would trap/crash if send were nil; no-op here
    }
}
