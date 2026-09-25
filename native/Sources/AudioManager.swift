import Foundation
import AVFoundation
import LuantiKit

/// Per-channel volume model. Master gain times a category gain (music vs sfx),
/// backed by UserDefaults so a chosen mix survives relaunch. Sensible defaults
/// (everything at 1.0) so a fresh install just plays. No settings UI yet — this
/// is the code-level model a future slider panel would bind to.
/// Display/system toggles (UserDefaults-backed like VolumeSettings) so a
/// future in-headset options menu can flip them.
final class DisplaySettings {
    static let shared = DisplaySettings()
    private let defaults = UserDefaults.standard
    /// hide visionOS's persistent system overlays in the immersive space
    /// (the circle/menu affordance that appears when you look at a Sense
    /// controller). Default on; read once when the scene is built.
    var hideSystemOverlays: Bool {
        get { defaults.object(forKey: "display.hideSystemOverlays") == nil ? true : defaults.bool(forKey: "display.hideSystemOverlays") }
        set { defaults.set(newValue, forKey: "display.hideSystemOverlays") }
    }
}

/// View distance in mapblocks (UserDefaults-backed, like VolumeSettings). Drives
/// the client's wanted_range in PLAYERPOS: lower = the server streams and the
/// client meshes fewer blocks, trading draw distance for a lighter GPU/thermal
/// load. Clamped to a sane band.
final class ViewSettings {
    static let shared = ViewSettings()
    static let minBlocks = 3, maxBlocks = 12, defaultBlocks = 8
    private let defaults = UserDefaults.standard
    private let key = "view.blocks"
    var blocks: Int {
        get {
            guard defaults.object(forKey: key) != nil else { return Self.defaultBlocks }
            return max(Self.minBlocks, min(Self.maxBlocks, defaults.integer(forKey: key)))
        }
        set { defaults.set(max(Self.minBlocks, min(Self.maxBlocks, newValue)), forKey: key) }
    }
}

final class VolumeSettings {
    static let shared = VolumeSettings()

    enum Channel: String { case master, music, sfx }

    private let defaults = UserDefaults.standard
    private func key(_ c: Channel) -> String { "vol.\(c.rawValue)" }

    private func get(_ c: Channel) -> Float {
        // Absent key -> default: music off for now (Eric asked), everything else full.
        // (object(forKey:) is nil when unset, not 0.)
        guard defaults.object(forKey: key(c)) != nil else { return c == .music ? 0 : 1 }
        return max(0, min(1, defaults.float(forKey: key(c))))
    }
    private func set(_ c: Channel, _ v: Float) { defaults.set(max(0, min(1, v)), forKey: key(c)) }

    // -vrdev.mute 1 silences everything: sim.sh sets it so a headless build+shot
    // run doesn't blast game audio through the Mac speakers (Eric).
    var master: Float { get { defaults.bool(forKey: "vrdev.mute") ? 0 : get(.master) } set { set(.master, newValue) } }
    var music: Float { get { get(.music) } set { set(.music, newValue) } }
    var sfx: Float { get { get(.sfx) } set { set(.sfx, newValue) } }

    /// Which channel a sound belongs to. Only real background-music tracks go to
    /// the music channel (Eric mutes it); everything else -- including 2D
    /// non-positional GAMEPLAY sfx (achievement, level-up, UI), which Luanti also
    /// sends as type 0 -- goes to sfx, so they aren't silenced. Classifying every
    /// 2D sound as music (the old rule) muted those (an award sound logged
    /// channel=music vol=0). VoxeLibre's mcl_music tracks are artist-prefixed
    /// ("DarkReaven-...") with no "music" in the name, so match that plus the
    /// generic music/record hints.
    func channel(forName name: String, type: Int) -> Channel {
        let n = name.lowercased()
        return (n.contains("music") || n.contains("record") || n.hasPrefix("darkreaven")) ? .music : .sfx
    }

    /// Linear volume for a resolved channel: base gain scaled by the master and
    /// per-category sliders, clamped to AVAudioPlayer's 0...1.
    func volume(base: Float, channel: Channel) -> Float {
        let catGain = channel == .music ? music : sfx
        return max(0, min(1, base * master * catGain))
    }

    /// Convenience: classify then scale in one step.
    func effectiveVolume(base: Float, name: String, type: Int) -> Float {
        volume(base: base, channel: channel(forName: name, type: type))
    }
}

