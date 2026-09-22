import simd

/// A parsed TOCLIENT_PLAY_SOUND request. Positions are in node coords (the wire
/// value is BS-space and already divided by BS=10 when this is built).
public struct SoundSpec {
    /// Server-assigned sound id. Negative/zero for ephemeral, one-shot sounds.
    public let id: Int
    /// Base sound name (e.g. "player_footstep"); resolves to one of several .ogg.
    public let name: String
    /// Base gain (0..1+, server-side volume for this play).
    public let gain: Float
    /// SoundLocation: 0 = local (2D), 1 = positional, 2 = attached to an object.
    public let type: Int
    /// World position (node coords) for positional/object sounds.
    public let pos: SIMD3<Float>
    /// Active-object id for type == 2 (attached sounds).
    public let objectId: Int
    /// Loop until stopped.
    public let loop: Bool
    /// Fade-in step (gain per second); 0 = no fade.
    public let fade: Float
    /// Playback pitch multiplier (1.0 = normal).
    public let pitch: Float
    /// One-shot fire-and-forget; the server won't send STOP for it.
    public let ephemeral: Bool

    public init(id: Int, name: String, gain: Float, type: Int, pos: SIMD3<Float>,
                objectId: Int, loop: Bool, fade: Float, pitch: Float, ephemeral: Bool) {
        self.id = id; self.name = name; self.gain = gain; self.type = type
        self.pos = pos; self.objectId = objectId; self.loop = loop
        self.fade = fade; self.pitch = pitch; self.ephemeral = ephemeral
    }
}
