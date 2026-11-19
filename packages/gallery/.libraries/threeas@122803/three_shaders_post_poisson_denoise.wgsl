// three.js PoissonDenoiseShader (examples/jsm/shaders/
// PoissonDenoiseShader.js): an edge-aware Poisson disk denoise, for
// GTAOPass. See ssao.wgsl for the conventions. SAMPLES and SAMPLE_VECTORS
// are uniforms (samples, at most 32; poissonDisk: xyz per vec4),
// NORMAL_VECTOR_TYPE too (normalVectorType); depth always comes from a
// depth texture (DEPTH_VALUE_SOURCE 0).

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

const MAX_SAMPLES: i32 = 32;

struct Uniforms {
    cameraProjectionMatrixInverse: mat4x4<f32>,
    poissonDisk: array<vec4<f32>, 32>,
    resolution: vec2<f32>,
    lumaPhi: f32,
    depthPhi: f32,
    normalPhi: f32,
    radius: f32,
    index: f32,
    samples: f32,
    normalVectorType: f32,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tDiffuse: texture_2d<f32>;
@group(2) @binding(2) var tNormal: texture_2d<f32>;
@group(2) @binding(3) var tDepth: texture_depth_2d;
@group(2) @binding(4) var tNoise: texture_2d<f32>;
@group(2) @binding(5) var s_tex: sampler;

const PI: f32 = 3.141592653589793;

fn get_luminance(a: vec3<f32>) -> f32 {
    return dot(vec3<f32>(0.2125, 0.7154, 0.0721), a);
}

fn get_view_position(uv: vec2<f32>, depth: f32) -> vec3<f32> {
    let clip = vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    let view = u.cameraProjectionMatrixInverse * clip;
    return view.xyz / view.w;
}

fn fetch_depth(p: vec2<i32>) -> f32 {
    let size = vec2<i32>(textureDimensions(tDepth));
    return textureLoad(tDepth, clamp(p, vec2<i32>(0), size - vec2<i32>(1)), 0);
}

fn get_depth(uv: vec2<f32>) -> f32 {
    let size = vec2<f32>(textureDimensions(tDepth));
    return fetch_depth(vec2<i32>(floor(uv * size)));
}

// As GTAOShader's (rows top down: "below" is +y in texels).
fn compute_normal_from_depth(uv: vec2<f32>) -> vec3<f32> {
    let size = vec2<f32>(textureDimensions(tDepth));
    let p = vec2<i32>(uv * size);
    let c0 = fetch_depth(p);
    let l2 = fetch_depth(p - vec2<i32>(2, 0));
    let l1 = fetch_depth(p - vec2<i32>(1, 0));
    let r1 = fetch_depth(p + vec2<i32>(1, 0));
    let r2 = fetch_depth(p + vec2<i32>(2, 0));
    let b2 = fetch_depth(p + vec2<i32>(0, 2));
    let b1 = fetch_depth(p + vec2<i32>(0, 1));
    let t1 = fetch_depth(p - vec2<i32>(0, 1));
    let t2 = fetch_depth(p - vec2<i32>(0, 2));
    let dl = abs((2.0 * l1 - l2) - c0);
    let dr = abs((2.0 * r1 - r2) - c0);
    let db = abs((2.0 * b1 - b2) - c0);
    let dt = abs((2.0 * t1 - t2) - c0);
    let ce = get_view_position(uv, c0);
    var dpdx_: vec3<f32>;
    if (dl < dr) {
        dpdx_ = ce - get_view_position(uv - vec2<f32>(1.0 / size.x, 0.0), l1);
    } else {
        dpdx_ = -ce + get_view_position(uv + vec2<f32>(1.0 / size.x, 0.0), r1);
    }
    var dpdy_: vec3<f32>;
    if (db < dt) {
        dpdy_ = ce - get_view_position(uv + vec2<f32>(0.0, 1.0 / size.y), b1);
    } else {
        dpdy_ = -ce + get_view_position(uv - vec2<f32>(0.0, 1.0 / size.y), t1);
    }
    return normalize(cross(dpdx_, dpdy_));
}

fn get_view_normal(uv: vec2<f32>) -> vec3<f32> {
    let size = vec2<i32>(textureDimensions(tNormal));
    let p = clamp(vec2<i32>(floor(uv * vec2<f32>(size))), vec2<i32>(0), size - vec2<i32>(1));
    let texel = textureLoad(tNormal, p, 0).rgb;
    if (u.normalVectorType > 1.5) {
        return normalize(texel);
    }
    if (u.normalVectorType > 0.5) {
        return texel * 2.0 - 1.0;
    }
    return compute_normal_from_depth(uv);
}

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let depth = get_depth(in.uv);
    let view_normal = get_view_normal(in.uv);
    let texel = textureSampleLevel(tDiffuse, s_tex, in.uv, 0.0);
    if (depth == 1.0 || dot(view_normal, view_normal) == 0.0) {
        discard;
    }
    let center = texel.rgb;
    let view_pos = get_view_position(in.uv, depth);

    let noise_size = vec2<i32>(textureDimensions(tNoise));
    let noise_texel = textureLoad(tNoise, vec2<i32>(floor(in.uv * u.resolution)) % noise_size, 0);
    let n = noise_texel[i32(u.index) % 4];
    let noise_vec = vec2<f32>(sin(n * 2.0 * PI), cos(n * 2.0 * PI));
    let rotation = mat2x2<f32>(noise_vec.x, -noise_vec.y, noise_vec.x, noise_vec.y);

    var total_weight = 1.0;
    var denoised = texel.rgb;
    let count = min(i32(u.samples), MAX_SAMPLES);
    for (var i = 0; i < count; i++) {
        let sample_dir = u.poissonDisk[i].xyz;
        let offset = rotation * (sample_dir.xy * (1.0 + sample_dir.z * (u.radius - 1.0)) / u.resolution);
        let sample_uv = in.uv + offset;

        // denoiseSample.
        let sample_texel = textureSampleLevel(tDiffuse, s_tex, sample_uv, 0.0);
        let sample_depth = get_depth(sample_uv);
        let sample_normal = get_view_normal(sample_uv);
        let neighbor_color = sample_texel.rgb;
        let view_pos_sample = get_view_position(sample_uv, sample_depth);
        let normal_diff = dot(view_normal, sample_normal);
        let normal_similarity = pow(max(normal_diff, 0.0), u.normalPhi);
        let luma_diff = abs(get_luminance(neighbor_color) - get_luminance(center));
        let luma_similarity = max(1.0 - luma_diff / u.lumaPhi, 0.0);
        let depth_diff = abs(dot(view_pos - view_pos_sample, view_normal));
        let depth_similarity = max(1.0 - depth_diff / u.depthPhi, 0.0);
        let w = luma_similarity * depth_similarity * normal_similarity;
        denoised += w * neighbor_color;
        total_weight += w;
    }
    if (total_weight > 0.0) {
        denoised /= total_weight;
    }
    return vec4<f32>(denoised, 1.0);
}
