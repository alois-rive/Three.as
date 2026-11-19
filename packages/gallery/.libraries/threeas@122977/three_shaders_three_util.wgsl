// ThreeAS renderer utilities (renderers/GPURenderer.as): clears inside a
// scissor rectangle and texture copies (copyFramebufferToTexture,
// copyTextureToTexture).

struct FillOut {
    @builtin(position) clip: vec4<f32>,
};

// A fullscreen triangle on the far plane (depth 1, the clear depth).
@vertex
fn vs_fill(@builtin(vertex_index) vi: u32) -> FillOut {
    var out: FillOut;
    let x = f32((vi << 1u) & 2u) * 2.0 - 1.0;
    let y = f32(vi & 2u) * 2.0 - 1.0;
    out.clip = vec4<f32>(x, y, 1.0, 1.0);
    return out;
}

// Scissored clears write 1 and blend it with the clear colour as the
// constant (one per colour attachment count).
@fragment
fn fs_one() -> @location(0) vec4<f32> {
    return vec4<f32>(1.0);
}

struct One2 {
    @location(0) c0: vec4<f32>,
    @location(1) c1: vec4<f32>,
};

@fragment
fn fs_one2() -> One2 {
    var out: One2;
    out.c0 = vec4<f32>(1.0);
    out.c1 = vec4<f32>(1.0);
    return out;
}

struct One3 {
    @location(0) c0: vec4<f32>,
    @location(1) c1: vec4<f32>,
    @location(2) c2: vec4<f32>,
};

@fragment
fn fs_one3() -> One3 {
    var out: One3;
    out.c0 = vec4<f32>(1.0);
    out.c1 = vec4<f32>(1.0);
    out.c2 = vec4<f32>(1.0);
    return out;
}

struct One4 {
    @location(0) c0: vec4<f32>,
    @location(1) c1: vec4<f32>,
    @location(2) c2: vec4<f32>,
    @location(3) c3: vec4<f32>,
};

@fragment
fn fs_one4() -> One4 {
    var out: One4;
    out.c0 = vec4<f32>(1.0);
    out.c1 = vec4<f32>(1.0);
    out.c2 = vec4<f32>(1.0);
    out.c3 = vec4<f32>(1.0);
    return out;
}

// Copies: the destination rectangle is the viewport; each fragment reads
// the source texel at the same offset from the source rectangle's corner.
struct CopyU {
    // x, y: the source rectangle's top left texel; z, w: the destination
    // rectangle's top left pixel.
    origin: vec4<f32>,
    // x: 1 flips rows (the source rectangle's rows bottom up), y: the
    // source rectangle's height.
    flags: vec4<f32>,
};

@group(0) @binding(0) var<uniform> C: CopyU;
@group(0) @binding(1) var t_copy: texture_2d<f32>;

@fragment
fn fs_copy(in: FillOut) -> @location(0) vec4<f32> {
    var d = floor(in.clip.xy) - C.origin.zw;
    if (C.flags.x > 0.5) {
        d.y = C.flags.y - 1.0 - d.y;
    }
    let p = vec2<i32>(C.origin.xy + d);
    return textureLoad(t_copy, p, 0);
}
