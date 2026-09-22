import Foundation
import CSTBVorbis

/// Decodes Ogg Vorbis (Luanti's sound format) to PCM WAV bytes. Apple's
/// AVFoundation can't open Ogg containers, so we decode with stb_vorbis and wrap
/// the interleaved 16-bit PCM in a minimal WAV header — which AVAudioPlayer reads
/// natively. All-in-memory; no temp files.
public enum Vorbis {
    /// Decode `ogg` and return a self-contained little-endian 16-bit PCM WAV, or
    /// nil if the data isn't decodable Vorbis.
    public static func decodeToWAV(_ ogg: Data) -> Data? {
        var channels: Int32 = 0
        var sampleRate: Int32 = 0
        var out: UnsafeMutablePointer<Int16>? = nil
        let samplesPerChannel: Int32 = ogg.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return Int32(stb_vorbis_decode_memory(base, Int32(ogg.count), &channels, &sampleRate, &out))
        }
        guard samplesPerChannel > 0, channels > 0, sampleRate > 0, let pcm = out else {
            if let out { free(out) }
            return nil
        }
        defer { free(pcm) }
        let sampleCount = Int(samplesPerChannel) * Int(channels)
        let dataBytes = sampleCount * MemoryLayout<Int16>.size
        return wav(pcm: pcm, dataBytes: dataBytes, channels: Int(channels), sampleRate: Int(sampleRate))
    }

    private static func wav(pcm: UnsafeMutablePointer<Int16>, dataBytes: Int,
                            channels: Int, sampleRate: Int) -> Data {
        let bitsPerSample = 16
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        var d = Data(capacity: 44 + dataBytes)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)                     // PCM
        u16(channels)
        u32(sampleRate)
        u32(byteRate)
        u16(blockAlign)
        u16(bitsPerSample)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        pcm.withMemoryRebound(to: UInt8.self, capacity: dataBytes) { p in
            d.append(p, count: dataBytes)
        }
        return d
    }
}
