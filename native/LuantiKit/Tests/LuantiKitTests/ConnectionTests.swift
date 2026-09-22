import XCTest
@testable import LuantiKit

/// The reliable-UDP receive path (Connection): original/reliable/split packets,
/// out-of-order buffering, duplicate suppression, seqnum wraparound at 65535,
/// and split reassembly. This is the transport's trickiest logic and had no
/// coverage; the tests drive datagrams straight in (no socket) via
/// ingestDatagramForTesting and observe delivery through onMessage.
final class ConnectionTests: XCTestCase {
    // Wire constants mirror Connection's private statics.
    private let TYPE_CONTROL: UInt8 = 0, TYPE_ORIGINAL: UInt8 = 1, TYPE_SPLIT: UInt8 = 2, TYPE_RELIABLE: UInt8 = 3
    private let CTRL_ACK: UInt8 = 0, CTRL_SET_PEER_ID: UInt8 = 1, CTRL_DISCO: UInt8 = 3
    private let SEQ_INITIAL = 65500

    private func u16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    /// PROTOCOL_ID (0x4F457403) BE, peer id 0, channel byte.
    private func base(_ channel: Int) -> [UInt8] { [0x4F, 0x45, 0x74, 0x03, 0, 0, UInt8(channel)] }

    private func datagram(channel: Int, _ inner: [UInt8]) -> Data { Data(base(channel) + inner) }

    private func original(_ opcode: Int, _ payload: [UInt8] = []) -> [UInt8] {
        [TYPE_ORIGINAL] + u16(opcode) + payload
    }
    private func reliable(_ seq: Int, _ inner: [UInt8]) -> [UInt8] { [TYPE_RELIABLE] + u16(seq) + inner }
    private func split(_ splitSeq: Int, count: Int, num: Int, _ chunk: [UInt8]) -> [UInt8] {
        [TYPE_SPLIT] + u16(splitSeq) + u16(count) + u16(num) + chunk
    }

    /// A Connection wired to record every delivered (opcode, payload).
    private func makeRecording() -> (Connection, () -> [(op: Int, payload: [UInt8])]) {
        let c = Connection()
        var got: [(op: Int, payload: [UInt8])] = []
        c.onMessage = { op, data in got.append((op, [UInt8](data))) }
        return (c, { got })
    }

    func testOriginalPacketDeliversImmediately() {
        let (c, got) = makeRecording()
        c.ingestDatagramForTesting(datagram(channel: 0, original(0x2F, [1, 2, 3])))
        XCTAssertEqual(got().count, 1)
        XCTAssertEqual(got()[0].op, 0x2F)
        XCTAssertEqual(got()[0].payload, [1, 2, 3])
    }

    func testInvalidProtocolIdIsDropped() {
        let (c, got) = makeRecording()
        var bad = datagram(channel: 0, original(0x2F))
        bad[0] = 0x00                                  // corrupt PROTOCOL_ID
        c.ingestDatagramForTesting(bad)
        XCTAssertTrue(got().isEmpty)
    }

    func testReliableInOrderDelivers() {
        let (c, got) = makeRecording()
        c.ingestDatagramForTesting(datagram(channel: 0, reliable(SEQ_INITIAL, original(0x10))))
        XCTAssertEqual(got().map(\.op), [0x10])
    }

    func testReliableOutOfOrderBuffersThenFlushesInOrder() {
        let (c, got) = makeRecording()
        // seq+1 arrives first: buffered, nothing delivered yet.
        c.ingestDatagramForTesting(datagram(channel: 0, reliable(SEQ_INITIAL + 1, original(0x11))))
        XCTAssertTrue(got().isEmpty, "a future seqnum must wait for the gap to fill")
        // the gap fills: both drain in seq order.
        c.ingestDatagramForTesting(datagram(channel: 0, reliable(SEQ_INITIAL, original(0x10))))
        XCTAssertEqual(got().map(\.op), [0x10, 0x11])
    }

