import Foundation
import os
import simd
import LuantiKit

/// Thread-safe player pose shared between the session thread (integrates
/// movement, sends PLAYERPOS) and the render thread (places the camera).
/// All positions are in node coordinates (1 node = 1 m in-world).
final class PlayerState {
    static let eyeHeight: Float = 1.5   // default before the server's eye_height arrives
    // Server eye_height for our own AO: 1.6 standing, 1.45 sneaking, 0.6
    // swimming in VoxeLibre. Eased over ~0.15 s so the view glides down into
    // the water instead of snapping a metre.
    private var _eyeTarget: Float = PlayerState.eyeHeight
    private var _eyeSmooth: Float = PlayerState.eyeHeight
    private var _eyeStamp = Date()
    private var _eyeBase: Float = PlayerState.eyeHeight   // SET_PROPERTIES eye_height
    private var _eyeOffsetY: Float = 0                     // TOCLIENT_EYE_OFFSET first-person y
    func setEyeHeight(_ h: Float) { lock.lock(); _eyeBase = h; _eyeTarget = max(0.2, _eyeBase + _eyeOffsetY); lock.unlock() }
    /// Camera::update adds the server's first-person eye offset on top of
    /// eye_height: beds send y -1.3 nodes for the lying-down view, minecarts
    /// and sitting a smaller dip. Only y matters in a headset.
    func setEyeOffset(_ v: SIMD3<Float>) { lock.lock(); _eyeOffsetY = v.y; _eyeTarget = max(0.2, _eyeBase + _eyeOffsetY); lock.unlock() }
    /// Current (eased) eye height above the feet, in nodes.
    var eyeHeight: Float {
        lock.lock(); defer { lock.unlock() }
        let now = Date(); let dt = Float(now.timeIntervalSince(_eyeStamp)); _eyeStamp = now
        let k = 1 - expf(-max(0, min(0.1, dt)) / 0.15)
        _eyeSmooth += (_eyeTarget - _eyeSmooth) * k
        return _eyeSmooth
    }
    static let scale: Float = 1.0    // meters per node — true first-person immersion

    private let lock = OSAllocatedUnfairLock()   // lighter than NSLock; contended by render+tick+net (perf)
    private var _feet = SIMD3<Float>(0, 0, 0)
    private var _yaw: Float = 0        // locomotion turn (stick), radians
    private var _pitch: Float = 0
    private var _meshRef = SIMD3<Float>(0, 0, 0)
    private var _haveSpawn = false
    private var _aim = SIMD3<Float>(0, 0, -1)   // look dir in node space (from head pose)
    private var _headPos: SIMD3<Float>?         // real tracked head in node space (nil in sim)
    // Full head transform in origin/ARKit space (identity in the sim). Used to
    // place head-locked overlays (Kogane menu, death text) at the real head
    // position and orientation, so they don't sit low or rotate with head tilt.
    private var _headXform = matrix_identity_float4x4
    private var _daylight: Float = 1.0
    private var _sunDir = SIMD3<Float>(0, 1, 0.2)
    private var _vy: Float = 0          // vertical velocity (jump/fall), m/s
    private var _grounded = true
    private var _submerged = false      // eye node is inside a liquid (drives the underwater tint)
    private var _dead = false           // hp == 0 (drives the red death tint)
    static let gravity: Float = 18.0    // default; snappier than real g; feels better in VR
    static let jumpSpeed: Float = 6.2   // default; ~1.07 block apex, clears a 1-block step
    static let walkSpeed: Float = 4.0   // default m/s (node/s); overwritten by TOCLIENT_MOVEMENT
    // Server-driven movement (TOCLIENT_MOVEMENT 0x45). Raw node/s|node/s^2 (our
    // world is 1 node = 1 unit, so no BS scaling). Default to the tuned values
    // until the server sends its set. gravity/jump keep our VR feel unless the
    // server overrides them.
    private var _gravity = PlayerState.gravity
    private var _jump = PlayerState.jumpSpeed
    private var _walk = PlayerState.walkSpeed
    private var _fast = PlayerState.walkSpeed * 1.9
    private var _crouch = PlayerState.walkSpeed * 0.4
    // Raw server MOVEMENT params + per-player physics_override multipliers
    // (AO_CMD_SET_PHYSICS_OVERRIDE). Effective values below are recomputed from
    // these whenever either arrives, so a later override or a re-sent MOVEMENT
    // both take effect. Luanti uses 2x movement_gravity as the airborne accel
    // (clientenvironment.cpp), which is why raw MOVEMENT gravity felt floaty.
    private var _baseWalk = PlayerState.walkSpeed
    private var _baseJump = PlayerState.jumpSpeed
    private var _baseGravity = PlayerState.gravity / 2   // stored pre-double
    private var _ovSpeed: Float = 1, _ovJump: Float = 1, _ovGravity: Float = 1
    private var _ovSpeedCrouch: Float = 1, _ovSpeedWalk: Float = 1   // 5.8/5.9 per-mode multipliers
    private var _baseCrouch = PlayerState.walkSpeed * 0.4
    private var _haveServerMovement = false              // don't 2x our tuned default
    var gravityNow: Float { lock.lock(); defer { lock.unlock() }; return _gravity }
    var jumpNow: Float { lock.lock(); defer { lock.unlock() }; return _jump }
    func moveSpeed(fast: Bool, sneak: Bool) -> Float { lock.lock(); defer { lock.unlock() }; return fast ? _fast : (sneak ? _crouch : _walk) }
    func setMovement(walk: Float, fast: Float, crouch: Float, jump: Float, gravity: Float) {
        _ = fast
        // NOTE: the server's `fast` is the fast/fly-privilege speed (~25), not
        // sprint, so we ignore it. Sprint speed is driven by the server's
        // physics_override.speed (mcl_sprint), triggered by the aux1 bit we send
        // while the grip is held -- see recomputeMovementLocked.
        lock.lock()
        _baseWalk = walk; _baseCrouch = crouch; _baseJump = jump; _baseGravity = gravity
        _haveServerMovement = true
        recomputeMovementLocked()
        lock.unlock()
    }

