// Byte layouts of the uniform blocks in three/shaders/three.wgsl (FrameU,
// ObjU, Light). Keep in sync with the shader.

export const MAX_LIGHTS: i32 = 32;
/// Lights one draw's fragments loop over (its nearest/strongest).
export const MAX_OBJECT_LIGHTS: i32 = 31;

export const FRAME_VIEW_PROJ: i32 = 0;
export const FRAME_VIEW: i32 = 64;
export const FRAME_INV_VIEW_PROJ: i32 = 128;
export const FRAME_CAMERA_POS: i32 = 192;
export const FRAME_CAMERA_DIR: i32 = 208;
export const FRAME_AMBIENT: i32 = 224;
export const FRAME_HEMI_SKY: i32 = 240;
export const FRAME_HEMI_GROUND: i32 = 256;
export const FRAME_HEMI_DIR: i32 = 272;
export const FRAME_FOG_COLOR: i32 = 288;
export const FRAME_FOG_PARAMS: i32 = 304;
export const FRAME_OUTPUT: i32 = 320;
export const FRAME_BG_ROTATION: i32 = 336;
export const FRAME_BG_FLAGS: i32 = 400;
export const FRAME_PROJ: i32 = 416;
export const FRAME_VIEWPORT: i32 = 480;
export const FRAME_ENV: i32 = 496;
export const FRAME_ENV_ROTATION: i32 = 512;
export const FRAME_ENV_FLAGS: i32 = 576;
export const FRAME_SHADOW_PARAMS: i32 = 592;
export const FRAME_PROBE: i32 = 608;     // 9 vec4: summed LightProbe SH coefficients
export const FRAME_LIGHTS: i32 = 752;
export const LIGHT_BYTES: i32 = 96;
export const FRAME_SHADOW_TILES: i32 = FRAME_LIGHTS + MAX_LIGHTS * LIGHT_BYTES;   // 3824
export const SHADOW_TILE_BYTES: i32 = 80;
export const MAX_SHADOW_TILES: i32 = 24;
export const FRAME_BYTES: i32 = FRAME_SHADOW_TILES + MAX_SHADOW_TILES * SHADOW_TILE_BYTES;   // 5744

export const OBJ_MODEL: i32 = 0;
export const OBJ_NORMAL: i32 = 64;
export const OBJ_COLOR: i32 = 128;
export const OBJ_EMISSIVE: i32 = 144;
export const OBJ_PBR: i32 = 160;
export const OBJ_UV: i32 = 176;
export const OBJ_SPECULAR: i32 = 192;
export const OBJ_EXTRA: i32 = 208;
export const OBJ_PHYSICAL0: i32 = 224;
export const OBJ_PHYSICAL1: i32 = 240;
export const OBJ_PHYSICAL2: i32 = 256;
export const OBJ_TEX_FLAGS: i32 = 272;
export const OBJ_FLAGS: i32 = 288;
export const OBJ_POINTS: i32 = 304;
export const OBJ_DASH: i32 = 320;
export const OBJ_SPRITE: i32 = 336;
export const OBJ_BIND_MATRIX: i32 = 352;
export const OBJ_BIND_MATRIX_INVERSE: i32 = 416;
export const OBJ_UV_MATRIX: i32 = 480;   // 8 slots x 2 vec4
export const OBJ_ENV: i32 = 736;         // x material envMap, y its max lod
// Extra maps (six slots, see MaterialUniforms' roles).
export const OBJ_X_UV: i32 = 752;        // 6 slots x 2 vec4 (row 0 w: channel, row 1 w: sampler binding)
export const OBJ_X_FLAGS: i32 = 944;     // u32: present, sRGB, premultiplied, flipY bits
export const OBJ_X_ROLES: i32 = 960;     // u32: roles 0-7 and 8-15 as slot nibbles (15: none), z tangents
export const OBJ_X_PARAMS: i32 = 976;    // bumpScale, displacementScale, displacementBias, lightMapIntensity
export const OBJ_X_PARAMS2: i32 = 992;   // normalMapType, combine, reflectivity, refractionRatio
export const OBJ_X_PARAMS3: i32 = 1008;  // clearcoatNormalScale xy, z 1: refraction mapping
// MeshPhysicalMaterial: transmission, volume, iridescence, anisotropy.
export const OBJ_PHYSICAL3: i32 = 1024;  // transmission, thickness, attenuationDistance, dispersion
export const OBJ_PHYSICAL4: i32 = 1040;  // attenuationColor rgb, iridescence
export const OBJ_PHYSICAL5: i32 = 1056;  // iridescenceIOR, thickness range min, max, anisotropy
export const OBJ_PHYSICAL6: i32 = 1072;  // anisotropy direction (cos, sin of anisotropyRotation)
export const OBJ_CLIP_PLANES: i32 = 1088;   // 8 planes: xyz normal, w constant (world)
export const OBJ_CLIP: i32 = 1216;          // x union count, y total count
export const MAX_CLIP_PLANES: i32 = 8;
export const OBJ_MISC0: i32 = 1232;   // MeshDistanceMaterial referencePosition xyz, nearDistance
export const OBJ_MISC1: i32 = 1248;   // farDistance, alphaHash
export const OBJ_LIGHTS: i32 = 1264;  // 2 vec4 of u8s: count, then up to 31 frame light indices
export const OBJ_USED: i32 = 1296;

