import Foundation

/// Big-endian serializer for the Luanti wire format (the engine's
/// NetworkPacket / serialize.h conventions), used to build the messages a
/// client sends: position updates, dig/place, chat, inventory actions.
/// Originally ported via packet_writer.gd.
public final class PacketWriter {
    public private(set) var data = Data()
    public init() {}

    @discardableResult public func u8(_ v: Int) -> PacketWriter { data.append(UInt8(v & 0xFF)); return self }
    @discardableResult public func s8(_ v: Int) -> PacketWriter { data.append(UInt8(bitPattern: Int8(truncatingIfNeeded: v))); return self }
    @discardableResult public func u16(_ v: Int) -> PacketWriter { data.append(UInt8((v >> 8) & 0xFF)); data.append(UInt8(v & 0xFF)); return self }
    @discardableResult public func s16(_ v: Int) -> PacketWriter { u16(v & 0xFFFF) }
    @discardableResult public func u32(_ v: Int) -> PacketWriter { for s in [24, 16, 8, 0] { data.append(UInt8((v >> s) & 0xFF)) }; return self }
    @discardableResult public func s32(_ v: Int) -> PacketWriter { u32(v & 0xFFFFFFFF) }
    @discardableResult public func f32(_ v: Float) -> PacketWriter { u32(Int(v.bitPattern)) }
    @discardableResult public func raw(_ b: Data) -> PacketWriter { data.append(b); return self }

    @discardableResult public func bytes16(_ b: Data) -> PacketWriter { u16(b.count); data.append(b); return self }
    @discardableResult public func bytes32(_ b: Data) -> PacketWriter { u32(b.count); data.append(b); return self }
    @discardableResult public func string16(_ s: String) -> PacketWriter { bytes16(Data(s.utf8)) }
    @discardableResult public func string32(_ s: String) -> PacketWriter { bytes32(Data(s.utf8)) }

    /// u16 code-unit count + UTF-16BE (Luanti wide strings).
    @discardableResult public func wstring(_ s: String) -> PacketWriter {
        var units = Data()
        for u in s.utf16 { units.append(UInt8((u >> 8) & 0xFF)); units.append(UInt8(u & 0xFF)) }
        u16(units.count / 2); data.append(units); return self
    }
}