    /// Per-player physics override (AO_CMD_SET_PHYSICS_OVERRIDE): multipliers on
    /// speed/jump/gravity, plus the 5.8/5.9 per-mode speed_crouch and speed_walk
    /// (1.0 when the server omits them). Defaults are 1.0, so this is a no-op unless the game
    /// (or a potion) changes them.
    func setPhysicsOverride(speed: Float, jump: Float, gravity: Float, speedCrouch: Float = 1, speedWalk: Float = 1) {
        lock.lock()
        _ovSpeed = speed; _ovJump = jump; _ovGravity = gravity
        _ovSpeedCrouch = speedCrouch; _ovSpeedWalk = speedWalk
        recomputeMovementLocked()
        lock.unlock()
    }

    /// Fold base MOVEMENT + override multipliers into the effective values the
    /// physics step reads. Airborne gravity is 2x movement_gravity, matching
    /// Luanti (this was the "floaty jump" fix). Caller holds `lock`.
    private func recomputeMovementLocked() {
        // localplayer.cpp applyControl: walk x speed_walk, crouch x speed_crouch,
        // then everything x speed. Crouch used to ignore both multipliers.
        _walk = _baseWalk * _ovSpeedWalk * _ovSpeed
        _crouch = _baseCrouch * _ovSpeedCrouch * _ovSpeed
        // Sprint speed comes from the SERVER's physics_override.speed (mcl_sprint
        // sets it to ~1.3 when it sees the aux1 bit we now send), which is already
        // folded into _walk via _ovSpeed. Don't multiply by another local 1.3:
        // that made sprint 1.3*1.3 = 1.69x, faster than the server's own
        // physics allowed, so its authoritative position correction (MOVE_PLAYER)
        // kept snapping us back. So "fast" is just the (already
        // override-scaled) walk speed, exactly what the official client does.
        _fast = _walk
        _jump = _baseJump * _ovJump
        // Before the server sends MOVEMENT, keep our tuned VR gravity (already the
        // airborne value). A physics-override packet often arrives FIRST on join,
        // and deriving the default from the pre-halved _baseGravity there would
        // leave gravity at half strength (floaty) until MOVEMENT lands. Once we
        // have server movement_gravity, airborne accel is 2x it (Luanti).
        let base = _haveServerMovement ? _baseGravity * 2 : PlayerState.gravity
        _gravity = base * _ovGravity
    }
    // Liquid (water) vertical model: strong drag toward a target vertical speed.
    // Holding jump swims up; releasing sinks slowly (a touch slower when fully
    // submerged, a mild buoyant bias, so you settle/bob rather than plummet).
    static let swimUpSpeed: Float = 3.2       // holding jump: rise through the column (pre-server fallback)
    static let liquidSurfaceSink: Float = -1.2 // head out of water: sink back under (at engine-default sink=10)
    static let liquidSubmergedSink: Float = -0.45 // fully under: buoyancy softens the sink (at sink=10)
    static let liquidVerticalTau: Float = 0.16 // approach time constant (strong drag)
    static let liquidSpeedFactor: Float = 0.5  // horizontal movement in liquid (~VoxeLibre)
    // Server liquid tuning. The engine applies 2*movement_liquid_sink as
    // in-water gravity against a capped viscous drag; our model keeps the drag
    // shape (VR comfort: no plummeting) but scales the sink targets by
    // sink/10 (engine default 10) and swims up at movement_speed_walk, the
    // engine's swim-up speed (localplayer.cpp applyControl).
    private var _liquidSinkScale: Float = 1
    private var _swimUp: Float = PlayerState.swimUpSpeed
    func setLiquidMovement(fluidity: Float, fluiditySmooth: Float, sink: Float) {
        lock.lock()
        if sink > 0 { _liquidSinkScale = max(0.2, min(4, sink / 10)) }
        _swimUp = max(1, _walk)
        lock.unlock()
    }

