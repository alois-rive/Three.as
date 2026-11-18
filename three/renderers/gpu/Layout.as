// Byte layouts of the uniform blocks in three/shaders/three.wgsl (FrameU,
// ObjU, Light). Keep in sync with the shader.

export const MAX_LIGHTS: i32 = 8;

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
export const FRAME_LIGHTS: i32 = 608;
export const LIGHT_BYTES: i32 = 96;
export const FRAME_SHADOW_TILES: i32 = FRAME_LIGHTS + MAX_LIGHTS * LIGHT_BYTES;   // 1376
export const SHADOW_TILE_BYTES: i32 = 80;
export const MAX_SHADOW_TILES: i32 = 12;
export const FRAME_BYTES: i32 = FRAME_SHADOW_TILES + MAX_SHADOW_TILES * SHADOW_TILE_BYTES;   // 2336

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
export const OBJ_USED: i32 = 752;

export const MAX_BONES: i32 = 256;
export const BONES_BYTES: i32 = MAX_BONES * 64;   // 16384
/// The per-draw buffer size (room to grow).
export const OBJ_BYTES: i32 = 768;

export const FLAG_VERTEX_COLORS: u32 = 1;
export const FLAG_FOG: u32 = 2;
export const FLAG_TRANSPARENT: u32 = 4;
export const FLAG_TONE_MAPPED: u32 = 8;
export const FLAG_RECEIVE_SHADOW: u32 = 16;

export const LIGHT_DIRECTIONAL: f32 = 0;
export const LIGHT_POINT: f32 = 1;
export const LIGHT_SPOT: f32 = 2;

export const FOG_LINEAR: f32 = 1;
export const FOG_EXP2: f32 = 2;

/// Instance buffer stride: a mat4 then an RGBA colour.
export const INSTANCE_MATRIX_STRIDE: u32 = 64;   // slot 4: a mat4 per instance
export const INSTANCE_COLOR_STRIDE: u32 = 12;    // slot 5: rgb per instance
