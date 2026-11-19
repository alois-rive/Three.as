// three.js SAOShader (examples/jsm/shaders/SAOShader.js), for SAOPass.
// See ssao.wgsl for the conventions. NUM_SAMPLES (7) and NUM_RINGS (4) are
// constants as three.js's defines; DIFFUSE_TEXTURE and PERSPECTIVE_CAMERA
// are uniforms (diffuseTexture, perspective).

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

struct Uniforms {
    cameraProjectionMatrix: mat4x4<f32>,
    cameraInverseProjectionMatrix: mat4x4<f32>,
    size: vec2<f32>,
    cameraNear: f32,
    cameraFar: f32,
    scale: f32,
    intensity: f32,
    bias: f32,
    minResolution: f32,
    kernelRadius: f32,
    randomSeed: f32,
    perspective: f32,
    diffuseTexture: f32,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tNormal: texture_2d<f32>;
@group(2) @binding(2) var tDepth: texture_depth_2d;
@group(2) @binding(3) var tDiffuse: texture_2d<f32>;
@group(2) @binding(4) var s_tex: sampler;

const PI: f32 = 3.141592653589793;
const PI2: f32 = 6.283185307179586;
const EPSILON: f32 = 1e-6;
const NUM_SAMPLES: i32 = 7;
const NUM_RINGS: i32 = 4;
const ANGLE_STEP: f32 = PI2 * f32(NUM_RINGS) / f32(NUM_SAMPLES);
const INV_NUM_SAMPLES: f32 = 1.0 / f32(NUM_SAMPLES);

// three.js's rand (common).
fn rand(uv: vec2<f32>) -> f32 {
    let dt = dot(uv, vec2<f32>(12.9898, 78.233));
    let sn = dt - PI * floor(dt / PI);
    return fract(sin(sn) * 43758.5453);
}

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

fn get_view_position(uv: vec2<f32>, depth: f32, view_z: f32) -> vec3<f32> {
    let clip_w = u.cameraProjectionMatrix[2][3] * view_z + u.cameraProjectionMatrix[3][3];
    let clip = vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0) * clip_w;
    return (u.cameraInverseProjectionMatrix * clip).xyz;
}

fn get_occlusion(center: vec3<f32>, normal: vec3<f32>, sample_position: vec3<f32>, scale_by_far: f32,
                 min_res_by_far: f32) -> f32 {
    let view_delta = sample_position - center;
    let view_distance = length(view_delta);
    let scaled_screen_distance = scale_by_far * view_distance;
    return max(0.0, (dot(normal, view_delta) - min_res_by_far) / scaled_screen_distance - u.bias)
        / (1.0 + scaled_screen_distance * scaled_screen_distance);
}

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let center_depth = get_depth(in.uv);
    let normal = textureSampleLevel(tNormal, s_tex, in.uv, 0.0).xyz * 2.0 - 1.0;
    var color = vec4<f32>(1.0);
    if (u.diffuseTexture > 0.5) {
        color = textureSampleLevel(tDiffuse, s_tex, in.uv, 0.0);
    }
    if (center_depth >= 1.0 - EPSILON) {
        discard;
    }
    let center_view_z = get_view_z(center_depth);
    let center = get_view_position(in.uv, center_depth, center_view_z);

    // getAmbientOcclusion.
    let scale_by_far = u.scale / u.cameraFar;
    let min_res_by_far = u.minResolution * u.cameraFar;
    var angle = rand(in.uv + u.randomSeed) * PI2;
    var radius = vec2<f32>(u.kernelRadius * INV_NUM_SAMPLES) / u.size;
    let radius_step = radius;
    var occlusion_sum = 0.0;
    var weight_sum = 0.0;
    for (var i = 0; i < NUM_SAMPLES; i++) {
        let sample_uv = in.uv + vec2<f32>(cos(angle), sin(angle)) * radius;
        radius += radius_step;
        angle += ANGLE_STEP;
        let sample_depth = get_depth(sample_uv);
        if (sample_depth >= 1.0 - EPSILON) {
            continue;
        }
        let sample_view_z = get_view_z(sample_depth);
        let sample_position = get_view_position(sample_uv, sample_depth, sample_view_z);
        occlusion_sum += get_occlusion(center, normal, sample_position, scale_by_far, min_res_by_far);
        weight_sum += 1.0;
    }
    if (weight_sum == 0.0) {
        discard;
    }
    let ambient_occlusion = occlusion_sum * (u.intensity / max(weight_sum, 1.0));
    return vec4<f32>(color.rgb * (1.0 - ambient_occlusion), color.a);
}