    struct Snapshot { var feet: SIMD3<Float>; var yaw: Float; var pitch: Float; var meshRef: SIMD3<Float> }

    var haveSpawn: Bool { lock.lock(); defer { lock.unlock() }; return _haveSpawn }
    /// (grounded, vy) for clipping diagnostics.
    func debugVertical() -> (Bool, Float) { lock.lock(); defer { lock.unlock() }; return (_grounded, _vy) }

    func setSpawn(_ pos: SIMD3<Float>, yaw: Float, pitch: Float) {
        lock.lock(); defer { lock.unlock() }
        _feet = pos; _yaw = yaw; _pitch = pitch
        // A spawn/teleport kills momentum. The fall speed built up while
        // waiting for the first MOVE_PLAYER (feet at the origin, nothing under
        // them) otherwise rides into the first tick and tunnels the player
        // through the spawn surface (one 0.4 s tick moved the feet 3 nodes).
        _vy = 0; _grounded = false
        if !_haveSpawn { _meshRef = pos; _haveSpawn = true }
    }

    /// Apply a world-space horizontal velocity (already rotated into the frame
    /// the player is looking) plus a stick yaw turn. Movement direction is
    /// computed by the caller from the head gaze so "forward" means where you're
    /// looking, not a fixed body heading.
    func integrate(worldVel: SIMD3<Float>, turn: Float, dt: Float) {
        lock.lock(); defer { lock.unlock() }
        _yaw += turn * dt
        _feet.x += worldVel.x * dt
        _feet.z += worldVel.z * dt
    }

    /// Add a direct yaw delta (radians), not a rate. Mouse-look feeds this: the
    /// callback gives a per-frame displacement, not a held-stick rate, so it must
    /// skip the rate-integration (turn*dt) path.
    func addYaw(_ r: Float) { lock.lock(); _yaw += r; lock.unlock() }

    /// Body forward in node space at the current locomotion yaw (fallback for
    /// when the head is looking straight up/down and gaze has no horizontal).
    func bodyForward() -> SIMD3<Float> {
        lock.lock(); defer { lock.unlock() }
        // Luanti is left-handed (X east, Z north). Our yaw 0 looks along +Z
        // (north) and the renderer mirrors Z into the right-handed view frame.
        return SIMD3(sinf(_yaw), 0, cosf(_yaw))
    }

    func setFeetY(_ y: Float) { lock.lock(); _feet.y = y; lock.unlock() }

