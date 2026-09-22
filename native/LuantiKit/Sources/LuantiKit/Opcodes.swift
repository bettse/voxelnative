import Foundation

/// Wire constants transcribed from the engine's networkprotocol.h
/// (ToServerCommand / ToClientCommand enums, PROTOCOL_ID, serialization
/// version), plus the per-opcode channel + reliability routing the official
/// client uses when it sends.
public enum Op {
    public static let protocolId = 0x4F457403
    public static let serializationVersion = 29
    public static let minProtocol = 37
    public static let latestProtocol = 53
    public static let formspecApiVersion = 11

    // toserver
    public static let toserverInit = 0x02
    public static let toserverInit2 = 0x11
    public static let toserverClientReady = 0x43
    public static let toserverFirstSrp = 0x50
    public static let toserverSrpBytesA = 0x51
    public static let toserverSrpBytesM = 0x52
    public static let toserverChatMessage = 0x32
    public static let toserverPlayerPos = 0x23
    public static let toserverGotBlocks = 0x24
    public static let toserverDeletedBlocks = 0x25    // TOSERVER_DELETEDBLOCKS (unloaded; server re-streams on return)
    public static let toserverInteract = 0x39
    public static let toserverInventoryAction = 0x31   // TOSERVER_INVENTORY_ACTION (Move/Drop/Craft text)
    public static let toserverPlayerItem = 0x37       // TOSERVER_PLAYERITEM (selected hotbar slot)
    public static let toserverDamage = 0x35           // TOSERVER_DAMAGE (client-computed fall damage)
    public static let toserverRespawn = 0x38          // TOSERVER_RESPAWN_LEGACY; modern servers null-handle it
    public static let toserverInventoryFields = 0x3c  // TOSERVER_INVENTORY_FIELDS (formspec submit)
    public static let toserverNodeMetaFields = 0x3b   // TOSERVER_NODEMETA_FIELDS (node formspec submit)
    public static let toserverRequestMedia = 0x40
    public static let toserverHaveMedia = 0x41        // TOSERVER_HAVE_MEDIA (acks MEDIA_PUSH tokens)
    public static let toserverRemovedSounds = 0x3a    // TOSERVER_REMOVED_SOUNDS (handles that finished playing)

    // toclient
    public static let toclientHello = 0x02
    public static let toclientAuthAccept = 0x03
    public static let toclientAccessDenied = 0x0A
    public static let toclientSrpBytesSB = 0x60
    public static let toclientBlockData = 0x20
    public static let toclientAddNode = 0x21
    public static let toclientRemoveNode = 0x22
    public static let toclientMovePlayer = 0x34
    public static let toclientHP = 0x33
    public static let toclientInventory = 0x27
    public static let toclientNodeDef = 0x3A
    public static let toclientAnnounceMedia = 0x3C
    public static let toclientItemDef = 0x3D
    public static let toclientMovement = 0x45
    public static let toclientMedia = 0x38
    public static let toclientTimeOfDay = 0x29
    public static let toclientActiveObjectRemoveAdd = 0x31
    public static let toclientActiveObjectMessages = 0x32
    public static let toclientMediaPush = 0x2C            // TOCLIENT_MEDIA_PUSH (runtime media)
    public static let toclientSpawnParticle = 0x46
    public static let toclientSpawnParticleBatch = 0x64   // TOCLIENT_SPAWN_PARTICLE_BATCH
    public static let toclientAddParticleSpawner = 0x47
    public static let toclientNodemetaChanged = 0x59
    public static let toclientInventoryFormspec = 0x42
    public static let toclientHudSetFlags = 0x4c      // TOCLIENT_HUD_SET_FLAGS (hotbar/healthbar/wielditem/... visibility)
    public static let toclientFov = 0x36              // TOCLIENT_FOV (fov override/multiplier; recorded, VR never re-projects)
    public static let toclientHudSetParam = 0x4d      // TOCLIENT_HUD_SET_PARAM (hotbar item count / images)
    public static let toclientEyeOffset = 0x52        // TOCLIENT_EYE_OFFSET (first/third-person camera offset, BS units)
    public static let toclientShowFormspec = 0x44
    public static let toclientFormspecPrepend = 0x61   // per-player string prepended to every formspec (bg panel, styles)
    public static let toclientPrivileges = 0x41       // TOCLIENT_PRIVILEGES (the player's privilege names)
    public static let toclientDetachedInventory = 0x43
    public static let toclientOverrideDayNightRatio = 0x50
    public static let toclientChatMessage = 0x2f
    public static let toclientSetSky = 0x4f
    public static let toclientCloudParams = 0x54   // TOCLIENT_CLOUD_PARAMS
    public static let toclientSetSun = 0x5a        // TOCLIENT_SET_SUN
    public static let toclientSetMoon = 0x5b       // TOCLIENT_SET_MOON
    public static let toclientSetStars = 0x5c      // TOCLIENT_SET_STARS
    public static let toclientSetLighting = 0x63   // TOCLIENT_SET_LIGHTING
    public static let toclientPlayerSpeed = 0x2b
    public static let toclientMovePlayerRel = 0x5d
    public static let toclientDeleteParticleSpawner = 0x53
    public static let toclientPlaySound = 0x3F
    public static let toclientStopSound = 0x40
    public static let toclientFadeSound = 0x55
    public static let toclientHudAdd = 0x49
    public static let toclientHudRm = 0x4A
    public static let toclientHudChange = 0x4B

    /// opcode -> (channel, reliable). Default when absent: (0, true).
    public static let toserverRouting: [Int: (channel: Int, reliable: Bool)] = [
        toserverInit: (1, false),
        toserverInit2: (1, true),
        toserverClientReady: (1, true),
        toserverFirstSrp: (1, true),
        toserverSrpBytesA: (1, true),
        toserverSrpBytesM: (1, true),
        toserverPlayerPos: (0, false),
        toserverDamage: (0, true),
        toserverRemovedSounds: (2, true),
        toserverGotBlocks: (2, true),
        toserverRequestMedia: (1, true),
    ]
}

public enum AuthMechanism: Int {
    case none = 0, legacyPassword = 1, srp = 2, firstSrp = 4
}