/// Bones the uniform block B holds; bigger skeletons read a bone texture.
export const MAX_BONES: i32 = 256;
export const BONES_BYTES: i32 = MAX_BONES * 64;   // 16384

// MorphU (group 1 binding 7): two vec4<u32> headers, then (target, weight)
// pairs, two a vec4.
export const MORPH_INFO: i32 = 0;      // active count, flags, morph texture width, texels a target
export const MORPH_BONES: i32 = 16;    // bone texture width
export const MORPH_ACTIVE: i32 = 32;
export const MORPH_BYTES: i32 = 16384;
export const MAX_ACTIVE_MORPHS: i32 = (MORPH_BYTES - MORPH_ACTIVE) / 8;   // 2044
export const MORPH_NORMALS: u32 = 1;
export const MORPH_INSTANCED: u32 = 2;
export const BONE_TEXTURE: u32 = 4;
// The extra map slots (t_x0-t_x4) that vertex data borrows: a material
// keeps the others for its extra maps.
export const X_SLOT_MORPH: i32 = 4;          // morph target deltas
export const X_SLOT_BONES: i32 = 3;          // bone matrices (above MAX_BONES)
export const X_SLOT_MORPH_INSTANCES: i32 = 2;   // InstancedMesh.morphTexture
/// Texels a bone takes in the bone texture (3 rows, hi + lo each).
export const BONE_TEXELS: i32 = 6;
/// The per-draw buffer size (room to grow).
export const OBJ_BYTES: i32 = 1536;

export const FLAG_VERTEX_COLORS: u32 = 1;
export const FLAG_FOG: u32 = 2;
export const FLAG_TRANSPARENT: u32 = 4;
export const FLAG_TONE_MAPPED: u32 = 8;
export const FLAG_RECEIVE_SHADOW: u32 = 16;

export const LIGHT_DIRECTIONAL: f32 = 0;
export const LIGHT_POINT: f32 = 1;
export const LIGHT_SPOT: f32 = 2;
export const LIGHT_RECT: f32 = 3;

export const FOG_LINEAR: f32 = 1;
export const FOG_EXP2: f32 = 2;

/// Instance buffer stride: a mat4 then an RGBA colour.
export const INSTANCE_MATRIX_STRIDE: u32 = 64;   // slot 4: a mat4 per instance
export const INSTANCE_COLOR_STRIDE: u32 = 12;    // slot 5: rgb per instance
