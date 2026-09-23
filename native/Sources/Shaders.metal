// Metal shaders for the voxel world. Each vertex carries a texture-array layer
// index and a directional shade term; the fragment samples the atlas layer.

#include <metal_stdlib>
#include <simd/simd.h>
#import "ShaderTypes.h"

using namespace metal;

typedef struct
{
    float3 position [[attribute(VertexAttributePosition)]];
    float2 uv       [[attribute(VertexAttributeTexcoord)]];
    float4 params   [[attribute(VertexAttributeParams)]];   // x=layer, y=shade, z=light, w=packed biome tint
} Vertex;

typedef struct
{
    float4 position [[position]];
    float2 uv;
    // layer/shade/tint are constant across every quad (and every model face)
    // the meshers emit, so they're flat: no interpolation, and the layer is an
    // exact integer in the fragment stage.
    uint   layer [[flat]];
    float  shade [[flat]];
    // Day/night light already decoded through the light curve and blended per
    // VERTEX (like the engine's nodes/opengl_vertex.glsl), so the fragment
    // stage multiplies one interpolated colour instead of running two exp/pow
    // curves per pixel. Smooth lighting (#273) gives each corner its own
    // nibbles, so this interpolates the curved value across the face, which
    // is also what desktop does.
    float3 lit;
    half3  tint [[flat]];
    float  fogDist;   // metres from the eye, for the distance fog (#285)
} ColorInOut;

// The engine's fog (nodes/opengl_fragment.glsl): linear from fog_start*range
// to range, blending toward the sky's horizon colour. fog.x = range in metres,
// fog.y = 1/(1 - fog_start).
static inline float3 applyFog(float3 col, float dist, constant Uniforms & uniforms)
{
    float clarity = clamp(uniforms.fog.y - uniforms.fog.y * dist / uniforms.fog.x, 0.0, 1.0);
    return mix(uniforms.fogColor.rgb, col, clarity);
}

static inline float2 unpackLight(float packed) {
    float night = floor(packed / 16.0);
    return float2(packed - night * 16.0, night);
}

// Unpack a biome tint packed as r + g*256 + b*65536 (each 0..255) into 0..1 RGB.
static inline half3 unpackTint(float p) {
    float b = floor(p / 65536.0);
    float g = floor((p - b * 65536.0) / 256.0);
    float r = p - b * 65536.0 - g * 256.0;
    return half3(r, g, b) / 255.0h;
}

// Luanti's light curve (light.cpp set_light_curve with the default settings:
// lighting_alpha 0, lighting_beta 1.5, boost 0.2 at 0.5 +/- 0.2, gamma 1):
// level 0 is black, night sky-light (0.175) comes out near 10%, day is 1.
static inline float luantiLight(float x)
{
    x = clamp(x, 0.0, 1.0);
    float b = (-0.5 * x + 1.5) * x * x;
    float t = (x - 0.5) / 0.2;
    b += 0.2 * exp(-0.5 * t * t);
    // No extra ambient floor: match Luanti desktop exactly (the old 0.06 lift
    // made caves/night brighter than desktop). Light 0 is near-black like vanilla.
    return clamp(b, 0.0, 1.0);
}

// The engine's two-bank blend (mapblock_mesh.cpp encode_light + nodes_shader
// opengl_vertex.glsl): each bank is decoded through the curve on its own, the
// part of the day bank ABOVE the night bank counts as sunlight and is tinted
// by get_sunlight_color(ratio) (rg = ratio-0.04, b = 0.98*ratio+0.078), the
// rest is artificial light at a flat 1.04, then a small blue lift in the dark
// (final_color_blend). Blending the raw nibbles first and decoding once made
// night ~30% darker and a grey instead of the desktop's blue moonlight.
static inline float3 bankLit(float dayNibble, float nightNibble, float r)
{
    float D = luantiLight(dayNibble), N = luantiLight(nightNibble);
    float sun = max(D - N, 0.0);
    float3 dl = float3(r - 0.04, r - 0.04, 0.98 * r + 0.078);
    float3 lit = sun * dl + N * 1.04;
    float br = (lit.r + lit.g + lit.b) / 3.0;
    lit.b += max(0.0, 0.021 - abs(0.2 * br - 0.021) + 0.07 * br);
    return lit;
}

