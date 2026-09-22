import Foundation
import simd

/// The server-driven sky look, gathered from TOCLIENT_SET_SKY / SET_SUN /
/// SET_MOON / SET_STARS / CLOUD_PARAMS / SET_LIGHTING. Kept in engine units so
/// the renderer can feed its procedural sky; only the fields that sky can
/// honour are kept (textures, tonemaps, fog, exposure, bloom are dropped).
/// Defaults are SkyboxDefaults from the engine's skyparams.h.
public struct SkyParams: Equatable {
    // SET_SKY "regular" colour table (rgb 0..1). The night pair are bright
    // bases the engine dims by the day-night brightness; the shader does the
    // same.
    public var daySky = SkyParams.rgb(97, 181, 245)
    public var dayHorizon = SkyParams.rgb(144, 211, 246)
    public var dawnSky = SkyParams.rgb(180, 186, 250)
    public var dawnHorizon = SkyParams.rgb(186, 193, 240)
    public var nightSky = SkyParams.rgb(0, 107, 255)
    public var nightHorizon = SkyParams.rgb(64, 144, 255)
    public var clouds = true
    /// A "plain"/"skybox" SET_SKY: flat bgcolor instead of the gradient
    /// (Nether/End). nil = "regular".
    public var solid: SIMD3<Float>? = nil
    /// A "skybox" SET_SKY's six textures in the API order Y+ Y- X- X+ Z+ Z-
    /// (the End's starry box). Empty for the other types (#290).
    public var skyboxTextures: [String] = []

    public var sunVisible = true
    public var sunScale: Float = 1
    public var moonVisible = true
    public var moonScale: Float = 1

    public var starsVisible = true
    public var starCount = 1000
    public var starColor = SkyParams.rgb(235, 235, 255)
    public var starScale: Float = 1

    public var cloudDensity: Float = 0.4
    public var cloudColor = SkyParams.rgb(240, 240, 255)   // color_bright
    public var cloudHeight: Float = 120
    public var cloudSpeed = SIMD2<Float>(0, -2)

    public var saturation: Float = 1   // SET_LIGHTING; 1 = untouched

    // SET_SKY fog tail (engine 5.9+). distance in nodes, -1 = the view range;
    // start as a fraction of that, -1 = the engine's fog_start default (0.4);
    // colour override with alpha 0 meaning "use the horizon colour".
    public var fogDistance: Int = -1
    public var fogStart: Float = -1
    public var fogColor = SIMD4<Float>(0, 0, 0, 0)
    // SET_SKY fog tints: with fog_tint_type "custom" the engine mixes the sun
    // tint into the horizon at dawn/dusk (sky.cpp pointcolor). VoxeLibre sends
    // #ff5f33 for every overworld sky; that's the orange sunsets.
    public var fogSunTint = SkyParams.rgb(244, 125, 29)
    public var fogMoonTint = SkyParams.rgb(127, 153, 204)
    public var fogTintCustom = false

    public init() {}

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
        SIMD3(Float(r) / 255, Float(g) / 255, Float(b) / 255)
    }
    /// Wire ARGB8 (u32) -> rgb 0..1.
    static func argb(_ v: Int) -> SIMD3<Float> {
        rgb((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
    }
}
