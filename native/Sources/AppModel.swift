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

    // PSVR2 Sense controllers are the only input, so the launcher refuses to
    // connect until BOTH are on, and losing either mid-game drops back to the
    // launcher (after a short grace so a radio blip doesn't eject you).
    var leftControllerOn = false
    var rightControllerOn = false
    var keyboardOn = false   // a BLE keyboard is an alternative to the Sense pair
    // Ready to play with either BOTH Sense controllers or a keyboard.
    var controllersReady: Bool { (leftControllerOn && rightControllerOn) || keyboardOn }
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
        if !controllersReady, immersiveSpaceState != .closed {
            lossTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                guard let self, !self.controllersReady, self.immersiveSpaceState != .closed else { return }
                print("[input] controller lost in-game -> back to launcher"); fflush(stdout)
                self.requestExit(.toMenu)
            }
        }
    }

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
    }
}
