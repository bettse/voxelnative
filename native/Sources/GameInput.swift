import Foundation
import GameController
import SwiftUI
import CoreHaptics
import simd

/// Reads locomotion/action input from the PSVR2 Sense controllers via the Game
/// Controller framework. Two shapes seen on visionOS 26: both hands on before
/// launch arrive as ONE merged MFi gamepad (extendedGamepad, L/R sides); a hand
/// paired after launch arrives as its own "Spatial Controller" with no
/// extendedGamepad, only named elements. We poll the current state each frame
/// rather than using callbacks, so it stays in step with the tick.
///
/// Mapping: left stick = walk (x strafe, y forward), right stick x = turn,
/// left trigger = jump, left grip = sprint, left stick click = sneak,
/// right trigger = dig, right grip = place, right trigger + right grip together
/// = drop the wielded stack (WorldSession.gateDropChord), menu = exit, both
/// grips (left + right) = screenshot.
///
/// A BLE keyboard is an alternative to the controllers (gaze aims): WASD/arrows
/// move, Left/Right arrows turn, Space jump, Left-Shift sneak, Left-Ctrl sprint,
/// F dig, R place, E inventory, [ / ] hotbar, Esc menu, Enter confirm.
///
/// A BLE mouse/trackpad supplements either input: moving it turns the view (yaw),
/// left button digs, right button places. Vertical mouse motion is ignored -- the
/// tracked head owns pitch, so a software pitch would slide the aim off the view.
final class GameInput {
    struct State {
        var move = SIMD2<Float>(0, 0)
        var turn: Float = 0
        var dig = false
        var place = false
        var menu = false
        var jump = false
        var fast = false
        var sneak = false
        var snap = false        // both grips: take a screenshot
        var hotbarPrev = false  // LEFT face button (square / Button A on the left Sense)
        var hotbarNext = false  // LEFT face button (triangle / Button B on the left Sense)
        var inventory = false   // RIGHT O (Button B): toggle the inventory panel
        var koganeMenu = false  // RIGHT X (Button A): open the Kogane menu
        var dismissChat = false // RIGHT stick click: clear the join/chat lines
        var menuNavY: Float = 0 // EITHER stick Y, for menu navigation
        var menuSelect = false  // EITHER trigger, for menu confirm
        var lookYaw: Float = 0  // MOUSE X: a direct yaw delta (radians) this frame
        // Keyboard-only actions (desktop Luanti keys with no controller button):
        var drop = false        // Q: drop the wielded stack (sneak held: one item)
        var chat = false        // T: open chat
        var hotbarSlot = -1     // 1-9: select that hotbar slot (-1 = none)
        var panelTake = false   // Enter in a panel: left-click the gazed slot (take / put all)
        var panelOne = false    // Shift+Enter in a panel: right-click it (put one)
    }

    private(set) var connected = false
    private(set) var keyboardPresent = false   // a BLE keyboard is an alternate input (WASD etc.)
    private(set) var mousePresent = false       // a BLE mouse/trackpad turns + digs/places
    private var discoveryTimer: Timer?

    // One CHHapticEngine per connected controller, made from GCController.haptics
    // (the Game Controller framework's bridge to CoreHaptics). Empty if the Sense
    // exposes no haptics on visionOS -- rumble() then no-ops, so callers never
    // have to check (#357).
    private var hapticEngines: [ObjectIdentifier: CHHapticEngine] = [:]

    // Mouse movement is delivered ONLY through a callback (no pollable delta), so
    // accumulate deltas off whatever queue fires them and drain once per poll.
    private let mouseLock = NSLock()
    private var mouseAccumX: Float = 0
    // Button state latched from the press handlers: a trackpad click can come
    // and go between two polls, and the device may not be GCMouse.current.
    private var mouseLeftDown = false, mouseRightDown = false
    private var mouseLeftClicked = false, mouseRightClicked = false
    private var hookedMouse: GCMouse?
    private var mouseMoveLogged = false, mouseButtonLogged = false
    // Turn per unit of mouse deltaX. Tuned low; feels like a slow desktop sens
    // and is easy to bump on device if it's sluggish.
    private static let mouseYawPerDelta: Float = 0.0022

