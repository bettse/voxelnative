import SwiftUI
import UIKit
import GameController

// Shared state between the SwiftUI app and the Metal render loop.
@Observable
final class AppModel {
    let immersiveSpaceID = "ImmersiveSpace"
    let launcherWindowID = "launcher"
    enum ImmersiveSpaceState { case closed, inTransition, open }
    var immersiveSpaceState = ImmersiveSpaceState.closed
    // The system closed the world under us (Siri, the Digital Crown): the
    // layer was invalidated without the menu's Exit/Quit. The launcher reopens
    // it as soon as the app is active again, so it doesn't read as a crash.
    var resumeWorld = false
    @ObservationIgnored var exitingByUser = false   // set by Exit to menu / Quit before we close the space

    // True once the world has enough streamed + meshed to show something (the
    // first real block mesh was posted). The launcher keeps its spinner up and
    // stays in front of the loading immersive space until this flips, so the
    // user never stares at a bare skybox wondering if it broke. Set on the main
    // actor by WorldSession; reset by the launcher before each connect.
    var worldReady = false

    // Connection phase, driven by WorldSession, read by the launcher so the user
    // sees "Connecting…/Reconnecting…/failed" instead of a bare skybox when the
    // server is unreachable. `.playing` means the world is up; `.failed` carries a
    // human reason and stops the retry loop.
    enum ConnPhase: Equatable {
        case idle, connecting, streaming, playing
        case reconnecting(Int)
        case failed(String)
    }
    var connPhase: ConnPhase = .idle

    // Kogane menu -> leave the world. ContentView installs `onExit` (which
    // captures the window/immersive-space actions); calling it survives the
    // launcher window being dismissed while you're in the world.
    enum ExitKind: Equatable { case toMenu, quit }
    @ObservationIgnored var onExit: ((ExitKind) -> Void)?
    func requestExit(_ kind: ExitKind) {
        if let onExit { onExit(kind) } else { print("[exit] no handler for \(kind)"); fflush(stdout) }
    }

    // Live world: the renderer reads meshHandoff each frame; the session fills it.
    @ObservationIgnored let meshHandoff = MeshHandoff()
    @ObservationIgnored let entityHandoff = EntityHandoff()
    @ObservationIgnored let modelHandoff = ModelHandoff()
    @ObservationIgnored let modelTextureHandoff = ModelTextureHandoff()
    @ObservationIgnored let handHudHandoff = HandHudHandoff()
    @ObservationIgnored let skyboxHandoff = SkyboxHandoff()
    @ObservationIgnored let screenshotFlag = ScreenshotFlag()
    @ObservationIgnored let player = PlayerState()
    @ObservationIgnored lazy var session = WorldSession(handoff: meshHandoff, entityHandoff: entityHandoff, modelHandoff: modelHandoff, modelTextureHandoff: modelTextureHandoff, handHudHandoff: handHudHandoff, skyboxHandoff: skyboxHandoff, screenshotFlag: screenshotFlag, player: player)

