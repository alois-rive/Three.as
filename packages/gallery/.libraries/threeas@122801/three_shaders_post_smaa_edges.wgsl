// SMAA 1x (v2.8, medium preset), stage 1 of 3: colour edge detection, as
// three.js's SMAAEdgesShader (examples/jsm/shaders/SMAAShader.js).
// ShaderMaterial contract as the other post shaders. The SMAA stages run
// three.js's WebGL port as is, in its GL texture coordinates (v = 0 at the
// bottom): render target textures (top row first) are read at (u, 1 - v).

struct Frame { view_proj: mat4x4<f32> };
struct Object { model: mat4x4<f32> };
@group(0) @binding(0) var<uniform> frame: Frame;
@group(1) @binding(0) var<uniform> object: Object;

struct QuadOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) uv: vec2<f32>,   // GL texture coordinates
};

@vertex
fn vs_main(@location(0) position: vec3<f32>, @location(2) uv: vec2<f32>) -> QuadOut {
    var out: QuadOut;
    let keep = frame.view_proj[3][3] * 0.0 + object.model[3][3] * 0.0;
    out.clip = vec4<f32>(position.xy, 0.5 + keep, 1.0);
    out.uv = uv;
    return out;
}

const SMAA_THRESHOLD: f32 = 0.1;

struct Uniforms { resolution: vec2<f32> };   // 1 / size in pixels
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tDiffuse: texture_2d<f32>;
@group(2) @binding(2) var s_tex: sampler;

fn color_at(texcoord: vec2<f32>) -> vec3<f32> {
    return textureSampleLevel(tDiffuse, s_tex, vec2<f32>(texcoord.x, 1.0 - texcoord.y), 0.0).rgb;
}

fn max3(t: vec3<f32>) -> f32 {
    return max(max(t.r, t.g), t.b);
}

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let texcoord = in.uv;
    let r = u.resolution;
    // SMAAEdgeDetectionVS (WebGL port: w components' signs changed).
    let offset0 = texcoord.xyxy + r.xyxy * vec4<f32>(-1.0, 0.0, 0.0, 1.0);
    let offset1 = texcoord.xyxy + r.xyxy * vec4<f32>(1.0, 0.0, 0.0, -1.0);
    let offset2 = texcoord.xyxy + r.xyxy * vec4<f32>(-2.0, 0.0, 0.0, 2.0);

    // SMAAColorEdgeDetectionPS: colour deltas.
    let threshold = vec2<f32>(SMAA_THRESHOLD, SMAA_THRESHOLD);
    var delta: vec4<f32>;
    let C = color_at(texcoord);
    let c_left = color_at(offset0.xy);
    delta.x = max3(abs(C - c_left));
    let c_top = color_at(offset0.zw);
    delta.y = max3(abs(C - c_top));

    // The usual threshold, then discard where there is no edge.
    var edges = step(threshold, delta.xy);
    if (dot(edges, vec2<f32>(1.0, 1.0)) == 0.0) {
        discard;
    }

    // Right and bottom deltas.
    let c_right = color_at(offset1.xy);
    delta.z = max3(abs(C - c_right));
    let c_bottom = color_at(offset1.zw);
    delta.w = max3(abs(C - c_bottom));

    // The maximum delta in the direct neighbourhood.
    var max_delta = max(max(max(delta.x, delta.y), delta.z), delta.w);

    // Left-left and top-top deltas.
    let c_left_left = color_at(offset2.xy);
    delta.z = max3(abs(C - c_left_left));
    let c_top_top = color_at(offset2.zw);
    delta.w = max3(abs(C - c_top_top));

    // The final maximum delta, and local contrast adaptation.
    max_delta = max(max(max_delta, delta.z), delta.w);
    edges = edges * step(vec2<f32>(0.5 * max_delta), delta.xy);
    return vec4<f32>(edges, 0.0, 0.0);
}
