// three.js DepthLimitedBlurShader (examples/jsm/shaders/
// DepthLimitedBlurShader.js): a separable gaussian that stops at depth
// edges, for SAOPass. See ssao.wgsl for the conventions. KERNEL_RADIUS and
// PERSPECTIVE_CAMERA are uniforms (kernelRadius, at most 64; perspective);
// sampleUvOffsets (xy) and sampleWeights (x) are arrays of vec4s. Depth is
// read from a depth texture (DEPTH_PACKING 0 only).

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

const MAX_KERNEL_RADIUS: i32 = 64;

struct Uniforms {
    sampleUvOffsets: array<vec4<f32>, 65>,
    sampleWeights: array<vec4<f32>, 65>,
    size: vec2<f32>,
    cameraNear: f32,
    cameraFar: f32,
    depthCutoff: f32,
    kernelRadius: f32,
    perspective: f32,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tDiffuse: texture_2d<f32>;
@group(2) @binding(2) var tDepth: texture_depth_2d;
@group(2) @binding(3) var s_tex: sampler;

const EPSILON: f32 = 1e-6;

fn get_depth(uv: vec2<f32>) -> f32 {
    let size = vec2<i32>(textureDimensions(tDepth));
    let p = clamp(vec2<i32>(floor(uv * vec2<f32>(size))), vec2<i32>(0), size - vec2<i32>(1));
    return textureLoad(tDepth, p, 0);
}

fn get_view_z(depth: f32) -> f32 {
    let near = u.cameraNear;
    let far = u.cameraFar;
    if (u.perspective > 0.5) {
        return (near * far) / ((far - near) * depth - far);
    }
    return depth * (near - far) - near;
}

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let inv_size = 1.0 / u.size;
    let depth = get_depth(in.uv);
    var weight_sum = u.sampleWeights[0].x;
    var diffuse_sum = textureSampleLevel(tDiffuse, s_tex, in.uv, 0.0) * weight_sum;
    if (depth >= 1.0 - EPSILON) {
        discard;
    }
    let center_view_z = -get_view_z(depth);
    var r_break = false;
    var l_break = false;
    let radius = min(i32(u.kernelRadius), MAX_KERNEL_RADIUS);
    for (var i = 1; i <= radius; i++) {
        let sample_weight = u.sampleWeights[i].x;
        let sample_uv_offset = u.sampleUvOffsets[i].xy * inv_size;

        var sample_uv = in.uv + sample_uv_offset;
        var view_z = -get_view_z(get_depth(sample_uv));
        if (abs(view_z - center_view_z) > u.depthCutoff) {
            r_break = true;
        }
        if (!r_break) {
            diffuse_sum += textureSampleLevel(tDiffuse, s_tex, sample_uv, 0.0) * sample_weight;
            weight_sum += sample_weight;
        }

        sample_uv = in.uv - sample_uv_offset;
        view_z = -get_view_z(get_depth(sample_uv));
        if (abs(view_z - center_view_z) > u.depthCutoff) {
            l_break = true;
        }
        if (!l_break) {
            diffuse_sum += textureSampleLevel(tDiffuse, s_tex, sample_uv, 0.0) * sample_weight;
            weight_sum += sample_weight;
        }
    }
    return diffuse_sum / weight_sum;
}
