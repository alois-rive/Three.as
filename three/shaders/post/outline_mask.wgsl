// OutlinePass's prepare-mask material (three.js OutlinePass.js
// getPrepareMaskMaterial): draws the selected objects as (0, hidden, 1, 1),
// `hidden` 1 where the non-selected objects' depth is in front. A
// ShaderMaterial over scene meshes (frame and object blocks, instancing
// through the instance matrix; no skinning or morphs). The depth of the
// non-selected objects is a DepthTexture the size of this pass, read at the
// fragment's pixel (three.js projects with textureMatrix instead).

struct Frame {
    view_proj: mat4x4<f32>,
    view: mat4x4<f32>,
};
struct Object {
    model: mat4x4<f32>,
};
@group(0) @binding(0) var<uniform> frame: Frame;
@group(1) @binding(0) var<uniform> object: Object;

// Uniforms in insertion order: cameraNearFar, perspective (then depthTexture).
struct Uniforms {
    cameraNearFar: vec2<f32>,
    perspective: f32,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var depthTexture: texture_depth_2d;
@group(2) @binding(2) var s_depth: sampler;

struct VsIn {
    @location(0) position: vec3<f32>,
    @location(4) i0: vec4<f32>,
    @location(5) i1: vec4<f32>,
    @location(6) i2: vec4<f32>,
    @location(7) i3: vec4<f32>,
};

struct VsOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) view_pos: vec3<f32>,
};

@vertex
fn vs_main(in: VsIn) -> VsOut {
    var out: VsOut;
    let instance = mat4x4<f32>(in.i0, in.i1, in.i2, in.i3);
    let world = object.model * instance * vec4<f32>(in.position, 1.0);
    out.view_pos = (frame.view * world).xyz;
    out.clip = frame.view_proj * world;
    return out;
}

fn depth_to_view_z(depth: f32, near: f32, far: f32) -> f32 {
    if (u.perspective > 0.5) {
        return (near * far) / ((far - near) * depth - far);
    }
    return depth * (near - far) - near;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let size = vec2<i32>(textureDimensions(depthTexture));
    let p = clamp(vec2<i32>(in.clip.xy), vec2<i32>(0), size - vec2<i32>(1));
    // The sampler is bound for the texture (the ShaderMaterial contract);
    // reading at the pixel centre with it keeps it in the layout.
    let depth = textureSampleLevel(depthTexture, s_depth, (vec2<f32>(p) + 0.5) / vec2<f32>(size), 0);
    let view_z = -depth_to_view_z(depth, u.cameraNearFar.x, u.cameraNearFar.y);
    let depth_test = select(0.0, 1.0, -in.view_pos.z > view_z);
    return vec4<f32>(0.0, depth_test, 1.0, 1.0);
}
