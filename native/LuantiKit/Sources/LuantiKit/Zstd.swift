import Foundation
import libzstd

/// Minimal zstd decompression tuned for the memory-tight visionOS device.
///
/// The old version allocated `maxSize` (up to 32 MB) up front whenever a frame
/// didn't declare its content size. On a fast relaunch the just-killed process's
/// surfaces aren't reclaimed yet, so that speculative allocation would fail and
/// Foundation traps inside `Data(count:)` (EXC_BREAKPOINT). Now we allocate the
/// exact size when the frame declares it, and otherwise stream into a buffer
/// that starts small and doubles only up to the real decompressed size.
public enum Zstd {
    /// Compress a buffer into a standalone zstd frame. Not used on the hot client
    /// path (the client only decompresses server frames), but handy for building
    /// NODEDEF/media test fixtures and any future outbound compression.
    public static func compress(_ data: Data, level: Int32 = 3) -> Data? {
        let bound = ZSTD_compressBound(data.count)
        var out = Data(count: bound)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src -> Int in
                let r = ZSTD_compress(dst.baseAddress, dst.count, src.baseAddress, src.count, level)
                return ZSTD_isError(r) != 0 ? -1 : Int(r)
            }
        }
        if written < 0 { return nil }
        out.removeSubrange(written..<out.count)
        return out
    }

    public static func decompress(_ data: Data, maxSize: Int = 8 * 1024 * 1024) -> Data? {
        if data.isEmpty { return nil }

        // Fast path: frame declares its exact size -> one allocation, no waste.
        let declared: UInt64 = data.withUnsafeBytes { src in
            ZSTD_getFrameContentSize(src.baseAddress, src.count)
        }
        // Two top sentinels are UNKNOWN/ERROR; anything past Int.max is garbage.
        if declared < UInt64(Int.max) {
            let cap = Int(declared)
            if cap == 0 { return Data() }
            if cap <= maxSize { return singleShot(data, cap: cap) }
            // declared but bigger than our ceiling: treat as untrusted, stream.
        }
        return streaming(data, maxSize: maxSize)
    }

    private static func singleShot(_ data: Data, cap: Int) -> Data? {
        var out = Data(count: cap)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src -> Int in
                let r = ZSTD_decompress(dst.baseAddress, dst.count, src.baseAddress, src.count)
                return ZSTD_isError(r) != 0 ? -1 : Int(r)
            }
        }
        if written < 0 { return nil }
        if written != out.count { out.removeSubrange(written..<out.count) }
        return out
    }

    /// Stream when the size is unknown: never allocate more than we actually
    /// need. Start at the recommended block size and grow by doubling, capped.
    private static func streaming(_ data: Data, maxSize: Int) -> Data? {
        guard let zds = ZSTD_createDStream() else { return nil }
        defer { ZSTD_freeDStream(zds) }
        _ = ZSTD_initDStream(zds)

        var out = Data()
        var chunk = min(maxSize, max(Int(ZSTD_DStreamOutSize()), 64 * 1024))
        var scratch = [UInt8](repeating: 0, count: chunk)

        let result: Data? = data.withUnsafeBytes { (srcBuf: UnsafeRawBufferPointer) -> Data? in
            var input = ZSTD_inBuffer(src: srcBuf.baseAddress, size: srcBuf.count, pos: 0)
            while true {
                var produced = 0
                let ret: size_t = scratch.withUnsafeMutableBytes { s -> size_t in
                    var output = ZSTD_outBuffer(dst: s.baseAddress, size: s.count, pos: 0)
                    let r = ZSTD_decompressStream(zds, &output, &input)
                    produced = output.pos
                    return r
                }
                if ZSTD_isError(ret) != 0 { return nil }
                if produced > 0 {
                    if out.count + produced > maxSize { return nil }   // runaway frame
                    scratch.withUnsafeBytes { out.append($0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: produced) }
                }
                // ret == 0 means a frame completed; if input is drained we're done.
                if ret == 0 || input.pos >= input.size { break }
                // Grow the scratch buffer if the last call filled it completely,
                // so large frames don't thrash on tiny reads.
                if produced == scratch.count && chunk < maxSize {
                    chunk = min(chunk * 2, maxSize)
                    scratch = [UInt8](repeating: 0, count: chunk)
                }
            }
            return out
        }
        return (result?.isEmpty == true) ? nil : result
    }
}