    func testReliableDuplicateIsDeliveredOnce() {
        let (c, got) = makeRecording()
        c.ingestDatagramForTesting(datagram(channel: 0, reliable(SEQ_INITIAL, original(0x20))))
        c.ingestDatagramForTesting(datagram(channel: 0, reliable(SEQ_INITIAL, original(0x20))))  // dup, already past
        XCTAssertEqual(got().map(\.op), [0x20], "a re-sent already-acked reliable is not re-delivered")
    }

    func testBufferedDuplicateDoesNotDeliverTwice() {
        let (c, got) = makeRecording()
        c.ingestDatagramForTesting(datagram(channel: 0, reliable(SEQ_INITIAL + 1, original(0x31))))
        c.ingestDatagramForTesting(datagram(channel: 0, reliable(SEQ_INITIAL + 1, original(0x31))))  // dup while buffered
        c.ingestDatagramForTesting(datagram(channel: 0, reliable(SEQ_INITIAL, original(0x30))))
        XCTAssertEqual(got().map(\.op), [0x30, 0x31])
    }

    func testReliableSeqnumWrapsPast65535() {
        let (c, got) = makeRecording()
        // Deliver a run that crosses the u16 boundary: 65500..65535 then 0, 1.
        var seq = SEQ_INITIAL
        var expected: [Int] = []
        for i in 0..<38 {
            c.ingestDatagramForTesting(datagram(channel: 0, reliable(seq, original(0x40 + i))))
            expected.append(0x40 + i)
            seq = (seq + 1) & 0xFFFF
        }
        XCTAssertEqual(got().map(\.op), expected, "delivery order is unbroken across 65535 -> 0")
        XCTAssertGreaterThanOrEqual(got().count, 38)
    }

    func testSplitReassemblesOutOfOrderChunks() {
        let (c, got) = makeRecording()
        // whole message = u16(opcode) + payload; opcode 0x64, payload "ABCD".
        // chunk 0 carries the opcode + "AB", chunk 1 carries "CD".
        c.ingestDatagramForTesting(datagram(channel: 0, split(7, count: 2, num: 1, [0x43, 0x44])))       // "CD" first
        XCTAssertTrue(got().isEmpty, "an incomplete split delivers nothing")
        c.ingestDatagramForTesting(datagram(channel: 0, split(7, count: 2, num: 0, u16(0x64) + [0x41, 0x42])))
        XCTAssertEqual(got().count, 1)
        XCTAssertEqual(got()[0].op, 0x64)
        XCTAssertEqual(got()[0].payload, [0x41, 0x42, 0x43, 0x44])   // "ABCD"
    }

    func testSplitWithBadCountIsIgnored() {
        let (c, got) = makeRecording()
        c.ingestDatagramForTesting(datagram(channel: 0, split(9, count: 0, num: 0, [1, 2])))   // count 0
        c.ingestDatagramForTesting(datagram(channel: 0, split(9, count: 2, num: 5, [1, 2])))   // num >= count
        XCTAssertTrue(got().isEmpty)
    }

    func testChannelsAreIndependent() {
        let (c, got) = makeRecording()
        // Same starting seqnum on two channels must not collide.
        c.ingestDatagramForTesting(datagram(channel: 0, reliable(SEQ_INITIAL, original(0xA0))))
        c.ingestDatagramForTesting(datagram(channel: 1, reliable(SEQ_INITIAL, original(0xB0))))
        XCTAssertEqual(Set(got().map(\.op)), [0xA0, 0xB0])
    }

    func testSetPeerIdIsRecorded() {
        let (c, _) = makeRecording()
        c.ingestDatagramForTesting(datagram(channel: 0, [TYPE_CONTROL, CTRL_SET_PEER_ID] + u16(42)))
        XCTAssertEqual(c.peerId, 42)
    }

    func testAckControlPacketDeliversNothing() {
        let (c, got) = makeRecording()
        c.ingestDatagramForTesting(datagram(channel: 0, [TYPE_CONTROL, CTRL_ACK] + u16(SEQ_INITIAL)))
        XCTAssertTrue(got().isEmpty)
    }
}