    /// Snapshot/apply the pieces the collision solver owns (Luanti-style AABB
    /// physics lives in WorldSession, which has the world; this just stores).
    func physics() -> (feet: SIMD3<Float>, vy: Float, grounded: Bool) {
        lock.lock(); defer { lock.unlock() }; return (_feet, _vy, _grounded)
    }
    func setPhysics(feet: SIMD3<Float>, vy: Float, grounded: Bool) {
        lock.lock(); _feet = feet; _vy = vy; _grounded = grounded; lock.unlock()
    }

    // Server-driven motion: PLAYER_SPEED adds a velocity impulse (knockback,
    // explosions) that decays with friction; MOVE_PLAYER_REL nudges position
    // (pistons, elevators, attachments).
    private var _extVel = SIMD3<Float>(0, 0, 0)   // horizontal knockback (node/s); Y goes straight to vy
    func addVelocity(_ v: SIMD3<Float>) { lock.lock(); _extVel.x += v.x; _extVel.z += v.z; _vy += v.y; lock.unlock() }
    func addPosition(_ p: SIMD3<Float>) { lock.lock(); _feet += p; lock.unlock() }
    /// Consume this tick's horizontal knockback delta and decay the impulse.
    func takeExternalDelta(dt: Float) -> SIMD2<Float> {
        lock.lock(); defer { lock.unlock() }
        let d = SIMD2(_extVel.x * dt, _extVel.z * dt)
        let decay: Float = powf(0.02, dt)   // ~friction: ~98% gone after 1s
        _extVel.x *= decay; _extVel.z *= decay
        if abs(_extVel.x) < 0.05 && abs(_extVel.z) < 0.05 { _extVel = .zero }
        return d
    }

    /// Begin a jump if standing on the ground.
    func jump() {
        lock.lock(); defer { lock.unlock() }
        if _grounded { _vy = _jump; _grounded = false }
    }

    /// Vertical physics for this tick. `groundTop` is the target feet Y for this
    /// column (highest surface + 1), or nil if the column isn't loaded. While
    /// grounded we follow the surface (stepping up to a block, or falling off a
    /// real ledge); while airborne we integrate gravity and land on the surface.
    /// Ease the buoyant vertical velocity toward its target for this tick and
    /// return it, WITHOUT moving. The caller sweeps the resulting delta through
    /// the same collision as land movement, so a swimmer climbing out under an
    /// overhang stops at the ceiling instead of rising through it, and
    /// settling lands on the column floor via the sweep (not a separate clamp).
    ///
    /// Buoyant model: a short time constant (strong drag) keeps a fast entry
    /// from plummeting to the floor. Holding jump swims up; otherwise you sink
    /// slowly, a touch slower when fully submerged (a mild buoyant bias).
    func buoyantVY(dt: Float, submerged: Bool = false, swimUp: Bool = false) -> Float {
        lock.lock(); defer { lock.unlock() }
        _grounded = false
        let target: Float = swimUp ? _swimUp
            : (submerged ? PlayerState.liquidSubmergedSink : PlayerState.liquidSurfaceSink) * _liquidSinkScale
        let k = 1 - expf(-dt / PlayerState.liquidVerticalTau)
        _vy += (target - _vy) * k
        return _vy
    }
    func setAim(_ dir: SIMD3<Float>) { lock.lock(); _aim = dir; lock.unlock() }
    func aim() -> SIMD3<Float> { lock.lock(); defer { lock.unlock() }; return _aim }
    func setHeadPos(_ p: SIMD3<Float>) { lock.lock(); _headPos = p; lock.unlock() }
    /// A real tracked head position has been set (else rayOrigin falls back to
    /// the nominal eye over possibly-unloaded origin nodes).
    func hasHead() -> Bool { lock.lock(); defer { lock.unlock() }; return _headPos != nil }
    func setHeadXform(_ m: simd_float4x4) { lock.lock(); _headXform = m; lock.unlock() }
    /// Right Sense controller pose in origin space (nil when not tracked): the
    /// pointer for the inventory panel.
    private var _rightHand: simd_float4x4? = nil
    func setRightHand(_ m: simd_float4x4?) { lock.lock(); _rightHand = m; lock.unlock() }
    func rightHand() -> simd_float4x4? { lock.lock(); defer { lock.unlock() }; return _rightHand }