/// Plays server-driven sounds through AVAudioEngine so positional sounds are
/// real 3D sources (AVAudioEnvironmentNode, HRTF) and pitch is a true playback
/// rate change (AVAudioUnitVarispeed), matching Luanti's OpenAL setup:
/// AL_INVERSE_DISTANCE_CLAMPED with reference distance 1 node, positional
/// gain x3 (PlayingSound::setGain), 2D sounds straight to the mixer.
/// Graph per sound: player -> varispeed -> environment (3D) | mixer (2D).
/// All access is serialized on a private queue.
final class AudioManager: NSObject {
    private let q = DispatchQueue(label: "audio.manager")
    private let engine = AVAudioEngine()
    private let env = AVAudioEnvironmentNode()
    // 2D (non-positional) sounds mix through their own submixer. Connecting a
    // 2D source straight to mainMixerNode silently dropped the env ->
    // mainMixer link (its outputConnectionPoints went to 0), and the next
    // positional play() raised 'player started when in a disconnected state'
    // -- an NSException Swift can't catch, so the app died. With the
    // submixer, per-sound connects never touch the bus the environment uses.
    private let flat = AVAudioMixerNode()
    private final class Source {
        let player = AVAudioPlayerNode()
        let speed = AVAudioUnitVarispeed()
        let positional: Bool
        var channel: VolumeSettings.Channel
        var baseVolume: Float
        var fadeTimer: DispatchSourceTimer?
        var format: AVAudioFormat?              // what the chain is currently connected with
        var generation = 0                      // bumped per play; a stale completion must not finish the next sound
        // Gain above 1 (thunder is 10, fireworks 3-4): the engine gives
        // min(1, 3*gain/d), but a player volume caps at 1 and the environment's
        // reference distance is shared. So the source sits `boost` times nearer
        // along the line to the listener, which is the same curve.
        var boost: Float = 1
        var truePos = SIMD3<Float>(0, 0, 0)
        init(positional: Bool, channel: VolumeSettings.Channel, baseVolume: Float) {
            self.positional = positional; self.channel = channel; self.baseVolume = baseVolume
        }
    }
    private var sources: [Int: Source] = [:]      // server sound id -> source
    private var oneShots: [ObjectIdentifier: Source] = [:]
    // Decoded PCM by "<file>|mono". Every VoxeLibre sfx is a few hundred KB
    // decoded and footsteps fire 3-4 times a second, so decoding Ogg through a
    // temp WAV per play was the largest sustained CPU cost outside the tick.
    // Music tracks (20 s+) aren't cached: they're tens of MB each and rare.
    private var pcmCache: [String: AVAudioPCMBuffer] = [:]
    private var pcmCacheOrder: [String] = []       // insertion order for a simple cap
    private static let pcmCacheMax = 160           // ~15-20 MB of sfx
    // Idle player->varispeed chains kept attached and wired to their stage, so
    // a play is a scheduleBuffer + play() instead of attach x2 / connect x2 /
    // detach x2 (each a graph edit under the engine's lock).
    private var idle3D: [Source] = [], idle2D: [Source] = []
    private static let poolMax = 12
    private var engineStarted = false
    private var playLogged = Set<String>()   // sound names already logged (q only)
    private var sessionReady = false

    override init() {
        super.init()
        configureSession()
        q.async { [weak self] in self?.startEngine() }
    }

    private func configureSession() {
        #if os(visionOS) || os(iOS)
        do {
            let s = AVAudioSession.sharedInstance()
            // .ambient: mixes with other audio, respects the silent switch — right
            // for game ambience/sfx. .playback would duck others; not wanted here.
            try s.setCategory(.ambient, options: [.mixWithOthers])
            try s.setActive(true)
            sessionReady = true
            print("[audio] session active (ambient, mixWithOthers)"); fflush(stdout)
        } catch {
            print("[audio] session config failed: \(error)"); fflush(stdout)
        }
        #else
        sessionReady = true
        #endif
    }

