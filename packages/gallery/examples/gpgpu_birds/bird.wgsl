// The birds (three.js webgl_gpgpu_birds' birdVS / birdFS), a ShaderMaterial
// (see three/materials/ShaderMaterial.as) placing each bird's three
// triangles from its texel of the computed position and velocity. three.js's
// attributes `reference`, `birdColor` and `birdVertex` arrive as the uv
// (location 2) and the colour (location 3: rgb, then the vertex number in
// a), the attributes a ShaderMaterial receives.

struct Frame {
    view_proj: mat4x4<f32>,
};

struct Object {
    model: mat4x4<f32>,
};

// Uniforms in insertion order: color, then time and delta (values), then
// texturePosition, textureVelocity and their sampler.
struct Uniforms {
    color: vec3<f32>,
    time: f32,
    delta: f32,
};

@group(0) @binding(0) var<uniform> frame: Frame;
@group(1) @binding(0) var<uniform> object: Object;
@group(2) @binding(0) var<uniform> u: Uniforms;
@group(2) @binding(1) var texturePosition: texture_2d<f32>;
@group(2) @binding(2) var textureVelocity: texture_2d<f32>;
@group(2) @binding(3) var s_tex: sampler;

struct VsIn {
    @location(0) position: vec3<f32>,
    @location(2) reference: vec2<f32>,
    @location(3) birdColorVertex: vec4<f32>,
};

struct VsOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) vColor: vec4<f32>,
    @location(1) z: f32,
};

@vertex
fn vs_main(in: VsIn) -> VsOut {
    // texture2D(texturePosition, reference) at a texel's corner: the texel.
    let size = vec2<f32>(textureDimensions(texturePosition));
    let ref_p = vec2<i32>(floor(in.reference * size + vec2<f32>(0.5)));
    let tmpPos = textureLoad(texturePosition, ref_p, 0);
    let pos = tmpPos.xyz;
    var velocity = normalize(textureLoad(textureVelocity, ref_p, 0).xyz);

    var newPosition = in.position;

    let birdVertex = in.birdColorVertex.a;
    if (birdVertex == 4.0 || birdVertex == 7.0) {
        // flap wings
        newPosition.y = sin(tmpPos.w) * 5.0;
    }

    let m = object.model;
    newPosition = mat3x3<f32>(m[0].xyz, m[1].xyz, m[2].xyz) * newPosition;

    velocity.z *= -1.0;
    let xz = length(velocity.xz);
    let xyz = 1.0;
    let x = sqrt(1.0 - velocity.y * velocity.y);

    let cosry = velocity.x / xz;
    let sinry = velocity.z / xz;

    let cosrz = x / xyz;
    let sinrz = velocity.y / xyz;

    let maty = mat3x3<f32>(
        cosry, 0.0, -sinry,
        0.0, 1.0, 0.0,
        sinry, 0.0, cosry
    );

    let matz = mat3x3<f32>(
        cosrz, sinrz, 0.0,
        -sinrz, cosrz, 0.0,
        0.0, 0.0, 1.0
    );

    newPosition = maty * matz * newPosition;
    newPosition += pos;

    var out: VsOut;
    out.z = newPosition.z;
    out.vColor = vec4<f32>(in.birdColorVertex.rgb, 1.0);
    out.clip = frame.view_proj * vec4<f32>(newPosition, 1.0);
    return out;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    // Fake colors for now (three.js); `color`, `time` and `delta` are
    // unused there too, kept so the block stays bound.
    _ = s_tex;   // bound by the contract, unused (textureLoad)
    let keep = u.color.x * 0.0 + u.time * 0.0 + u.delta * 0.0;
    let z2 = 0.2 + (1000.0 - in.z) / 1000.0 * in.vColor.x + keep;
    return vec4<f32>(z2, z2, z2, 1.0);
}