    /// The open inventory/formspec panel's plane in origin space, so the
    /// renderer can draw the pointer dot from each frame's controller pose
    /// instead of the tick's (the dot trailed the controller by a tick plus a
    /// handoff). nil while no panel is open.
    struct PanelPointer {
        var center: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>, toward: SIMD3<Float>
        var dotLayer: Int, dotHalf: Float
        var heldLayer: Int, heldHalf: Float   // heldLayer -1: nothing in hand
    }
    private var _panelPointer: PanelPointer? = nil
    func setPanelPointer(_ p: PanelPointer?) { lock.lock(); _panelPointer = p; lock.unlock() }
    func panelPointer() -> PanelPointer? { lock.lock(); defer { lock.unlock() }; return _panelPointer }
    func headXform() -> simd_float4x4 { lock.lock(); defer { lock.unlock() }; return _headXform }
    /// Origin for dig/place/crosshair rays: the real tracked head if we have it
    /// (so aiming matches your gaze), else the nominal eye (feet + eye height).
    func rayOrigin() -> SIMD3<Float> {
        lock.lock(); defer { lock.unlock() }
        return _headPos ?? (_feet + SIMD3(0, _eyeSmooth, 0))
    }
    func setDaylight(_ d: Float, timeOfDay t: Float, skyVisible sv: Float) {
        lock.lock(); _daylight = d; _timeOfDay = t; _skyVisible = sv; lock.unlock()
    }
    private var _timeOfDay: Float = 0.5
    private var _skyVisible: Float = 1     // 0 = deep underground, 1 = open sky (fog darkening)
    private var _skySolid = SIMD4<Float>(0, 0, 0, 0)   // server solid-sky (Nether/End); a>0 = on
    private var _sky = SkyParams()                        // engine defaults until the server says otherwise
    /// Server sky look. Also derives the flat-colour sky for Nether/End.
    func setSky(_ s: SkyParams) {
        lock.lock()
        _sky = s
        _skySolid = s.solid.map { SIMD4($0.x, $0.y, $0.z, 1) } ?? SIMD4(0, 0, 0, 0)
        lock.unlock()
    }
    func skySolid() -> SIMD4<Float> { lock.lock(); defer { lock.unlock() }; return _skySolid }

    /// SkyParams packed the way the Uniforms struct wants them (see
    /// ShaderTypes.h), so the renderer never has to know LuantiKit types.
    struct SkyUniforms {
        var dayZenith, dayHorizon, nightZenith, nightHorizon: SIMD4<Float>
        var bodies, stars, starColor, clouds, cloudColor: SIMD4<Float>
        var saturation: Float
        var fog: SIMD4<Float>        // x distance (nodes, -1 = view range), y start (-1 = default)
        var fogColor: SIMD4<Float>   // rgb + a>0 = server override
        var sunTint: SIMD4<Float>    // rgb + w = 1 when fog_tint_type is "custom"
        var moonTint: SIMD4<Float>
    }
    func skyUniforms() -> SkyUniforms {
        lock.lock(); let s = _sky; lock.unlock()
        return Self.skyUniforms(from: s)
    }
    /// Pure SkyParams -> SkyUniforms packing, so the batched render read
    /// can compute it while already holding the lock.
    static func skyUniforms(from s: SkyParams) -> SkyUniforms {
        func v4(_ c: SIMD3<Float>) -> SIMD4<Float> { SIMD4(c.x, c.y, c.z, 0) }
        // Star count -> hash threshold: the sky shader lights a cell when its
        // hash clears the threshold, so 1000 stars ~ the top 0.8% of cells.
        let starTh = max(0.9, min(0.9999, 1 - 0.008 * Float(s.starCount) / 1000))
        return SkyUniforms(
            dayZenith: v4(s.daySky), dayHorizon: v4(s.dayHorizon),
            nightZenith: v4(s.nightSky), nightHorizon: v4(s.nightHorizon),
            bodies: SIMD4(s.sunVisible ? 1 : 0, s.sunScale, s.moonVisible ? 1 : 0, s.moonScale),
            stars: SIMD4(s.starsVisible ? 1 : 0, starTh, s.starScale, s.clouds ? 1 : 0),
            starColor: v4(s.starColor),
            clouds: SIMD4(s.cloudDensity, s.cloudHeight / 120, s.cloudSpeed.x, s.cloudSpeed.y),
            cloudColor: v4(s.cloudColor),
            saturation: s.saturation,
            fog: SIMD4(Float(s.fogDistance), s.fogStart, s.skyboxTextures.count == 6 ? 1 : 0, 0),
            fogColor: s.fogColor,
            sunTint: SIMD4(s.fogSunTint.x, s.fogSunTint.y, s.fogSunTint.z, s.fogTintCustom ? 1 : 0),
            moonTint: v4(s.fogMoonTint))
    }
    func daylight() -> Float { lock.lock(); defer { lock.unlock() }; return _daylight }
    func setSunDir(_ d: SIMD3<Float>) { lock.lock(); _sunDir = d; lock.unlock() }
    func sunDir() -> SIMD3<Float> { lock.lock(); defer { lock.unlock() }; return _sunDir }
    /// Eye position in node coordinates.
    /// Height of origin-space (0,0,0) above the feet. On device ARKit's origin
    /// is the FLOOR under the user, so the real head sits at its true height
    /// (sitting or standing) above the feet: lift 0. In the sim the head pose
    /// is identity, so the origin is placed at the nominal eye instead.
    /// (This is the "too tall" fix: adding a floor-origin head to an eye-height
    /// origin put the eye ~3 nodes up.)
    private var _originLift: Float = PlayerState.eyeHeight
    func setOriginLift(_ l: Float) { lock.lock(); _originLift = l; lock.unlock() }
    func origin() -> SIMD3<Float> { lock.lock(); defer { lock.unlock() }; return _feet + SIMD3(0, _originLift, 0) }

