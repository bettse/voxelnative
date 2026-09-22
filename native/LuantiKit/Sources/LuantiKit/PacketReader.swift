import Foundation

/// Big-endian reader for Luanti payloads (port of packet_reader.gd). Reads past
/// the end return zeros and set `overrun`, matching the engine's tolerance.
public final class PacketReader {
    private let buf: [UInt8]
    private var pos = 0
    public private(set) var overrun = false

    public init(_ d: Data) { buf = [UInt8](d) }

    public func remaining() -> Int { buf.count - pos }
    public func has(_ n: Int) -> Bool { remaining() >= n }

    private func check(_ n: Int) -> Bool {
        if remaining() < n { overrun = true; pos = buf.count; return false }
        return true
    }

    public func u8() -> Int { guard check(1) else { return 0 }; defer { pos += 1 }; return Int(buf[pos]) }
    public func u16() -> Int { guard check(2) else { return 0 }; defer { pos += 2 }; return (Int(buf[pos]) << 8) | Int(buf[pos + 1]) }
    public func u32() -> Int {
        guard check(4) else { return 0 }; defer { pos += 4 }
        return (Int(buf[pos]) << 24) | (Int(buf[pos + 1]) << 16) | (Int(buf[pos + 2]) << 8) | Int(buf[pos + 3])
    }
    public func u64() -> Int {
        let hi = u32(); let lo = u32(); return (hi << 32) | lo
    }
    public func f32() -> Float { Float(bitPattern: UInt32(truncatingIfNeeded: u32())) }
    public func s16() -> Int { let v = u16(); return v >= 0x8000 ? v - 0x10000 : v }
    public func s32() -> Int { let v = u32(); return v >= 0x8000_0000 ? v - 0x1_0000_0000 : v }

    public func raw(_ n: Int) -> Data { guard check(n) else { return Data() }; defer { pos += n }; return Data(buf[pos..<pos + n]) }
    public func rest() -> Data { Data(buf[pos...]) }
    public func bytes16() -> Data { raw(u16()) }
    public func bytes32() -> Data { raw(u32()) }
    public func string16() -> String { String(decoding: bytes16(), as: UTF8.self) }
    /// Luanti wide string: u16 char count, then that many UTF-16 big-endian
    /// code units (used by CHAT_MESSAGE, some access-denied reasons).
    public func wideString() -> String {
        let count = u16()
        var units = [UInt16](); units.reserveCapacity(count)
        for _ in 0..<count { units.append(UInt16(u16())) }
        return String(decoding: units, as: UTF16.self)
    }
    public func string32() -> String { String(decoding: bytes32(), as: UTF8.self) }
}
