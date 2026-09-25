import Foundation
import simd

/// Client-side active objects: mobs, dropped items, other players. Parses
/// TOCLIENT_ACTIVE_OBJECT_REMOVE_ADD / _MESSAGES and the per-object AO commands,
/// tracks positions with light interpolation, and hands the renderer a snapshot
/// of billboards. Port of active_objects.gd. Positions are node coordinates.
public final class ActiveObjects {
    public static let BS: Float = 10.0
    // AO command ids
    private static let SET_PROPERTIES = 0, UPDATE_POSITION = 1, SET_TEXTURE_MOD = 2, PUNCHED = 4
    private static let ATTACH_TO = 8, SET_ANIMATION = 6, SET_ANIMATION_SPEED = 12, STOP_ANIMATION = 13
    private static let SET_PHYSICS_OVERRIDE = 9, SET_BONE_POSITION = 7, SET_SPRITE = 3, UPDATE_ARMOR_GROUPS = 5

    /// One bone's server override with the engine's interpolation state
    /// (activeobject.h BoneOverride): a re-send snapshots the previous targets
    /// and restarts the timer; each channel eases previous -> target over its
    /// own duration (0 = jump).
    public struct BoneOverride {
        public var pos: SIMD3<Float> = .zero, prevPos: SIMD3<Float> = .zero
        public var rot = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), prevRot = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        public var scale = SIMD3<Float>(1, 1, 1), prevScale = SIMD3<Float>(1, 1, 1)
        public var absPos = false, absRot = false, absScale = false
        public var posDur: Float = 0, rotDur: Float = 0, scaleDur: Float = 0
        public var elapsed: Float = 0