    private func startEngine() {
        guard !engineStarted else { return }
        engine.attach(env)
        // Luanti: AL_INVERSE_DISTANCE_CLAMPED with reference 1 node, but it
        // sets the SOURCE gain to 3x and OpenAL clamps only the final result,
        // so a gain-1 sound is full volume out to 3 nodes and then 3/d. AVAudio
        // clamps the player volume at 1 before attenuating, which made sounds
        // fade ~3x too fast (a third at 3 nodes). A 3-node reference
        // distance gives the same min(1, 3/d) curve for gain 1 (the common
        // case); low-gain sounds carry a little farther than desktop, high-gain
        // ones (lightning) a little less.
        env.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        env.distanceAttenuationParameters.referenceDistance = 3
        env.distanceAttenuationParameters.rolloffFactor = 1
        env.distanceAttenuationParameters.maximumDistance = 1000
        env.renderingAlgorithm = .HRTFHQ
        env.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
        engine.attach(flat)
        engine.connect(env, to: engine.mainMixerNode, format: stereo)
        engine.connect(flat, to: engine.mainMixerNode, format: stereo)
        // Sim runs pipe game sound to the Mac speakers: -vrdev.mute silences the
        // final mix too, not just the per-sound gain, so no path leaks through.
        if UserDefaults.standard.bool(forKey: "vrdev.mute") { engine.mainMixerNode.outputVolume = 0 }
        do {
            try engine.start()
            engineStarted = true
            print("[audio] engine started (HRTF 3D + varispeed pitch)"); fflush(stdout)
        } catch {
            print("[audio] engine start failed: \(error)"); fflush(stdout)
        }
    }

    /// Listener = the player's head, in Luanti node space (left-handed).
    /// AVAudio's frame is right-handed (-Z forward), so Z flips, the same
    /// mirror the renderer applies to the world.
    // Last pose handed to the engine: skip the per-tick dispatch (a closure
    // context + a queue wake at 62 Hz) while the head hasn't moved.
    private var lastListenerPos = SIMD3<Float>(repeating: .nan)
    private var lastListenerFwd = SIMD3<Float>(repeating: .nan)
    func setListener(pos: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>) {
        if simd_length_squared(pos - lastListenerPos) < 1e-6, simd_length_squared(forward - lastListenerFwd) < 1e-6 { return }
        lastListenerPos = pos; lastListenerFwd = forward
        q.async { [weak self] in
            guard let self, self.engineStarted else { return }
            self.env.listenerPosition = AVAudio3DPoint(x: pos.x, y: pos.y, z: -pos.z)
            self.listenerPos = pos
            for src in self.sources.values where src.boost > 1 { self.place(src) }
            for src in self.oneShots.values where src.boost > 1 { self.place(src) }
            self.env.listenerVectorOrientation = AVAudio3DVectorOrientation(
                forward: AVAudio3DVector(x: forward.x, y: forward.y, z: -forward.z),
                up: AVAudio3DVector(x: up.x, y: up.y, z: -up.z))
        }
    }

    /// Move a playing positional sound (object-attached sounds follow their mob).
    func setPosition(id: Int, pos: SIMD3<Float>) {
        q.async { [weak self] in
            guard let self, let src = self.sources[id], src.positional else { return }
            src.truePos = pos
            self.place(src)
        }
    }

    private var listenerPos = SIMD3<Float>(0, 0, 0)   // audio queue copy, for boosted sources
    private func place(_ src: Source) {
        let p = src.boost > 1 ? listenerPos + (src.truePos - listenerPos) / src.boost : src.truePos
        src.player.position = AVAudio3DPoint(x: p.x, y: p.y, z: -p.z)
    }

