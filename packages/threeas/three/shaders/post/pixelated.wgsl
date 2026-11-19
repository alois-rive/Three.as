// three.js examples/jsm/postprocessing/RenderPixelatedPass.js's pixelated
// material, as a post shader (see copy.wgsl): the low resolution render,
// darkened on depth edges and lightened on normal edges.

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

// Values in insertion order (resolution, normalEdgeStrength,
// depthEdgeStrength), then tDiffuse, tDepth, tNormal and tDiffuse's sampler
// (nearest).
struct Uniforms {
    resolution: vec4<f32>,
    normalEdgeStrength: f32,
    depthEdgeStrength: f32,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tDiffuse: texture_2d<f32>;
@group(2) @binding(2) var tDepth: texture_depth_2d;
@group(2) @binding(3) var tNormal: texture_2d<f32>;
@group(2) @binding(4) var s_tex: sampler;

// The texel (x, y) away from `uv` (y up, as three.js's vUv; rows here run
// top first).
fn texel_coord(uv: vec2<f32>, x: i32, y: i32) -> vec2<i32> {
    let size = u.resolution.xy;
    let p = (uv + vec2<f32>(f32(x), -f32(y)) * u.resolution.zw) * size;
    return vec2<i32>(clamp(floor(p), vec2<f32>(0.0), size - vec2<f32>(1.0)));
}

fn get_depth(uv: vec2<f32>, x: i32, y: i32) -> f32 {
    return textureLoad(tDepth, texel_coord(uv, x, y), 0);
}

fn get_normal(uv: vec2<f32>, x: i32, y: i32) -> vec3<f32> {
    return textureLoad(tNormal, texel_coord(uv, x, y), 0).rgb * 2.0 - 1.0;
}

fn depth_edge_indicator(uv: vec2<f32>, depth: f32) -> f32 {
    var diff = 0.0;
    diff += clamp(get_depth(uv, 1, 0) - depth, 0.0, 1.0);
    diff += clamp(get_depth(uv, -1, 0) - depth, 0.0, 1.0);
    diff += clamp(get_depth(uv, 0, 1) - depth, 0.0, 1.0);
    diff += clamp(get_depth(uv, 0, -1) - depth, 0.0, 1.0);
    return floor(smoothstep(0.01, 0.02, diff) * 2.0) / 2.0;
}

fn neighbor_normal_edge_indicator(uv: vec2<f32>, x: i32, y: i32, depth: f32, normal: vec3<f32>) -> f32 {
    let depth_diff = get_depth(uv, x, y) - depth;
    let neighbor_normal = get_normal(uv, x, y);
    // Edge pixels yield to faces whose normals are closer to the bias normal.
    let normal_edge_bias = vec3<f32>(1.0, 1.0, 1.0);
    let normal_diff = dot(normal - neighbor_normal, normal_edge_bias);
    let normal_indicator = clamp(smoothstep(-0.01, 0.01, normal_diff), 0.0, 1.0);
    // Only the shallower pixel detects the normal edge.
    let depth_indicator = clamp(sign(depth_diff * 0.25 + 0.0025), 0.0, 1.0);
    return (1.0 - dot(normal, neighbor_normal)) * depth_indicator * normal_indicator;
}

fn normal_edge_indicator(uv: vec2<f32>, depth: f32, normal: vec3<f32>) -> f32 {
    var indicator = 0.0;
    indicator += neighbor_normal_edge_indicator(uv, 0, -1, depth, normal);
    indicator += neighbor_normal_edge_indicator(uv, 0, 1, depth, normal);
    indicator += neighbor_normal_edge_indicator(uv, -1, 0, depth, normal);
    indicator += neighbor_normal_edge_indicator(uv, 1, 0, depth, normal);
    return step(0.1, indicator);
}

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let texel = textureSampleLevel(tDiffuse, s_tex, in.uv, 0.0);
    var depth = 0.0;
    var normal = vec3<f32>(0.0);
    if (u.depthEdgeStrength > 0.0 || u.normalEdgeStrength > 0.0) {
        depth = get_depth(in.uv, 0, 0);
        normal = get_normal(in.uv, 0, 0);
    }
    var dei = 0.0;
    if (u.depthEdgeStrength > 0.0) {
        dei = depth_edge_indicator(in.uv, depth);
    }
    var nei = 0.0;
    if (u.normalEdgeStrength > 0.0) {
        nei = normal_edge_indicator(in.uv, depth, normal);
    }
    let strength = select(1.0 + u.normalEdgeStrength * nei, 1.0 - u.depthEdgeStrength * dei, dei > 0.0);
    return texel * strength;
}
