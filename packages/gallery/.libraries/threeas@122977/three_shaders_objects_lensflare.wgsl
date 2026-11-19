// three.js LensflareElement.Shader (examples/jsm/objects/Lensflare.js,
// r170), for three/addons/objects/Lensflare: one flare element, a textured
// quad along the line through the screen centre, faded by how much of the
// occlusion quad (`occlusionMap`: 16 x 16, read texel by texel) stayed
// magenta. ShaderMaterial contract (see three/materials/ShaderMaterial.as).
// Images are premultiplied with rows top first: `map` is read at (u, 1 - v)
// and its colour and alpha scaled together.

struct Frame { view_proj: mat4x4<f32> };
struct Object { model: mat4x4<f32> };
@group(0) @binding(0) var<uniform> frame: Frame;
@group(1) @binding(0) var<uniform> object: Object;

// Uniforms in insertion order: color, scale, screenPosition; then map,
// occlusionMap.
struct Uniforms {
    color: vec3<f32>,
    scale: vec2<f32>,
    screenPosition: vec3<f32>,
};
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var map: texture_2d<f32>;
@group(2) @binding(2) var occlusionMap: texture_2d<f32>;
@group(2) @binding(3) var s_tex: sampler;

struct VsOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) vUV: vec2<f32>,
    @location(1) vVisibility: f32,
};

// The occlusion texel at GL uv (v up; the copy's rows are top first).
fn occlusion(uv: vec2<f32>) -> vec4<f32> {
    let size = vec2<f32>(textureDimensions(occlusionMap));
    let x = i32(min(uv.x * size.x, size.x - 1.0));
    let y = i32(min((1.0 - uv.y) * size.y, size.y - 1.0));
    return textureLoad(occlusionMap, vec2<i32>(x, y), 0);
}

@vertex
fn vs_main(@location(0) position: vec3<f32>, @location(2) uv: vec2<f32>) -> VsOut {
    var out: VsOut;
    out.vUV = uv;

    let pos = position.xy;

    var visibility = occlusion(vec2<f32>(0.1, 0.1));
    visibility += occlusion(vec2<f32>(0.5, 0.1));
    visibility += occlusion(vec2<f32>(0.9, 0.1));
    visibility += occlusion(vec2<f32>(0.9, 0.5));
    visibility += occlusion(vec2<f32>(0.9, 0.9));
    visibility += occlusion(vec2<f32>(0.5, 0.9));
    visibility += occlusion(vec2<f32>(0.1, 0.9));
    visibility += occlusion(vec2<f32>(0.1, 0.5));
    visibility += occlusion(vec2<f32>(0.5, 0.5));

    out.vVisibility = visibility.r / 9.0;
    out.vVisibility *= 1.0 - visibility.g / 9.0;
    out.vVisibility *= visibility.b / 9.0;

    let keep = frame.view_proj[3][3] * 0.0 + object.model[3][3] * 0.0;
    out.clip = vec4<f32>((pos * u.scale + u.screenPosition.xy).xy, u.screenPosition.z + keep, 1.0);
    return out;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let texel = textureSample(map, s_tex, vec2<f32>(in.vUV.x, 1.0 - in.vUV.y));
    // three.js: texture.a *= vVisibility; rgb *= color, blended additively
    // with SrcAlpha (premultiplied here).
    return vec4<f32>(texel.rgb * u.color * in.vVisibility, texel.a * in.vVisibility);
}
