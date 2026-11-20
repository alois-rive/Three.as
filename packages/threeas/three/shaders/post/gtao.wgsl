// three.js GTAOShader (examples/jsm/shaders/GTAOShader.js), for GTAOPass:
// ground truth ambient occlusion by horizon search. See ssao.wgsl for the
// conventions. The defines are uniforms: SAMPLES (samples),
// PERSPECTIVE_CAMERA (perspective), NORMAL_VECTOR_TYPE (normalVectorType:
// 0 normals from depth, 1 packed, 2 unpacked), SCREEN_SPACE_RADIUS
// (screenSpaceRadius, scale 100) and SCENE_CLIP_BOX (sceneClipBox). Depth
// always comes from a depth texture (DEPTH_SWIZZLING "x").

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
    cameraProjectionMatrixInverse: mat4x4<f32>,
    cameraWorldMatrix: mat4x4<f32>,
    sceneBoxMin: vec3<f32>,
    radius: f32,
    sceneBoxMax: vec3<f32>,
    distanceExponent: f32,
    resolution: vec2<f32>,
    cameraNear: f32,
    cameraFar: f32,
    thickness: f32,
    distanceFallOff: f32,
    scale: f32,
    samples: f32,
    perspective: f32,
    normalVectorType: f32,
    screenSpaceRadius: f32,
    sceneClipBox: f32,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tNormal: texture_2d<f32>;
@group(2) @binding(2) var tDepth: texture_depth_2d;
@group(2) @binding(3) var tNoise: texture_2d<f32>;
@group(2) @binding(4) var s_tex: sampler;

const PI: f32 = 3.141592653589793;
const SCREEN_SPACE_RADIUS_SCALE: f32 = 100.0;

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

// Rows run top down here, so "below" (b) is +y in texels: the cross product
// order is kept so the normal still faces the camera.
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
    let texel = textureSampleLevel(tNormal, s_tex, uv, 0.0).rgb;
    if (u.normalVectorType > 1.5) {
        return normalize(texel);
    }
    if (u.normalVectorType > 0.5) {
        return texel * 2.0 - 1.0;
    }
    return compute_normal_from_depth(uv);
}

fn get_scene_uv_and_depth(sample_view_pos: vec3<f32>) -> vec3<f32> {
    let clip = u.cameraProjectionMatrix * vec4<f32>(sample_view_pos, 1.0);
    let ndc = clip.xy / clip.w;
    let sample_uv = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    return vec3<f32>(sample_uv, get_depth(sample_uv));
}

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let depth = get_depth(in.uv);
    let view_normal = get_view_normal(in.uv);
    if (depth >= 1.0) {
        discard;
    }
    let view_pos = get_view_position(in.uv, depth);

    var radius_to_use = u.radius;
    var distance_falloff_to_use = u.thickness;
    if (u.screenSpaceRadius > 0.5) {
        let radius_scale = get_view_position(vec2<f32>(0.5 + SCREEN_SPACE_RADIUS_SCALE / u.resolution.x, 0.0), depth).x;
        radius_to_use *= radius_scale;
        distance_falloff_to_use *= radius_scale;
    }

    var box_distance = 0.0;
    if (u.sceneClipBox > 0.5) {
        let world_pos = (u.cameraWorldMatrix * vec4<f32>(view_pos, 1.0)).xyz;
        box_distance = length(max(vec3<f32>(0.0), max(u.sceneBoxMin - world_pos, world_pos - u.sceneBoxMax)));
        if (box_distance > radius_to_use) {
            discard;
        }
    }

    // The noise repeats over the screen (RepeatWrapping, nearest).
    let noise_size = vec2<i32>(textureDimensions(tNoise));
    let noise_texel = textureLoad(tNoise, vec2<i32>(floor(in.uv * u.resolution)) % noise_size, 0);
    let random_vec = noise_texel.xyz * 2.0 - 1.0;
    let tangent = normalize(vec3<f32>(random_vec.xy, 0.0));
    let bitangent = vec3<f32>(-tangent.y, tangent.x, 0.0);
    let kernel_matrix = mat3x3<f32>(tangent, bitangent, vec3<f32>(0.0, 0.0, 1.0));

    let samples = i32(u.samples);
    let directions = select(5, 3, samples < 30);
    let steps = (samples + directions - 1) / directions;
    var ao = 0.0;
    for (var i = 0; i < directions; i++) {
        let angle = f32(i) / f32(directions) * PI;
        var sample_dir = vec4<f32>(cos(angle), sin(angle), 0.0, 0.5 + 0.5 * noise_texel.w);
        sample_dir = vec4<f32>(normalize(kernel_matrix * sample_dir.xyz), sample_dir.w);

        let view_dir = normalize(-view_pos);
        let slice_bitangent = normalize(cross(sample_dir.xyz, view_dir));
        let slice_tangent = cross(slice_bitangent, view_dir);
        let normal_in_slice = normalize(view_normal - slice_bitangent * dot(view_normal, slice_bitangent));

        let tangent_to_normal_in_slice = cross(normal_in_slice, slice_bitangent);
        var cos_horizons = vec2<f32>(dot(view_dir, tangent_to_normal_in_slice),
            dot(view_dir, -tangent_to_normal_in_slice));

        for (var j = 0; j < steps; j++) {
            let sample_view_offset = sample_dir.xyz * radius_to_use * sample_dir.w
                * pow(f32(j + 1) / f32(steps), u.distanceExponent);

            var scene = get_scene_uv_and_depth(view_pos + sample_view_offset);
            var scene_view_pos = get_view_position(scene.xy, scene.z);
            var view_delta = scene_view_pos - view_pos;
            if (abs(view_delta.z) < distance_falloff_to_use) {
                let sample_cos_horizon = dot(view_dir, normalize(view_delta));
                cos_horizons.x += max(0.0, (sample_cos_horizon - cos_horizons.x)
                    * mix(1.0, 2.0 / f32(j + 2), u.distanceFallOff));
            }

            scene = get_scene_uv_and_depth(view_pos - sample_view_offset);
            scene_view_pos = get_view_position(scene.xy, scene.z);
            view_delta = scene_view_pos - view_pos;
            if (abs(view_delta.z) < distance_falloff_to_use) {
                let sample_cos_horizon = dot(view_dir, normalize(view_delta));
                cos_horizons.y += max(0.0, (sample_cos_horizon - cos_horizons.y)
                    * mix(1.0, 2.0 / f32(j + 2), u.distanceFallOff));
            }
        }

        let sin_horizons = sqrt(1.0 - cos_horizons * cos_horizons);
        let nx = dot(normal_in_slice, slice_tangent);
        let ny = dot(normal_in_slice, view_dir);
        let nxb = 0.5 * (acos(cos_horizons.y) - acos(cos_horizons.x) + sin_horizons.x * cos_horizons.x
            - sin_horizons.y * cos_horizons.y);
        let nyb = 0.5 * (2.0 - cos_horizons.x * cos_horizons.x - cos_horizons.y * cos_horizons.y);
        ao += nx * nxb + ny * nyb;
    }

    ao = clamp(ao / f32(directions), 0.0, 1.0);
    if (u.sceneClipBox > 0.5) {
        ao = mix(ao, 1.0, smoothstep(0.0, radius_to_use, box_distance));
    }
    ao = pow(ao, u.scale);
    return vec4<f32>(vec3<f32>(ao), 1.0);
}