// Per-vertex light: unpack the mesher's byte (day nibble low, night nibble
// high) and decode both banks. The packed byte must never be interpolated
// raw (that scrambled the day bank wherever the night bank differed between
// corners), which is why the nibbles come apart here, before any interpolation.
static inline float3 vertexLit(float packed, float daylight)
{
    float2 l = unpackLight(packed);
    return bankLit(l.x / 15.0, l.y / 15.0, daylight);
}

// The engine's shaders/nodes/opengl_vertex.glsl smoothTriangleWave: a
// triangle wave (period 1) smoothed into a sine-like curve, 0..1.
static inline float smoothTriangleWave(float x)
{
    float tri = abs(fract(x + 0.5) * 2.0 - 1.0);
    return tri * tri * (3.0 - 2.0 * tri);
}

vertex ColorInOut vertexShader(Vertex in [[stage_in]],
                               ushort amp_id [[amplification_id]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                               constant ViewProjectionArray & viewProjectionArray [[ buffer(BufferIndexViewProjection) ]])
{
    ColorInOut out;
    float4 position = float4(in.position, 1.0);
    // nodedef waving (#300), packed by the mesher as shade + 2*class. The
    // engine's nodes shader: plants (1) sway only their top vertices (uv.y
    // near 0), leaves (2) wobble the whole node on all three axes, both as
    // smooth triangle waves keyed on position so neighbours are out of phase.
    // Amplitudes are the engine's (0.08 / 0.05 node); periods are shortened
    // from its 100 s animationTimer cycle to read at VR eye height.
    float wave = floor(in.params.y / 2.0);
    float shade = in.params.y - wave * 2.0;
    float t = uniforms.sunDir.w;
    if (wave == 1.0) {
        if (in.uv.y < 0.05) {
            position.x += (smoothTriangleWave(t * 0.35 + position.x * 0.1 + position.z * 0.1) * 2.0 - 1.0) * 0.08;
            position.y -= (smoothTriangleWave(t * 0.14 - position.x * 0.5 - position.z * 0.5) * 2.0 - 1.0) * 0.04;
        }
    } else if (wave == 2.0) {
        // Leaves (waving 2). The engine's amplitude (0.05) and rate read as too
        // much in a headset -- big, fast tree sway is distracting up close in VR
        // (Eric). Softer amplitude and a slower rate keep the life without the
        // seasick wobble; plants (wave 1) are gentler already and left alone.
        position.x += (smoothTriangleWave(t * 0.5 + position.x * 0.01 + position.z * 0.01) * 2.0 - 1.0) * 0.028;
        position.y += (smoothTriangleWave(t * 0.7 - position.x * 0.01 - position.z * 0.01) * 2.0 - 1.0) * 0.028;
        position.z += (smoothTriangleWave(t * 0.5 - position.x * 0.01 - position.z * 0.01) * 2.0 - 1.0) * 0.028;
    }
    float4 wp = uniforms.modelMatrix * position;
    out.position = viewProjectionArray.viewProjectionMatrix[amp_id] * wp;
    out.uv = in.uv;
    out.layer = uint(in.params.x + 0.5);
    out.shade = shade;
    out.lit = vertexLit(in.params.z, uniforms.daylight);
    out.tint = unpackTint(in.params.w);
    out.fogDist = length(wp.xyz - uniforms.eyePos.xyz);
    return out;
}

// Liquid surfaces: same as vertexShader but with a gentle vertical wave so water
// isn't dead flat. Each (x,z) column bobs by a small sine of position+time, so a
// column's top and bottom shift together (side faces stay intact) while adjacent
// columns bob out of phase -> a rolling surface. sunDir.w carries elapsed time.
vertex ColorInOut liquidVertex(Vertex in [[stage_in]],
                               ushort amp_id [[amplification_id]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                               constant ViewProjectionArray & viewProjectionArray [[ buffer(BufferIndexViewProjection) ]])
{
    ColorInOut out;
    float4 position = float4(in.position, 1.0);
    float t = uniforms.sunDir.w;
    // Lava (negative shade sentinel) waves slower and shallower than water.
    // Stained glass / blended nodeboxes share this stream but are flagged with
    // shade + 2 (params.y >= 1.5); they're solid, so don't wave them (#143/#177).
    bool lava = in.params.y < 0.0;
    bool blended = in.params.y >= 1.5;
    if (!blended) {
        float amp = lava ? 0.015 : 0.03;
        float spd = lava ? 0.6 : 1.3;
        position.y += sin(t * spd + position.x * 1.8 + position.z * 2.1) * amp
                   + sin(t * spd * 0.7 + position.x * 3.3 - position.z * 1.1) * amp * 0.4;
    }
    float4 wp = uniforms.modelMatrix * position;
    out.position = viewProjectionArray.viewProjectionMatrix[amp_id] * wp;
    out.uv = in.uv;
    out.layer = uint(in.params.x + 0.5);
    out.shade = in.params.y;
    out.lit = vertexLit(in.params.z, uniforms.daylight);
    out.tint = unpackTint(in.params.w);
    out.fogDist = length(wp.xyz - uniforms.eyePos.xyz);
    return out;
}

// Entities are billboards already positioned in origin space; skip the model matrix.
vertex ColorInOut entityVertex(Vertex in [[stage_in]],
                               ushort amp_id [[amplification_id]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                               constant ViewProjectionArray & viewProjectionArray [[ buffer(BufferIndexViewProjection) ]])
{
    ColorInOut out;
    out.position = viewProjectionArray.viewProjectionMatrix[amp_id] * float4(in.position, 1.0);
    out.uv = in.uv;
    out.layer = uint(in.params.x + 0.5);
    out.shade = in.params.y;
    out.lit = vertexLit(in.params.z, uniforms.daylight);
    out.tint = unpackTint(in.params.w);
    out.fogDist = length(in.position - uniforms.eyePos.xyz);
    return out;
}

// World atlas sampler: nearest when magnified (blocky up close, like the
// engine's default), trilinear across the mip chain when minified so far
// tiles stop shimmering and stop thrashing the texture cache (one texel per
// pixel instead of a 64-texel stride). The node atlas carries a full mip
// chain (MeshHandoff.makeAtlas); the model array does not and keeps nearest.
constexpr sampler worldSampler(mag_filter::nearest, min_filter::linear, mip_filter::linear, max_anisotropy(4));
// Liquid tops carry a per-cell UV translate (drawLiquidTop's tcoord_translate)
// so the flow animation lines up across cells; that pushes UVs outside 0..1,
// so this pass must wrap instead of clamping.
constexpr sampler liquidSampler(mag_filter::nearest, min_filter::linear, mip_filter::linear, max_anisotropy(4), address::repeat);

// Shared world shading: un-premultiply, biome tint, day/night light, saturation.
static inline float4 worldLit(half4 c, ColorInOut in, constant Uniforms & uniforms)
{
    half3 rgb = c.a > 0.0h ? c.rgb / c.a : c.rgb;   // un-premultiply
    rgb *= in.tint;                                 // biome palette tint (white = no change)
    float3 lit = float3(rgb) * in.shade * in.lit;
    // SET_LIGHTING saturation (1 = untouched), the engine's luma weights.
    float luma = dot(lit, float3(0.213, 0.715, 0.072));
    lit = mix(float3(luma), lit, uniforms.saturation);
    return float4(applyFog(lit, in.fogDist, uniforms), 1.0);
}

// Cutout world (leaves, plants, nodeboxes): alpha-tests, so it cannot use
// early-Z. The solid world uses fragmentShaderOpaque below instead (#164).
fragment float4 fragmentShader(ColorInOut in [[stage_in]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                               texture2d_array<half> atlas [[ texture(TextureIndexColor) ]])
{
    half4 c = atlas.sample(worldSampler, in.uv, in.layer);
    // Alpha cutout: drop transparent texels (leaves, plants) so their gaps show
    // through instead of rendering as a solid block.
    if (c.a < 0.5h) { discard_fragment(); }
    return worldLit(c, in, uniforms);
}

// Entities (mobs, dropped items, billboards). Same lighting as the world, but a
// non-white tint BLENDS toward the colour instead of multiplying: a hit-flash or
// a hot-pink creeper reads as that colour even on a dark skin, where a multiply
// would just darken it. White tint (the common case) blends at 0 = unchanged.
fragment float4 entityFragment(ColorInOut in [[stage_in]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                               texture2d_array<half> atlas [[ texture(TextureIndexColor) ]])
{
    constexpr sampler s(mag_filter::nearest, min_filter::nearest);
    half4 c = atlas.sample(s, in.uv, in.layer);
    if (c.a < 0.5h) { discard_fragment(); }
    half3 rgb = c.a > 0.0h ? c.rgb / c.a : c.rgb;
    half3 tintRGB = in.tint;
    // A grey tint is a SHADE (the inventory cube icons darken their side faces
    // with 184/140 greys): multiply, or the sides wash out toward light grey.
    // A coloured tint (hit-flash red, creeper pink) blends toward the colour.
    bool grey = abs(tintRGB.r - tintRGB.g) < 0.02h && abs(tintRGB.g - tintRGB.b) < 0.02h;
    half str = (grey || all(tintRGB > half3(0.99h))) ? 0.0h : 0.7h;
    rgb = grey ? rgb * tintRGB : mix(rgb, tintRGB, str);
    float3 lit = float3(rgb) * in.shade * in.lit;
    float luma = dot(lit, float3(0.213, 0.715, 0.072));
    lit = mix(float3(luma), lit, uniforms.saturation);
    return float4(applyFog(lit, in.fogDist, uniforms), 1.0);
}

// use_texture_alpha entities (slimes): entityFragment's lighting and tint, but
// the texture's own alpha is kept and blended instead of cut out at 0.5.
fragment float4 entityBlendFragment(ColorInOut in [[stage_in]],
                                    constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                                    texture2d_array<half> atlas [[ texture(TextureIndexColor) ]])
{
    constexpr sampler s(mag_filter::nearest, min_filter::nearest);
    half4 c = atlas.sample(s, in.uv, in.layer);
    if (c.a < 0.02h) { discard_fragment(); }
    half3 rgb = c.rgb / c.a;
    half3 tintRGB = in.tint;
    bool grey = abs(tintRGB.r - tintRGB.g) < 0.02h && abs(tintRGB.g - tintRGB.b) < 0.02h;
    half str = (grey || all(tintRGB > half3(0.99h))) ? 0.0h : 0.7h;
    rgb = grey ? rgb * tintRGB : mix(rgb, tintRGB, str);
    float3 lit = float3(rgb) * in.shade * in.lit;
    float luma = dot(lit, float3(0.213, 0.715, 0.072));
    lit = mix(float3(luma), lit, uniforms.saturation);
    return float4(applyFog(lit, in.fogDist, uniforms), float(c.a));
}

// Glass backing plate behind the head-locked vitals (HUD layout B, P4): a soft-
// edged dark translucent panel so the icons have consistent contrast in any
// scene (kills glare on snow, grounds them in dark caves) instead of floating
// full-bright. uv is 0..1 across the panel; feather the border.
fragment float4 glassFragment(ColorInOut in [[stage_in]])
{
    float2 e = min(in.uv, 1.0 - in.uv);                 // 0 at edge -> 0.5 at centre
    float a = smoothstep(0.0, 0.05, min(e.x, e.y));     // 5% feathered border
    return float4(0.03, 0.03, 0.05, 0.5 * a);
}

// Solid opaque blocks (NDT_NORMAL cubes): no discard, so the GPU can run depth
// tests before the fragment shader and skip occluded surfaces (#164). Byte-for-
// byte the same colour as fragmentShader for a fully-opaque texel.
[[early_fragment_tests]]
fragment float4 fragmentShaderOpaque(ColorInOut in [[stage_in]],
                                     constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                                     texture2d_array<half> atlas [[ texture(TextureIndexColor) ]])
{
    half4 c = atlas.sample(worldSampler, in.uv, in.layer);
    return worldLit(c, in, uniforms);
}

// Liquid surfaces (water/lava tops and sides). Same atlas sample + biome tint +
// day/night lighting as fragmentShader, but NO alpha cutout — instead the tile
// is returned translucent (alpha ~0.7) and nudged toward blue so the terrain
// behind it shows through. The liquid pipeline supplies the alpha blend and a
// depth-test-on / depth-write-off state, so this just authors the colour.
fragment float4 liquidFragment(ColorInOut in [[stage_in]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                               texture2d_array<half> atlas [[ texture(TextureIndexColor) ]])
{
    half4 c = atlas.sample(liquidSampler, in.uv, in.layer);
    half3 rgb = c.a > 0.0h ? c.rgb / c.a : c.rgb;   // un-premultiply
    rgb *= in.tint;                                 // biome palette tint (white = no change)
    // The mesher flags lava with a negative shade; it glows instead of being
    // treated as translucent blue water.
    bool lava = in.shade < 0.0;
    float shade = abs(in.shade);
    if (lava) {
        // Self-lit and opaque: keep the native orange, lift it so it reads as
        // molten day or night, and don't apply the water blue/alpha.
        float3 col = float3(rgb) * shade * 1.25;
        col = clamp(col, 0.0, 1.0);
        return float4(applyFog(col, in.fogDist, uniforms), 1.0);
    }
    // Stained glass: the mesher flags it with shade + 2. Use the texture's own
    // alpha (so a 40%-alpha pane reads as 40% translucent) with day/night light
    // and biome tint, but NONE of the water blue nudge or fixed 0.7 alpha.
    if (in.shade > 1.5) {
        float gshade = in.shade - 2.0;
        return float4(applyFog(float3(rgb) * gshade * in.lit, in.fogDist, uniforms), float(c.a));
    }
    float3 col = float3(rgb) * shade * in.lit;
    // Nudge toward VoxeLibre water blue so even a pale/animated tile reads as water.
    col = mix(col, col * float3(0.55, 0.75, 1.15), 0.35);
    return float4(applyFog(col, in.fogDist, uniforms), 0.7);
}

// Hash for the star field and moon mottle (the cloud noise is a baked
// texture now, see Renderer.cloudNoiseTexture).
static inline float skyHash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// Sky: a fullscreen triangle at the far plane (reverse-Z depth 0) so every
// pixel gets a colour AND a depth value. visionOS reprojects using depth and
// drops pixels that never wrote any, which is why a plain clear shows as black.
typedef struct { float4 position [[position]]; float3 rayDir; } SkyInOut;

vertex SkyInOut skyVertex(uint vid [[vertex_id]],
                          ushort amp_id [[amplification_id]],
                          constant ViewProjectionArray & vp [[ buffer(BufferIndexViewProjection) ]])
{
    // (0,0) (2,0) (0,2) -> covers the screen as one big triangle
    float2 uv = float2((vid << 1) & 2, vid & 2);
    float2 p = uv * 2.0 - 1.0;
    SkyInOut out;
    out.position = float4(p, 5e-5, 1.0);   // tiny non-zero depth: visionOS drops depth==0 pixels
    // Reconstruct the world-space view ray so we can place a real sun/gradient.
    float4 nearP = vp.inverseViewProjectionMatrix[amp_id] * float4(p, 1.0, 1.0);   // reverse-Z near
    float4 farP  = vp.inverseViewProjectionMatrix[amp_id] * float4(p, 5e-5, 1.0);  // far
    out.rayDir = (farP.xyz / farP.w) - (nearP.xyz / nearP.w);
    return out;
}

fragment float4 skyFragment(SkyInOut in [[stage_in]],
                            constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                            texturecube<half> skybox [[ texture(1) ]],
                            texture2d<half> cloudNoise [[ texture(2) ]])
{
    float3 rd = normalize(in.rayDir);
    // Server-set solid sky (a plain/skybox SET_SKY, e.g. the Nether/End): a flat
    // colour instead of our procedural day sky. a>0 enables it; a==2 means the
    // skybox cube is ready (the End's starry box), sampled along the WORLD ray
    // so it stays put when you stick-turn, like Sky::render's box does.
    if (uniforms.skySolid.a > 1.5) {
        constexpr sampler cs(mag_filter::linear, min_filter::linear);
        float3 rw = normalize((uniforms.skyRayToWorld * float4(rd, 0.0)).xyz);
        return float4(float3(skybox.sample(cs, rw).rgb), 1.0);
    }
    if (uniforms.skySolid.a > 0.0) { return float4(uniforms.skySolid.rgb, 1.0); }
    float up = clamp(rd.y, 0.0, 1.0);
    // Colours come from the server's SET_SKY (or the engine defaults). The
    // engine's night colours are bright bases that Sky::update dims by the
    // day-night brightness, so dim them here the same way.
    const float nightDim = 0.12;
    float3 dayHorizon   = uniforms.skyDayHorizon.rgb;
    float3 dayZenith    = uniforms.skyDayZenith.rgb;
    float3 nightHorizon = uniforms.skyNightHorizon.rgb * nightDim;
    float3 nightZenith  = uniforms.skyNightZenith.rgb * nightDim;
    float d = clamp((uniforms.daylight - 0.175) / 0.825, 0.0, 1.0);   // 0 = full night
    float3 horizon = mix(nightHorizon, dayHorizon, d);
    float3 zenith  = mix(nightZenith,  dayZenith,  d);
    // Sunrise/sunset: the sun-side sky leans to the sun tint, the far side to
    // the moon tint (the engine blends by camera yaw; per pixel reads the same
    // and doesn't swing when you turn). Weight = m_horizon_blend, 0 by day.
    float hb = uniforms.skySunTint.w;
    if (hb > 0.0) {
        float2 sxz = normalize(uniforms.sunDir.xz + float2(1e-5, 0.0));
        float2 rxz = normalize(rd.xz + float2(1e-5, 0.0));
        float side = clamp(dot(sxz, rxz) * 0.5 + 0.5, 0.0, 1.0);   // 1 toward the sun
        float3 point = mix(uniforms.skyMoonTint.rgb, uniforms.skySunTint.rgb, side);
        horizon = mix(horizon, point, hb * 0.5);
        zenith  = mix(zenith,  point, hb * 0.25);
    }
    float3 col = mix(horizon, zenith, smoothstep(0.0, 0.55, up));

    // Sun: a sharp disk plus a soft glow, only while it's up and daytime.
    // sunDir is unit length from the CPU.
    float sdot = dot(rd, uniforms.sunDir.xyz);
    // SET_SUN scale widens the disk (cosine threshold); visible gates it.
    // Engine sun quad: half-size 0.07*1.7 at unit distance = ~13.6 deg across
    // (cos threshold 0.007); drawn at full strength whenever it's above the
    // horizon (no elevation fade), which is what makes it visible at sunrise
    // instead of ~2 minutes later.
    float sr = 0.007 * uniforms.skyBodies.y;
    float disk = smoothstep(1.0 - sr, 1.0 - sr + 0.003, sdot);
    float g = max(sdot, 0.0);
    g *= g; g *= g; g *= g; g *= g;            // g^16
    float glow = g * g * g * 0.35;             // g^48, no exp/log
    float sunUp = smoothstep(-0.02, 0.02, uniforms.sunDir.y);
    col += (disk + glow) * float3(1.0, 0.96, 0.82) * mix(0.7, 1.0, d) * sunUp * uniforms.skyBodies.x;

    // Moon: opposite the sun, up and visible at night.
    float mdot = -sdot;
    // Engine moon quad: 0.04*1.9 half-size = ~8.7 deg across (cos threshold
    // 0.0029; the old 0.011 drew it twice the desktop size). A little hashed
    // mottling so it reads as a moon, not a lamp.
    float mr = 0.0029 * uniforms.skyBodies.w;                // SET_MOON scale
    float moon = smoothstep(1.0 - mr, 1.0 - mr + 0.0015, mdot);
    float moonUp = smoothstep(-0.02, 0.02, -uniforms.sunDir.y);
    if (moon > 0.0) {   // the hash only matters on the disk itself
        float mottle = 0.8 + 0.2 * skyHash(floor(rd.xz * 90.0));
        col += moon * float3(0.85, 0.87, 0.95) * mottle * (1.0 - d) * moonUp * uniforms.skyBodies.z;
    }

    // World-space ray so stars/clouds are anchored to the world (turn with a
    // stick-turn) instead of staying fixed to the head like the sun already does.
    // skyRayToWorld is a pure rotation/mirror, so the result stays unit length.
    float3 rw = (uniforms.skyRayToWorld * float4(rd, 0.0)).xyz;

    // Stars: sparse twinkling points high in the sky at night.
    // SET_STARS: visible, count (as a hash threshold), colour, scale (cell size).
    if (uniforms.skyStars.x > 0.5 && rw.y > 0.15 && d < 0.9) {
        float2 sp = floor(rw.xz / rw.y * 60.0 / max(uniforms.skyStars.z, 0.1));
        float s = skyHash(sp);
        float th = uniforms.skyStars.y;
        float star = smoothstep(th, th + 0.006, s);
        col += star * (1.0 - d) * uniforms.skyStarColor.rgb;
    }

    // Clouds: project the ray onto a high plane, sample drifting noise, and
    // fade them out toward the horizon. sunDir.w carries elapsed time.
    // CLOUD_PARAMS: density (cover threshold), height (plane factor), speed
    // (drift direction), color_bright; SET_SKY's clouds flag gates them.
    if (uniforms.skyStars.w > 0.5 && rw.y > 0.03) {
        float2 drift = float2(uniforms.skyClouds.z, uniforms.skyClouds.w) * uniforms.sunDir.w * 0.003;
        float2 cp = rw.xz / rw.y * (0.5 * uniforms.skyClouds.y) + drift;
        // The baked fbm tiles every 8 lattice cells of the old skyFbm(cp * 1.5).
        constexpr sampler ns(filter::linear, mip_filter::linear, address::repeat);
        float n = float(cloudNoise.sample(ns, cp * (1.5 / 8.0)).r);
        float th = mix(0.75, 0.35, clamp(uniforms.skyClouds.x, 0.0, 1.0));
        float cover = smoothstep(th, th + 0.28, n);
        float fade = smoothstep(0.03, 0.35, rd.y);
        float3 cloudCol = mix(float3(0.45, 0.48, 0.55), uniforms.skyCloudColor.rgb, d);
        col = mix(col, cloudCol, cover * fade * 0.9);
    }
    return float4(col, 1.0);
}

// Underwater tint: a fullscreen blended overlay drawn only while the eye/head
// node is inside a liquid, casting the whole view toward water colour (with the
// alpha-blended pipeline) so submersion actually reads as being underwater.
// No stage_in / view-projection: one clip-space triangle covers each eye's
// viewport, and the colour is uniform, so it needs no per-eye reconstruction.
vertex float4 underwaterVertex(uint vid [[vertex_id]])
{
    // (0,0) (2,0) (0,2) -> a triangle that covers the whole screen.
    float2 uv = float2((vid << 1) & 2, vid & 2);
    return float4(uv * 2.0 - 1.0, 5e-5, 1.0);
}

fragment float4 underwaterFragment(constant float4 &color [[buffer(0)]])
{
    // The camera node's post_effect_color from NODEDEF (what desktop draws as a
    // full-screen rectangle), already light-shaded on the session side.
    return color;
}

// Diegetic threshold vignette (HUD P8): a soft edge tint that stays clear in the
// centre, so low health / low breath registers at the periphery without reading
// the stat columns. color.rgb = tint, color.a = strength at the corners.
typedef struct { float4 position [[position]]; float2 uv; } VignetteInOut;
vertex VignetteInOut vignetteVertex(uint vid [[vertex_id]])
{
    float2 uv = float2((vid << 1) & 2, vid & 2);   // 0,0 / 2,0 / 0,2
    VignetteInOut o;
    o.position = float4(uv * 2.0 - 1.0, 5e-5, 1.0);
    o.uv = uv;                                     // 0..1 over the visible screen
    return o;
}
fragment float4 vignetteFragment(VignetteInOut in [[stage_in]], constant float4 &color [[buffer(0)]])
{
    float2 c = in.uv - 0.5;
    float d = length(c) * 1.41421356;              // 0 centre -> ~1 at the corners
    float v = smoothstep(0.32, 1.0, d);            // clear middle, ramps in toward the edges
    return float4(color.rgb, color.a * v);
}

fragment float4 handFragment()
{
    // Solid glove/skin tan for the controller-hand boxes (no texture).
    return float4(0.86, 0.66, 0.50, 1.0);
}

fragment float4 deathFragment()
{
    // Blood-red cast over the whole view when hp hits 0, so death is obvious
    // even without a text death screen. Reuses underwaterVertex + the same
    // blended fullscreen pass.
    return float4(0.55, 0.0, 0.0, 0.5);
}
