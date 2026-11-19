// SMAA 1x (v2.8, medium preset), stage 2 of 3: blending weights, as
// three.js's SMAAWeightsShader, in its GL texture coordinates (see
// smaa_edges.wgsl). tArea and tSearch are three.js's area and search
// textures (data textures, row 0 at v = 0, as three.js's flipY false);
// the search texture is read with textureLoad (three.js samples it
// nearest; the one sampler here is the edges texture's linear one).

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

const SMAA_MAX_SEARCH_STEPS: i32 = 8;
const SMAA_AREATEX_MAX_DISTANCE: f32 = 16.0;
const SMAA_AREATEX_PIXEL_SIZE: vec2<f32> = vec2<f32>(1.0 / 160.0, 1.0 / 560.0);
const SMAA_AREATEX_SUBTEX_SIZE: f32 = 1.0 / 7.0;

struct Uniforms { resolution: vec2<f32> };   // 1 / size in pixels
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var tDiffuse: texture_2d<f32>;   // the edges
@group(2) @binding(2) var tArea: texture_2d<f32>;
@group(2) @binding(3) var tSearch: texture_2d<f32>;
@group(2) @binding(4) var s_tex: sampler;

// The edges texture at GL texture coordinates.
fn edges_at(texcoord: vec2<f32>) -> vec2<f32> {
    return textureSampleLevel(tDiffuse, s_tex, vec2<f32>(texcoord.x, 1.0 - texcoord.y), 0.0).rg;
}

fn SMAASearchLength(e_in: vec2<f32>, bias: f32, scale: f32) -> f32 {
    var e = e_in;
    e.r = bias + e.r * scale;
    // Nearest: the texel under e.
    let size = vec2<i32>(textureDimensions(tSearch));
    let p = clamp(vec2<i32>(floor(e * vec2<f32>(size))), vec2<i32>(0), size - vec2<i32>(1));
    return 255.0 * textureLoad(tSearch, p, 0).r;
}

fn SMAASearchXLeft(texcoord_in: vec2<f32>, end: f32) -> f32 {
    let r = u.resolution;
    var texcoord = texcoord_in;
    var e = vec2<f32>(0.0, 1.0);
    for (var i = 0; i < SMAA_MAX_SEARCH_STEPS; i++) {
        e = edges_at(texcoord);
        texcoord -= vec2<f32>(2.0, 0.0) * r;
        if (!(texcoord.x > end && e.g > 0.8281 && e.r == 0.0)) {
            break;
        }
    }
    texcoord.x += 0.25 * r.x;
    texcoord.x += r.x;
    texcoord.x += 2.0 * r.x;
    texcoord.x -= r.x * SMAASearchLength(e, 0.0, 0.5);
    return texcoord.x;
}

fn SMAASearchXRight(texcoord_in: vec2<f32>, end: f32) -> f32 {
    let r = u.resolution;
    var texcoord = texcoord_in;
    var e = vec2<f32>(0.0, 1.0);
    for (var i = 0; i < SMAA_MAX_SEARCH_STEPS; i++) {
        e = edges_at(texcoord);
        texcoord += vec2<f32>(2.0, 0.0) * r;
        if (!(texcoord.x < end && e.g > 0.8281 && e.r == 0.0)) {
            break;
        }
    }
    texcoord.x -= 0.25 * r.x;
    texcoord.x -= r.x;
    texcoord.x -= 2.0 * r.x;
    texcoord.x += r.x * SMAASearchLength(e, 0.5, 0.5);
    return texcoord.x;
}

fn SMAASearchYUp(texcoord_in: vec2<f32>, end: f32) -> f32 {
    let r = u.resolution;
    var texcoord = texcoord_in;
    var e = vec2<f32>(1.0, 0.0);
    for (var i = 0; i < SMAA_MAX_SEARCH_STEPS; i++) {
        e = edges_at(texcoord);
        texcoord += vec2<f32>(0.0, 2.0) * r;
        if (!(texcoord.y > end && e.r > 0.8281 && e.g == 0.0)) {
            break;
        }
    }
    texcoord.y -= 0.25 * r.y;
    texcoord.y -= r.y;
    texcoord.y -= 2.0 * r.y;
    texcoord.y += r.y * SMAASearchLength(e.gr, 0.0, 0.5);
    return texcoord.y;
}

