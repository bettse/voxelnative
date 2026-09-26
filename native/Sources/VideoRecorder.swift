import AVFoundation
import CoreVideo
import Metal
import Photos

/// Photo mode's video: frames from the level camera, written to an H.264 .mov
/// in the temp dir, then added to Photos. Frames arrive from the render thread
/// as BGRA pixel buffers the GPU filled (Renderer.encodeVideoFrame); a frame is
/// dropped rather than queued when the encoder is behind.
final class VideoRecorder {
    static let width = 1920, height = 1080, fps = 30
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let url: URL
    private var textureCache: CVMetalTextureCache?
    private let queue = DispatchQueue(label: "video.writer")
    private var firstTime: CFTimeInterval?
    private var lastTime: CFTimeInterval = -1
    private(set) var frames = 0
    private var finished = false

    init?(device: MTLDevice) {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(Int(Date().timeIntervalSince1970)).mov")
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        writer = w
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.width, AVVideoHeightKey: Self.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000,
                                              AVVideoExpectedSourceFrameRateKey: Self.fps],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.width, kCVPixelBufferHeightKey as String: Self.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else {
            print("[video] startWriting failed: \(writer.error.map { "\($0)" } ?? "?")"); fflush(stdout); return nil
        }
        writer.startSession(atSourceTime: .zero)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        print("[video] recording \(Self.width)x\(Self.height) to \(url.lastPathComponent)"); fflush(stdout)
    }

    /// A pooled pixel buffer and a Metal texture over it for the GPU to fill,
    /// or nil when the encoder is behind (the frame is skipped). Keep the
    /// CVMetalTexture alive until the GPU is done with the texture.
    func nextTarget() -> (buffer: CVPixelBuffer, texture: MTLTexture, ref: CVMetalTexture)? {
        guard !finished, input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool, let cache = textureCache else { return nil }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let buffer = pb else { return nil }
        var cvTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm,
                                                        Self.width, Self.height, 0, &cvTex) == kCVReturnSuccess,
              let ref = cvTex, let tex = CVMetalTextureGetTexture(ref) else { return nil }
        return (buffer, tex, ref)
    }

    /// Called once the GPU has written `buffer`. `time` is when the frame was
    /// rendered (CACurrentMediaTime), so the clip plays at real speed.
    func append(_ buffer: CVPixelBuffer, at time: CFTimeInterval) {
        queue.async { [self] in
            guard !finished, input.isReadyForMoreMediaData else { return }
            let t0 = firstTime ?? time
            firstTime = t0
            guard time > lastTime else { return }   // presentation times must increase
            lastTime = time
            if adaptor.append(buffer, withPresentationTime: CMTime(seconds: time - t0, preferredTimescale: 600)) { frames += 1 }
        }
    }

    /// Finish the file and add it to Photos. `done(ok, denied)` runs on an
    /// arbitrary queue.
    func finish(_ done: @escaping (_ ok: Bool, _ denied: Bool) -> Void) {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            input.markAsFinished()
            writer.finishWriting { [self] in
                let n = frames, url = self.url
                guard writer.status == .completed, n > 0 else {
                    print("[video] finish failed frames=\(n) \(writer.error.map { "\($0)" } ?? "")"); fflush(stdout)
                    done(false, false); return
                }
                print("[video] wrote \(n) frames"); fflush(stdout)
                #if targetEnvironment(simulator)
                // The sim can't answer the Photos prompt headless; keep a copy to inspect.
                let keep = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.copyItem(at: url, to: keep)
                #endif
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    guard status == .authorized || status == .limited else { done(false, true); return }
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
                    }) { ok, err in
                        print("[video] saved to Photos ok=\(ok) \(err.map { "\($0)" } ?? "")"); fflush(stdout)
                        try? FileManager.default.removeItem(at: url)
                        done(ok, false)
                    }
                }
            }
        }
    }
}