        func progress(_ d: Float) -> Float { d <= 0 ? 1 : min(1, elapsed / d) }
        public var finished: Bool { elapsed >= max(posDur, rotDur, scaleDur) }
        /// Nothing left to apply: the engine drops such entries.
        public var isIdentity: Bool {
            finished && !absPos && pos == .zero && !absRot && abs(rot.real) > 0.999999
                && !absScale && scale == SIMD3(1, 1, 1)
        }
        /// The override as the skinner sees it right now.
        public func current() -> B3DLoader.JointOverride {
            var o = B3DLoader.JointOverride()
            let pp = progress(posDur), rp = progress(rotDur), sp = progress(scaleDur)
            o.pos = prevPos + (pos - prevPos) * pp
            o.rot = rp >= 1 ? rot : simd_slerp(prevRot, rot, rp)
            o.scale = prevScale + (scale - prevScale) * sp
            o.absPos = absPos; o.absRot = absRot; o.absScale = absScale
            return o
        }
    }

    public struct Entity {
        public var id: Int = 0            // server active-object id
        public var name: String
        public var isPlayer: Bool
        public var pos: SIMD3<Float>       // interpolated node position
        public var target: SIMD3<Float>
        public var vel: SIMD3<Float>
        public var size: SIMD3<Float>      // visual_size (nodes)
        public var textures: [String]
        public var visual: String
        public var glow: Int
        public var mesh: String            // model filename for visual == "mesh"
        public var cbMin: SIMD3<Float>     // collisionbox (nodes) for auto-fit sizing
        public var stepHeight: Float = 0.6  // ObjectProperties stepheight (nodes)
        public var eyeHeight: Float = 1.625 // ObjectProperties eye_height (nodes)
        public var cbMax: SIMD3<Float>
        public var yaw: Float              // facing, radians (eased toward yawTarget like rot_translator)
        /// Server rotation.x in radians: a tilt about the model's X axis (Y-Z
        /// plane). VoxeLibre boats bob with it (mcl_boats set_rotation(anim, yaw, anim)).
        public var pitch: Float = 0
        /// Server rotation.z in radians: a tilt about the model's Z axis (X-Y
        /// plane). This is where vl_projectile puts a projectile's flight pitch
        /// (set_rotation(0, yaw, asin(v.y))) because the arrow models point
        /// along +X, so arrows, tridents and thrown things nose along their arc
        /// with THIS, not with rotation.x.
        public var roll: Float = 0
        public var acc: SIMD3<Float> = .zero   // acceleration (nodes/s^2), integrated each step like GenericCAO
        public var physical = false            // ObjectProperties physical: collides with the world (items, mobs)
        public var makesFootstepSound = false  // ObjectProperties makes_footstep_sound
        // rot_translator state: yaw eases from yawOld toward yawTarget over
        // animTime (the server's update_interval), shortest way round.
        public var yawOld: Float = 0
        public var yawTarget: Float = 0
        public var animTime: Float = 0.1   // SmoothTranslator::anim_time (s)
        public var animCounter: Float = 0  // time since the last UPDATE_POSITION
        public var aimIsEnd = true         // is_movement_end: no 1.5x overshoot past the target
        public var automaticRotate: Float = 0   // rad/s constant yaw spin (spawner dolls, some display entities)
        public var attachParent: Int = 0   // AO id we're attached to (0 = none)
        public var attachOffset: SIMD3<Float> = .zero  // local offset from parent (nodes)
        /// Parent bone the attachment hangs off ("" = the parent's origin). The
        /// renderer resolves it against the parent's animated model.
        public var attachBone: String = ""
        /// ATTACH_TO rotation (radians, x/y/z). While attached the child's own
        /// rotation is ignored and this is applied relative to the parent
        /// (GenericCAO::updateAttachments setRotationDegrees(m_attachment_rotation)).
        public var attachRot: SIMD3<Float> = .zero
        /// ATTACH_TO force_visible: drawn even when attached to the local player
        /// (a tamed parrot on your shoulder, mobs_mc/parrot.lua set_attach(..., true)).
        public var forceVisible = false
        /// Set by PUNCHED when hp reaches 0: the renderer spawns the engine's
        /// smoke puff (createSmokePuff) once and clears it.
        public var deathPuff = false
        // Skeletal animation from AO_CMD_SET_ANIMATION: frame range (Irrlicht
        // 0-based), fps, loop; `animFrame` advances in step() like
        // CAnimatedMeshSceneNode does. nil range = bind pose.
        public var animRange: SIMD2<Float>? = nil
        public var animFps: Float = 15
        public var animLoop: Bool = true
        public var animFrame: Float = 0
        // Current hp (initial value from the add packet, then AO_CMD_PUNCHED) and
        // a hit-flash timer that mirrors GenericCAO's damage-texture timer.
        public var hp: Int = 0
        public var hitFlash: Float = 0     // seconds of flash left (0 = none)
        /// armor_groups.immortal: punches do no damage, so no hit flash
        /// (content_cao.cpp directReportPunch flashes only on damage != 0).
        public var immortal = false
        /// ObjectProperties.use_texture_alpha: the engine draws these with a
        /// blended material (content_cao.cpp), so a slime's 194/255 shell shows
        /// its core and face instead of an opaque green box.
        public var useTextureAlpha = false
        // From ObjectProperties: the floating name over the object, and the
        // texture modifier the engine overlays briefly when it takes damage.
        public var nametag: String = ""
        public var nametagColor: UInt32 = 0xFFFF_FFFF   // ARGB8
        // ObjectProperties wield_item: the itemstring a "wielditem" visual shows
        // (dropped items are __builtin:item with this set, NOT textures).
        public var wieldItem: String = ""
        /// ObjectProperties.pointable: false for display-only entities (chest
        /// model, item frames), so the crosshair/dig raycast passes through them
        /// to the node behind. Defaults true (mobs, players).
        public var pointable: Bool = true
        /// ObjectProperties.is_visible: false entities aren't drawn and aren't
        /// pointable (empty-hand wieldview, a dropped item pre-texture).
        public var isVisible: Bool = true
        /// ObjectProperties selectionbox (nodes), the pointable region; distinct
        /// from the collisionbox. Zero-size (degenerate) -> fall back to cb.
        public var selMin: SIMD3<Float> = .zero
        public var selMax: SIMD3<Float> = .zero
        /// ObjectProperties damage_texture_modifier; the engine default is
        /// "^[brighten" (object_properties.h), overwritten by SET_PROPERTIES.
        public var damageTexMod: String = "^[brighten"
        /// Live texture modifier from AO_CMD_SET_TEXTURE_MOD, appended to every
        /// surface's texture (mcl_mobs burning/damage/status overlays).
        public var textureMod: String = ""
        /// AO_CMD_SET_BONE_POSITION overrides by bone name (mob head swivel,
        /// fish body pitch). Applied on top of the animation when skinning.
        public var boneOverrides: [String: BoneOverride] = [:]
        // Sprite sheets (visual "sprite"/"upright_sprite"): spritediv is the
        // sheet's cell grid, basepos the cell, and AO_CMD_SET_SPRITE runs an
        // animation down the column (GenericCAO: row = base.y + frame).
        public var spriteDiv = SIMD2<Int>(1, 1)
        public var spriteBase = SIMD2<Int>(0, 0)
        public var spriteFrames = 1
        public var spriteFrameLen: Float = 0.2
        public var spriteFrame = 0
        public var spriteTimer: Float = 0

        /// The texture string for the sheet cell showing right now, or nil when
        /// the texture isn't a sheet (draw textures[0] whole).
        public var spriteCellTexture: String? {
            guard visual == "sprite" || visual == "upright_sprite", let t = textures.first,
                  spriteDiv.x > 1 || spriteDiv.y > 1 else { return nil }
            return Entity.sheetCell(t, div: spriteDiv, col: spriteBase.x, row: spriteBase.y + spriteFrame)
        }
        /// "tex^[sheet:WxH:col,row", wrapping out-of-range cells the way GL
        /// texture repeat did for the engine's UV offsets.
        public static func sheetCell(_ tex: String, div: SIMD2<Int>, col: Int, row: Int) -> String {
            let c = ((col % div.x) + div.x) % div.x, r = ((row % div.y) + div.y) % div.y
            return "\(tex)^[sheet:\(div.x)x\(div.y):\(c),\(r)"
        }
    }

    /// Every cell the sprite animation can show, so one atlas build bakes them all.
    private func registerSpriteCells(_ o: Entity) {
        guard o.visual == "sprite" || o.visual == "upright_sprite", let t = o.textures.first,
              o.spriteDiv.x > 1 || o.spriteDiv.y > 1 else { return }
        for f in 0..<max(1, o.spriteFrames) {
            tiles.insert(Entity.sheetCell(t, div: o.spriteDiv, col: o.spriteBase.x, row: o.spriteBase.y + f))
        }
    }

    public private(set) var objects: [Int: Entity] = [:]
    /// Drop every object (a reconnect: the new session re-sends what's around
    /// you; old mobs would otherwise stand frozen, unhittable).
    public func removeAll() { objects.removeAll() }
    public private(set) var tiles: Set<String> = []   // entity texture strings seen
    public private(set) var meshes: Set<String> = []  // entity model filenames seen
    public var localPlayerName = ""
    /// The local player's physics override changed (AO_CMD_SET_PHYSICS_OVERRIDE):
    /// speed/jump/gravity multipliers. Only fired for our own player object.
    /// speed/jump/gravity multipliers, plus the 5.8/5.9 per-mode multipliers
    /// speed_crouch and speed_walk (1.0 when the server didn't send them).
    public var onLocalPhysicsOverride: ((_ speed: Float, _ jump: Float, _ gravity: Float,
                                         _ speedCrouch: Float, _ speedWalk: Float) -> Void)?
    /// The local player's own ObjectProperties (SET_PROPERTIES on our AO):
    /// collisionbox, stepheight, eye_height. VoxeLibre swaps these per state
    /// (swimming: 0.8-tall box + 0.6 eye so you fit through 1-node gaps;
    /// sneaking: 1.45 eye) and the client is expected to move with them.
    public var onLocalProperties: ((_ cbMin: SIMD3<Float>, _ cbMax: SIMD3<Float>, _ stepHeight: Float, _ eyeHeight: Float) -> Void)?
    /// Is this node a full solid cube? Set by the client so step() can keep
    /// physical entities on the floor (see step). nil = no floor check.
    public var isSolidNode: ((SIMD3<Int>) -> Bool)?

    private func v3f(_ r: PacketReader) -> SIMD3<Float> { SIMD3(r.f32(), r.f32(), r.f32()) }

    /// TOCLIENT_ACTIVE_OBJECT_REMOVE_ADD.
    public func handleRemoveAdd(_ payload: Data) {
        let r = PacketReader(payload)
        let removed = r.u16()
        for _ in 0..<removed { objects.removeValue(forKey: r.u16()) }
        let added = r.u16()
        for _ in 0..<added {
            let id = r.u16()
            _ = r.u8()                    // type (generic vs player) — unused
            add(id, r.bytes32())
        }
    }

    /// TOCLIENT_ACTIVE_OBJECT_MESSAGES: repeated (u16 id, bytes16 msg).
    public func handleMessages(_ payload: Data) {
        let r = PacketReader(payload)
        while r.has(4) {
            let id = r.u16()
            process(id, r.bytes16())
        }
    }

    private func add(_ id: Int, _ initData: Data) {
        let r = PacketReader(initData)
        guard r.u8() >= 1 else { return }
        let name = r.string16()
        let isPlayer = r.u8() != 0
        _ = r.u16()                       // id again
        let pos = v3f(r) / ActiveObjects.BS + Client.gridShift   // server grid -> ours
        let rot = v3f(r)                  // rotation (degrees)
        let hp = r.u16()                  // starting hp; PUNCHED diffs against it
        var ent = Entity(id: id, name: name, isPlayer: isPlayer, pos: pos, target: pos,
                         vel: .zero, size: SIMD3(1, 1, 1), textures: [], visual: "",
                         glow: 0, mesh: "", cbMin: SIMD3(-0.3, 0, -0.3), cbMax: SIMD3(0.3, 1.7, 0.3),
                         yaw: rot.y * .pi / 180)
        ent.pitch = rot.x * .pi / 180
        ent.roll = rot.z * .pi / 180
        ent.yawOld = ent.yaw; ent.yawTarget = ent.yaw
        ent.hp = hp
        objects[id] = ent
        let count = r.u8()
        for _ in 0..<count { process(id, r.bytes32()) }
    }

    private func process(_ id: Int, _ msg: Data) {
        guard var o = objects[id], !msg.isEmpty else { return }
        let r = PacketReader(msg)
        let cmd = r.u8()
        switch cmd {
        case ActiveObjects.SET_PROPERTIES:
            parseProperties(r, into: &o)
            if o.isPlayer, o.name == localPlayerName {
                onLocalProperties?(o.cbMin, o.cbMax, o.stepHeight, o.eyeHeight)
            }
        case ActiveObjects.UPDATE_POSITION:
            // GenericCAO AO_CMD_UPDATE_POSITION: position, velocity,
            // acceleration, rotation, do_interpolate, is_movement_end,
            // update_interval.
            let pos = v3f(r) / ActiveObjects.BS + Client.gridShift
            let vel = v3f(r) / ActiveObjects.BS
            let acc = v3f(r) / ActiveObjects.BS
            let rot = v3f(r)              // rotation (degrees)
            o.pitch = rot.x * .pi / 180
            o.roll = rot.z * .pi / 180    // projectiles nose along their arc
            let interpolate = r.u8() != 0
            let isEnd = r.u8() != 0
            let interval = r.f32()
            o.target = pos; o.vel = vel; o.acc = acc
            // rot_translator.update(rotation, false, update_interval): ease the
            // facing from where it is now to the new heading.
            o.yawOld = o.yaw; o.yawTarget = rot.y * .pi / 180
            // SmoothTranslator::update: the blend runs over the server's own
            // update interval (VoxeLibre mobs ~0.1-0.2 s); when the server
            // sends 0, keep the last measured one.
            if interval > 0 { o.animTime = interval }
            else if o.animTime < 0.001 || o.animTime > 1 { o.animTime = max(0.05, o.animCounter) }
            o.animCounter = 0
            o.aimIsEnd = isEnd
            // do_interpolate false is a teleport (GenericCAO re-inits its
            // pos_translator): snap, don't streak across the world.
            if !interpolate { o.pos = pos; o.yaw = o.yawTarget; o.yawOld = o.yaw }
        case ActiveObjects.SET_TEXTURE_MOD:
            let m = r.string16()
            // mcl_mobs drives visible state through this: burning ^[colorize,
            // damage ^[brighten, etc. Keep it so the renderer can append it to
            // each surface's texture. Empty clears it back to the base.
            // A mod-issued texture modifier cancels an engine damage flash
            // still running (content_cao.cpp: m_reset_textures_timer = -1), so
            // a mob that catches fire doesn't stay tinted.
            o.hitFlash = 0
            o.textureMod = m
            if !m.isEmpty, o.textures.isEmpty { o.textures = [m] }
        case ActiveObjects.ATTACH_TO:
            // s16 parent, string16 bone, v3f position, v3f rotation, [u8 force_visible].
            // Luanti reads the id into a u16 (content_cao.cpp), so read it unsigned:
            // s16 would turn a parent id > 32767 negative and the attach would miss.
            let parent = r.u16()
            let bone = r.string16()
            let offset = v3f(r) / ActiveObjects.BS
            let rotDeg = v3f(r)
            let force = r.has(1) ? r.u8() != 0 : false   // force_visible (5.4+)
            o.attachParent = parent == 0 ? 0 : parent
            o.attachOffset = offset
            o.attachBone = parent == 0 ? "" : bone
            o.attachRot = rotDeg * (.pi / 180)
            o.forceVisible = parent != 0 && force
        case ActiveObjects.SET_ANIMATION:
            // v2f range, f32 fps, f32 blend, u8 !loop (GenericCAO::processMessage)
            let x = r.f32(), y = r.f32()
            let fps = r.f32()
            _ = r.f32()                   // blend
            let noLoop = r.u8() != 0
            let range = SIMD2<Float>(min(x, y), max(x, y))
            // 5.17+: track id, priority, cur_frame follow; else the clip restarts
            // at min (or max when playing backwards), as GenericCAO does.
            var cur: Float? = nil
            if r.has(2) {
                _ = r.u16()               // track id
                if r.has(8) { _ = r.s32(); cur = max(0, r.f32()) }
            }
            o.animRange = range; o.animFps = fps; o.animLoop = !noLoop
            o.animFrame = cur ?? (fps >= 0 ? range.x : range.y)
            if o.mesh.contains("chest") { print("[chest] id=\(id) anim \(range) fps=\(fps) loop=\(!noLoop)"); fflush(stdout) }
        case ActiveObjects.SET_ANIMATION_SPEED:
            o.animFps = r.f32()
        case ActiveObjects.UPDATE_ARMOR_GROUPS:
            // u16 count, then (string16 name, s16 rating) pairs.
            let n = Int(r.u16())
            var imm = false
            for _ in 0..<n where r.has(2) {
                let name = r.string16(); let rating = r.s16()
                if name == "immortal", rating != 0 { imm = true }
            }
            o.immortal = imm
        case ActiveObjects.PUNCHED:
            // u16 result_hp. GenericCAO diffs it against the last known hp (so it
            // doesn't fight client prediction), flashes damage_texture_modifier
            // for 0.05s (+0.05s per point from 2 damage up, capped at 1s), and on
            // death drops the attachment to its parent and from its children.
            let newHp = r.u16()
            let damage = o.hp - newHp
            o.hp = newHp
            if damage > 0 {
                if newHp == 0 {
                    // The killing blow makes a smoke puff instead of a flash.
                    o.deathPuff = true
                } else if o.hitFlash <= 0, !o.damageTexMod.isEmpty {
                    // Only when not already flashing and the object defines a
                    // damage_texture_modifier (the engine default is ^[brighten;
                    // VoxeLibre players use ^[colorize:red:130). Engine base is
                    // 0.05 s, but one quick flash is easy to miss in the headset,
                    // so floor it at 0.2 s.
                    var t: Float = 0.05
                    if damage >= 2 { t += 0.05 * Float(damage) }
                    o.hitFlash = min(1, max(0.2, t))
                }
            }
            if newHp == 0 {
                o.attachParent = 0                       // clearParentAttachment
                if !o.isPlayer {                         // clearChildAttachments
                    for (cid, var c) in objects where c.attachParent == id {
                        c.attachParent = 0; objects[cid] = c
                    }
                }
            }
        case ActiveObjects.STOP_ANIMATION:
            o.animRange = nil                            // back to the bind pose
        case ActiveObjects.SET_SPRITE:
            // v2s16 basepos, u16 num_frames, f32 frame length, u8 select_horiz_by_yawpitch
            o.spriteBase = SIMD2(r.s16(), r.s16())
            o.spriteFrames = max(1, r.u16())
            o.spriteFrameLen = max(0.001, r.f32())
            _ = r.u8()                                   // yaw/pitch column select: unused by VoxeLibre
            o.spriteFrame = 0; o.spriteTimer = 0
            registerSpriteCells(o)
        case ActiveObjects.SET_BONE_POSITION:
            // string16 bone, v3f position, v3f rotation (degrees), then at
            // proto >= 44: v3f scale, f32 x3 interpolation seconds, u8 absolute
            // flags (1 pos, 2 rot, 4 scale). Older servers: pos+rot only, both
            // absolute. Positions are model units (no BS), as the engine sends.
            let bone = r.string16()
            var ov: BoneOverride
            if let old = o.boneOverrides[bone] {
                ov = old
                ov.elapsed = 0
                ov.prevPos = old.pos; ov.prevRot = old.rot; ov.prevScale = old.scale
            } else {
                ov = BoneOverride()                      // first time: no interpolation
            }
            ov.pos = v3f(r)
            ov.rot = B3DLoader.irrQuat(euler: v3f(r) * (.pi / 180))
            if r.has(12 + 12 + 1) {
                ov.scale = v3f(r)
                ov.posDur = r.f32(); ov.rotDur = r.f32(); ov.scaleDur = r.f32()
                let flags = r.u8()
                ov.absPos = flags & 1 != 0; ov.absRot = flags & 2 != 0; ov.absScale = flags & 4 != 0
            } else {
                ov.absPos = true; ov.absRot = true
            }
            if o.boneOverrides[bone] == nil { ov.posDur = 0; ov.rotDur = 0; ov.scaleDur = 0 }
            o.boneOverrides[bone] = ov
        case ActiveObjects.SET_PHYSICS_OVERRIDE:
            // content_cao.cpp: f32 speed, jump, gravity; u8 sneak, sneak_glitch,
            // new_move (inverted legacy bools); since 5.8 f32 speed_climb,
            // speed_crouch, liquid_fluidity, liquid_fluidity_smooth, liquid_sink,
            // acceleration_default, acceleration_air; since 5.9 f32 speed_fast,
            // acceleration_fast, speed_walk. VoxeLibre's Swift Sneak enchant
            // drives speed_crouch (mcl_playerplus), so that one matters.
            let speed = r.f32(), jump = r.f32(), gravity = r.f32()
            _ = r.u8(); _ = r.u8(); _ = r.u8()
            var speedCrouch: Float = 1, speedWalk: Float = 1
            if r.has(7 * 4) {
                _ = r.f32(); speedCrouch = r.f32()
                _ = r.f32(); _ = r.f32(); _ = r.f32(); _ = r.f32(); _ = r.f32()
            }
            if r.has(3 * 4) { _ = r.f32(); _ = r.f32(); speedWalk = r.f32() }
            if o.isPlayer, o.name == localPlayerName {
                onLocalPhysicsOverride?(speed, jump, gravity, speedCrouch, speedWalk)
            }
        default:
            break
        }
        objects[id] = o
    }

    /// Parse ObjectProperties (v4) far enough to grab visual, size, textures.
    private func parseProperties(_ r: PacketReader, into o: inout Entity) {
        guard r.u8() == 4 else { return }
        _ = r.u16()                       // hp_max
        o.physical = r.u8() != 0
        _ = r.u32()                       // weight (removed)
        o.cbMin = v3f(r); o.cbMax = v3f(r) // collisionbox (node units) for sizing
        o.selMin = v3f(r); o.selMax = v3f(r)  // selectionbox: the pointable region
        o.pointable = r.u8() != 0         // display entities (chest model) set false
        o.visual = r.string16()
        o.size = v3f(r)
        var textures: [String] = []
        let nt = r.u16()
        for _ in 0..<nt { textures.append(r.string16()) }
        // Replaced wholesale, empty included: ObjectProperties::deSerialize
        // clears the list before reading, so a re-sent empty list blanks the
        // entity rather than keeping its stale skin.
        o.textures = textures; for t in textures { tiles.insert(t) }
        // Continue to the mesh filename (needed for visual == "mesh").
        o.spriteDiv = SIMD2(max(1, r.s16()), max(1, r.s16()))
        o.spriteBase = SIMD2(r.s16(), r.s16())
        registerSpriteCells(o)
        o.isVisible = r.u8() != 0         // false: not drawn, not pointable
        o.makesFootstepSound = r.u8() != 0   // mobs and players: footsteps every 1.5 nodes
        o.automaticRotate = r.f32()       // rad/s constant spin (spawner dolls)
        let mesh = r.string16()           // mesh model filename
        if !mesh.isEmpty { o.mesh = mesh; meshes.insert(mesh) }
        // Tail, in ObjectProperties::serialize order. Every read is bounds-
        // checked (a short/older tail just yields zeros), so walking this far is
        // safe on any protocol version we accept.
        let nc = r.u16()
        for _ in 0..<nc { _ = r.u32() }   // colors (ARGB8 each)
        _ = r.u8()                        // collideWithObjects
        o.stepHeight = r.f32() / ActiveObjects.BS   // stepheight (BS units on the wire)
        _ = r.u8()                        // automatic_face_movement_dir
        _ = r.f32()                       // automatic_face_movement_dir_offset
        _ = r.u8()                        // backface_culling
        o.nametag = r.string16()
        o.nametagColor = UInt32(truncatingIfNeeded: r.u32())   // ARGB8; alpha 0 = hidden
        _ = r.f32()                       // automatic_face_movement_max_rotation_per_sec
        _ = r.string16()                  // infotext
        o.wieldItem = r.string16()        // itemstring for a "wielditem" visual (dropped items)
        o.glow = Int(Int8(truncatingIfNeeded: r.u8()))   // s8; -1 = full-bright/unshaded
        _ = r.u16()                       // breath_max
        if !r.overrun { o.eyeHeight = r.f32() }   // eye_height (nodes)
        _ = r.f32()                       // zoom_fov
        o.useTextureAlpha = r.u8() != 0   // use_texture_alpha: blended, not cut out (slimes)
        o.damageTexMod = r.string16()
        // (shaded, show_on_minimap, nametag_bgcolor and later fields: not needed)
    }

    /// Advance interpolation the way GenericCAO::step does: the server target
    /// is dead-reckoned every frame (pos += v*dt + a*dt^2/2, v += a*dt) and the
    /// drawn position eases toward it at 0.8/anim_time per second (the
    /// pos_translator's per-frame update+translate with the 0.8 damping).
    /// Rotation follows rot_translator: approach the target heading the short
    /// way round by (diff * 0.8 * counter/anim_time) per frame, never past it.
    /// The engine also runs client-side collision for physical objects
    /// (collisionMoveSimple). We only do the part that matters for things at
    /// rest: a dropped item's last server update has velocity 0 but gravity
    /// still in `acc`, and no further update ever comes, so integrating it
    /// blindly sank every drop through the floor within a second of landing
    /// ("I don't see mined blocks"). Walls can still lead a mob's
    /// reckoned target astray for one update interval; the next packet fixes it.
    public func step(_ dt: Float) {
        // `for (id, var o) in objects { ...; objects[id] = o }` iterated a copy
        // of the dictionary while writing back into it, so every tick paid a
        // full copy-on-write of the whole entity table. Walk the keys and
        // mutate each value in place instead (perf review, idle-cost item).
        // Mutating through `objects.values[i]` edits the entry in place: no
        // key array, no copy-out/copy-back per entity.
        for i in objects.values.indices {
            objects.values[i].animCounter += dt
            var o = objects.values[i]
            let rate = 0.8 / max(0.02, o.animTime)
            let a = min(1, dt * rate)
            if o.attachParent == 0 {
                o.target += o.vel * dt + o.acc * (0.5 * dt * dt)
                o.vel += o.acc * dt
                // Floor clamp: if the collisionbox bottom has entered a solid
                // node while moving down, sit on that node's top and stop.
                if o.physical, o.vel.y <= 0, let solid = isSolidNode {
                    let feetY = o.target.y + o.cbMin.y
                    let n = SIMD3(Int(o.target.x.rounded(.down)), Int(feetY.rounded(.down)), Int(o.target.z.rounded(.down)))
                    if solid(n) {
                        o.target.y = Float(n.y + 1) - o.cbMin.y
                        o.vel.y = 0
                    }
                }
                o.pos += (o.target - o.pos) * a
                // rot_translator: wrappedApproachShortest toward yawTarget.
                var diff = o.yawTarget - o.yawOld
                diff = atan2(sin(diff), cos(diff))   // shortest arc
                let stepSize = abs(diff) * min(0.8 * o.animCounter / max(0.001, o.animTime), o.aimIsEnd ? 1 : 1.5)
                var delta = o.yawTarget - o.yaw
                delta = atan2(sin(delta), cos(delta))
                if delta > stepSize { o.yaw += stepSize }
                else if delta < -stepSize { o.yaw -= stepSize }
                else { o.yaw = o.yawTarget }
            }
            if let r = o.animRange {
                // AnimSpec: advance by fps (either sign); looping wraps into
                // [min, max], otherwise clamp at both ends.
                o.animFrame += o.animFps * dt
                let len = r.y - r.x
                if o.animLoop && len > 0 {
                    var f = (o.animFrame - r.x).truncatingRemainder(dividingBy: len)
                    if f < 0 { f += len }
                    o.animFrame = r.x + f
                } else {
                    o.animFrame = max(r.x, min(r.y, o.animFrame))
                }
            }
            o.hitFlash = max(0, o.hitFlash - dt)   // PUNCHED flash runs down
            if o.spriteFrames > 1 {                // sprite sheet animation, GenericCAO::step
                o.spriteTimer += dt
                if o.spriteTimer >= o.spriteFrameLen {
                    o.spriteTimer -= o.spriteFrameLen
                    o.spriteFrame += 1
                    if o.spriteFrame >= o.spriteFrames { o.spriteFrame = 0 }
                }
            }
            if !o.boneOverrides.isEmpty {
                for (bone, var ov) in o.boneOverrides {
                    ov.elapsed += dt
                    if ov.isIdentity { o.boneOverrides[bone] = nil } else { o.boneOverrides[bone] = ov }
                }
            }
            objects.values[i] = o
        }
        // Attached entities (riders, boats/minecart occupants, items in frames)
        // follow their parent: pos = parent.pos + offset rotated by parent yaw.
        // Collect first: iterating `objects` while writing `objects[id]` held a
        // second reference to the storage, so the first write copied the whole
        // table every tick that anything was attached.
        attachedScratch.removeAll(keepingCapacity: true)
        for (id, o) in objects where o.attachParent != 0 { attachedScratch.append(id) }
        for id in attachedScratch {
            guard let o0 = objects[id], let parent = objects[o0.attachParent] else { continue }
            var o = o0
            o.pos = ActiveObjects.attachedPosition(parent: parent.pos, yaw: parent.yaw, offset: o.attachOffset)
            o.target = o.pos
            // While attached the child's own rotation is replaced by the
            // attachment rotation relative to the parent (updateAttachments).
            o.yaw = parent.yaw + o.attachRot.y; o.yawTarget = o.yaw; o.yawOld = o.yaw
            o.pitch = o.attachRot.x; o.roll = o.attachRot.z
            objects[id] = o
        }
    }
    private var attachedScratch: [Int] = []

    /// World position of something attached to a parent: parent position plus the
    /// local offset rotated by the parent's yaw (radians). Used for both passenger
    /// AOs and the local player riding a vehicle, so a rider and a passenger land
    /// in the same spot instead of mirrored ones. The sign convention matches the
    /// entity render frame (Z-mirrored), so keep both callers on this one helper.
    public static func attachedPosition(parent: SIMD3<Float>, yaw: Float, offset: SIMD3<Float>) -> SIMD3<Float> {
        let c = cos(yaw), s = sin(yaw)
        return parent + SIMD3(offset.x * c + offset.z * s, offset.y, -offset.x * s + offset.z * c)
    }

    public func entity(_ id: Int) -> Entity? { objects[id] }
    public var count: Int { objects.count }

    /// Entities whose killing blow just landed: returns (pos, visual_size.xy)
    /// for each and clears the flag, so the renderer puffs smoke exactly once.
    public func takeDeathPuffs() -> [(pos: SIMD3<Float>, size: SIMD2<Float>)] {
        var out: [(SIMD3<Float>, SIMD2<Float>)] = []
        for i in objects.values.indices where objects.values[i].deathPuff {
            objects.values[i].deathPuff = false
            let o = objects.values[i]
            out.append((o.pos, SIMD2(o.size.x, o.size.y)))
        }
        return out
    }

    /// Flash an object red for `seconds` (the PUNCHED hit-tint). Called
    /// when the local player melee-hits a mob so the feedback is immediate and
    /// doesn't wait on the server's AO_CMD_PUNCHED round-trip, which mcl_mobs
    /// doesn't always send as a clean hp diff. Never shortens a longer flash
    /// already running (a real server punch on the same frame still wins).
    public func flash(_ id: Int, seconds: Float) {
        guard var o = objects[id], !o.immortal else { return }
        o.hitFlash = max(o.hitFlash, seconds)
        objects[id] = o
    }

    /// The nearest object the aim ray hits within `maxDist`: its AO id and the
    /// hit distance. Ray vs each entity's world AABB (pos + collisionbox), so a
    /// mob (or dropped item, other player) can be pointed at and punched. The
    /// local player is skipped. Same coordinate frame as WorldMap.raycast.
    public func raycastEntity(origin: SIMD3<Float>, dir: SIMD3<Float>, maxDist: Float) -> (id: Int, dist: Float)? {
        let len = (dir.x*dir.x + dir.y*dir.y + dir.z*dir.z).squareRoot()
        guard len > 1e-8 else { return nil }
        let d = dir / len
        let selfId = localPlayerId
        var best: (id: Int, dist: Float)?
        // The engine (GenericCAO::getSelectionBox) returns no box -> not pointable
        // only when the object is non-pointable, invisible, or the local player.
        // Attached objects stay pointable (a player riding a boat, a shoulder
        // parrot); only things riding the local player are skipped, since the
        // ray starts inside them.
        for (id, o) in objects where id != selfId && o.pointable && o.isVisible && (o.attachParent == 0 || o.attachParent != selfId) {
            // Point at the selectionbox, not the collisionbox; fall back to the
            // collisionbox when the selectionbox is degenerate (zero-size).
            let degenerate = o.selMin == o.selMax
            let lo = o.pos + (degenerate ? o.cbMin : o.selMin)
            let hi = o.pos + (degenerate ? o.cbMax : o.selMax)
            guard let t = ActiveObjects.rayAABB(origin: origin, dir: d, lo: lo, hi: hi), t <= maxDist else { continue }
            if best == nil || t < best!.dist { best = (id, t) }
        }
        return best
    }

    /// Slab ray/AABB: the nearest entry distance the ray crosses into [lo, hi]
    /// (0 if the origin is already inside), or nil if it misses / is behind.
    static func rayAABB(origin: SIMD3<Float>, dir: SIMD3<Float>, lo: SIMD3<Float>, hi: SIMD3<Float>) -> Float? {
        var tmin: Float = -.infinity, tmax: Float = .infinity
        for a in 0..<3 {
            if abs(dir[a]) < 1e-8 {
                if origin[a] < lo[a] || origin[a] > hi[a] { return nil }   // parallel and outside the slab
            } else {
                let inv = 1 / dir[a]
                var t1 = (lo[a] - origin[a]) * inv, t2 = (hi[a] - origin[a]) * inv
                if t1 > t2 { swap(&t1, &t2) }
                tmin = max(tmin, t1); tmax = min(tmax, t2)
                if tmin > tmax { return nil }
            }
        }
        return tmax >= 0 ? max(tmin, 0) : nil
    }

    /// The local player's own active-object id (0 if not seen yet). Effects
    /// attached to it (weather rain/snow) must follow the live camera position,
    /// not this AO's stale server pos. Called every tick, so memoize: the cached
    /// id is validated by a single dict lookup and only rescans when it's gone
    /// stale (the id changed, which is rare).
    private var cachedLocalPlayerId: Int = 0
    public var localPlayerId: Int {
        if cachedLocalPlayerId != 0, let o = objects[cachedLocalPlayerId], o.isPlayer, o.name == localPlayerName {
            return cachedLocalPlayerId
        }
        for (id, o) in objects where o.isPlayer && o.name == localPlayerName { cachedLocalPlayerId = id; return id }
        cachedLocalPlayerId = 0
        return 0
    }

    /// All non-local-player entities to draw.
    public func snapshot() -> [Entity] {
        // is_visible == false: not drawn (empty-hand wieldview, a dropped item
        // before it's textured). Matches the engine skipping its scene node.
        // Anything attached to the local player is hidden too, like the engine
        // in first person (GenericCAO::setAttachment: m_is_visible =
        // !m_attached_to_local): the mcl_burning fire billboard, our own
        // wieldview item, a riding parrot. Not the vehicle we ride, which
        // is the parent, not a child.
        let me = localPlayerId
        return objects.values.filter {
            $0.isVisible && !($0.isPlayer && $0.name == localPlayerName)
                && !(me != 0 && $0.attachParent == me && !$0.forceVisible)   // force_visible: shoulder parrot
        }
    }
}
