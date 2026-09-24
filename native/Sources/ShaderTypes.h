//
//  Header containing types and enum constants shared between Metal shaders and Swift/ObjC source
//
#ifndef ShaderTypes_h
#define ShaderTypes_h

#ifdef __METAL_VERSION__
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
typedef metal::int32_t EnumBackingType;
#else
#import <Foundation/Foundation.h>
typedef NSInteger EnumBackingType;
#endif

#include <simd/simd.h>

typedef NS_ENUM(EnumBackingType, BufferIndex)
{
    BufferIndexMeshPositions  = 0,
    BufferIndexMeshGenerics   = 1,
    BufferIndexUniforms       = 2,
    BufferIndexViewProjection = 3,
};

typedef NS_ENUM(EnumBackingType, VertexAttribute)
{
    VertexAttributePosition   = 0,
    VertexAttributeTexcoord   = 1,
    VertexAttributeParams     = 2,
};

typedef NS_ENUM(EnumBackingType, TextureIndex)
{
    TextureIndexColor         = 0,
};

typedef struct
{
    matrix_float4x4 viewProjectionMatrix[2];
    matrix_float4x4 inverseViewProjectionMatrix[2];
} ViewProjectionArray;

typedef struct
{
    matrix_float4x4 modelMatrix;
    float daylight;
    vector_float4 sunDir;   // xyz = direction, in immersive-origin space
    vector_float4 skySolid; // rgb solid sky (Nether/End SET_SKY); a>0 = enabled
    // Rotates a sky view ray from immersive-origin space into WORLD space, so
    // stars/clouds stay fixed to the world (and turn when you stick-turn) like
    // the sun does. = transpose(mirror * R(-yaw)).
    matrix_float4x4 skyRayToWorld;
    // Server-driven sky look (SET_SKY regular colours, SET_SUN/MOON/STARS,
    // CLOUD_PARAMS, SET_LIGHTING); rgb in xyz. Filled from SkyParams.
    vector_float4 skyDayZenith;
    vector_float4 skyDayHorizon;
    vector_float4 skyNightZenith;
    vector_float4 skyNightHorizon;
    vector_float4 skyBodies;      // x sun visible, y sun scale, z moon visible, w moon scale
    vector_float4 skyStars;       // x visible, y hash threshold (density), z scale, w clouds on/off
    vector_float4 skyStarColor;   // rgb
    vector_float4 skyClouds;      // x density 0..1, y height factor, z speed.x, w speed.y
    vector_float4 skyCloudColor;  // rgb (color_bright)
    float saturation;             // SET_LIGHTING; 1 = untouched
    // Distance fog, the engine's linear fog toward the horizon colour:
    // fog.x = end distance in metres, fog.y = 1/(1 - fog_start) (the engine's
    // fogShadingParameter), eyePos = the head in immersive-origin space.
    vector_float4 fog;
    vector_float4 fogColor;       // rgb
    // Dawn/dusk point colour (sky.cpp): rgb of the sun tint and moon tint,
    // w of skySunTint = horizon blend weight (0 outside the sunrise/sunset window).
    vector_float4 skySunTint;
    vector_float4 skyMoonTint;
    vector_float4 eyePos;         // xyz
} Uniforms;

#endif /* ShaderTypes_h */

