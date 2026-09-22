import XCTest
@testable import LuantiKit

/// PacketWriter -> PacketReader round-trips. This framing is the base of every
/// protocol message, so a regression here breaks everything downstream.
final class PacketCodecTests: XCTestCase {
    func testIntegerRoundTrip() {
        let w = PacketWriter()
        w.u8(0xAB).u16(0x1234).u32(0x89ABCDEF).s16(-1234).s32(-100000)
        let r = PacketReader(w.data)
        XCTAssertEqual(r.u8(), 0xAB)
        XCTAssertEqual(r.u16(), 0x1234)
        XCTAssertEqual(r.u32(), 0x89ABCDEF)
        XCTAssertEqual(r.s16(), -1234)
        XCTAssertEqual(r.s32(), -100000)
        XCTAssertFalse(r.overrun)
    }

    func testFloatRoundTrip() {
        let w = PacketWriter()
        for v: Float in [0, 1, -0.3125, 12345.678, -5.0] { w.f32(v) }
        let r = PacketReader(w.data)
        for v: Float in [0, 1, -0.3125, 12345.678, -5.0] {
            XCTAssertEqual(r.f32(), v, accuracy: 1e-4)
        }
    }

    func testStringAndBytes() {
        let w = PacketWriter()
        w.string16("hello").string32("a longer string").bytes16(Data([1, 2, 3]))
        let r = PacketReader(w.data)
        XCTAssertEqual(r.string16(), "hello")
        XCTAssertEqual(r.string32(), "a longer string")
        XCTAssertEqual(Array(r.bytes16()), [1, 2, 3])
    }

    func testOverrunIsSafe() {
        let r = PacketReader(Data([0x01, 0x02]))
        XCTAssertEqual(r.u8(), 1)
        XCTAssertEqual(r.u8(), 2)
        // Reading past the end must not crash; it flags overrun and returns 0.
        XCTAssertEqual(r.u32(), 0)
        XCTAssertTrue(r.overrun)
    }

    func testZstdRoundTrip() {
        let original = Data((0..<5000).map { UInt8($0 % 251) })
        guard let packed = Zstd.compress(original) else { return XCTFail("compress failed") }
        XCTAssertLessThan(packed.count, original.count)   // it actually compressed
        XCTAssertEqual(Zstd.decompress(packed), original)
    }
}
