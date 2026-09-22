import Foundation
import Compression

/// zlib (RFC1950) inflate, for the few packets Luanti compresses with zlib
/// rather than zstd (e.g. TOCLIENT_NODEMETA_CHANGED). Apple's Compression
/// framework only does RAW DEFLATE (COMPRESSION_ZLIB is headerless), so we strip
/// the 2-byte zlib header and ignore the trailing adler32, then raw-inflate.
public enum Zlib {
    public static func inflate(_ data: Data, maxSize: Int = 8 * 1024 * 1024) -> Data? {
        guard data.count > 2 else { return nil }
        // zlib header: CMF (0x78 typically) + FLG; skip it. No preset dict support
        // (FLG bit 5) — Luanti never sets it.
        let body = data.subdata(in: (data.startIndex + 2)..<data.endIndex)
        var capacity = max(4096, data.count * 4)
        while capacity <= maxSize {
            var out = Data(count: capacity)
            let n = out.withUnsafeMutableBytes { dst -> Int in
                body.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              src.bindMemory(to: UInt8.self).baseAddress!, body.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            if n > 0 && n < capacity { out.removeSubrange(n..<out.count); return out }
            // n == capacity means the buffer was likely too small; grow and retry.
            capacity *= 2
        }
        return nil
    }
}
