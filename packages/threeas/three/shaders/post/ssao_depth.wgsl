// three.js SSAODepthShader (examples/jsm/shaders/SSAOShader.js): the depth
// texture as linear depth, white near. See ssao.wgsl for the conventions.
// The sampler a post shader's group 2 always has is paired with tDiffuse
// (white unless set), as a depth texture is read with textureLoad.

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
    cameraNear: f32,
    cameraFar: f32,
    perspective: f32,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tDiffuse: texture_2d<f32>;
@group(2) @binding(2) var tDepth: texture_depth_2d;
@group(2) @binding(3) var s_tex: sampler;

fn get_linear_depth(uv: vec2<f32>) -> f32 {
    let size = vec2<i32>(textureDimensions(tDepth));
    let p = clamp(vec2<i32>(floor(uv * vec2<f32>(size))), vec2<i32>(0), size - vec2<i32>(1));
    let d = textureLoad(tDepth, p, 0);
    if (u.perspective > 0.5) {
        let near = u.cameraNear;
        let far = u.cameraFar;
        let view_z = (near * far) / ((far - near) * d - far);
        return (view_z + near) / (near - far);
    }
    return d;
}

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let unused = textureSampleLevel(tDiffuse, s_tex, in.uv, 0.0).a * 0.0;
    let depth = get_linear_depth(in.uv);
    return vec4<f32>(vec3<f32>(1.0 - depth + unused), 1.0);
}
