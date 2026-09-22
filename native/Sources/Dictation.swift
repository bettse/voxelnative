import Foundation
import Speech
import AVFoundation

/// On-device dictation for the in-game keyboard. The immersive Metal space has
/// no UIKit text field, so we can't borrow the system keyboard's dictation; this
/// drives the Speech framework directly and streams a live transcript.
///
/// Callbacks fire on the MAIN queue. The keyboard reads the transcript off its
/// own tick thread, so it copies the latest value under `lastTranscript` (guarded
/// by the caller) rather than mutating keyboard state from here.
final class Dictation {
    private let recognizer = SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private(set) var isRunning = false

    /// Latest transcript so far, plus whether it's a finalized segment (main-queue
    /// writes; read it however you marshal). isFinal means the recognizer closed
    /// this segment (a pause, or a punctuation word like "period"): the caller
    /// should bank that text so the next segment can't overwrite it.
    var onTranscript: ((String, Bool) -> Void)?
    /// Keep listening across segment finalizations by rolling a fresh recognition
    /// task instead of stopping, so a "period" or a pause doesn't end dictation.
    private var wantContinuous = false
    /// Fired when recognition stops (final result, error, or manual stop).
    var onStop: ((_ error: String?) -> Void)?

    /// Request mic + speech authorization, then start capturing. `completion`
    /// reports (started, reason-if-not) on the main queue.
    func start(completion: @escaping (Bool, String?) -> Void) {
        guard !isRunning else { completion(true, nil); return }
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else { completion(false, "speech auth: \(status.rawValue)"); return }
                AVAudioApplication.requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        guard granted else { completion(false, "mic denied"); return }
                        self.begin(completion: completion)
                    }
                }
            }
        }
    }

    private func begin(completion: (Bool, String?) -> Void) {
        guard let recognizer, recognizer.isAvailable else { completion(false, "recognizer unavailable"); return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch { completion(false, "audio session: \(error.localizedDescription)"); return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.request?.append(buf)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            completion(false, "audio engine: \(error.localizedDescription)"); return
        }
        isRunning = true
        wantContinuous = true
        startTask()
        completion(true, nil)
    }

    /// Open one recognition segment on the already-running engine. On a natural
    /// finalization we roll a fresh segment (keeping the tap and audio engine) so
    /// dictation continues; on error or a manual stop we tear everything down.
    /// The mic tap always appends into whatever `request` currently points at, so
    /// swapping the request mid-capture just redirects audio to the new segment.
    private func startTask() {
        guard let recognizer else { finish(error: "recognizer unavailable"); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Prefer on-device so dictation works offline and no audio leaves the
        // headset; fall back to server recognition where the model isn't present.
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                let final = result.isFinal
                DispatchQueue.main.async { self.onTranscript?(text, final) }
            }
            let done = error != nil || (result?.isFinal ?? false)
            guard done else { return }
            if error == nil, self.wantContinuous, self.isRunning {
                // Segment closed cleanly and we're still listening: roll a new one.
                DispatchQueue.main.async { self.rollTask() }
            } else {
                self.finish(error: error?.localizedDescription)
            }
        }
    }

    /// Close the finished segment's task/request and open the next, leaving the
    /// audio engine and mic tap untouched so no capture setup is lost.
    private func rollTask() {
        guard isRunning, wantContinuous else { return }
        task?.cancel()
        request?.endAudio()
        request = nil; task = nil
        startTask()
    }

    /// Stop capturing (keeps whatever was transcribed).
    func stop() { finish(error: nil) }

    private func finish(error: String?) {
        guard isRunning else { return }
        isRunning = false
        wantContinuous = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        DispatchQueue.main.async { self.onStop?(error) }
    }
}
