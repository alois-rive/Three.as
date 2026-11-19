// three.js SSAOShader (examples/jsm/shaders/SSAOShader.js), for SSAOPass.
// Post shader contract (see copy.wgsl): in.uv has v down, so render
// target textures (rows top first) are read at in.uv; ndc.y = 1 - 2 uv.y.
// Projections map depth to [0, 1] (WebGPU): a fragment unprojects with
// clip z = depth. KERNEL_SIZE and PERSPECTIVE_CAMERA are uniforms
// (kernelSize, perspective): WGSL pipelines take no defines.

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

// Uniforms, in SSAOShaderDefinition's insertion order.
struct Uniforms {
    cameraProjectionMatrix: mat4x4<f32>,
    cameraInverseProjectionMatrix: mat4x4<f32>,
    kernel: array<vec4<f32>, 32>,
    resolution: vec2<f32>,
    cameraNear: f32,
    cameraFar: f32,
    kernelRadius: f32,
    minDistance: f32,
    maxDistance: f32,
    kernelSize: f32,
    perspective: f32,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tNormal: texture_2d<f32>;
@group(2) @binding(2) var tDepth: texture_depth_2d;
@group(2) @binding(3) var tNoise: texture_2d<f32>;
@group(2) @binding(4) var s_tex: sampler;

fn perspective_depth_to_view_z(depth: f32, near: f32, far: f32) -> f32 {
    return (near * far) / ((far - near) * depth - far);
}

fn orthographic_depth_to_view_z(depth: f32, near: f32, far: f32) -> f32 {
    return depth * (near - far) - near;
}

fn view_z_to_orthographic_depth(view_z: f32, near: f32, far: f32) -> f32 {
    return (view_z + near) / (near - far);
}

fn get_depth(uv: vec2<f32>) -> f32 {
    let size = vec2<i32>(textureDimensions(tDepth));
    let p = clamp(vec2<i32>(floor(uv * vec2<f32>(size))), vec2<i32>(0), size - vec2<i32>(1));
    return textureLoad(tDepth, p, 0);
}

fn get_linear_depth(uv: vec2<f32>) -> f32 {
    let d = get_depth(uv);
    if (u.perspective > 0.5) {
        let view_z = perspective_depth_to_view_z(d, u.cameraNear, u.cameraFar);
        return view_z_to_orthographic_depth(view_z, u.cameraNear, u.cameraFar);
    }
    return d;
}

fn get_view_z(depth: f32) -> f32 {
    if (u.perspective > 0.5) {
        return perspective_depth_to_view_z(depth, u.cameraNear, u.cameraFar);
    }
    return orthographic_depth_to_view_z(depth, u.cameraNear, u.cameraFar);
}

fn get_view_position(uv: vec2<f32>, depth: f32, view_z: f32) -> vec3<f32> {
    let clip_w = u.cameraProjectionMatrix[2][3] * view_z + u.cameraProjectionMatrix[3][3];
    let clip = vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0) * clip_w;
    return (u.cameraInverseProjectionMatrix * clip).xyz;
}

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let depth = get_depth(in.uv);
    // The normals (packed) and the noise, read before any branch.
    let packed = textureSampleLevel(tNormal, s_tex, in.uv, 0.0).xyz;
    let noise_size = vec2<i32>(textureDimensions(tNoise));
    let np = vec2<i32>(floor(in.uv * u.resolution)) % noise_size;
    let random = vec3<f32>(textureLoad(tNoise, np, 0).r);
    if (depth == 1.0) {
        return vec4<f32>(1.0);   // don't influence the background
    }
    let view_z = get_view_z(depth);
    let view_position = get_view_position(in.uv, depth, view_z);
    let view_normal = packed * 2.0 - 1.0;

    // The matrix reorienting a kernel vector.
    let tangent = normalize(random - view_normal * dot(random, view_normal));
    let bitangent = cross(view_normal, tangent);
    let kernel_matrix = mat3x3<f32>(tangent, bitangent, view_normal);

    var occlusion = 0.0;
    let count = i32(u.kernelSize);
    for (var i = 0; i < count; i++) {
        let sample_vector = kernel_matrix * u.kernel[i].xyz;
        let sample_point = view_position + sample_vector * u.kernelRadius;
        var ndc = u.cameraProjectionMatrix * vec4<f32>(sample_point, 1.0);
        ndc = ndc / ndc.w;
        let sample_uv = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
        let real_depth = get_linear_depth(sample_uv);
        let sample_depth = view_z_to_orthographic_depth(sample_point.z, u.cameraNear, u.cameraFar);
        let delta = sample_depth - real_depth;
        if (delta > u.minDistance && delta < u.maxDistance) {
            occlusion += 1.0;
        }
    }
    occlusion = clamp(occlusion / f32(max(count, 1)), 0.0, 1.0);
    return vec4<f32>(vec3<f32>(1.0 - occlusion), 1.0);
}