    init() {
        // Keep receiving controller input while the 2D window is backgrounded by
        // the open immersive space, and while a controller pairs mid-session.
        // Without this, a controller connected AFTER launch never reaches us.
        GCController.shouldMonitorBackgroundEvents = true
        let nc = NotificationCenter.default
        // Register the observers BEFORE starting discovery. If discovery starts
        // first, a controller that connects in the gap before we observe fires
        // its DidConnect into the void and we only catch it on the next refresh.
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            let c = note.object as? GCController
            print("[input] GCControllerDidConnect vendor=\(c?.vendorName ?? "?") cat=\(c?.productCategory ?? "?") ext=\(c?.extendedGamepad != nil)"); fflush(stdout)
            self?.assignPlayerIndices()
            self?.refresh()
            c.map { self?.setupHaptics($0) }
            // A controller can pair while discovery has stopped; restart it so
            // the next one (e.g. the second Sense controller) is found too.
            GCController.startWirelessControllerDiscovery {}
        }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            let c = note.object as? GCController
            print("[input] GCControllerDidDisconnect vendor=\(c?.vendorName ?? "?")"); fflush(stdout)
            if let c { self?.hapticEngines[ObjectIdentifier(c)]?.stop(); self?.hapticEngines[ObjectIdentifier(c)] = nil }
            self?.assignPlayerIndices()
            self?.refresh()
        }
        // Wake the framework so controllers/notifications start flowing, then
        // pick up anything already paired at launch.
        GCController.startWirelessControllerDiscovery {}
        refresh()
        GCController.controllers().forEach { setupHaptics($0) }   // haptics for anything paired at launch (#357)
        // Keep discovery alive: a second controller turned on well after the
        // first fired no connect in testing, and re-arming discovery gives it
        // (and any late pair) a fresh chance to surface.
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            let n = GCController.controllers().count
            if n < 2 {
                print("[input] re-arming discovery (have \(n))"); fflush(stdout)
                GCController.startWirelessControllerDiscovery {}
            }
        }
        // A BLE mouse/trackpad turns the view and digs/places. Movement only
        // comes through mouseMovedHandler, so attach it on connect (and to one
        // already paired at launch).
        nc.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
            (note.object as? GCMouse).map { self?.hookMouse($0) }
        }
        nc.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] note in
            if let self, (note.object as? GCMouse) === self.hookedMouse { self.hookedMouse = nil }
        }
        GCMouse.current.map { hookMouse($0) }
    }

    /// Accumulate mouse deltas off whatever queue the handler fires on; poll()
    /// drains them. Only deltaX is used (yaw turn); deltaY is dropped because the
    /// head owns pitch and a software pitch would slide the aim off the view.
    private func hookMouse(_ m: GCMouse) {
        hookedMouse = m
        m.mouseInput?.mouseMovedHandler = { [weak self] _, dx, dy in
            guard let self else { return }
            self.mouseLock.lock(); self.mouseAccumX += dx
            let first = !self.mouseMoveLogged; self.mouseMoveLogged = true
            self.mouseLock.unlock()
            if first { print("[input] mouse first move dx=\(dx) dy=\(dy)"); fflush(stdout) }
        }
        // Latch presses from the handlers so a quick tap-to-click registers even
        // if it's released before the next poll.
        m.mouseInput?.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.noteMouseButton(left: true, pressed: pressed)
        }
        m.mouseInput?.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.noteMouseButton(left: false, pressed: pressed)
        }
        print("[input] mouse hooked vendor=\(m.vendorName ?? "?") input=\(m.mouseInput != nil) right=\(m.mouseInput?.rightButton != nil)"); fflush(stdout)
    }

    private func noteMouseButton(left: Bool, pressed: Bool) {
        mouseLock.lock()
        if left { mouseLeftDown = pressed; if pressed { mouseLeftClicked = true } }
        else { mouseRightDown = pressed; if pressed { mouseRightClicked = true } }
        let first = !mouseButtonLogged; mouseButtonLogged = true
        mouseLock.unlock()
        if first { print("[input] mouse first button left=\(left) pressed=\(pressed)"); fflush(stdout) }
    }

    // MARK: - Haptics (#357)

    /// Build (once) a CoreHaptics engine for a controller, if it exposes haptics.
    /// The Sense may report no haptic locality through GameController on visionOS,
    /// in which case we log that and stay silent (no engine stored).
    private func setupHaptics(_ c: GCController) {
        let key = ObjectIdentifier(c)
        guard hapticEngines[key] == nil else { return }
        guard let hap = c.haptics else {
            print("[haptics] \(c.vendorName ?? "?"): no GCDeviceHaptics"); fflush(stdout); return
        }
        let localities = hap.supportedLocalities
        guard let engine = hap.createEngine(withLocality: .default) else {
            print("[haptics] \(c.vendorName ?? "?"): createEngine(.default) failed; localities=\(localities)"); fflush(stdout); return
        }
        // The engine can be stopped by the system (app backgrounded, route
        // change); restart it so the next rumble still fires.
        engine.stoppedHandler = { reason in print("[haptics] engine stopped: \(reason.rawValue)"); fflush(stdout) }
        engine.resetHandler = { [weak engine] in try? engine?.start() }
        do { try engine.start() } catch {
            print("[haptics] engine start failed: \(error)"); fflush(stdout); return
        }
        hapticEngines[key] = engine
        print("[haptics] engine ready for \(c.vendorName ?? "?") localities=\(localities)"); fflush(stdout)
    }

    /// Fire a short buzz on every connected controller. Safe to call from the
    /// game loop: it no-ops when no engine exists (unsupported Sense / sim).
    /// intensity/sharpness 0..1; a transient tap by default, a short continuous
    /// buzz when duration is given.
    func rumble(intensity: Float = 0.7, sharpness: Float = 0.5, duration: TimeInterval = 0) {
        // Game events fire on the session queue; the engines are made/mutated on
        // main (connect/disconnect), so hop to main to touch them safely.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hapticEngines.isEmpty else { return }
            let params = [CHHapticEventParameter(parameterID: .hapticIntensity, value: max(0, min(1, intensity))),
                          CHHapticEventParameter(parameterID: .hapticSharpness, value: max(0, min(1, sharpness)))]
            let event = duration > 0
                ? CHHapticEvent(eventType: .hapticContinuous, parameters: params, relativeTime: 0, duration: duration)
                : CHHapticEvent(eventType: .hapticTransient, parameters: params, relativeTime: 0)
            guard let pattern = try? CHHapticPattern(events: [event], parameters: []) else { return }
            for engine in self.hapticEngines.values {
                do {
                    let player = try engine.makePlayer(with: pattern)
                    try player.start(atTime: CHHapticTimeImmediate)
                } catch {
                    try? engine.start()   // was stopped; re-arm for next time
                }
            }
        }
    }

    /// Give every connected controller a distinct player index. Forcing them all
    /// to .index1 (the old behaviour) collides, and the second Sense controller
    /// never surfaced -- letting each claim its own slot is the fix to try.
    private func assignPlayerIndices() {
        let slots: [GCControllerPlayerIndex] = [.index1, .index2, .index3, .index4]
        for (i, c) in GCController.controllers().enumerated() {
            c.playerIndex = slots[min(i, slots.count - 1)]
        }
    }

    /// Best-effort left/right for a spatial Sense controller. GameController
    /// doesn't cleanly expose chirality on visionOS (only ARKit's
    /// AccessoryAnchor.chirality does), so check the vendor string first, then
    /// fall back to connection order when two controllers are on and neither is
    /// marked. A lone, unmarked controller stays "right" -- we never fabricate a
    /// left hand from a single device (that would be the single-controller mode
    /// we explicitly don't want).
    private func isLeftHand(_ c: GCController, index: Int, total: Int) -> Bool {
        let v = (c.vendorName ?? "").lowercased()
        if v.contains("(l)") || v.contains("left")  { return true }
        if v.contains("(r)") || v.contains("right") { return false }
        // No marker in the vendor string. With a pair present, the lower
        // player-index / first-seen device is the left hand.
        return total >= 2 && index == 0
    }

    private func refresh() {
        let cs = GCController.controllers()
        connected = !cs.isEmpty
        print("[input] controllers connected: \(cs.count)")
        for (i, c) in cs.enumerated() {
            let cat = c.productCategory
            let vendor = c.vendorName ?? "?"
            let hasExt = c.extendedGamepad != nil
            let elems = c.physicalInputProfile.elements.keys.sorted().joined(separator: ",")
            print("[input]  #\(i) vendor=\(vendor) cat=\(cat) extendedGamepad=\(hasExt)")
            print("[input]  #\(i) elements=[\(elems)]")
        }
        fflush(stdout)
    }

    private var pollDebug = 0

    /// Deadzoned, combined state across all connected controllers.
    func poll() -> State {
        var s = State()
        func dz(_ v: Float) -> Float { abs(v) < 0.15 ? 0 : v }
        let cs = GCController.controllers()
        pollDebug += 1
        let debug = pollDebug % 600 == 0   // ~ every 10s
        var leftGrip = false, rightGrip = false
        for (i, c) in cs.enumerated() {
            if let gp = c.extendedGamepad {
                // Both Sense controllers on before launch: one merged MFi gamepad,
                // each hand populating its own side.
                if debug {
                    print("[input] poll #\(i) ext L(\(gp.leftThumbstick.xAxis.value),\(gp.leftThumbstick.yAxis.value)) R(\(gp.rightThumbstick.xAxis.value),\(gp.rightThumbstick.yAxis.value)) lt=\(gp.leftTrigger.value) rt=\(gp.rightTrigger.value)")
                }
                let lx = dz(gp.leftThumbstick.xAxis.value)
                let ly = dz(gp.leftThumbstick.yAxis.value)
                let rx = dz(gp.rightThumbstick.xAxis.value)
                if lx != 0 { s.move.x = lx }
                if ly != 0 { s.move.y = ly }
                if rx != 0 { s.turn = rx }    // push right = turn right (the view frame mirrors Z, see PlayerState.bodyForward)
                // Match the Godot client's scheme: left hand = jump(trigger)/
                // sprint(grip)/sneak(stick-click), right hand = dig(trigger)/
                // place(grip).
                if gp.leftTrigger.value > 0.5 { s.jump = true }
                if gp.rightTrigger.value > 0.5 { s.dig = true }
                if gp.rightShoulder.isPressed { s.place = true; rightGrip = true }   // right grip
                if gp.leftShoulder.isPressed { s.fast = true; leftGrip = true }     // left grip = sprint
                if gp.leftThumbstickButton?.isPressed == true { s.sneak = true }
                if gp.buttonMenu.isPressed { s.menu = true }
                if gp.buttonX.isPressed { s.hotbarPrev = true }   // left square -> prev hotbar
                if gp.buttonY.isPressed { s.hotbarNext = true }   // left triangle -> next hotbar
                if gp.buttonB.isPressed { s.inventory = true }    // right O -> inventory
                if gp.buttonA.isPressed { s.koganeMenu = true }   // right X -> Kogane menu
                if gp.rightThumbstickButton?.isPressed == true { s.dismissChat = true }   // right stick click -> clear chat
                s.menuNavY = abs(ly) >= abs(dz(gp.rightThumbstick.yAxis.value)) ? ly : dz(gp.rightThumbstick.yAxis.value)
                if gp.leftTrigger.value > 0.5 || gp.rightTrigger.value > 0.5 { s.menuSelect = true }
                continue
            }
            // A Sense controller paired AFTER launch arrives on its own as a
            // "Spatial Controller" with no extendedGamepad, only per-hand
            // elements (Thumbstick, Trigger, Grip, Button A/B/Menu). Read those
            // by name; the hand comes from the vendor string "(L)" / "(R)".
            let p = c.physicalInputProfile
            let isLeft = isLeftHand(c, index: i, total: cs.count)
            let stick = p.dpads["Thumbstick"]
            let sx = dz(stick?.xAxis.value ?? 0), sy = dz(stick?.yAxis.value ?? 0)
            let trigger = (p.buttons["Trigger"]?.value ?? 0) > 0.5
            let grip = p.buttons["Grip"]?.isPressed == true
            if debug {
                print("[input] poll #\(i) spatial \(isLeft ? "L" : "R") stick(\(sx),\(sy)) trig=\(trigger) grip=\(grip) cat=\(c.productCategory)")
            }
            if abs(sy) > abs(s.menuNavY) { s.menuNavY = sy }   // either controller navigates the menu
            if trigger { s.menuSelect = true }
            if isLeft {
                if sx != 0 { s.move.x = sx }
                if sy != 0 { s.move.y = sy }
                if trigger { s.jump = true }
                if grip { s.fast = true; leftGrip = true }
                if p.buttons["Thumbstick Button"]?.isPressed == true { s.sneak = true }
                // A standalone left Sense labels its two face buttons "Button A"/
                // "Button B" (device-observed), but accept the PlayStation-glyph
                // names X/Y too so hotbar prev/next survive a future relabel (#81).
                if p.buttons["Button A"]?.isPressed == true || p.buttons["Button X"]?.isPressed == true { s.hotbarPrev = true }   // left square
                if p.buttons["Button B"]?.isPressed == true || p.buttons["Button Y"]?.isPressed == true { s.hotbarNext = true }   // left triangle
            } else {
                if sx != 0 { s.turn = sx }
                if trigger { s.dig = true }
                if grip { s.place = true; rightGrip = true }
                if p.buttons["Button B"]?.isPressed == true { s.inventory = true }    // right O
                if p.buttons["Button A"]?.isPressed == true { s.koganeMenu = true }   // right X
                if p.buttons["Thumbstick Button"]?.isPressed == true { s.dismissChat = true }   // right stick click -> clear chat
            }
            if p.buttons["Button Menu"]?.isPressed == true { s.menu = true }
        }
        if debug { fflush(stdout) }
        if leftGrip && rightGrip { s.snap = true }   // both grips = screenshot
        // A BLE keyboard is an alternative to the Sense controllers: gaze still
        // aims, the keyboard drives movement + actions. Applied after the sticks
        // so a key press wins only when actually held (either input works).
        if let kb = GCKeyboard.coalesced?.keyboardInput {
            @inline(__always) func k(_ c: GCKeyCode) -> Bool { kb.button(forKeyCode: c)?.isPressed ?? false }
            var mx: Float = 0, my: Float = 0, tn: Float = 0
            if k(.keyW) || k(.upArrow)   { my += 1 }   // forward
            if k(.keyS) || k(.downArrow) { my -= 1 }   // back
            if k(.keyA) { mx -= 1 }                     // strafe left
            if k(.keyD) { mx += 1 }                     // strafe right
            if k(.leftArrow)  { tn -= 1 }               // turn left
            if k(.rightArrow) { tn += 1 }               // turn right
            if mx != 0 { s.move.x = mx }
            if my != 0 { s.move.y = my; s.menuNavY = my }
            if tn != 0 { s.turn = tn }
            // Desktop Luanti's default keys (defaultsettings.cpp), so desktop
            // habits carry over: E is aux1 (VoxeLibre sprint), I the inventory,
            // Q drop, T chat, 1-9 / B / N the hotbar. F and R stand in for the
            // mouse buttons (the trackpad doesn't reach the game), Left Control
            // sprints too, and [ ] still step the hotbar.
            let shift = k(.leftShift) || k(.rightShift)
            if k(.spacebar)     { s.jump = true }
            if shift            { s.sneak = true }
            if k(.keyE) || k(.leftControl) { s.fast = true }
            if k(.keyF)         { s.dig = true }         // attack / mine (gaze-aimed)
            if k(.keyR)         { s.place = true }       // place / use
            if k(.keyI)         { s.inventory = true }   // toggle inventory
            if k(.keyQ)         { s.drop = true }
            if k(.keyT)         { s.chat = true }
            // Esc opens/closes the Kogane menu (the keyboard has no right X) and
            // still cancels: it closes the inventory or the text keyboard first.
            if k(.escape)       { s.menu = true; s.koganeMenu = true }
            if k(.openBracket) || k(.keyB)  { s.hotbarPrev = true }
            if k(.closeBracket) || k(.keyN) { s.hotbarNext = true }
            let digits: [GCKeyCode] = [.one, .two, .three, .four, .five, .six, .seven, .eight, .nine]
            if let n = digits.firstIndex(where: { k($0) }) { s.hotbarSlot = n }
            if k(.keyF) || k(.returnOrEnter) { s.menuSelect = true }  // confirm in menus
            // Enter clicks the gazed inventory slot: plain = take / put the whole
            // stack, Shift = put one (desktop's left / right click).
            if k(.returnOrEnter) { if shift { s.panelOne = true } else { s.panelTake = true } }
            keyboardPresent = true
        } else {
            keyboardPresent = false
        }
        // A BLE mouse/trackpad: deltaX (drained from the handler) turns the view,
        // left button digs, right button places. deltaY is intentionally ignored
        // (the head owns pitch). Works alongside a keyboard or the controllers.
        if let mi = (hookedMouse ?? GCMouse.current)?.mouseInput {
            mouseLock.lock()
            let dx = mouseAccumX; mouseAccumX = 0
            // Held, or pressed at any point since the last poll.
            let left = mouseLeftDown || mouseLeftClicked || mi.leftButton.isPressed
            let right = mouseRightDown || mouseRightClicked || mi.rightButton?.isPressed == true
            mouseLeftClicked = false; mouseRightClicked = false
            mouseLock.unlock()
            if dx != 0 { s.lookYaw = dx * Self.mouseYawPerDelta }
            if left  { s.dig = true; s.menuSelect = true }
            if right { s.place = true }
            mousePresent = true
        } else {
            mousePresent = false
        }
        // Trackpad clicks that arrive as spatial pointer events (the route
        // visionOS actually uses in an immersive space) dig / confirm too.
        if PointerInput.shared.take() { s.dig = true; s.menuSelect = true }
        return s
    }
}

/// Trackpad/mouse clicks as visionOS delivers them to a full immersive space:
/// as spatial events on the LayerRenderer (kind .pointer), not through
/// GCMouse, which never fired for Eric's keyboard trackpad. The renderer's
/// onSpatialEvent writes here; GameInput.poll reads it like a mouse button.
final class PointerInput: @unchecked Sendable {
    static let shared = PointerInput()
    private let lock = NSLock()
    private var down = false, clicked = false
    private var seenKinds = Set<String>()

    /// Called on the main actor from LayerRenderer.onSpatialEvent.
    func handle(_ events: SpatialEventCollection) {
        for e in events {
            let kind = "\(e.kind)"
            lock.lock()
            let first = seenKinds.insert(kind).inserted
            lock.unlock()
            if first { print("[input] first spatial event kind=\(kind) phase=\(e.phase)"); fflush(stdout) }
            guard e.kind == .pointer else { continue }
            lock.lock()
            switch e.phase {
            case .active: down = true; clicked = true
            default: down = false
            }
            lock.unlock()
        }
    }

    /// Held, or clicked since the last read (a quick tap still counts once).
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let v = down || clicked
        clicked = false
        return v
    }
}