    // The launcher refuses to connect until BOTH Sense controllers (or a
    // keyboard) are on. Mid-game, only losing ALL input drops back to the
    // launcher (after a short grace so a radio blip doesn't eject you): one
    // controller going to sleep just shows a notice, since the other still
    // walks or digs. It used to eject on either.
    var leftControllerOn = false
    var rightControllerOn = false
    var keyboardOn = false   // a BLE keyboard is an alternative to the Sense pair
    // Ready to play with either BOTH Sense controllers or a keyboard.
    var controllersReady: Bool { (leftControllerOn && rightControllerOn) || keyboardOn }
    var anyInput: Bool { leftControllerOn || rightControllerOn || keyboardOn }
    @ObservationIgnored private var controllersObserved = false
    @ObservationIgnored private var lossTimer: Timer?
    func observeControllers() {
        if controllersObserved { return }
        controllersObserved = true
        GCController.shouldMonitorBackgroundEvents = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.refreshControllers()
            GCController.startWirelessControllerDiscovery {}
        }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.refreshControllers()
        }
        // A BLE keyboard is an alternative to the Sense pair, so watch it too.
        nc.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.refreshControllers()
        }
        nc.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.refreshControllers()
        }
        GCController.startWirelessControllerDiscovery {}
        refreshControllers()
    }
    private func refreshControllers() {
        var l = false, r = false
        for c in GCController.controllers() {
            let v = (c.vendorName ?? "").lowercased()
            if v.contains("(l)") || v.contains("left") { l = true }
            else if v.contains("(r)") || v.contains("right") { r = true }
        }
        leftControllerOn = l; rightControllerOn = r
        keyboardOn = GCKeyboard.coalesced != nil
        print("[input] sense L=\(l) R=\(r) kbd=\(keyboardOn)"); fflush(stdout)
        lossTimer?.invalidate(); lossTimer = nil
        if controllersReady || (anyInput && immersiveSpaceState != .closed) {
            if lossCountdownShown { session.showControllerLoss(secondsLeft: nil); lossCountdownShown = false }
            if !controllersReady, immersiveSpaceState != .closed {
                session.showOneControllerMissing(left: !leftControllerOn)
            }
            return
        }
        guard immersiveSpaceState != .closed else { return }
        // Controllers gone mid-game: a visible countdown first (they often
        // come back within a second or two), and only leave if they don't.
        // The first second stays quiet so a radio blip doesn't flash a warning,
        // then 3-2-1 (Eric: 12 s was too long to stand there defenceless).
        var left = Self.lossGrace
        lossTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            guard !self.anyInput, self.immersiveSpaceState != .closed else {
                t.invalidate(); self.lossTimer = nil
                if self.lossCountdownShown { self.session.showControllerLoss(secondsLeft: nil); self.lossCountdownShown = false }
                return
            }
            left -= 1
            if left <= 0 {
                t.invalidate(); self.lossTimer = nil; self.lossCountdownShown = false
                print("[input] controllers lost for \(Self.lossGrace) s -> back to launcher"); fflush(stdout)
                // Exit to menu sends the server a goodbye, so the character
                // leaves the world at once instead of standing there for the
                // server's ~30 s timeout, where mobs could kill it.
                self.requestExit(.toMenu)
            } else if left <= Self.lossGrace - 1 {
                self.session.showControllerLoss(secondsLeft: left); self.lossCountdownShown = true
            }
        }
    }
    static let lossGrace = 4           // seconds without controllers before leaving the world
    @ObservationIgnored private var lossCountdownShown = false

    func startSession() { session.appModel = self; session.start() }
    func stopSession() { session.stop() }

    /// Disconnect cleanly when the app itself leaves (so the server frees our
    /// name immediately and a relaunch reconnects at once), and reconnect when
    /// it returns. These are APP-level notifications: unlike SwiftUI scenePhase,
    /// they do NOT fire when the immersive space opens (which just backgrounds
    /// the 2D window), so they don't thrash the live session.
    @ObservationIgnored private var lifecycleObserved = false
    func observeLifecycle() {
        if lifecycleObserved { return }
        lifecycleObserved = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            // stop() sends the disconnect on the session queue, but the OS can
            // suspend us the instant we background, before that UDP goodbye
            // flushes. Hold a short background-task assertion so the packet
            // actually leaves: then the server frees our name at once and a
            // relaunch reconnects instantly instead of waiting out its ~30s
            // peer timeout. (We deliberately do NOT keep the connection alive
            // in the background: a crash wouldn't send a goodbye anyway, so the
            // reconnect retry covers that case; this just makes the clean exit clean.)
            let app = UIApplication.shared
            var bg = UIBackgroundTaskIdentifier.invalid
            bg = app.beginBackgroundTask(withName: "voxel.disconnect") {
                if bg != .invalid { app.endBackgroundTask(bg); bg = .invalid }
            }
            self?.session.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if bg != .invalid { app.endBackgroundTask(bg); bg = .invalid }
            }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.session.start()
        }
        // Focus changes, timestamped, so a world the system closed can be lined
        // up with what the player was doing (it resigns active before it closes).
        for (name, label) in [(UIApplication.willResignActiveNotification, "will resign active"),
                              (UIApplication.didBecomeActiveNotification, "became active"),
                              (UIApplication.didEnterBackgroundNotification, "entered background")] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                print("[app] \(label) at=\(WorldSession.clockTime())"); fflush(stdout)
            }
        }
        // Log heat and memory changes as they happen (see WorldSession.healthNote).
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            print("[health] thermal changed \(WorldSession.healthNote()) at=\(WorldSession.clockTime())"); fflush(stdout)
        }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            print("[health] MEMORY WARNING \(WorldSession.healthNote()) at=\(WorldSession.clockTime())"); fflush(stdout)
        }
    }
}