fn SMAASearchYDown(texcoord_in: vec2<f32>, end: f32) -> f32 {
    let r = u.resolution;
    var texcoord = texcoord_in;
    var e = vec2<f32>(1.0, 0.0);
    for (var i = 0; i < SMAA_MAX_SEARCH_STEPS; i++) {
        e = edges_at(texcoord);
        texcoord -= vec2<f32>(0.0, 2.0) * r;
        if (!(texcoord.y < end && e.r > 0.8281 && e.g == 0.0)) {
            break;
        }
    }
    texcoord.y += 0.25 * r.y;
    texcoord.y += r.y;
    texcoord.y += 2.0 * r.y;
    texcoord.y -= r.y * SMAASearchLength(e.gr, 0.5, 0.5);
    return texcoord.y;
}

fn SMAAArea(dist: vec2<f32>, e1: f32, e2: f32, offset: f32) -> vec2<f32> {
    // Rounding prevents precision errors of bilinear filtering (halves away
    // from zero, as GLSL's round on GPUs and three.js's fallback; WGSL's
    // round goes to even).
    let e = 4.0 * vec2<f32>(e1, e2);
    var texcoord = SMAA_AREATEX_MAX_DISTANCE * (sign(e) * floor(abs(e) + 0.5)) + dist;
    // Scale and bias for mapping to texel space.
    texcoord = SMAA_AREATEX_PIXEL_SIZE * texcoord + (0.5 * SMAA_AREATEX_PIXEL_SIZE);
    // Move to the proper place, according to the subpixel offset.
    texcoord.y += SMAA_AREATEX_SUBTEX_SIZE * offset;
    return textureSampleLevel(tArea, s_tex, texcoord, 0.0).rg;
}

@fragment
fn fs_main(in: QuadOut) -> @location(0) vec4<f32> {
    let texcoord = in.uv;
    let r = u.resolution;
    // SMAABlendingWeightCalculationVS (WebGL port: y and w signs changed).
    let pixcoord = texcoord / r;
    let offset0 = texcoord.xyxy + r.xyxy * vec4<f32>(-0.25, 0.125, 1.25, 0.125);
    let offset1 = texcoord.xyxy + r.xyxy * vec4<f32>(-0.125, 0.25, -0.125, -1.25);
    let offset2 = vec4<f32>(offset0.xz, offset1.yw)
        + vec4<f32>(-2.0, 2.0, -2.0, 2.0) * r.xxyy * f32(SMAA_MAX_SEARCH_STEPS);

    // SMAABlendingWeightCalculationPS (subsample indices 0).
    var weights = vec4<f32>(0.0);
    let e = edges_at(texcoord);

    if (e.g > 0.0) {
        // An edge at the north: the distance to the left.
        var d: vec2<f32>;
        var coords: vec2<f32>;
        coords.x = SMAASearchXLeft(offset0.xy, offset2.x);
        coords.y = offset1.y;
        d.x = coords.x;
        // The left crossing edges, two at a time (bilinear).
        let e1 = edges_at(coords).r;
        // The distance to the right.
        coords.x = SMAASearchXRight(offset0.zw, offset2.y);
        d.y = coords.x;
        // In pixels.
        d = d / r.x - pixcoord.x;
        let sqrt_d = sqrt(abs(d));
        // The right crossing edges.
        coords.y -= 1.0 * r.y;
        let e2 = edges_at(coords + vec2<f32>(1.0, 0.0) * r).r;
        weights = vec4<f32>(SMAAArea(sqrt_d, e1, e2, 0.0), weights.ba);
    }

    if (e.r > 0.0) {
        // An edge at the west: the distance to the top.
        var d: vec2<f32>;
        var coords: vec2<f32>;
        coords.y = SMAASearchYUp(offset1.xy, offset2.z);
        coords.x = offset0.x;
        d.x = coords.y;
        // The top crossing edges.
        let e1 = edges_at(coords).g;
        // The distance to the bottom.
        coords.y = SMAASearchYDown(offset1.zw, offset2.w);
        d.y = coords.y;
        d = d / r.y - pixcoord.y;
        let sqrt_d = sqrt(abs(d));
        // The bottom crossing edges.
        coords.y -= 1.0 * r.y;
        let e2 = edges_at(coords + vec2<f32>(0.0, 1.0) * r).g;
        weights = vec4<f32>(weights.rg, SMAAArea(sqrt_d, e1, e2, 0.0));
    }

    return weights;
}