    /// Everything the per-frame world/sky uniform update reads, grabbed under a
    /// single lock instead of six separate acquisitions (snapshot, origin,
    /// daylight, skySolid, skyUniforms, sunDir). Also a consistent snapshot: the
    /// six used to race the tick thread independently.
    struct RenderState {
        var snap: Snapshot
        var origin: SIMD3<Float>
        var daylight: Float
        var timeOfDay: Float          // 0..1, for the dawn/dusk horizon tint window
        var skyVisible: Float         // 0..1 sunlight reaching the head (cave fog)
        var skySolid: SIMD4<Float>
        var sky: SkyUniforms
        var sunDir: SIMD3<Float>
        var head: simd_float4x4      // last frame's head transform (fog eye position)
    }
    func renderState() -> RenderState {
        lock.lock(); defer { lock.unlock() }
        return RenderState(
            snap: Snapshot(feet: _feet, yaw: _yaw, pitch: _pitch, meshRef: _meshRef),
            origin: _feet + SIMD3(0, _originLift, 0),
            daylight: _daylight, timeOfDay: _timeOfDay, skyVisible: _skyVisible, skySolid: _skySolid,
            sky: Self.skyUniforms(from: _sky), sunDir: _sunDir, head: _headXform)
    }
    /// True while the eye/head node is inside a liquid (set by the session tick,
    /// read by the renderer to toggle the underwater colour tint).
    private var _postEffect = SIMD4<Float>.zero   // camera node's post_effect_color (rgba), alpha 0 = none
    func setPostEffect(_ c: SIMD4<Float>) { lock.lock(); _postEffect = c; lock.unlock() }
    func postEffect() -> SIMD4<Float> { lock.lock(); defer { lock.unlock() }; return _postEffect }
    // Diegetic threshold vignette (HUD P8): rgb tint + corner strength, set by the
    // session from health/breath, drawn by the renderer as a soft edge cast.
    private var _vignette = SIMD4<Float>.zero
    func setVignette(_ c: SIMD4<Float>) { lock.lock(); _vignette = c; lock.unlock() }
    func vignette() -> SIMD4<Float> { lock.lock(); defer { lock.unlock() }; return _vignette }
    func setSubmerged(_ s: Bool) { lock.lock(); _submerged = s; lock.unlock() }
    func submerged() -> Bool { lock.lock(); defer { lock.unlock() }; return _submerged }
    func setDead(_ d: Bool) { lock.lock(); _dead = d; lock.unlock() }
    func isDead() -> Bool { lock.lock(); defer { lock.unlock() }; return _dead }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(feet: _feet, yaw: _yaw, pitch: _pitch, meshRef: _meshRef)
    }
}
