// Post-processing shader (three/addons/postprocessing), ShaderMaterial
// contract: frame block at group 0, object block at group 1 (both touched so
// they stay in the layout), uniforms at group 2. Fullscreen-quad vertices
// pass through; uv (0, 0) is the bottom left, so textures rendered by the
// renderer (top row first) are read at (u, 1 - v).

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

// FXAA (a compact form of FXAA 3.11's edge search): smooths aliased edges
// by luma contrast. Run it on display-ready (sRGB) colour, after OutputPass.
struct Uniforms { resolution: vec2<f32> };   // 1 / size in pixels
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tDiffuse: texture_2d<f32>;
@group(2) @binding(2) var s_tex: sampler;

fn luma(c: vec4<f32>) -> f32 {
    return dot(c.rgb, vec3<f32>(0.299, 0.587, 0.114));
}

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let px = u.resolution;
    let c = textureSample(tDiffuse, s_tex, in.uv);
    let nw = luma(textureSampleLevel(tDiffuse, s_tex, in.uv + vec2<f32>(-px.x, -px.y), 0.0));
    let ne = luma(textureSampleLevel(tDiffuse, s_tex, in.uv + vec2<f32>(px.x, -px.y), 0.0));
    let sw = luma(textureSampleLevel(tDiffuse, s_tex, in.uv + vec2<f32>(-px.x, px.y), 0.0));
    let se = luma(textureSampleLevel(tDiffuse, s_tex, in.uv + vec2<f32>(px.x, px.y), 0.0));
    let m = luma(c);
    let lo = min(m, min(min(nw, ne), min(sw, se)));
    let hi = max(m, max(max(nw, ne), max(sw, se)));
    var dir = vec2<f32>(-((nw + ne) - (sw + se)), (nw + sw) - (ne + se));
    let reduce = max((nw + ne + sw + se) * 0.25 * 0.125, 1.0 / 128.0);
    let rcp = 1.0 / (min(abs(dir.x), abs(dir.y)) + reduce);
    dir = clamp(dir * rcp, vec2<f32>(-8.0), vec2<f32>(8.0)) * px;
    let a = 0.5 * (textureSampleLevel(tDiffuse, s_tex, in.uv + dir * (1.0 / 3.0 - 0.5), 0.0)
        + textureSampleLevel(tDiffuse, s_tex, in.uv + dir * (2.0 / 3.0 - 0.5), 0.0));
    let b = a * 0.5 + 0.25 * (textureSampleLevel(tDiffuse, s_tex, in.uv + dir * -0.5, 0.0)
        + textureSampleLevel(tDiffuse, s_tex, in.uv + dir * 0.5, 0.0));
    let lb = luma(b);
    return select(b, a, lb < lo || lb > hi);
}