    /// Decode .ogg -> PCM buffer via a temp WAV (AVAudioFile can't read Ogg).
    /// Positional sources must be mono for the environment node to place them.
    private func pcmBuffer(_ ogg: Data, mono: Bool) -> AVAudioPCMBuffer? {
        guard let wav = Vorbis.decodeToWAV(ogg) else { return nil }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snd-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try wav.write(to: url)
            let file = try AVAudioFile(forReading: url)
            let fmt = file.processingFormat
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
            try file.read(into: buf)
            if mono, fmt.channelCount > 1, let mfmt = AVAudioFormat(standardFormatWithSampleRate: fmt.sampleRate, channels: 1),
               let mbuf = AVAudioPCMBuffer(pcmFormat: mfmt, frameCapacity: buf.frameLength),
               let src = buf.floatChannelData, let dst = mbuf.floatChannelData {
                let n = Int(buf.frameLength), ch = Int(fmt.channelCount)
                for i in 0..<n {
                    var acc: Float = 0
                    for c in 0..<ch { acc += src[c][i] }
                    dst[0][i] = acc / Float(ch)
                }
                mbuf.frameLength = buf.frameLength
                return mbuf
            }
            return buf
        } catch {
            print("[audio] wav load failed: \(error)"); fflush(stdout)
            return nil
        }
    }

    /// Start a sound. `pos` (node coords) makes it a 3D source; nil = 2D.
    /// `file` is the resolved media name, the decoded-PCM cache key.
    func play(spec: SoundSpec, data: Data, file: String = "", pos: SIMD3<Float>? = nil) {
        q.async { [weak self] in
            guard let self, self.engineStarted else { return }
            var channel = VolumeSettings.shared.channel(forName: spec.name, type: spec.type)
            let positional = pos != nil
            // Luanti multiplies positional gain by 3 (see the 3-node reference
            // distance in startEngine); the clamp to 1 below is the near-field
            // ceiling, the distance curve does the rest.
            // Gain above 1 is carried by the source's distance boost instead
            // (see Source.boost), so the sliders still scale it.
            let base = positional && spec.gain > 1 ? 1 : spec.gain * (positional ? 3 : 1)
            var vol = VolumeSettings.shared.volume(base: base, channel: channel)
            // A muted channel (music off, master 0) must be SILENT. Setting the
            // player volume to 0 didn't reliably silence a long music track on
            // device (Eric kept hearing the background music), so don't schedule
            // it at all -- also saves decoding a multi-MB ogg. A fade-in still
            // starts at 0, so only skip when there's no fade ramp coming.
            if vol <= 0, spec.fade <= 0 {
                print("[audio] skip muted id=\(spec.id) name=\(spec.name) channel=\(channel.rawValue)"); fflush(stdout)
                return
            }
            let cacheKey = file.isEmpty ? "" : "\(file)|\(positional)"
            var buf: AVAudioPCMBuffer
            if !cacheKey.isEmpty, let cached = self.pcmCache[cacheKey] {
                buf = cached
            } else {
                guard let decoded = self.pcmBuffer(data, mono: positional) else {
                    print("[audio] vorbis decode failed id=\(spec.id) name=\(spec.name)"); fflush(stdout)
                    return
                }
                buf = decoded
                let secs = buf.format.sampleRate > 0 ? Double(buf.frameLength) / buf.format.sampleRate : 0
                if !cacheKey.isEmpty, secs < 20 {
                    if self.pcmCacheOrder.count >= Self.pcmCacheMax, let oldest = self.pcmCacheOrder.first {
                        self.pcmCacheOrder.removeFirst(); self.pcmCache[oldest] = nil
                    }
                    self.pcmCache[cacheKey] = buf; self.pcmCacheOrder.append(cacheKey)
                }
            }
            // Length-based music classification (Eric): every VoxeLibre sfx is
            // <=9s, while music/jukebox/theme tracks run 66s+. So any long track
            // is musical regardless of name -- this catches mcl_music (diminixed-,
            // Jester-, Herowl-, ... which the name hint missed and leaked past the
            // music mute), jukebox discs, and theme.ogg. Re-decide by duration and
            // re-apply the mute so a muted music channel is actually silent.
            let seconds = buf.format.sampleRate > 0 ? Double(buf.frameLength) / buf.format.sampleRate : 0
            if seconds >= 20, channel != .music {
                channel = .music
                vol = VolumeSettings.shared.volume(base: base, channel: .music)
                if vol <= 0, spec.fade <= 0 {
                    print("[audio] skip long-track muted id=\(spec.id) name=\(spec.name) sec=\(Int(seconds))"); fflush(stdout)
                    return
                }
            }
            let src: Source
            if let pooled = positional ? self.idle3D.popLast() : self.idle2D.popLast() {
                src = pooled
                src.channel = channel; src.baseVolume = vol
                // Re-wire only when the buffer's format differs from what the
                // chain was last connected with (mono 44.1k for every 3D sfx).
                // connect() raises an uncatchable NSException on a format the
                // graph won't take (error -10868 after a session interruption /
                // route change) -- catch it so a bad sound drops, not the app.
                if src.format != buf.format {
                    if let err = VNCatchNSException({
                        self.engine.connect(src.player, to: src.speed, format: buf.format)
                        self.engine.connect(src.speed, to: positional ? self.env : self.flat, format: buf.format)
                    }) {
                        print("[audio] connect failed (pooled), dropped id=\(spec.id) name=\(spec.name): \(err)"); fflush(stdout)
                        self.safeDetach(src.player, src.speed)
                        return
                    }
                    src.format = buf.format
                }
            } else {
                src = Source(positional: positional, channel: channel, baseVolume: vol)
                self.engine.attach(src.player); self.engine.attach(src.speed)
                if let err = VNCatchNSException({
                    self.engine.connect(src.player, to: src.speed, format: buf.format)
                    self.engine.connect(src.speed, to: positional ? self.env : self.flat, format: buf.format)
                }) {
                    print("[audio] connect failed (new), dropped id=\(spec.id) name=\(spec.name): \(err)"); fflush(stdout)
                    self.safeDetach(src.player, src.speed)
                    return
                }
                src.format = buf.format
                if positional { src.player.renderingAlgorithm = .HRTFHQ }
            }
            src.boost = positional ? max(1, spec.gain) : 1
            if positional, let p = pos { src.truePos = p; self.place(src) }
            src.speed.rate = max(0.25, min(4.0, spec.pitch))   // AL_PITCH = playback rate; varispeed range, fireworks use 2-3
            src.player.volume = spec.fade > 0 ? 0 : vol
            let key = ObjectIdentifier(src)
            src.generation += 1
            let gen = src.generation
            src.player.scheduleBuffer(buf, at: nil, options: spec.loop ? [.loops] : []) { [weak self] in
                guard !spec.loop else { return }
                // A stop() also fires this; by then the chain may be back in the
                // pool and playing something else. Only the play that scheduled
                // this buffer may finish it.
                self?.q.async { guard src.generation == gen else { return }; self?.finish(src, key: key) }
            }
            // AVAudioPlayerNode.play() raises (SIGABRT, uncatchable in Swift) if
            // the engine isn't RUNNING — engineStarted is a once-set flag, but the
            // engine can stop on an audio-session interruption or route change. A
            // chest-open sound firing then aborted the app. Ensure it's running;
            // if it won't restart, drop the sound cleanly and detach the nodes.
            if !self.engine.isRunning {
                do { try self.engine.start() }
                catch {
                    print("[audio] engine down, dropped id=\(spec.id) name=\(spec.name): \(error)"); fflush(stdout)
                    self.safeDetach(src.player, src.speed)
                    return
                }
            }
            // play() raises an uncatchable NSException if the path from the
            // player to the output is broken anywhere. Check the whole chain
            // first; try to re-link a dropped submixer/environment, and if a
            // link is still missing drop this sound instead of the app.
            let stage = positional ? self.env : self.flat
            if self.engine.outputConnectionPoints(for: stage, outputBus: 0).isEmpty {
                print("[audio] \(positional ? "environment" : "2D mixer") lost its output link; reconnecting"); fflush(stdout)
                if let err = VNCatchNSException({
                    self.engine.connect(stage, to: self.engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
                }) {
                    print("[audio] stage reconnect failed, dropped id=\(spec.id) name=\(spec.name): \(err)"); fflush(stdout)
                    self.safeDetach(src.player, src.speed)
                    return
                }
            }
            if self.engine.outputConnectionPoints(for: src.player, outputBus: 0).isEmpty
                || self.engine.outputConnectionPoints(for: src.speed, outputBus: 0).isEmpty
                || self.engine.outputConnectionPoints(for: stage, outputBus: 0).isEmpty {
                print("[audio] graph incomplete, dropped id=\(spec.id) name=\(spec.name) 3d=\(positional)"); fflush(stdout)
                self.safeDetach(src.player, src.speed)
                return
            }
            src.player.play()
            // Ephemeral sounds arrive with id -1 (server.cpp: every sound_play
            // without a handle) and the engine treats them as fire-and-forget
            // (clientpackethandler.cpp). Keying them by id made every ephemeral
            // replace the previous one: a door click cut off a mob call, a
            // footstep cut off the dug sound. Only real handles (> 0)
            // are tracked for STOP/FADE.
            // Ids <= -1000 are local handles WorldSession gives one-shots attached
            // to a mob, so the sound can follow it; they're never reported back.
            if spec.id > 0 || spec.id <= -1000 {
                if let old = self.sources[spec.id] { self.tearDown(old) }   // replace any prior sound on this id
                self.sources[spec.id] = src
            } else {
                self.oneShots[key] = src
            }
            if spec.fade > 0 { self.ramp(src, to: vol, step: spec.fade) }
            // Once per sound name: footsteps and dig sounds alone were ~2000
            // lines of a 30-minute device log.
            if self.playLogged.insert(spec.name).inserted {
                print("[audio] playing id=\(spec.id) name=\(spec.name) channel=\(channel.rawValue) vol=\(vol) 3d=\(positional) pitch=\(spec.pitch) loop=\(spec.loop)"); fflush(stdout)
            }
        }
    }

    /// A server-handled (id > 0) sound ran to its end on its own. WorldSession
    /// reports these as TOSERVER_REMOVED_SOUNDS. Called on the audio queue.
    var onFinished: ((Int) -> Void)?

    private func finish(_ src: Source, key: ObjectIdentifier) {
        if oneShots.removeValue(forKey: key) != nil { tearDown(src); return }
        if let id = sources.first(where: { $0.value === src })?.key {
            sources.removeValue(forKey: id); tearDown(src)
            onFinished?(id)
        }
    }

    /// Detaching a node whose connect just failed can ITSELF raise an AVAudio
    /// NSException: after a -10868 format reject (audio-session interruption /
    /// route change) the engine is in a bad state, and the cleanup detach used
    /// to run outside the catch. So "connect failed ... dropped" logged, then
    /// the very next detach aborted the app -- Eric's tunnel crash right after a
    /// level-up sound while mining coal. Catch the detach too so a bad sound
    /// truly drops instead of crashing (follow-up).
    private func safeDetach(_ nodes: AVAudioNode...) {
        for n in nodes {
            if let err = VNCatchNSException({ self.engine.detach(n) }) {
                print("[audio] detach raised (ignored): \(err)"); fflush(stdout)
            }
        }
    }

    private func tearDown(_ src: Source) {
        src.fadeTimer?.cancel(); src.fadeTimer = nil
        src.player.stop()
        src.player.volume = 1; src.speed.rate = 1
        // Park the chain for reuse instead of detaching (graph edit + realloc
        // per sound); past the pool cap it's detached as before.
        if src.positional {
            if idle3D.count < Self.poolMax { idle3D.append(src); return }
        } else {
            if idle2D.count < Self.poolMax { idle2D.append(src); return }
        }
        safeDetach(src.player, src.speed)
    }

    /// Stop every tracked sound (a reconnect: the server won't stop the old
    /// session's loops, like rain).
    func stopAll() {
        q.async { [weak self] in
            guard let self else { return }
            for src in self.sources.values { self.tearDown(src) }
            self.sources.removeAll()
        }
    }

    /// Stop a sound by its server id (TOCLIENT_STOP_SOUND).
    func stop(id: Int) {
        q.async { [weak self] in
            guard let self, let src = self.sources.removeValue(forKey: id) else { return }
            self.tearDown(src)
            print("[audio] stopped id=\(id)"); fflush(stdout)
        }
    }

    /// Linear volume ramp at `step` gain/second (Luanti's fade semantics); a
    /// ramp to silence stops and drops the source.
    private func ramp(_ src: Source, to target: Float, step: Float) {
        src.fadeTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: q)
        let tick: Float = 0.05
        t.schedule(deadline: .now(), repeating: .milliseconds(50))
        t.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            let v = src.player.volume
            let next = v < target ? min(target, v + abs(step) * tick) : max(target, v - abs(step) * tick)
            src.player.volume = next
            if abs(next - target) < 1e-4 {
                src.fadeTimer?.cancel(); src.fadeTimer = nil
                if target <= 0.001, let id = self.sources.first(where: { $0.value === src })?.key {
                    self.sources.removeValue(forKey: id); self.tearDown(src)
                }
            }
        }
        src.fadeTimer = t
        t.resume()
    }

    /// Fade a sound toward a target gain (TOCLIENT_FADE_SOUND).
    func fade(id: Int, step: Float, gain: Float) {
        q.async { [weak self] in
            guard let self, let src = self.sources[id] else { return }
            let target = VolumeSettings.shared.volume(base: gain * (src.positional ? 3 : 1), channel: src.channel)
            print("[audio] fade id=\(id) -> \(target) at \(step)/s"); fflush(stdout)
            self.ramp(src, to: target, step: step == 0 ? 1e6 : step)
        }
    }
}
