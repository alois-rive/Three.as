// three.js BokehShader (examples/jsm/shaders/BokehShader.js, after Martins
// Upitis's lens blur): 41 taps whose spread grows with the distance from
// the focus plane. Post shader (see copy.wgsl). The depth is the scene's
// DepthTexture (window depth, read exactly) rather than an RGBA-packed
// MeshDepthMaterial target.

struct Frame { view_proj: mat4x4<f32> };
struct Object { model: mat4x4<f32> };
@group(0) @binding(0) var<uniform> frame: Frame;
@group(1) @binding(0) var<uniform> object: Object;

struct QuadOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_main(@location(0) position: vec3<f32>, @location(2) uv: vec2<f32>) -> QuadOut {
    var out: QuadOut;
    let keep = frame.view_proj[3][3] * 0.0 + object.model[3][3] * 0.0;
    out.clip = vec4<f32>(position.xy, 0.5 + keep, 1.0);
    out.uv = vec2<f32>(uv.x, 1.0 - uv.y);
    return out;
}

// Uniforms in insertion order (then tColor, tDepth). perspective: 1 for a
// PerspectiveCamera (three.js's PERSPECTIVE_CAMERA define).
struct Uniforms {
    focus: f32,
    aspect: f32,
    aperture: f32,
    maxblur: f32,
    nearClip: f32,
    farClip: f32,
    perspective: f32,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tColor: texture_2d<f32>;
@group(2) @binding(2) var tDepth: texture_depth_2d;
@group(2) @binding(3) var s_tex: sampler;

fn get_depth(uv: vec2<f32>) -> f32 {
    let size = vec2<i32>(textureDimensions(tDepth));
    let p = clamp(vec2<i32>(uv * vec2<f32>(size)), vec2<i32>(0), size - vec2<i32>(1));
    return textureLoad(tDepth, p, 0);
}

// three.js's packing.glsl (the same for [0, 1] window depth).
fn get_view_z(depth: f32) -> f32 {
    if (u.perspective > 0.5) {
        return (u.nearClip * u.farClip) / ((u.farClip - u.nearClip) * depth - u.farClip);
    }
    return depth * (u.nearClip - u.farClip) - u.nearClip;
}

// One tap: offsets are in three.js's uv space (y up); textures are top first.
fn tap(uv: vec2<f32>, offset: vec2<f32>, blur: vec2<f32>) -> vec4<f32> {
    let o = offset * vec2<f32>(1.0, u.aspect) * blur;
    return textureSampleLevel(tColor, s_tex, uv + vec2<f32>(o.x, -o.y), 0.0);
}

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let uv = in.uv;
    let view_z = get_view_z(get_depth(uv));
    let factor = u.focus + view_z;   // view_z <= 0: a difference
    let dofblur = vec2<f32>(clamp(factor * u.aperture, -u.maxblur, u.maxblur));
    let dofblur9 = dofblur * 0.9;
    let dofblur7 = dofblur * 0.7;
    let dofblur4 = dofblur * 0.4;
    var col = vec4<f32>(0.0);
    col += textureSampleLevel(tColor, s_tex, uv, 0.0);
    col += tap(uv, vec2<f32>(0.0, 0.4), dofblur);
    col += tap(uv, vec2<f32>(0.15, 0.37), dofblur);
    col += tap(uv, vec2<f32>(0.29, 0.29), dofblur);
    col += tap(uv, vec2<f32>(-0.37, 0.15), dofblur);
    col += tap(uv, vec2<f32>(0.40, 0.0), dofblur);
    col += tap(uv, vec2<f32>(0.37, -0.15), dofblur);
    col += tap(uv, vec2<f32>(0.29, -0.29), dofblur);
    col += tap(uv, vec2<f32>(-0.15, -0.37), dofblur);
    col += tap(uv, vec2<f32>(0.0, -0.4), dofblur);
    col += tap(uv, vec2<f32>(-0.15, 0.37), dofblur);
    col += tap(uv, vec2<f32>(-0.29, 0.29), dofblur);
    col += tap(uv, vec2<f32>(0.37, 0.15), dofblur);
    col += tap(uv, vec2<f32>(-0.4, 0.0), dofblur);
    col += tap(uv, vec2<f32>(-0.37, -0.15), dofblur);
    col += tap(uv, vec2<f32>(-0.29, -0.29), dofblur);
    col += tap(uv, vec2<f32>(0.15, -0.37), dofblur);
    col += tap(uv, vec2<f32>(0.15, 0.37), dofblur9);
    col += tap(uv, vec2<f32>(-0.37, 0.15), dofblur9);
    col += tap(uv, vec2<f32>(0.37, -0.15), dofblur9);
    col += tap(uv, vec2<f32>(-0.15, -0.37), dofblur9);
    col += tap(uv, vec2<f32>(-0.15, 0.37), dofblur9);
    col += tap(uv, vec2<f32>(0.37, 0.15), dofblur9);
    col += tap(uv, vec2<f32>(-0.37, -0.15), dofblur9);
    col += tap(uv, vec2<f32>(0.15, -0.37), dofblur9);
    col += tap(uv, vec2<f32>(0.29, 0.29), dofblur7);
    col += tap(uv, vec2<f32>(0.40, 0.0), dofblur7);
    col += tap(uv, vec2<f32>(0.29, -0.29), dofblur7);
    col += tap(uv, vec2<f32>(0.0, -0.4), dofblur7);
    col += tap(uv, vec2<f32>(-0.29, 0.29), dofblur7);
    col += tap(uv, vec2<f32>(-0.4, 0.0), dofblur7);
    col += tap(uv, vec2<f32>(-0.29, -0.29), dofblur7);
    col += tap(uv, vec2<f32>(0.0, 0.4), dofblur7);
    col += tap(uv, vec2<f32>(0.29, 0.29), dofblur4);
    col += tap(uv, vec2<f32>(0.4, 0.0), dofblur4);
    col += tap(uv, vec2<f32>(0.29, -0.29), dofblur4);
    col += tap(uv, vec2<f32>(0.0, -0.4), dofblur4);
    col += tap(uv, vec2<f32>(-0.29, 0.29), dofblur4);
    col += tap(uv, vec2<f32>(-0.4, 0.0), dofblur4);
    col += tap(uv, vec2<f32>(-0.29, -0.29), dofblur4);
    col += tap(uv, vec2<f32>(0.0, 0.4), dofblur4);
    var result = col / 41.0;
    result.a = 1.0;
    return result;
}
