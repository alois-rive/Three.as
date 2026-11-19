// SMAA 1x (v2.8, medium preset), stage 3 of 3: neighbourhood blending, as
// three.js's SMAABlendShader, in its GL texture coordinates (see
// smaa_edges.wgsl). tDiffuse holds the weights, tColor the image.

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

struct Uniforms { resolution: vec2<f32> };   // 1 / size in pixels
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tDiffuse: texture_2d<f32>;   // the blending weights
@group(2) @binding(2) var tColor: texture_2d<f32>;
@group(2) @binding(3) var s_tex: sampler;

fn flip(c: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(c.x, 1.0 - c.y);
}

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    var texcoord = in.uv;
    let r = u.resolution;
    // SMAANeighborhoodBlendingVS (WebGL port: w signs changed; its left/top
    // offset is unused).
    let offset1 = texcoord.xyxy + r.xyxy * vec4<f32>(1.0, 0.0, 0.0, -1.0);

    // The blending weights of this pixel and its right and bottom ones.
    let here = textureSampleLevel(tDiffuse, s_tex, flip(texcoord), 0.0);
    var a: vec4<f32>;
    a.x = here.x;
    a.z = here.z;
    a.y = textureSampleLevel(tDiffuse, s_tex, flip(offset1.zw), 0.0).g;
    a.w = textureSampleLevel(tDiffuse, s_tex, flip(offset1.xy), 0.0).a;

    // No blending weight: the colour as is.
    if (dot(a, vec4<f32>(1.0, 1.0, 1.0, 1.0)) < 1e-5) {
        return textureSampleLevel(tColor, s_tex, flip(texcoord), 0.0);
    }
    // Up to four lines can cross a pixel (one through each edge): blend
    // along the one of largest weight in each direction.
    var offset: vec2<f32>;
    offset.x = select(-a.b, a.a, a.a > a.b);   // left vs. right
    offset.y = select(a.r, -a.g, a.g > a.r);   // top vs. bottom (WebGL port: signs changed)
    if (abs(offset.x) > abs(offset.y)) {
        offset.y = 0.0;
    } else {
        offset.x = 0.0;
    }
    // The opposite colour, mixed by hand.
    var C = textureSampleLevel(tColor, s_tex, flip(texcoord), 0.0);
    texcoord += sign(offset) * r;
    var Cop = textureSampleLevel(tColor, s_tex, flip(texcoord), 0.0);
    let s = select(abs(offset.y), abs(offset.x), abs(offset.x) > abs(offset.y));
    // WebGL port: gamma correction added.
    C = vec4<f32>(pow(max(C.xyz, vec3<f32>(0.0)), vec3<f32>(2.2)), C.w);
    Cop = vec4<f32>(pow(max(Cop.xyz, vec3<f32>(0.0)), vec3<f32>(2.2)), Cop.w);
    var mixed = mix(C, Cop, s);
    mixed = vec4<f32>(pow(max(mixed.xyz, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.2)), mixed.w);
    return mixed;
}
