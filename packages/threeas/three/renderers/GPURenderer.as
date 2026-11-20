// GPURenderer: three.js's WebGLRenderer for Rive. Renders a scene into a
// Rive GPUCanvas; `present` composites the canvas into the Rive renderer.
//
//     export class Demo extends Layout {
//         renderer: GPURenderer? = null;
//         override init(context: Context): bool {
//             this.renderer = new GPURenderer(context, { antialias: true });
//             ...
//         }
//         override resize(width: f64, height: f64, scale: f64): void {
//             renderer.setPixelRatio(scale);
//             renderer.setSize(width, height);
//             camera.aspect = width / height;
//             camera.updateProjectionMatrix();
//         }
//         override draw(renderer: Renderer): void {
//             this.renderer!.render(scene, camera);   // only inside draw()
//             this.renderer!.present(renderer);
//         }
//     }
//
// Output is tone mapped (toneMapping), sRGB, premultiplied. Draw order: the
// background, opaque objects front to back, then transparent ones back to
// front, each sorted by renderOrder first.

import { Context } from "rive/host";
import { Renderer } from "rive/renderer";
import { Mat4 } from "rive/mat4";
import { Mat2D } from "rive/mat2d";
import { BlendMode } from "rive/paint";
import { ImageSampler, ImageWrap, ImageFilter } from "rive/image";
import {
    GPUCanvas, GPUTexture, GPUTextureDesc, GPUTextureView, GPUBuffer, GPUPipeline, GPUPipelineDesc,
    GPUColorTargetDesc, GPUDepthStencilDesc, GPUVertexBufferLayout, GPUVertexAttribute, GPUBindGroup,
    GPUBindGroupLayout, GPUBindGroupUBO, GPUBindGroupTexture, GPUBindGroupSampler, GPUColorAttachment,
    GPUPassDesc, GPUSampler, GPUShaderModule, GPUBlendState, GPURenderPass, GPUTextureViewDesc, GPUStencilFaceState,
} from "rive/gpu";
import {
    BufferUsage, TextureFormat, CompareFunction, CullMode, VertexFormat, VertexStepMode, LoadOp, StoreOp, Filter,
    WrapMode, BlendFactor, FaceWinding, PrimitiveTopology, ColorWriteMask, TextureType, TextureViewDimension,
    TextureAspect, StencilOp,
} from "rive/gpu_enums";
import { rive_gpu_texture_upload_v1 } from "rive/bindings";
import { clock } from "rive/os";

import { Object3D } from "../core/Object3D";
import { BufferGeometry, GeometryGroup, disposedGeometries } from "../core/BufferGeometry";
import { BufferAttribute } from "../core/BufferAttribute";
import { Camera } from "../cameras/Camera";
import { OrthographicCamera } from "../cameras/OrthographicCamera";
import { Scene } from "../scenes/Scene";
import { Fog, FogExp2 } from "../scenes/Fog";
import { Mesh } from "../objects/Mesh";
import { InstancedMesh } from "../objects/InstancedMesh";
import { BatchedMesh } from "../objects/BatchedMesh";
import { SkinnedMesh } from "../objects/SkinnedMesh";
import { Line, LineSegments, LineLoop } from "../objects/Line";
import { Points } from "../objects/Points";
import { Sprite } from "../objects/Sprite";
import { LOD } from "../objects/LOD";
import { Light } from "../lights/Light";
import { AmbientLight } from "../lights/AmbientLight";
import { HemisphereLight } from "../lights/HemisphereLight";
import { DirectionalLight } from "../lights/DirectionalLight";
import { PointLight } from "../lights/PointLight";
import { SpotLight } from "../lights/SpotLight";
import { Material } from "../materials/Material";
import {
    MaterialUniforms, TEXTURE_SLOTS, SLOT_ENV, ROLE_COUNT, EXTRA_SLOTS, ROLE_DISPLACEMENT, KIND_PHYSICAL, KIND_WIDE_LINE,
} from "../materials/MaterialUniforms";
import { ShaderMaterial } from "../materials/ShaderMaterial";
import { Texture, disposedTextures } from "../textures/Texture";
import { Color, LinearToSRGB } from "../math/Color";
import { Euler } from "../math/Euler";
import { Vector2 } from "../math/Vector2";
import { Vector3 } from "../math/Vector3";
import { Vector4 } from "../math/Vector4";
import { Matrix3 } from "../math/Matrix3";
import { Matrix4 } from "../math/Matrix4";
import { Frustum } from "../math/Frustum";
import { Sphere } from "../math/Sphere";
import {
    BackSide, DoubleSide, NearestFilter, NearestMipmapNearestFilter, NearestMipmapLinearFilter,
    LinearMipmapLinearFilter, RepeatWrapping, MirroredRepeatWrapping, SRGBColorSpace, NoToneMapping,
    NoBlending, NormalBlending, AdditiveBlending, SubtractiveBlending, MultiplyBlending,
    EquirectangularReflectionMapping, EquirectangularRefractionMapping, CubeRefractionMapping, BasicShadowMap, PCFShadowMap,
    HalfFloatType, NoColorSpace, LessEqualDepth, NeverDepth, AlwaysDepth, LessDepth, EqualDepth, GreaterEqualDepth, GreaterDepth,
    NotEqualDepth, NeverStencilFunc, LessStencilFunc, EqualStencilFunc, LessEqualStencilFunc, GreaterStencilFunc,
    NotEqualStencilFunc, GreaterEqualStencilFunc, ZeroStencilOp, ReplaceStencilOp, IncrementStencilOp,
    DecrementStencilOp, IncrementWrapStencilOp, DecrementWrapStencilOp, InvertStencilOp,
} from "../constants";
import { Plane } from "../math/Plane";
import { LightShadow } from "../lights/LightShadow";
import { RectAreaLight } from "../lights/RectAreaLight";
import { LightProbe } from "../lights/LightProbe";
import { LTC_TABLE } from "../lights/RectAreaLightTables";
import { CubeTexture } from "../textures/CubeTexture";
import { CubeCamera } from "../cameras/CubeCamera";
import { PerspectiveCamera } from "../cameras/PerspectiveCamera";
import { ArrayCamera } from "../cameras/ArrayCamera";
import { GPUGeometries, GeometryGPU, LINE_STRIP, LINE_LOOP, LINE_SEGMENTS, LINE_WIREFRAME } from "./gpu/GPUGeometries";
import { interleaveNormalTangent } from "./gpu/GPUGeometries";
import { GPUTextures, wantsMipmaps } from "./gpu/GPUTextures";
import { RenderTarget, RenderTargetOptions, RenderTargetTexture } from "./RenderTarget";
import { FramebufferTexture } from "../textures/FramebufferTexture";
import { DepthTexture } from "../textures/DepthTexture";
import { Box2 } from "../math/Box2";
import { fromHalf } from "../textures/DataUpload";
import { MorphTexelInput, morphTexels, fastHalf } from "./gpu/MorphTexels";
import { Job, Jobs } from "rive/jobs";
import { Parallel, SharedArray } from "rive/parallel";
import { cullObjects, cullParts, prepareBounds } from "./gpu/Culling";
import { bakedShaderName } from "./gpu/ShaderVariants";
import { Skeleton } from "../objects/Skeleton";
import {
    MAX_LIGHTS, FRAME_VIEW_PROJ, FRAME_VIEW, FRAME_INV_VIEW_PROJ, FRAME_CAMERA_POS, FRAME_CAMERA_DIR, FRAME_AMBIENT,
    FRAME_HEMI_SKY, FRAME_HEMI_GROUND, FRAME_HEMI_DIR, FRAME_FOG_COLOR, FRAME_FOG_PARAMS, FRAME_OUTPUT,
    FRAME_BG_ROTATION, FRAME_BG_FLAGS, FRAME_PROJ, FRAME_VIEWPORT, FRAME_LIGHTS, LIGHT_BYTES, FRAME_BYTES, OBJ_SPRITE,
    FRAME_ENV, FRAME_ENV_ROTATION, FRAME_ENV_FLAGS, FRAME_SHADOW_PARAMS, FRAME_SHADOW_TILES, SHADOW_TILE_BYTES,
    MAX_SHADOW_TILES, FLAG_RECEIVE_SHADOW,
    OBJ_MODEL, OBJ_NORMAL, OBJ_COLOR, OBJ_EMISSIVE, OBJ_PBR, OBJ_SPECULAR, OBJ_EXTRA, OBJ_PHYSICAL0,
    OBJ_PHYSICAL1, OBJ_PHYSICAL2, OBJ_TEX_FLAGS, OBJ_FLAGS, OBJ_POINTS, OBJ_DASH, OBJ_BYTES,
    FLAG_VERTEX_COLORS, FLAG_FOG, FLAG_TRANSPARENT, FLAG_TONE_MAPPED, LIGHT_DIRECTIONAL, LIGHT_POINT, LIGHT_SPOT, LIGHT_RECT, FRAME_PROBE,
    FOG_LINEAR, FOG_EXP2, INSTANCE_MATRIX_STRIDE, INSTANCE_COLOR_STRIDE, MORPH_ROW_STRIDE, OBJ_BIND_MATRIX, OBJ_BIND_MATRIX_INVERSE, OBJ_UV_MATRIX, OBJ_ENV, OBJ_X_UV, OBJ_X_FLAGS, OBJ_X_ROLES, OBJ_X_PARAMS, OBJ_X_PARAMS2, OBJ_X_PARAMS3, OBJ_PHYSICAL3, OBJ_PHYSICAL4, OBJ_PHYSICAL5, OBJ_PHYSICAL6, OBJ_CLIP_PLANES, OBJ_CLIP, MAX_CLIP_PLANES, OBJ_MISC0, OBJ_MISC1, OBJ_LIGHTS, OBJ_USED, MAX_OBJECT_LIGHTS, MAX_BONES, BONES_BYTES,
    MORPH_INFO, MORPH_BONES, MORPH_ACTIVE, MORPH_BYTES, MAX_ACTIVE_MORPHS, MORPH_NORMALS, MORPH_INSTANCED, BONE_TEXTURE,
    X_SLOT_MORPH, X_SLOT_BONES, X_SLOT_MORPH_INSTANCES, BONE_TEXELS,
} from "./gpu/Layout";

// The main shader: newer CLIs name assets by path, 1.9.x by file name.
const SHADER_NAMES: Array<string> = ["three/shaders/three", "shaders/three", "three"];
const BACKGROUND_SHADER_NAMES: Array<string> = [
    "three/shaders/three_background", "shaders/three_background", "three_background",
];

const UTIL_SHADER_NAMES: Array<string> = ["three/shaders/three_util", "shaders/three_util", "three_util"];

const uploadRegion = new rive_gpu_texture_upload_v1();

// Pipeline key fields.
const KEY_CULL_MASK: i32 = 3;            // 0 back, 1 none, 2 front
const KEY_BLEND_SHIFT: i32 = 2;          // 3 bits: three.js blending (0 none)
const KEY_DEPTH_TEST: i32 = 1 << 5;
const KEY_DEPTH_WRITE: i32 = 1 << 6;
const KEY_MIRRORED: i32 = 1 << 7;
const KEY_COLOR_WRITE: i32 = 1 << 8;
const KEY_PRIM_SHIFT: i32 = 9;          // 2 bits: PRIM_*
const KEY_MSAA: i32 = 1 << 11;
const KEY_SKINNED: i32 = 1 << 12;
const KEY_DISPLACED: i32 = 1 << 13;      // displacementMap: the vs_*_displaced entry points
const KEY_CLIP_SHADOW: i32 = 1 << 14;    // shadow passes: clip casters (clipShadows)
const KEY_CUTOUT_SHADOW: i32 = 1 << 15;  // shadow passes: alphaTest / alphaHash cut-outs
const KEY_WIDE_LINE: i32 = 1 << 16;      // LineMaterial: vs_wideline
const KEY_LOG_DEPTH: i32 = 1 << 17;      // logarithmicDepthBuffer: fs_main_logdepth
const KEY_MORPH_INSTANCED: i32 = 1 << 18; // InstancedMesh morphs: vs_morph_instanced*, rows at slot 7
const KEY_STATE_SHIFT: i32 = 21;         // 9 bits: a depthFunc/stencil/polygonOffset state (0: default)
const KEY_STATE_MASK: i32 = 511;
// The key bits that pick a draw's entry points (buildPipeline, vertexEntry).
const KEY_ENTRY_MASK: i32 = (3 << KEY_PRIM_SHIFT) | KEY_SKINNED | KEY_DISPLACED | KEY_WIDE_LINE | KEY_LOG_DEPTH
    | KEY_MORPH_INSTANCED;

/// The vertex entry point of a draw's pipeline key (as buildPipeline picks it).
function vertexEntry(key: i32): string {
    const prim = (key >> KEY_PRIM_SHIFT) & 3;
    if (prim == PRIM_POINTS) return "vs_points";
    if (prim == PRIM_SPRITE) return "vs_sprite";
    if ((key & KEY_SKINNED) != 0) return (key & KEY_DISPLACED) != 0 ? "vs_skinned_displaced" : "vs_skinned";
    if ((key & KEY_WIDE_LINE) != 0) return "vs_wideline";
    if ((key & KEY_MORPH_INSTANCED) != 0) {
        return (key & KEY_DISPLACED) != 0 ? "vs_morph_instanced_displaced" : "vs_morph_instanced";
    }
    return (key & KEY_DISPLACED) != 0 ? "vs_displaced" : "vs_main";
}
// The colour passes' depth (and stencil) format.
const DEPTH_FORMAT: TextureFormat = TextureFormat.depth24plusStencil8;

/// Depth function, stencil and polygon offset of a material, beyond the
/// defaults (pipeline state, interned by GPURenderer.stateIndex).
class PassState {
    depthFunc: i32 = 3;
    stencil: bool = false;
    stencilFunc: i32 = 519;
    stencilFuncMask: i32 = 0xff;
    stencilWriteMask: i32 = 0xff;
    stencilFail: i32 = 7680;
    stencilZFail: i32 = 7680;
    stencilZPass: i32 = 7680;
    polygonOffsetFactor: f64 = 0;
    polygonOffsetUnits: f64 = 0;
}
const KEY_BACKGROUND: i32 = 1 << 30;

// The depth (and MSAA colour) attachments of one render destination.
class PassTargets {
    depthTex: GPUTexture? = null;
    depthView: GPUTextureView? = null;
    msaaTex: GPUTexture? = null;
    msaaView: GPUTextureView? = null;
    width: u32 = 0;
    height: u32 = 0;
    format: u32 = 0xFFFFFFFF;
    samples: u32 = 0;
    // Store the MSAA colour / the depth at the end of a pass: set once a
    // pass loads them (autoClear off, a scissor, renderer.clear).
    keepColor: bool = false;
    keepDepth: bool = false;

    release(): void {
        releaseTex(this.depthTex); this.depthTex = null; this.depthView = null;
        releaseTex(this.msaaTex); this.msaaTex = null; this.msaaView = null;
    }
}

// A ShaderMaterial's pipeline and the layouts its shader declares.
class CustomPipeline {
    pipeline: GPUPipeline;
    layout0: GPUBindGroupLayout;
    layout1: GPUBindGroupLayout;
    layout2: GPUBindGroupLayout? = null;
    frameGroup: GPUBindGroup;
    // Its group 1 over the object arena (rebuilt when the arena grows).
    objGroup: GPUBindGroup? = null;
    // `lights: true`: its group 0 with every frame binding, and their views.
    lights: bool = false;
    fullGroup: GPUBindGroup? = null;
    fullViews: StaticArray<GPUTextureView?> = new StaticArray<GPUTextureView?>(3);
    objArena: GPUBuffer? = null;

    constructor(pipeline: GPUPipeline, layout0: GPUBindGroupLayout, layout1: GPUBindGroupLayout, frameGroup: GPUBindGroup) {
        this.pipeline = pipeline;
        this.layout0 = layout0;
        this.layout1 = layout1;
        this.frameGroup = frameGroup;
    }
}

// A ShaderMaterial's uniform block and bind group.
class CustomUniforms {
    buffer: GPUBuffer? = null;
    staging: ArrayBuffer = new ArrayBuffer(16);
    f32: Float32Array = Float32Array.wrap(this.staging);
    group: GPUBindGroup? = null;
    views: Array<GPUTextureView> = [];
    frame: i32 = -1;
}

// What a draw rasterizes.
const PRIM_TRIANGLES: i32 = 0;
const PRIM_LINES: i32 = 1;
const PRIM_POINTS: i32 = 2;
const PRIM_SPRITE: i32 = 3;

// A mesh's morphed positions and normals (CPU blended).
class MorphGPU {
    position: GPUBuffer? = null;
    normal: GPUBuffer? = null;
    positions: Float32Array = new Float32Array(0);
    normals: Float32Array = new Float32Array(0);
    influences: Array<f64> = [];
    geometryVersion: i32 = -1;
}

// A geometry's morph target deltas as an rgba16float texture (three.wgsl's
// morph()): target-major, a position texel (and a normal texel) a vertex.
class MorphTargetsGPU {
    texture: GPUTexture? = null;
    view: GPUTextureView? = null;
    width: i32 = 0;
    targets: i32 = 0;
    texelsPerTarget: i32 = 0;
    normals: bool = false;
    /// The geometry's position and morph attribute versions it was built from.
    key: i32 = -1;
    /// Converting the texels of `key` (GPURenderer.joinMorphJobs uploads them).
    job: Job<Uint16Array>? = null;
    /// The view that queued it for a join; the texture was zeroed while
    /// a join gave up.
    awaited: i32 = -1;
    zeroed: bool = false;
}

/// Morph textures above this many texels convert in a job (the 48-target
/// blob of the Animation example, 259k texels, took 115 ms on the main lane
/// interpreted, 31 ms compiled ahead of time).
const MORPH_JOB_TEXELS: i32 = 65536;

// Where a mesh's MorphU block (group 1 binding 7) sits in the renderer's
// morph arena this view and, for skeletons above MAX_BONES, its bone
// texture.
class DeformGPU {
    offset: u32 = 0;
    frame: i32 = -1;
    boneTexture: GPUTexture? = null;
    boneView: GPUTextureView? = null;
    boneWidth: i32 = 0;
    boneData: Uint16Array = new Uint16Array(0);
    /// The bone rows last uploaded (12 floats a bone).
    boneCache: Float32Array = new Float32Array(0);
    boneFrame: i32 = -1;
}

// A wide line geometry's packed segments.
class WideLineGPU {
    buffer: GPUBuffer? = null;
    data: Float32Array = new Float32Array(0);
    version: i32 = -1;
}

// An InstancedMesh's packed instance buffer.
class InstanceGPU {
    /// instanceMatrix, uploaded as is (64 bytes an instance).
    matrices: GPUBuffer? = null;
    /// instanceColor (12 bytes an instance), or the shared white buffer.
    colors: GPUBuffer? = null;
    ownColors: bool = false;
    matrixVersion: i32 = -1;
    colorVersion: i32 = -1;
    count: i32 = -1;
}

// A BatchedMesh's visible instances, packed by geometry: geometry k's
// instances are `count[k]` from `first[k]`.
class BatchedGPU {
    matrices: GPUBuffer? = null;
    colors: GPUBuffer? = null;
    matrixData: Float32Array = new Float32Array(0);
    colorData: Float32Array = new Float32Array(0);
    first: Array<i32> = [];
    count: Array<i32> = [];
    version: i32 = -1;
}

// -----------------------------------------------------------------------------

export class GPURendererParameters {
    /// 4x MSAA when the device has it.
    antialias: bool = false;
    /// Clear to transparent (clear alpha 0) by default, so the artboard
    /// shows behind the scene.
    alpha: bool = false;
    /// Logarithmic depth (three.js): the depth of built-in materials is
    /// log2(1 + w) / log2(1 + far), for scenes spanning huge depth ranges.
    logarithmicDepthBuffer: bool = false;
}

/// three.js's renderer.shadowMap.
export class ShadowMapSettings {
    /// Render shadow maps for lights with castShadow (meshes need castShadow
    /// to cast and receiveShadow to receive).
    enabled: bool = false;
    /// BasicShadowMap, PCFShadowMap (default) or PCFSoftShadowMap
    /// (VSMShadowMap renders as PCFSoftShadowMap).
    type: i32 = PCFShadowMap;
    /// Re-render the maps every frame (else only when needsUpdate is set).
    autoUpdate: bool = true;
    needsUpdate: bool = false;
}

// One shadow map layer: a light camera's view-projection.
class ShadowTile {
    matrix: Matrix4 = new Matrix4();
}

/// A scene to render into a cube map at the start of the next render
/// (PMREMGenerator.fromScene).
export class SceneCapture {
    scene: Object3D;
    camera: CubeCamera;

    constructor(scene: Object3D, camera: CubeCamera) {
        this.scene = scene;
        this.camera = camera;
    }
}

export class RenderInfo {
    frame: i32 = 0;
    calls: i32 = 0;
    triangles: i32 = 0;
    lines: i32 = 0;
    points: i32 = 0;
    /// Objects skipped by frustum culling this frame (not in three.js).
    culled: i32 = 0;
}

/// three.js's info.memory: what the renderer holds on the GPU.
export class MemoryInfo {
    /// Geometries with vertex buffers.
    geometries: i32 = 0;
    /// Textures prepared for sampling and not disposed.
    textures: i32 = 0;
}

/// Where render() spends its time on the CPU (Rive-only): seconds summed
/// over `renders` views since the last `reset()`, when `enabled`.
export class RenderTimings {
    enabled: bool = false;
    renders: i32 = 0;
    /// updateMatrixWorld, the camera and frustum.
    matrices: f64 = 0;
    /// Walking the scene: culling, draw items, texture and geometry uploads.
    collect: f64 = 0;
    /// Background, shadow planning, environment, the frame block, sorting.
    prepare: f64 = 0;
    /// Object blocks and bind groups (writeDraws) and their upload.
    write: f64 = 0;
    /// Shadow and transmission passes.
    passes: f64 = 0;
    /// The main pass's draw calls.
    draw: f64 = 0;

    reset(): void {
        this.renders = 0;
        this.matrices = 0; this.collect = 0; this.prepare = 0; this.write = 0; this.passes = 0; this.draw = 0;
    }

    /// Average milliseconds per render, one line.
    summary(): string {
        const n = <f64>max<i32>(1, this.renders);
        const k = 1000 / n;
        return "matrices " + fmtMs(this.matrices * k) + " collect " + fmtMs(this.collect * k) + " prepare "
            + fmtMs(this.prepare * k) + " write " + fmtMs(this.write * k) + " passes " + fmtMs(this.passes * k)
            + " draw " + fmtMs(this.draw * k) + " ms (" + this.renders.toString() + " renders)";
    }
}

function fmtMs(v: f64): string {
    return (Math.round(v * 1000) / 1000).toString();
}

export class RendererInfo {
    /// Reset the render counters at each render() (else call reset()).
    autoReset: bool = true;
    render: RenderInfo = new RenderInfo();
    memory: MemoryInfo = new MemoryInfo();
    /// CPU time per render stage (off by default; Rive-only).
    timings: RenderTimings = new RenderTimings();

    reset(): void {
        const r = this.render;
        r.calls = 0;
        r.triangles = 0;
        r.lines = 0;
        r.points = 0;
        r.culled = 0;
    }
}

// One draw's state, kept across frames.
class DrawState {
    /// Byte offset of its object block in the renderer's object arena
    /// (bound with a dynamic offset): its own slot, kept across frames and
    /// rewritten only when the block changes.
    objOffset: u32 = 0;
    /// Its arena slot (-1: none yet).
    slot: i32 = -1;
    /// What the slot holds: the material block and its version, the world
    /// matrix, the light list and the per-draw patches it was written from.
    block: MaterialBlock? = null;
    blockVersion: i32 = -1;
    model: StaticArray<f32> = new StaticArray<f32>(16);
    lights: StaticArray<u32> = new StaticArray<u32>(8);
    patch: i32 = -1;
    spriteX: f64 = 0;
    spriteY: f64 = 0;
    /// The material entry it last drew with (skips a map lookup).
    entry: MaterialEntry? = null;
    /// Skinned draws: a group 1 of their own (arena + their bones).
    objGroup: GPUBindGroup? = null;
    arena: GPUBuffer? = null;
    bones: GPUBuffer? = null;
    morph: GPUBuffer? = null;
    matGroup: GPUBindGroup? = null;
    samplerGroup: GPUBindGroup? = null;
    /// The extra map slots' views (group 1 bindings 2-7) and how many.
    xviews: StaticArray<GPUTextureView?> = new StaticArray<GPUTextureView?>(EXTRA_SLOTS);
    xcount: i32 = 0;
    xgroupViews: StaticArray<GPUTextureView?> = new StaticArray<GPUTextureView?>(EXTRA_SLOTS);
    frame: i32 = -1;
    /// Its baked shader variant and what it was chosen from.
    variant: i32 = -1;
    vblock: MaterialBlock? = null;
    vversion: i32 = -1;
    vpatch: i32 = -1;
    vframe: i32 = -1;
    ventry: i32 = -1;
    vlights: StaticArray<u32> = new StaticArray<u32>(8);
}

// What a material needs from a view, found once per view however many
// draws use it: its textures updated, its shading kind, and its blocks.
class MaterialEntry {
    material: Material;
    prepared: i32 = -1;
    kind: i32 = 0;
    displaced: bool = false;
    transmissive: bool = false;
    /// Its object block templates, by the vertex textures a draw borrows
    /// extra slots for (morph texture 1, bone texture 2, instance morphs 4).
    blocks: StaticArray<MaterialBlock?> = new StaticArray<MaterialBlock?>(8);
    /// Its interned depth/stencil/offset state (GPURenderer.stateIndex) and
    /// the fields it was interned from.
    stateIndex: i32 = -1;
    depthFunc: i32 = 0;
    stencilWrite: bool = false;
    stencilFunc: i32 = 0;
    stencilFuncMask: i32 = 0;
    stencilWriteMask: i32 = 0;
    stencilFail: i32 = 0;
    stencilZFail: i32 = 0;
    stencilZPass: i32 = 0;
    polygonOffset: bool = false;
    polygonOffsetFactor: f64 = 0;
    polygonOffsetUnits: f64 = 0;
    /// A ShaderMaterial's pipeline and what it was made for.
    custom: CustomPipeline? = null;
    customKey: i32 = 0;
    customFormat: u32 = 0;
    customCount: i32 = 0;
    customShader: string = "";
    customVertex: string = "";
    customFragment: string = "";
    customLights: bool = false;

    constructor(material: Material) {
        this.material = material;
    }
}

// A material's share of the object block (everything but the world and
// normal matrices, the light list and a few per-draw fields), written once
// per view, with the texture views and samplers it binds. `version`
// changes only when its bytes do, so draws keep their arena blocks while
// their material and transform stand still.
class MaterialBlock {
    frame: i32 = -1;
    version: i32 = 0;
    bytes: ArrayBuffer = new ArrayBuffer(OBJ_BYTES);
    u8: Uint8Array = Uint8Array.wrap(this.bytes);
    i64: Int64Array = Int64Array.wrap(this.bytes);
    views: StaticArray<GPUTextureView?> = new StaticArray<GPUTextureView?>(TEXTURE_SLOTS);
    samplers: StaticArray<GPUSampler?> = new StaticArray<GPUSampler?>(TEXTURE_SLOTS);
    xviews: StaticArray<GPUTextureView?> = new StaticArray<GPUTextureView?>(EXTRA_SLOTS);
    xcount: i32 = 0;
    matGroup: GPUBindGroup? = null;
    samplerGroup: GPUBindGroup? = null;
    groupViews: StaticArray<GPUTextureView?> = new StaticArray<GPUTextureView?>(TEXTURE_SLOTS);
    groupSamplers: StaticArray<GPUSampler?> = new StaticArray<GPUSampler?>(TEXTURE_SLOTS);
    /// Its share of the program key (GPURenderer.programKey).
    vkind: u32 = 0;
    vpresent: u32 = 0;
    vflags: u32 = 0;
    vroles: u32 = 0;
    vcutout: bool = true;
    vflat: bool = false;
    vownEnv: bool = false;
}

// One draw of this frame (pooled: GPURenderer.newItem resets every field).
class DrawItem {
    object: Object3D;
    material: Material;
    geometry: GeometryGPU?;
    prim: i32 = PRIM_TRIANGLES;
    index: GPUBuffer? = null;
    indexFormat: u32 = 0;
    state: DrawState;
    entry: MaterialEntry? = null;
    pipelineKey: i32 = 0;
    depth: f64 = 0;
    first: i32 = 0;
    count: i32 = 0;
    instances: GPUBuffer;
    instanceColors: GPUBuffer;
    instanceCount: u32 = 1;
    /// The first instance read from `instances` (BatchedMesh geometries).
    instanceFirst: u32 = 0;
    skinned: bool = false;
    bones: GPUBuffer? = null;
    /// Morph targets / a bone texture: the mesh's MorphU block (at
    /// `morphOffset` in the morph arena), and the textures it borrows extra
    /// slots for.
    morphed: bool = false;
    morphOffset: u32 = 0;
    morphView: GPUTextureView? = null;
    /// Its baked shader variant (-1: the uber-shader).
    variant: i32 = -1;
    boneView: GPUTextureView? = null;
    instanceMorphView: GPUTextureView? = null;
    /// The instance rows bound at slot 7 (KEY_MORPH_INSTANCED draws).
    morphRows: GPUBuffer? = null;
    custom: CustomPipeline? = null;
    customUniforms: CustomUniforms? = null;
    positionOverride: GPUBuffer? = null;
    /// MeshPhysicalMaterial with transmission: left out of the transmission pass.
    transmissive: bool = false;
    stencilRef: u32 = 0;
    normalOverride: GPUBuffer? = null;

    constructor(object: Object3D, material: Material, geometry: GeometryGPU?, state: DrawState, instances: GPUBuffer,
                instanceColors: GPUBuffer) {
        this.object = object;
        this.material = material;
        this.geometry = geometry;
        this.state = state;
        this.instances = instances;
        this.instanceColors = instanceColors;
    }

    reset(object: Object3D, material: Material, geometry: GeometryGPU?, state: DrawState, instances: GPUBuffer,
          instanceColors: GPUBuffer): void {
        this.object = object;
        this.material = material;
        this.geometry = geometry;
        this.state = state;
        this.instances = instances;
        this.instanceColors = instanceColors;
        this.entry = null;
        this.prim = PRIM_TRIANGLES;
        this.index = null;
        this.indexFormat = 0;
        this.pipelineKey = 0;
        this.depth = 0;
        this.first = 0;
        this.count = 0;
        this.instanceCount = 1;
        this.instanceFirst = 0;
        this.skinned = false;
        this.bones = null;
        this.morphed = false;
        this.morphOffset = 0;
        this.morphView = null;
        this.boneView = null;
        this.instanceMorphView = null;
        this.morphRows = null;
        this.custom = null;
        this.customUniforms = null;
        this.positionOverride = null;
        this.transmissive = false;
        this.stencilRef = 0;
        this.normalOverride = null;
        this.variant = -1;
    }
}

export class GPURenderer {
    readonly context: Context;
    /// Clear the canvas before each render (else draw over the last one).
    autoClear: bool = true;
    /// What autoClear clears: colour, depth and stencil (as three.js).
    autoClearColor: bool = true;
    autoClearDepth: bool = true;
    autoClearStencil: bool = true;
    /// Sort draws (opaque front to back, transparent back to front).
    sortObjects: bool = true;
    /// NoToneMapping, LinearToneMapping, ReinhardToneMapping,
    /// CineonToneMapping, ACESFilmicToneMapping, AgXToneMapping or
    /// NeutralToneMapping.
    toneMapping: i32 = NoToneMapping;
    toneMappingExposure: f64 = 1;
    /// Always sRGB here.
    readonly outputColorSpace: string = SRGBColorSpace;
    readonly info: RendererInfo = new RendererInfo();
    readonly shadowMap: ShadowMapSettings = new ShadowMapSettings();
    /// Global clipping planes (world space), for every material.
    clippingPlanes: Array<Plane> = [];
    /// Whether materials' own clippingPlanes apply.
    localClippingEnabled: bool = false;

    private canvas: GPUCanvas? = null;
    private width: f64 = 0;
    private height: f64 = 0;
    private pixelRatio: f64 = 1;
    private _clearColor: Color = new Color(0, 0, 0);
    private clearAlpha: f64 = 1;
    private antialias: bool;
    private broken: bool = false;
    private maxAnisotropy: i32 = 1;

    private module: GPUShaderModule? = null;
    private frameLayout: GPUBindGroupLayout? = null;
    private objLayout: GPUBindGroupLayout? = null;
    private matLayout: GPUBindGroupLayout? = null;
    // Group 3: the material's samplers (Rive allows bindings 0-7 a group,
    // so textures and samplers do not fit in one).
    private samplerLayout: GPUBindGroupLayout? = null;
    private vertexBuffers: Array<GPUVertexBufferLayout> = [];
    private pointBuffers: Array<GPUVertexBufferLayout> = [];
    private skinBuffers: Array<GPUVertexBufferLayout> = [];
    // vertexBuffers plus the instance rows of instanced morphs at slot 7.
    private morphRowBuffers: Array<GPUVertexBufferLayout> = [];
    private dummyBones: GPUBuffer? = null;
    private dummyMorph: GPUBuffer? = null;
    private morphTargets: Map<i32, MorphTargetsGPU> = new Map<i32, MorphTargetsGPU>();
    private pendingMorphs: Array<MorphTargetsGPU> = [];
    private deforms: Map<i32, DeformGPU> = new Map<i32, DeformGPU>();
    private warnedMorphs: bool = false;
    private boneBuffers: Map<i32, GPUBuffer> = new Map<i32, GPUBuffer>();
    private morphs: Map<i32, MorphGPU> = new Map<i32, MorphGPU>();
    private customPipelines: Map<string, CustomPipeline> = new Map<string, CustomPipeline>();
    private customModules: Map<string, GPUShaderModule> = new Map<string, GPUShaderModule>();
    private customUniforms: Map<i32, CustomUniforms> = new Map<i32, CustomUniforms>();
    private warnedShaders: Map<string, bool> = new Map<string, bool>();
    private warnedBones: bool = false;
    private instanceBuffers: Map<i32, InstanceGPU> = new Map<i32, InstanceGPU>();
    private batchedBuffers: Map<i32, BatchedGPU> = new Map<i32, BatchedGPU>();
    private pipelines: Map<i64, GPUPipeline> = new Map<i64, GPUPipeline>();
    // The colour format of the target being rendered (pipelines are cached
    // per format).
    private pipelineFormat: u32 = 0xFFFFFFFF;
    private linearOutput: bool = false;
    private samples: u32 = 1;

    private frameUbo: GPUBuffer? = null;
    private ltcUbo: GPUBuffer? = null;
    private frameGroup: GPUBindGroup? = null;
    private frameStaging: ArrayBuffer = new ArrayBuffer(FRAME_BYTES);
    // A material block being written (compared with its last bytes).
    private objStaging: ArrayBuffer = new ArrayBuffer(OBJ_BYTES);
    private objF32: Float32Array = Float32Array.wrap(this.objStaging);
    private objU32: Uint32Array = Uint32Array.wrap(this.objStaging);
    private objU8: Uint8Array = Uint8Array.wrap(this.objStaging);
    private objI64: Int64Array = Int64Array.wrap(this.objStaging);
    // Every draw's object block, in one uniform buffer bound at a dynamic
    // offset per draw. Each draw keeps its slot across frames; a slot is
    // rewritten and uploaded only when its block changed (runs of changed
    // slots upload together).
    private arena: GPUBuffer? = null;
    private arenaStaging: ArrayBuffer = new ArrayBuffer(0);
    private arenaBytes: Uint8Array = new Uint8Array(0);
    private arenaF32: Float32Array = new Float32Array(0);
    private arenaU32: Uint32Array = new Uint32Array(0);
    private arenaCapacity: i32 = 0;
    private slotCount: i32 = 0;
    // Draw states and material entries that have not been drawn for a while
    // are evicted (sweepStale): their bind groups are released and their
    // arena slots reused. Without it every object and material ever drawn
    // kept its state, bind groups and arena slot, so a scene that keeps
    // making new objects (clones, per-level copies) leaked GPU handles and
    // memory.
    private freeSlots: Array<i32> = [];
    private lastSweep: i32 = 0;
    private slotDirty: Uint8Array = new Uint8Array(0);
    private dirtyLo: i32 = 0x7fffffff;
    private dirtyHi: i32 = -1;
    private uploadAll: bool = false;
    private arenaGroup: GPUBindGroup? = null;
    private lightWords: StaticArray<u32> = new StaticArray<u32>(8);
    private materialEntries: Map<i32, MaterialEntry> = new Map<i32, MaterialEntry>();
    private itemPool: Array<DrawItem> = [];
    private itemsUsed: i32 = 0;
    /// Cull big scenes (from PARALLEL_CULL_MIN candidates) in a Rive
    /// parallel call (Rive-only; same result either way).
    parallelCulling: bool = true;
    private renderables: Array<Object3D> = [];
    private cullTest: Uint8Array = new Uint8Array(0);
    private cullOut: SharedArray<u8> = new SharedArray<u8>(0);
    private cullPlanes: Float64Array = new Float64Array(24);
    /// Draw with the baked shader variant of a draw's program key where the
    /// project has one (tools/threeas_bake.sh, "optimized" mode, Rive-only);
    /// else, and always without a bake, with the uber-shader.
    useBakedShaders: bool = true;
    // Baked variants, found by asset name (gpu/ShaderVariants): each program
    // key seen -> its index in variantModules (-1: none, the uber-shader),
    // looked up once; the variants' pipelines.
    private variantByKey: Map<string, i32> = new Map<string, i32>();
    private variantModules: Array<GPUShaderModule> = [];
    private variantPipelines: Array<Map<i64, GPUPipeline>> = [];
    // Dev builds: keys with no variant, logged once the project turns out
    // to have a bake (a variant was found).
    private variantMisses: Array<string> = [];
    // `--arg threeShaderKeys=1`: log every program key once, and its
    // variant (the bake tool's recording).
    private recordKeys: bool = false;
    // The frame's share of the program key and its lights' types.
    private frameVariantBits: i32 = 0;
    private frameLightTypes: Int32Array = new Int32Array(MAX_LIGHTS);
    // Pass descriptors reused from pass to pass (no garbage per frame).
    private attachmentList: Array<GPUColorAttachment> = [];
    private noAttachments: Array<GPUColorAttachment> = [];
    private shadowPassDesc: GPUPassDesc = new GPUPassDesc();
    private transmissionDesc: GPUPassDesc = new GPUPassDesc();
    private transmissionColor: GPUColorAttachment = new GPUColorAttachment();
    private transmissionAttachments: Array<GPUColorAttachment> = [];
    private transmissionGroup: GPUBindGroup? = null;
    private transmissionGroupViews: StaticArray<GPUTextureView?> = new StaticArray<GPUTextureView?>(2);
    private transmissionBgGroup: GPUBindGroup? = null;
    private transmissionBgView: GPUTextureView? = null;
    private transmissionBgMipmapped: bool = false;
    private frameF32: Float32Array = Float32Array.wrap(this.frameStaging);
    private frameU32: Uint32Array = Uint32Array.wrap(this.frameStaging);
    private customViews: Array<GPUTextureView> = [];
    // ShaderMaterials: their object block offset; built-in materials: it and
    // the morph block offset (group 1 bindings 0 and 7 are dynamic).
    private dynamicOffset: Array<u32> = [0];
    private dynamicOffsets: Array<u32> = [0, 0];
    // Every morphed (or big-skinned) mesh's MorphU block of the view, packed at
    // 256-byte offsets into one uniform buffer: a block takes the bytes it
    // uses (a binding spans MORPH_BYTES from its offset, so the buffer has
    // that much room past the last one).
    private morphArena: GPUBuffer? = null;
    private morphStaging: ArrayBuffer = new ArrayBuffer(0);
    private morphF32: Float32Array = new Float32Array(0);
    private morphU32: Uint32Array = new Uint32Array(0);
    private morphBytes: Uint8Array = new Uint8Array(0);
    private morphCapacity: i32 = 0;
    private morphUsed: i32 = 0;
    private morphFlushed: i32 = 0;
    private white: GPUTextureView? = null;
    private identityInstance: GPUBuffer? = null;
    private identityColor: GPUBuffer? = null;
    private whiteColors: GPUBuffer? = null;
    private whiteCount: i32 = 0;
    private morphRows: GPUBuffer? = null;
    private morphRowCount: u32 = 0;
    private samplers: Map<i32, GPUSampler> = new Map<i32, GPUSampler>();
    private bgView: GPUTextureView? = null;
    private bgModule: GPUShaderModule? = null;
    private backgroundLayout: GPUBindGroupLayout? = null;
    private bgGroup: GPUBindGroup? = null;
    private bgGroupView: GPUTextureView? = null;
    private bgGroupMipmapped: bool = false;
    private bgMipmapped: bool = false;
    private bgTexture: Texture? = null;
    private envTexture: Texture? = null;
    private envView: GPUTextureView? = null;
    private envLevels: u32 = 1;
    private captures: Array<SceneCapture> = [];
    private capturing: bool = false;
    private envPrefiltered: bool = false;
    private bgPrefiltered: bool = false;
    private frameGroupView: GPUTextureView? = null;
    private frameGroupShadow: GPUTextureView? = null;
    private frameGroupTransmission: GPUTextureView? = null;
    private frameEnvView: GPUTextureView? = null;
    private frameShadowView: GPUTextureView? = null;
    // Transmission.
    private hasTransmission: bool = false;
    private transmissionTarget: RenderTarget? = null;
    private transmissionTargets: PassTargets = new PassTargets();
    private transmissionUbo: GPUBuffer? = null;
    private transmissionView: GPUTextureView? = null;
    // Shadows.
    private shadowTex: GPUTexture? = null;
    private shadowView: GPUTextureView? = null;
    private shadowLayerViews: Array<GPUTextureView> = [];
    private shadowSize: u32 = 0;
    private shadowLayers: u32 = 0;
    private dummyShadowView: GPUTextureView? = null;
    private tileUbos: Array<GPUBuffer> = [];
    private tileGroups: Array<GPUBindGroup> = [];
    private tileStaging: ArrayBuffer = new ArrayBuffer(FRAME_BYTES);
    private tiles: Array<ShadowTile> = [];
    private tileCount: i32 = 0;
    private lightFirstTile: Map<i32, i32> = new Map<i32, i32>();
    private casterMeshes: Array<Mesh> = [];
    private casterItems: Array<DrawItem> = [];
    private shadowPipelines: Map<i32, GPUPipeline> = new Map<i32, GPUPipeline>();
    private shadowsWarned: bool = false;
    private warnedExtraMaps: bool = false;
    private warnedDepthMap: bool = false;
    private dummyDepthView: GPUTextureView? = null;
    // The frame's lights for per-object culling: x, y, z, reach, weight.
    private frameLights: Float64Array = new Float64Array(MAX_LIGHTS * 5);
    private frameLightCount: i32 = 0;
    private cameraPos: Vector3 = new Vector3();
    private lightScores: Float64Array = new Float64Array(MAX_LIGHTS);
    private lightOrder: Int32Array = new Int32Array(MAX_LIGHTS);
    private passStates: Array<PassState> = [new PassState()];
    private wideLines: Map<i32, WideLineGPU> = new Map<i32, WideLineGPU>();
    private passStateKeys: Map<string, i32> = new Map<string, i32>();

    private mainTargets: PassTargets = new PassTargets();
    private rtTargets: Map<i32, PassTargets> = new Map<i32, PassTargets>();
    private renderTarget: RenderTarget? = null;
    // The destination of the render in progress.
    private passSamples: u32 = 1;
    private passWidth: u32 = 0;
    private passHeight: u32 = 0;
    private passRatio: f64 = 1;
    private destCanvas: GPUCanvas? = null;
    private destView: GPUTextureView? = null;
    private destTargets: PassTargets? = null;
    private destDepth: GPUTextureView? = null;
    private destKeepsDepth: bool = false;
    // Colour attachments of the pass (multiple render targets) beyond the
    // first, and their attachments.
    private pipelineCount: i32 = 1;
    private extraViews: Array<GPUTextureView> = [];
    private extraAttachments: Array<GPUColorAttachment> = [];
    // Viewport (setViewport, in points from the bottom left), scissor and
    // the pass's viewport and scissor in pixels from the top left.
    private _viewport: Vector4 = new Vector4();
    private _scissor: Vector4 = new Vector4();
    private _scissorSet: bool = false;
    private _scissorTest: bool = false;
    private viewportOverride: Vector4? = null;
    private vpX: f32 = 0;
    private vpY: f32 = 0;
    private vpW: f32 = 0;
    private vpH: f32 = 0;
    private vpFull: bool = true;
    private scissorOn: bool = false;
    private scX: u32 = 0;
    private scY: u32 = 0;
    private scW: u32 = 0;
    private scH: u32 = 0;
    // ArrayCamera views after the first reuse its shadow maps.
    private skipShadows: bool = false;
    // ArrayCamera views after the first: the background was drawn already.
    private arraySubView: bool = false;
    // compile(): collect everything, culled or not.
    private noCull: bool = false;
    // GPURendererParameters.logarithmicDepthBuffer.
    private logDepth: bool = false;
    // Counts renders (views): per-draw state is written once per view.
    private frameId: i32 = 0;
    private utilModule: GPUShaderModule? = null;
    private utilBroken: bool = false;
    private fillPipelines: Map<i64, GPUPipeline> = new Map<i64, GPUPipeline>();
    private copyPipelines: Map<u32, GPUPipeline> = new Map<u32, GPUPipeline>();
    private copyUbo: GPUBuffer? = null;
    private copyStaging: Float32Array = new Float32Array(8);

    private geometries: GPUGeometries = new GPUGeometries();
    private textures: GPUTextures;
    private states: Map<i32, DrawState> = new Map<i32, DrawState>();
    private opaque: Array<DrawItem> = [];
    private transparent: Array<DrawItem> = [];
    private lights: Array<Light> = [];
    private stack: Array<Object3D> = [];
    private uniforms: MaterialUniforms = new MaterialUniforms();
    private warnedLights: bool = false;
    private colorAttachment: GPUColorAttachment = new GPUColorAttachment();
    private passDesc: GPUPassDesc = new GPUPassDesc();
    private viewProj: Matrix4 = new Matrix4();
    private invViewProj: Matrix4 = new Matrix4();
    private overrideMaterial: Material? = null;
    // onBeforeRender / onAfterRender: the objects a view draws (collect
    // fills drawnObjects; a view takes the list, nested renders get one of
    // their own from hookLists), the renders in progress, a count of passes
    // (a hook that renders bumps it), and while after-render hooks run, the
    // targets of their view and whether a hook loaded what that view's
    // pass did not keep.
    private drawnObjects: Array<Object3D> = [];
    private hookLists: Array<Array<Object3D>> = [];
    private renderDepth: i32 = 0;
    private passSerial: i32 = 0;
    private afterHooks: i32 = 0;
    private hookTargets: PassTargets? = null;
    // Hooks in progress, the outermost hooked view's number, and the objects
    // whose hook rendered for it (id -> view).
    private hookDepth: i32 = 0;
    private hookView: i32 = 0;
    private hookedObjects: Map<i32, i32> = new Map<i32, i32>();
    private framebufferLost: bool = false;
    // renderBufferDirect: its one-object scene, and while it renders (no
    // hooks, no culling, no clear).
    private directScene: Scene? = null;
    private directing: bool = false;
    private warnedDirect: bool = false;

    constructor(context: Context, parameters: GPURendererParameters? = null) {
        this.context = context;
        this.textures = new GPUTextures(context);
        this.antialias = parameters != null ? parameters.antialias : false;
        if (parameters != null && parameters.alpha) this.clearAlpha = 0;
        this.logDepth = parameters != null && parameters.logarithmicDepthBuffer;
        this.recordKeys = context.arg("threeShaderKeys") != null;
        // `--arg threeUberShader=1`: ignore the baked variants (to compare).
        if (context.arg("threeUberShader") != null) this.useBakedShaders = false;
    }

    /// The canvas rendered into (three.js's `domElement`), null until the
    /// first render with a size.
    get domElement(): GPUCanvas? { return this.canvas; }

    // ------------------------------------------------------------------- size

    getPixelRatio(): f64 { return this.pixelRatio; }

    /// Device pixels per point: pass `resize`'s `scale`.
    setPixelRatio(value: f64): void {
        this.pixelRatio = value > 0 ? value : 1;
    }

    getSize(target: Vector2): Vector2 { return target.set(this.width, this.height); }

    /// The size in points (the layout's size). Resets the viewport to the
    /// whole canvas, as three.js.
    setSize(width: f64, height: f64): void {
        this.width = width;
        this.height = height;
        this._viewport.set(0, 0, width, height);
        if (!this._scissorSet) this._scissor.set(0, 0, width, height);
    }

    // --------------------------------------------------- viewport and scissor

    /// The viewport (in points, from the bottom left, as three.js):
    /// `setViewport(x, y, width, height)` or `setViewport(vector4)`.
    setViewport<T>(x: T, y: f64 = 0, width: f64 = 0, height: f64 = 0): void {
        if (isReference<T>()) {
            if (x instanceof Vector4) this._viewport.copy(x as Vector4);
        } else {
            this._viewport.set(<f64>x, y, width, height);
        }
    }

    getViewport(target: Vector4): Vector4 { return target.copy(this._viewport); }

    /// The viewport in drawing-buffer pixels (the render target's when one
    /// is set).
    getCurrentViewport(target: Vector4): Vector4 {
        const rt = this.renderTarget;
        if (rt != null) return target.copy(rt.viewport);
        const r = this.pixelRatio;
        const v = this._viewport;
        return target.set(Math.round(v.x * r), Math.round(v.y * r), Math.round(v.z * r), Math.round(v.w * r));
    }

    /// The scissor rectangle (points, from the bottom left), used while
    /// `setScissorTest(true)`: `setScissor(x, y, width, height)` or
    /// `setScissor(vector4)`.
    setScissor<T>(x: T, y: f64 = 0, width: f64 = 0, height: f64 = 0): void {
        if (isReference<T>()) {
            if (x instanceof Vector4) this._scissor.copy(x as Vector4);
        } else {
            this._scissor.set(<f64>x, y, width, height);
        }
        this._scissorSet = true;
    }

    getScissor(target: Vector4): Vector4 { return target.copy(this._scissor); }

    /// Restricts drawing and clearing to the scissor rectangle.
    setScissorTest(value: bool): void { this._scissorTest = value; }
    getScissorTest(): bool { return this._scissorTest; }

    getDrawingBufferSize(target: Vector2): Vector2 {
        return target.set(<f64>this.pixelWidth(), <f64>this.pixelHeight());
    }

    /// The highest anisotropy textures can use (1 without the feature).
    getMaxAnisotropy(): i32 {
        return this.context.features().anisotropicFiltering ? 16 : 1;
    }

    private pixelWidth(): u32 { return this.width > 0 ? <u32>Math.ceil(this.width * this.pixelRatio) : 0; }
    private pixelHeight(): u32 { return this.height > 0 ? <u32>Math.ceil(this.height * this.pixelRatio) : 0; }

    // ------------------------------------------------------------ clear colour

    /// `color` is an sRGB hex (or a Rive Color, alpha ignored), a CSS string
    /// or a Color.
    setClearColor<T>(color: T, alpha: f64 = 1): void {
        this._clearColor.set<T>(color);
        this.clearAlpha = alpha;
    }

    /// Renders into `target` from now on (null: the canvas presented).
    setRenderTarget(target: RenderTarget?): void { this.renderTarget = target; }
    getRenderTarget(): RenderTarget? { return this.renderTarget; }

    getClearColor(target: Color): Color { return target.copy(this._clearColor); }
    getClearAlpha(): f64 { return this.clearAlpha; }
    setClearAlpha(alpha: f64): void { this.clearAlpha = alpha; }

    // ----------------------------------------------------------------- render

    /// Renders `scene` from `camera` into the canvas. Call it from the
    /// script's `draw()`, then `present`.
    /// Renders `capture` before the next render (internal: PMREMGenerator).
    queueSceneCapture(capture: SceneCapture): void {
        this.captures.push(capture);
    }

    /// Renders `scene` from `camera` into the current render target (or the
    /// canvas). It can be called from an object's onBeforeRender /
    /// onAfterRender during another render (Reflector, Lensflare): that
    /// render's viewport override and ArrayCamera state are set aside.
    render(scene: Object3D, camera: Camera): void {
        const depth = this.renderDepth++;
        const ov = this.viewportOverride;
        const skip = this.skipShadows;
        const sub = this.arraySubView;
        if (depth > 0) {
            this.viewportOverride = null;
            this.skipShadows = false;
            this.arraySubView = false;
        }
        this.renderTop(scene, camera, depth);
        this.viewportOverride = ov;
        this.skipShadows = skip;
        this.arraySubView = sub;
        this.renderDepth--;
    }

    private renderTop(scene: Object3D, camera: Camera, depth: i32): void {
        if (this.captures.length > 0 && !this.capturing) {
            this.capturing = true;
            const captures = this.captures;
            this.captures = [];
            const autoClear = this.autoClear;
            this.autoClear = true;
            for (let i = 0; i < captures.length; i++) {
                const c = captures[i];
                c.camera.updateMatrixWorld();
                c.camera.update(this, c.scene);
            }
            this.autoClear = autoClear;
            this.capturing = false;
        }
        if (depth == 0) {
            if (this.info.autoReset) this.info.reset();
            this.info.render.frame++;
        }
        if (this.broken) return;
        if (camera instanceof ArrayCamera) {
            // One view per sub-camera, into its viewport; the first clears.
            const cameras = (camera as ArrayCamera).cameras;
            const autoClear = this.autoClear;
            for (let i = 0; i < cameras.length; i++) {
                const sub = cameras[i];
                this.viewportOverride = sub.viewport;
                this.skipShadows = i > 0;
                this.arraySubView = i > 0;
                this.renderView(scene, sub);
                this.autoClear = false;
            }
            this.autoClear = autoClear;
            this.viewportOverride = null;
            this.skipShadows = false;
            this.arraySubView = false;
            return;
        }
        this.renderView(scene, camera);
    }

    /// Picks the destination of the next pass (the render target, or the
    /// canvas presented): fills destCanvas, destView, destTargets, the pass
    /// size and output format. False when there is nothing to render into.
    private beginDestination(): bool {
        const rt = this.renderTarget;
        let canvas: GPUCanvas?;
        let pw: u32, ph: u32;
        let targets: PassTargets;
        if (rt != null) {
            pw = rt.width; ph = rt.height;
            if (pw == 0 || ph == 0) return false;
            canvas = rt.isHDR ? this.ensureCanvas() : rt.ensureCanvas(this.context);
            if (!this.rtTargets.has(rt.id)) this.rtTargets.set(rt.id, new PassTargets());
            targets = this.rtTargets.get(rt.id);
            this.passRatio = 1;
        } else {
            pw = this.pixelWidth(); ph = this.pixelHeight();
            if (pw == 0 || ph == 0) return false;
            canvas = this.ensureCanvas();
            if (canvas != null && (canvas.width != pw || canvas.height != ph)) {
                if (!canvas.resize(pw, ph)) return false;
            }
            targets = this.mainTargets;
            this.passRatio = this.pixelRatio;
        }
        if (canvas == null) return false;
        // HDR targets render into their own texture, through the main canvas
        // (any target can host a pass).
        let target: GPUTextureView?;
        this.linearOutput = false;
        if (rt != null && rt.isHDR) {
            const host = this.ensureCanvas();
            if (host == null) return false;
            canvas = host;
            target = rt.ensureHDR();
            this.pipelineFormat = <u32>TextureFormat.rgba16float;
            this.linearOutput = true;
        } else {
            target = canvas.view;
            this.pipelineFormat = canvas.format;
        }
        if (target == null) return false;
        if (!this.ensureSetup(canvas)) return false;
        this.passSamples = rt != null ? (rt.samples > 1 ? this.samples : 1) : this.samples;
        this.passWidth = pw;
        this.passHeight = ph;
        // A multiple render target's extra attachments; a depth texture
        // stands in for the pass's own depth (neither with MSAA).
        const depthTexture = rt != null ? rt.depthTexture : null;
        this.pipelineCount = rt != null ? rt.textures.length : 1;
        if (this.pipelineCount > 1 || depthTexture != null) this.passSamples = 1;
        this.extraViews.length = 0;
        for (let i = 1; i < this.pipelineCount; i++) {
            const v = rt!.textures[i].ensureOwn(this.pipelineFormat);
            if (v == null) return false;
            this.extraViews.push(v!);
        }
        this.ensureTargets(targets, this.pipelineFormat, pw, ph, this.passSamples, depthTexture == null);
        const depth = depthTexture != null ? depthTexture.ensureAttachment(pw, ph) : targets.depthView;
        if (depth == null) return false;
        this.destDepth = depth;
        this.destKeepsDepth = depthTexture != null;
        this.destCanvas = canvas;
        this.destView = target;
        this.destTargets = targets;
        return this.computeViewport();
    }

    /// The pass's viewport and scissor in pixels (top-left origin, inside
    /// the target): an ArrayCamera sub-camera's viewport, the render
    /// target's, or setViewport's times the pixel ratio. False when the
    /// viewport or scissor is empty.
    private computeViewport(): bool {
        const pw = <f64>this.passWidth, ph = <f64>this.passHeight;
        const rt = this.renderTarget;
        const ov = this.viewportOverride;
        const r = this.pixelRatio;
        let x: f64, y: f64, w: f64, h: f64;
        if (ov != null) {
            x = ov.x; y = ov.y; w = ov.z; h = ov.w;
        } else if (rt != null) {
            const v = rt.viewport;
            x = v.x; y = v.y; w = v.z; h = v.w;
        } else {
            const v = this._viewport;
            x = Math.round(v.x * r); y = Math.round(v.y * r); w = Math.round(v.z * r); h = Math.round(v.w * r);
        }
        // Bottom-left origin (three.js) to top-left, clamped to the target.
        let top = ph - (y + h);
        const x0 = Math.max(0, x), y0 = Math.max(0, top);
        const x1 = Math.min(pw, x + w), y1 = Math.min(ph, top + h);
        if (x1 <= x0 || y1 <= y0) return false;
        this.vpX = <f32>x0; this.vpY = <f32>y0; this.vpW = <f32>(x1 - x0); this.vpH = <f32>(y1 - y0);
        this.vpFull = x0 == 0 && y0 == 0 && x1 == pw && y1 == ph;
        const test = rt != null ? rt.scissorTest : this._scissorTest;
        this.scissorOn = false;
        if (test) {
            let sx: f64, sy: f64, sw: f64, sh: f64;
            if (rt != null) {
                const s = rt.scissor;
                sx = s.x; sy = s.y; sw = s.z; sh = s.w;
            } else {
                const s = this._scissor;
                sx = Math.round(s.x * r); sy = Math.round(s.y * r); sw = Math.round(s.z * r); sh = Math.round(s.w * r);
            }
            const stop = ph - (sy + sh);
            const ax = Math.max(0, sx), ay = Math.max(0, stop);
            const bx = Math.min(pw, sx + sw), by = Math.min(ph, stop + sh);
            if (bx <= ax || by <= ay) return false;
            this.scX = <u32>ax; this.scY = <u32>ay; this.scW = <u32>(bx - ax); this.scH = <u32>(by - ay);
            this.scissorOn = !(ax == 0 && ay == 0 && bx == pw && by == ph);
        }
        return true;
    }

    /// Sets the pass's viewport and scissor when they are not the whole
    /// target.
    private applyViewport(pass: GPURenderPass): void {
        if (!this.vpFull) pass.setViewport(this.vpX, this.vpY, this.vpW, this.vpH, 0, 1);
        if (this.scissorOn) pass.setScissor(this.scX, this.scY, this.scW, this.scH);
    }

    /// Fills the scissor rectangle with the clear colour (and depth 1,
    /// stencil 0) where a load op cannot: three.js clears only inside the
    /// scissor.
    private clearScissor(pass: GPURenderPass, color: bool, depth: bool, stencil: bool, r: f32, g: f32, b: f32,
                         a: f32): void {
        const p = this.fillPipeline(color, depth, stencil);
        if (p == null) return;
        pass.setScissor(this.scX, this.scY, this.scW, this.scH);
        pass.setPipeline(p!);
        pass.setBlendColor(r, g, b, a);
        if (stencil) pass.setStencilReference(0);
        pass.draw(3);
    }

    /// The pipeline of scissored clears for the current pass's format and
    /// samples.
    private fillPipeline(color: bool, depth: bool, stencil: bool): GPUPipeline? {
        if (!this.ensureUtil()) return null;
        const key = (<i64>this.pipelineCount << 56) | (<i64>this.pipelineFormat << 32) | <i64>((color ? 1 : 0) | (depth ? 2 : 0) | (stencil ? 4 : 0)
            | (<i32>this.passSamples << 4));
        if (this.fillPipelines.has(key)) return this.fillPipelines.get(key);
        const target = new GPUColorTargetDesc();
        target.format = <TextureFormat>this.pipelineFormat;
        if (color) {
            const blend = new GPUBlendState();
            blend.srcColor = BlendFactor.blendColor; blend.dstColor = BlendFactor.zero;
            blend.srcAlpha = BlendFactor.blendColor; blend.dstAlpha = BlendFactor.zero;
            target.blend = blend;
        } else {
            target.writeMask = <u32>ColorWriteMask.none;
        }
        const ds = new GPUDepthStencilDesc();
        ds.format = DEPTH_FORMAT;
        ds.compare = CompareFunction.always;
        ds.write = depth;
        if (stencil) {
            ds.stencilFront.passOp = StencilOp.replace;
            ds.stencilBack.passOp = StencilOp.replace;
        } else {
            ds.stencilWriteMask = 0;
        }
        const d = new GPUPipelineDesc();
        d.vertexModule = this.utilModule;
        d.vertexEntryPoint = "vs_fill";
        d.fragmentModule = this.utilModule;
        const counts: StaticArray<string> = ["fs_one", "fs_one2", "fs_one3", "fs_one4"];
        d.fragmentEntryPoint = counts[min<i32>(3, this.pipelineCount - 1)];
        d.colorTargets = this.colorTargets(target, true);
        d.depthStencil = ds;
        d.sampleCount = this.passSamples;
        const p = new GPUPipeline(d);
        this.fillPipelines.set(key, p);
        return p;
    }

    private ensureUtil(): bool {
        if (this.utilModule != null) return true;
        if (this.utilBroken) return false;
        let module: GPUShaderModule? = null;
        for (let i = 0; i < UTIL_SHADER_NAMES.length && module == null; i++) {
            module = this.context.shader(UTIL_SHADER_NAMES[i]);
        }
        if (module == null) {
            this.context.log("three: shader asset 'three/shaders/three_util.wgsl' not found");
            this.utilBroken = true;
            return false;
        }
        this.utilModule = module;
        return true;
    }

    /// Opens the pass of a render or clear on the destination: clears
    /// with load ops, or loads (keeping what earlier renders drew) and
    /// clears inside the scissor.
    private openPass(clearColor: bool, clearDepth: bool, clearStencil: bool, r: f64, g: f64, b: f64, a: f64,
                     label: string): GPURenderPass {
        const targets = this.destTargets!;
        const target = this.destView!;
        const canvas = this.destCanvas!;
        const scissored = this.scissorOn;
        const color = this.colorAttachment;
        let cr: f32, cg: f32, cb: f32;
        if (this.linearOutput) {
            cr = <f32>(r * a); cg = <f32>(g * a); cb = <f32>(b * a);
        } else {
            cr = <f32>(LinearToSRGB(r) * a); cg = <f32>(LinearToSRGB(g) * a); cb = <f32>(LinearToSRGB(b) * a);
        }
        color.clearR = cr; color.clearG = cg; color.clearB = cb; color.clearA = <f32>a;
        // Load ops clear the whole target: only without a scissor.
        const loadColor = !clearColor || scissored;
        const loadDepth = !clearDepth || scissored;
        // A render that is one of several (a viewport, a scissor, a load)
        // keeps its MSAA colour and depth for the next one.
        const partial = !this.vpFull || scissored;
        this.passSerial++;
        if (this.afterHooks > 0 && targets === this.hookTargets
                && ((loadColor && targets.msaaView != null && !targets.keepColor)
                    || (loadDepth && !targets.keepDepth && !this.destKeepsDepth))) {
            this.framebufferLost = true;
        }
        if (loadColor || partial) targets.keepColor = true;
        if (loadDepth || partial) targets.keepDepth = true;
        color.loadOp = loadColor ? LoadOp.load : LoadOp.clear;
        const msaa = targets.msaaView;
        if (msaa != null) {
            // The MSAA texture keeps its samples only once a pass loads it.
            color.view = msaa;
            color.resolveTarget = target;
            color.storeOp = targets.keepColor ? StoreOp.store : StoreOp.discard;
        } else {
            color.view = this.linearOutput ? target : null;
            color.resolveTarget = null;
            color.storeOp = StoreOp.store;
        }
        const pd = this.passDesc;
        pd.label = label;
        const attachments = this.attachmentList;
        attachments.length = 0;
        attachments.push(color);
        for (let i = 0; i < this.extraViews.length; i++) {
            while (this.extraAttachments.length <= i) this.extraAttachments.push(new GPUColorAttachment());
            const e = this.extraAttachments[i];
            e.view = this.extraViews[i];
            e.resolveTarget = null;
            e.loadOp = color.loadOp;
            e.storeOp = StoreOp.store;
            e.clearR = cr; e.clearG = cg; e.clearB = cb; e.clearA = <f32>a;
            attachments.push(e);
        }
        pd.color = attachments;
        pd.depthView = this.destDepth;
        pd.depthLoadOp = loadDepth ? LoadOp.load : LoadOp.clear;
        pd.depthStoreOp = targets.keepDepth || this.destKeepsDepth ? StoreOp.store : StoreOp.discard;
        pd.depthClearValue = 1;
        const pass = canvas.beginRenderPass(pd);
        if (scissored && (clearColor || clearDepth || clearStencil)) {
            this.clearScissor(pass, clearColor, clearDepth, clearStencil, cr, cg, cb, <f32>a);
        }
        this.applyViewport(pass);
        return pass;
    }

    /// Clears the destination (inside the scissor when the scissor test is
    /// on), as three.js's renderer.clear.
    clear(color: bool = true, depth: bool = true, stencil: bool = true): void {
        if (this.broken || !this.beginDestination()) return;
        // What a clear is for: renders that keep (load) what it cleared.
        const targets = this.destTargets!;
        targets.keepColor = true;
        targets.keepDepth = true;
        const c = this._clearColor;
        const pass = this.openPass(color, depth, stencil, c.r, c.g, c.b, this.clearAlpha, "three clear");
        pass.finish();
    }

    clearColor(): void { this.clear(true, false, false); }
    clearDepth(): void { this.clear(false, true, false); }
    clearStencil(): void { this.clear(false, false, true); }

    private renderView(scene: Object3D, camera: Camera, beforeHooks: bool = true, retry: bool = true): void {
        const info = this.info.render;
        const timings = this.info.timings;
        const timed = timings.enabled;
        let t0 = timed ? clock() : 0;
        const frame = ++this.frameId;
        this.morphUsed = 0;
        this.morphFlushed = 0;
        if (!this.beginDestination()) return;
        const canvas = this.destCanvas!;
        const pw = this.passWidth, ph = this.passHeight;
        this.drainDisposed();
        this.sweepStale(frame);

        // Matrices.
        if (scene.matrixWorldAutoUpdate) scene.updateMatrixWorld();
        if (camera.parent == null && camera.matrixWorldAutoUpdate) camera.updateMatrixWorld();
        else camera.updateWorldMatrix(true, false);
        Mat4.multiply(this.viewProj.mat4, camera.projectionMatrix.mat4, camera.matrixWorldInverse.mat4);
        this.cameraPos.setFromMatrixPosition(camera.matrixWorld);
        this.invViewProj.copy(this.viewProj).invert();
        _frustum.setFromProjectionMatrix(this.viewProj);
        if (timed) { const t = clock(); timings.matrices += t - t0; t0 = t; }

        // Collect lights and draws (textures draw and upload here).
        this.overrideMaterial = scene instanceof Scene ? (scene as Scene).overrideMaterial : null;
        this.hasTransmission = false;
        this.collect(scene, camera, frame);
        if (timed) { const t = clock(); timings.collect += t - t0; t0 = t; }
        // onBeforeRender: before the pass. A hook that rendered (a mirror)
        // left the renderer's state at its render: collect again, without
        // calling the hooks twice.
        const drawn = this.drawnObjects;
        this.drawnObjects = this.hookLists.length > 0 ? this.hookLists.pop() : [];
        if (beforeHooks && drawn.length > 0) {
            // three.js calls a hook right before its object's draw, so an
            // object draws what its hook rendered for this camera, even when
            // a later hook's nested renders (a mirror seen in the water)
            // called it again. Here every hook runs first: an object whose
            // hook rendered for the outermost view is not called again by
            // the nested renders of that view's later hooks (they draw it
            // with what it rendered for the outermost camera).
            const top = this.hookDepth == 0;
            if (top) this.hookView++;
            const view = this.hookView;
            const serial = this.passSerial;
            const target = this.renderTarget;
            for (let i = 0; i < drawn.length; i++) {
                const o = unchecked(drawn[i]);
                if (o.noBeforeRender || (!top && this.hookedObjects.has(o.id) && this.hookedObjects.get(o.id) == view)) continue;
                const before = this.passSerial;
                this.hookDepth++;
                o.onBeforeRender(this, scene, camera, geometryOf(o), materialOf(o), null);
                this.hookDepth--;
                if (top && this.passSerial != before) this.hookedObjects.set(o.id, view);
            }
            this.renderTarget = target;
            if (this.passSerial != serial) {
                this.recycleHooks(drawn);
                this.renderView(scene, camera, false, retry);
                return;
            }
        }
        const background = this.prepareBackground(scene, frame, canvas);
        this.planShadows();
        this.prepareEnvironment(scene, frame, canvas);
        this.writeFrame(scene, camera);
        if (this.sortObjects) {
            this.opaque.sort(compareOpaque);
            this.transparent.sort(compareTransparent);
        }
        if (timed) { const t = clock(); timings.prepare += t - t0; t0 = t; }
        // Per-draw blocks; mip chains render here, before the main pass.
        this.writeDraws(this.opaque, frame, canvas);
        this.writeDraws(this.transparent, frame, canvas);
        this.joinMorphJobs();
        if (timed) { const t = clock(); timings.write += t - t0; t0 = t; }

        // Shadow maps: one depth pass per light view, before the main pass.
        if (!this.skipShadows) this.renderShadows(canvas, frame);

        // Transmission: the opaque scene into a mipmapped HDR target first.
        if (this.hasTransmission) this.renderTransmission(canvas, scene, background, pw, ph, frame);
        this.ensureFrameGroup();
        if (timed) { const t = clock(); timings.passes += t - t0; t0 = t; }

        // The pass.
        let r: f64 = this._clearColor.r, g: f64 = this._clearColor.g, b: f64 = this._clearColor.b;
        let a = this.clearAlpha;
        // A colour background clears even with autoClear off, as three.js's
        // WebGLBackground forces the clear (once for an ArrayCamera).
        let forceClear = false;
        if (scene instanceof Scene) {
            const bg = (scene as Scene).background;
            if (bg != null && bg instanceof Color) {
                const c = bg as Color;
                const k = (scene as Scene).backgroundIntensity;
                r = c.r * k; g = c.g * k; b = c.b * k; a = 1;
                forceClear = !this.arraySubView;
            }
        }
        const clear = this.autoClear || forceClear;
        const pass = this.openPass(clear && this.autoClearColor, clear && this.autoClearDepth,
            clear && this.autoClearStencil, r, g, b, a, "three");
        if (background) {
            pass.setPipeline(this.pipeline(KEY_BACKGROUND | (this.passSamples > 1 ? KEY_MSAA : 0)));
            pass.setBindGroup(0, this.bgGroup!);
            pass.draw(3);
        }
        this.drawList(pass, this.opaque);
        this.drawList(pass, this.transparent);
        pass.finish();
        const memory = this.info.memory;
        memory.geometries = this.geometries.count;
        memory.textures = this.textures.count;
        if (timed) {
            timings.draw += clock() - t0;
            timings.renders++;
        }
        if (drawn.length > 0) this.afterRenderHooks(drawn, scene, camera, retry);
        this.recycleHooks(drawn);
    }

    /// onAfterRender for the objects a view drew. A hook drawing over the
    /// view (loading its colour or depth) needs the pass to have kept them:
    /// a pass keeps them once a later pass loaded them, so the first time,
    /// the view renders again (once) with them kept.
    private afterRenderHooks(drawn: Array<Object3D>, scene: Object3D, camera: Camera, retry: bool): void {
        const targets = this.destTargets;
        const outerTargets = this.hookTargets;
        const outerLost = this.framebufferLost;
        const target = this.renderTarget;
        this.hookTargets = targets;
        this.framebufferLost = false;
        this.afterHooks++;
        for (let i = 0; i < drawn.length; i++) {
            const o = unchecked(drawn[i]);
            if (!o.noAfterRender) o.onAfterRender(this, scene, camera, geometryOf(o), materialOf(o), null);
        }
        this.afterHooks--;
        this.renderTarget = target;
        const lost = this.framebufferLost;
        this.hookTargets = outerTargets;
        this.framebufferLost = outerLost;
        if (lost && retry) this.renderView(scene, camera, false, false);
    }

    private recycleHooks(list: Array<Object3D>): void {
        list.length = 0;
        this.hookLists.push(list);
    }

    /// three.js's renderBufferDirect: draws `object` (a Mesh, at its
    /// matrixWorld) with `geometry` and `material` over the current render
    /// target, from `camera`, without clearing, culling or lights (`scene`
    /// and `group` are accepted for the signature). Each call is a pass:
    /// call it from draw(), e.g. in onAfterRender (Lensflare).
    renderBufferDirect(camera: Camera, scene: Object3D?, geometry: BufferGeometry, material: Material,
                       object: Object3D, group: GeometryGroup? = null): void {
        if (!(object instanceof Mesh)) {
            if (!this.warnedDirect) {
                this.context.log("three: renderBufferDirect draws meshes only");
                this.warnedDirect = true;
            }
            return;
        }
        const mesh = object as Mesh;
        let ds = this.directScene;
        if (ds == null) {
            ds = new Scene();
            ds.matrixWorldAutoUpdate = false;
            this.directScene = ds;
        }
        const geometry0 = mesh.geometry, material0 = mesh.material, materials0 = mesh.materials;
        mesh.geometry = geometry;
        mesh.material = material;
        mesh.materials = _noMaterials;
        ds.children.push(object);
        const autoClear = this.autoClear, directing = this.directing, noCull = this.noCull;
        this.autoClear = false;
        this.directing = true;
        this.noCull = true;
        this.render(ds, camera);
        this.autoClear = autoClear;
        this.directing = directing;
        this.noCull = noCull;
        ds.children.length = 0;
        mesh.geometry = geometry0;
        mesh.material = material0;
        mesh.materials = materials0;
    }

    /// Prepares everything `render(scene, camera)` would draw (pipelines,
    /// buffers, bind groups, texture uploads and mip chains) without
    /// drawing, so the first real render does not stall; returns the
    /// materials seen. Call it from `draw()`, as render. `targetScene` is
    /// accepted for three.js's signature (its lights are not merged).
    compile(scene: Object3D, camera: Camera, targetScene: Object3D? = null): Array<Material> {
        const materials: Array<Material> = [];
        if (this.broken || !this.beginDestination()) return materials;
        const canvas = this.destCanvas!;
        const frame = ++this.frameId;
        this.morphUsed = 0;
        this.morphFlushed = 0;
        if (scene.matrixWorldAutoUpdate) scene.updateMatrixWorld();
        if (camera.parent == null && camera.matrixWorldAutoUpdate) camera.updateMatrixWorld();
        else camera.updateWorldMatrix(true, false);
        Mat4.multiply(this.viewProj.mat4, camera.projectionMatrix.mat4, camera.matrixWorldInverse.mat4);
        this.cameraPos.setFromMatrixPosition(camera.matrixWorld);
        this.invViewProj.copy(this.viewProj).invert();
        // Everything, not only what the camera sees now.
        this.noCull = true;
        this.overrideMaterial = scene instanceof Scene ? (scene as Scene).overrideMaterial : null;
        this.hasTransmission = false;
        this.collect(scene, camera, frame);
        this.noCull = false;
        this.drawnObjects.length = 0;
        const background = this.prepareBackground(scene, frame, canvas);
        this.planShadows();
        this.prepareEnvironment(scene, frame, canvas);
        this.writeFrame(scene, camera);
        this.writeDraws(this.opaque, frame, canvas);
        this.writeDraws(this.transparent, frame, canvas);
        this.joinMorphJobs();
        this.ensureFrameGroup();
        if (background) this.pipeline(KEY_BACKGROUND | (this.passSamples > 1 ? KEY_MSAA : 0));
        const lists: StaticArray<Array<DrawItem>> = [this.opaque, this.transparent];
        for (let l = 0; l < 2; l++) {
            const list = lists[l];
            for (let i = 0; i < list.length; i++) {
                const item = list[i];
                if (item.custom == null) this.drawPipeline(item.pipelineKey, item.variant);
                if (materials.indexOf(item.material) < 0) materials.push(item.material);
            }
        }
        if (this.tileCount > 0) {
            const casters = this.casterItems;
            casters.length = 0;
            for (let i = 0; i < this.casterMeshes.length; i++) this.collectCaster(this.casterMeshes[i], frame, casters);
            for (let i = 0; i < casters.length; i++) this.shadowPipeline(casters[i].pipelineKey);
        }
        this.joinMorphJobs();
        return materials;
    }

    // ------------------------------------------------------------- copies

    /// Copies what was rendered into the current render target (or the
    /// canvas), from `position` (pixels from the bottom left), into
    /// `texture` (a FramebufferTexture, its size), as three.js. The texture
    /// takes the source's colour space (sRGB, premultiplied from the canvas
    /// or an UnsignedByteType target). Call it from draw(), after the
    /// render. Level 0 only.
    copyFramebufferToTexture(texture: Texture, position: Vector2? = null, level: i32 = 0): void {
        if (this.broken || level != 0) return;
        const rt = this.renderTarget;
        let src: GPUTextureView? = null;
        let sw: u32 = 0, sh: u32 = 0;
        let hdr = false;
        if (rt != null) {
            src = rt.texture.getView();
            sw = rt.width; sh = rt.height;
            hdr = rt.isHDR;
        } else {
            const c = this.canvas;
            if (c == null) return;
            src = c.view;
            sw = c.width; sh = c.height;
        }
        if (src == null) return;
        texture.colorSpace = hdr ? NoColorSpace : SRGBColorSpace;
        texture.premultiplyAlpha = true;
        const x = position != null ? position.x : 0;
        const y = position != null ? position.y : 0;
        this.copyRegion(src!, true, sw, sh, x, y, <f64>texture.width, <f64>texture.height, texture, 0, 0,
            hdr ? <u32>TextureFormat.rgba16float : <u32>TextureFormat.rgba8unorm);
    }

    /// Copies `srcRegion` of `srcTexture` (texels from the bottom left in
    /// uv terms; null: all of it) into `dstTexture` at `dstPosition`, as
    /// three.js. The destination can be any 2D texture: render target
    /// textures are written in place, others (images, data textures,
    /// FramebufferTextures) sample a GPU copy of themselves from then on,
    /// until their own content changes. Level 0 only.
    copyTextureToTexture(srcTexture: Texture, dstTexture: Texture, srcRegion: Box2? = null,
                         dstPosition: Vector2? = null, level: i32 = 0): void {
        if (this.broken || level != 0) return;
        if (!this.ensureSetup(this.ensureCanvas()!)) return;
        this.textures.update(srcTexture, this.frameId);
        const src = this.textures.baseView(srcTexture);
        if (src == null) return;
        let x: f64 = 0, y: f64 = 0, w = <f64>srcTexture.width, h = <f64>srcTexture.height;
        if (srcRegion != null) {
            x = srcRegion.min.x; y = srcRegion.min.y;
            w = srcRegion.max.x - srcRegion.min.x;
            h = srcRegion.max.y - srcRegion.min.y;
        }
        const dx = dstPosition != null ? dstPosition.x : 0;
        const dy = dstPosition != null ? dstPosition.y : 0;
        this.copyRegion(src!, srcTexture.flipY, srcTexture.width, srcTexture.height, x, y, w, h, dstTexture, dx, dy,
            srcTexture.isHDRSource ? <u32>TextureFormat.rgba16float : <u32>TextureFormat.rgba8unorm);
    }

    /// Copies the `w` x `h` texels at (sx, sy) of `src` to (dx, dy) of `dst`
    /// (positions from the bottom, in uv terms; rows flipped where the two
    /// store them in opposite orders).
    private copyRegion(src: GPUTextureView, srcFlip: bool, sw: u32, sh: u32, sx: f64, sy: f64, w: f64, h: f64,
                       dst: Texture, dx: f64, dy: f64, newFormat: u32): void {
        const host = this.ensureCanvas();
        if (host == null || !this.ensureUtil()) return;
        this.textures.update(dst, this.frameId);
        let view: GPUTextureView? = null;
        let format: u32 = <u32>TextureFormat.rgba8unorm;
        const dw = dst.width, dh = dst.height;
        if (dw == 0 || dh == 0) return;
        if (dst instanceof RenderTargetTexture) {
            const rtt = dst as RenderTargetTexture;
            const c = rtt.canvas;
            if (rtt.hdrView != null) {
                view = rtt.hdrView;
                format = rtt.gpuFormat;
            } else if (c != null) {
                view = c.view;
                format = c.format;
            }
        } else {
            let ct = this.textures.copyTarget(dst);
            if (ct == null) {
                // The first copy: a texture of its own, from its current content.
                const fmt = dst.isHDRSource ? <u32>TextureFormat.rgba16float
                    : dst instanceof FramebufferTexture ? newFormat : <u32>TextureFormat.rgba8unorm;
                const d = new GPUTextureDesc();
                d.width = dw; d.height = dh;
                d.format = <TextureFormat>fmt;
                d.renderTarget = true;
                const tex = new GPUTexture(d);
                const initial = this.textures.baseView(dst);
                const created = this.textures.setCopyTarget(dst, tex, tex.view(), fmt);
                if (initial != null) {
                    this.copyPass(host!, initial!, created.view, fmt, 0, 0, 0, 0, <f64>dw, <f64>dh, false);
                }
                ct = created;
            }
            view = ct!.view;
            format = ct!.format;
        }
        if (view == null) return;
        if (view === src) {
            this.context.log("three: copyTextureToTexture: a texture cannot be copied into itself");
            return;
        }
        // Clamp to both textures.
        if (sx < 0) { w += sx; dx -= sx; sx = 0; }
        if (sy < 0) { h += sy; dy -= sy; sy = 0; }
        if (dx < 0) { w += dx; sx -= dx; dx = 0; }
        if (dy < 0) { h += dy; sy -= dy; dy = 0; }
        w = Math.min(w, Math.min(<f64>sw - sx, <f64>dw - dx));
        h = Math.min(h, Math.min(<f64>sh - sy, <f64>dh - dy));
        if (w <= 0 || h <= 0) return;
        const dFlip = dst.flipY;
        const sTop = srcFlip ? <f64>sh - (sy + h) : sy;
        const dTop = dFlip ? <f64>dh - (dy + h) : dy;
        this.copyPass(host!, src, view!, format, sx, sTop, dx, dTop, w, h, srcFlip != dFlip);
        this.textures.invalidate(dst);
    }

    /// One copy pass: the `w` x `h` rectangle at (dx, dy) of `into` (rows
    /// top first) from (sx, sy) of `from`.
    private copyPass(host: GPUCanvas, from: GPUTextureView, into: GPUTextureView, format: u32, sx: f64, sy: f64,
                     dx: f64, dy: f64, w: f64, h: f64, flipRows: bool): void {
        let pipeline: GPUPipeline;
        if (this.copyPipelines.has(format)) pipeline = this.copyPipelines.get(format);
        else {
            const target = new GPUColorTargetDesc();
            target.format = <TextureFormat>format;
            const d = new GPUPipelineDesc();
            d.vertexModule = this.utilModule;
            d.vertexEntryPoint = "vs_fill";
            d.fragmentModule = this.utilModule;
            d.fragmentEntryPoint = "fs_copy";
            d.colorTargets = [target];
            pipeline = new GPUPipeline(d);
            this.copyPipelines.set(format, pipeline);
        }
        let ubo = this.copyUbo;
        if (ubo == null) {
            ubo = new GPUBuffer(BufferUsage.uniform, 32);
            this.copyUbo = ubo;
        }
        this.passSerial++;
        const f = this.copyStaging;
        f[0] = <f32>sx; f[1] = <f32>sy; f[2] = <f32>dx; f[3] = <f32>dy;
        f[4] = flipRows ? 1 : 0; f[5] = <f32>h; f[6] = 0; f[7] = 0;
        ubo.update(0, f.buffer);
        const group = new GPUBindGroup(pipeline.getBindGroupLayout(0), [new GPUBindGroupUBO(0, ubo)],
            [new GPUBindGroupTexture(1, from)]);
        const color = new GPUColorAttachment();
        color.view = into;
        color.loadOp = LoadOp.load;
        color.storeOp = StoreOp.store;
        const pd = new GPUPassDesc();
        pd.label = "three copy";
        pd.color = [color];
        const pass = host.beginRenderPass(pd);
        pass.setViewport(<f32>dx, <f32>dy, <f32>w, <f32>h, 0, 1);
        pass.setScissor(<u32>dx, <u32>dy, <u32>w, <u32>h);
        pass.setPipeline(pipeline);
        pass.setBindGroup(0, group);
        pass.draw(3);
        pass.finish();
    }

    /// Composites the last render into `renderer` at the origin, sized
    /// `setSize` points (the canvas is premultiplied).
    present(renderer: Renderer): void {
        const canvas = this.canvas;
        if (canvas == null || canvas.width == 0) return;
        const s = <f32>(1 / this.pixelRatio);
        renderer.save();
        renderer.transform(Mat2D(s, 0, 0, s, 0, 0));
        renderer.drawImage(canvas.image, ImageSampler(ImageWrap.clamp, ImageWrap.clamp, ImageFilter.bilinear),
            BlendMode.srcOver, 1);
        renderer.restore();
    }

    /// Frees every GPU resource the renderer made.
    dispose(): void {
        this.geometries.disposeAll();
        this.states.clear();
        const arena = this.arena;
        if (arena != null) arena.release();
        this.arena = null;
        this.arenaGroup = null;
        this.arenaCapacity = 0;
        this.slotCount = 0;
        this.dirtyLo = 0x7fffffff;
        this.dirtyHi = -1;
        this.materialEntries.clear();
        this.pipelines.clear();
        this.mainTargets.release();
        const rts = this.rtTargets.values();
        for (let i = 0; i < rts.length; i++) rts[i].release();
        this.rtTargets.clear();
        const canvas = this.canvas;
        if (canvas != null) canvas.release();
        this.canvas = null;
    }

    // ------------------------------------------------------------------ setup

    private fail(why: string): bool {
        this.context.log("three: GPURenderer disabled: " + why);
        this.broken = true;
        return false;
    }

    private ensureCanvas(): GPUCanvas? {
        let c = this.canvas;
        if (c == null) {
            c = this.context.gpuCanvas(0, 0);
            if (c == null) {
                this.fail("no GPU canvas on this host");
                return null;
            }
            this.canvas = c;
        }
        return c;
    }

    private ensureSetup(canvas: GPUCanvas): bool {
        if (this.module == null) {
            let module: GPUShaderModule? = null;
            for (let i = 0; i < SHADER_NAMES.length && module == null; i++) module = this.context.shader(SHADER_NAMES[i]);
            let bgModule: GPUShaderModule? = null;
            for (let i = 0; i < BACKGROUND_SHADER_NAMES.length && bgModule == null; i++) {
                bgModule = this.context.shader(BACKGROUND_SHADER_NAMES[i]);
            }
            if (bgModule == null) return this.fail("shader asset 'three/shaders/three_background.wgsl' not found");
            this.bgModule = bgModule;
            this.backgroundLayout = GPUBindGroupLayout.fromShader(bgModule!, 0);
            if (module == null) return this.fail("shader asset 'three/shaders/three.wgsl' not found");
            this.module = module;
            const g0 = GPUBindGroupLayout.fromShader(module, 0);
            const g1 = GPUBindGroupLayout.fromShader(module, 1, [0, 7]);
            const g2 = GPUBindGroupLayout.fromShader(module, 2);
            const g3 = GPUBindGroupLayout.fromShader(module, 3);
            if (g0 == null || g1 == null || g2 == null || g3 == null) return this.fail("bind group layouts rejected");
            this.frameLayout = g0;
            this.objLayout = g1;
            this.matLayout = g2;
            this.samplerLayout = g3;

            // Normals and tangents interleaved at slot 1.
            const normalTangent = new GPUVertexBufferLayout();
            normalTangent.stride = 28;
            normalTangent.attributes = [
                new GPUVertexAttribute(VertexFormat.float3, 1, 0),
                new GPUVertexAttribute(VertexFormat.float4, 12, 12),
            ];
            // Instances: matrices at slot 4 (InstancedMesh.instanceMatrix as
            // is), colours at slot 5 (instanceColor, rgb).
            const instance = new GPUVertexBufferLayout();
            instance.stride = INSTANCE_MATRIX_STRIDE;
            instance.stepMode = VertexStepMode.instance;
            instance.attributes = [
                new GPUVertexAttribute(VertexFormat.float4, 4, 0),
                new GPUVertexAttribute(VertexFormat.float4, 5, 16),
                new GPUVertexAttribute(VertexFormat.float4, 6, 32),
                new GPUVertexAttribute(VertexFormat.float4, 7, 48),
            ];
            const instanceColor = vertexLayout(INSTANCE_COLOR_STRIDE, VertexFormat.float3, 8);
            instanceColor.stepMode = VertexStepMode.instance;
            this.vertexBuffers = [
                vertexLayout(12, VertexFormat.float3, 0),
                normalTangent,
                vertexLayout(8, VertexFormat.float2, 2),
                vertexLayout(16, VertexFormat.float4, 3),
                instance,
                instanceColor,
                vertexLayout(8, VertexFormat.float2, 11),   // uv1
            ];
            const pointPosition = vertexLayout(12, VertexFormat.float3, 0);
            pointPosition.stepMode = VertexStepMode.instance;
            const pointColor = vertexLayout(16, VertexFormat.float4, 3);
            pointColor.stepMode = VertexStepMode.instance;
            this.pointBuffers = [pointPosition, pointColor];
            const skin = new GPUVertexBufferLayout();
            skin.stride = 32;
            skin.attributes = [
                new GPUVertexAttribute(VertexFormat.float4, 9, 0),
                new GPUVertexAttribute(VertexFormat.float4, 10, 16),
            ];
            this.skinBuffers = this.vertexBuffers.concat([skin]);
            // An InstancedMesh's morphTexture row: 0, 1, 2 ... per instance
            // (three.wgsl's MorphRowIn; WGSL's instance_index is not used,
            // see vs_morph_instanced). InstancedMesh is never skinned, so
            // slot 7 is free.
            const morphRow = vertexLayout(MORPH_ROW_STRIDE, VertexFormat.float1, 13);
            morphRow.stepMode = VertexStepMode.instance;
            this.morphRowBuffers = this.vertexBuffers.concat([morphRow]);
            this.dummyBones = new GPUBuffer(BufferUsage.uniform, <u32>BONES_BYTES);
            this.dummyMorph = new GPUBuffer(BufferUsage.uniform, <u32>MORPH_BYTES, new ArrayBuffer(MORPH_BYTES), true);
            const sd = new GPUTextureDesc();
            sd.width = 1; sd.height = 1;
            sd.format = TextureFormat.depth32float;
            sd.textureType = TextureType.array2D;
            sd.renderTarget = true;
            const dummyShadow = new GPUTexture(sd);
            const dv = new GPUTextureViewDesc();
            dv.dimension = TextureViewDimension.array2D;
            dv.aspect = TextureAspect.depthOnly;
            this.dummyShadowView = dummyShadow.view(dv);
            const features = this.context.features();
            this.samples = this.antialias && features.maxSamples >= 4 ? 4 : 1;
            this.maxAnisotropy = features.anisotropicFiltering ? 16 : 1;

            const ubo = new GPUBuffer(BufferUsage.uniform, <u32>FRAME_BYTES);
            this.frameUbo = ubo;
            // The RectAreaLight LTC tables, once.
            const ltc = new Uint32Array(LTC_TABLE.length);
            for (let i = 0; i < LTC_TABLE.length; i++) ltc[i] = LTC_TABLE[i];
            this.ltcUbo = new GPUBuffer(BufferUsage.uniform, <u32>ltc.byteLength, ltc.buffer, true);

            const wd = new GPUTextureDesc();
            wd.width = 1; wd.height = 1;
            wd.format = TextureFormat.rgba8unorm;
            const white = new GPUTexture(wd);
            const px = new Uint8Array(4);
            px.fill(255);
            uploadRegion.width = 1; uploadRegion.height = 1;
            white.upload(uploadRegion, px.buffer);
            this.white = white.view();

            // One identity instance (white) for every non-instanced draw.
            const id = new Float32Array(16);
            id[0] = 1; id[5] = 1; id[10] = 1; id[15] = 1;
            this.identityInstance = new GPUBuffer(BufferUsage.vertex, <u32>INSTANCE_MATRIX_STRIDE, id.buffer, true);
            const white3 = new Float32Array(3);
            white3.fill(1);
            this.identityColor = new GPUBuffer(BufferUsage.vertex, <u32>INSTANCE_COLOR_STRIDE, white3.buffer, true);
        }
        return true;
    }

    private ensureTargets(t: PassTargets, format: u32, w: u32, h: u32, samples: u32, ownDepth: bool = true): void {
        if ((t.depthView != null) == ownDepth && t.width == w && t.height == h && t.format == format
                && t.samples == samples) return;
        t.release();
        if (ownDepth) {
            const dd = new GPUTextureDesc();
            dd.width = w; dd.height = h;
            dd.format = DEPTH_FORMAT;
            dd.renderTarget = true;
            dd.sampleCount = samples;
            const depth = new GPUTexture(dd);
            t.depthTex = depth;
            t.depthView = depth.view();
        }
        if (samples > 1) {
            const md = new GPUTextureDesc();
            md.width = w; md.height = h;
            md.format = <TextureFormat>format;
            md.renderTarget = true;
            md.sampleCount = samples;
            const msaa = new GPUTexture(md);
            t.msaaTex = msaa;
            t.msaaView = msaa.view();
        }
        t.width = w;
        t.height = h;
        t.format = format;
        t.samples = samples;
    }

    private pipeline(key: i32): GPUPipeline {
        const cacheKey = (<i64>this.pipelineCount << 56) | (<i64>this.pipelineFormat << 32) | <i64><u32>key;
        if (this.pipelines.has(cacheKey)) return this.pipelines.get(cacheKey);
        const p = this.buildPipeline(key, this.module!);
        this.pipelines.set(cacheKey, p);
        return p;
    }

    /// A pipeline of `module` (three.wgsl or one of its baked variants, which
    /// share its bind group layouts) for a pipeline key.
    private buildPipeline(key: i32, module: GPUShaderModule): GPUPipeline {
        const target = new GPUColorTargetDesc();
        target.format = <TextureFormat>this.pipelineFormat;
        const ds = new GPUDepthStencilDesc();
        ds.format = DEPTH_FORMAT;
        const d = new GPUPipelineDesc();
        d.vertexModule = module;
        d.fragmentModule = module;
        d.sampleCount = (key & KEY_MSAA) != 0 ? this.samples : 1;
        d.depthStencil = ds;
        if ((key & KEY_BACKGROUND) != 0) {
            d.vertexModule = this.bgModule;
            d.fragmentModule = this.bgModule;
            d.vertexEntryPoint = "vs_background";
            d.fragmentEntryPoint = "fs_background";
            ds.compare = CompareFunction.always;
            ds.write = false;
            d.colorTargets = this.colorTargets(target, false);
            d.bindGroupLayouts = [this.backgroundLayout];
        } else {
            const cull = key & KEY_CULL_MASK;
            const blending = (key >> KEY_BLEND_SHIFT) & 7;
            const blend = blendState(blending);
            if (blend != null) target.blend = blend;
            if ((key & KEY_COLOR_WRITE) == 0) target.writeMask = <u32>ColorWriteMask.none;
            ds.compare = (key & KEY_DEPTH_TEST) != 0 ? CompareFunction.lessEqual : CompareFunction.always;
            this.applyPassState(ds, key);
            ds.write = (key & KEY_DEPTH_WRITE) != 0;
            const prim = (key >> KEY_PRIM_SHIFT) & 3;
            d.fragmentEntryPoint = (key & KEY_LOG_DEPTH) != 0 ? "fs_main_logdepth" : "fs_main";
            d.colorTargets = this.colorTargets(target, false);
            d.bindGroupLayouts = [this.frameLayout, this.objLayout, this.matLayout, this.samplerLayout];
            d.cullMode = cull == 0 ? CullMode.back : cull == 2 ? CullMode.front : CullMode.none;
            // three.js flips the front face of mirrored (negative determinant)
            // objects, so front_facing stays true on their outside.
            d.winding = (key & KEY_MIRRORED) != 0 ? FaceWinding.clockwise : FaceWinding.counterClockwise;
            d.topology = PrimitiveTopology.triangleList;
            if (prim == PRIM_POINTS) {
                d.vertexEntryPoint = "vs_points";
                d.vertexBuffers = this.pointBuffers;
                d.cullMode = CullMode.none;
            } else if (prim == PRIM_SPRITE) {
                d.vertexEntryPoint = "vs_sprite";
                d.cullMode = CullMode.none;
            } else if ((key & KEY_SKINNED) != 0) {
                d.vertexEntryPoint = (key & KEY_DISPLACED) != 0 ? "vs_skinned_displaced" : "vs_skinned";
                d.vertexBuffers = this.skinBuffers;
            } else {
                d.vertexEntryPoint = vertexEntry(key);
                d.vertexBuffers = (key & KEY_MORPH_INSTANCED) != 0 ? this.morphRowBuffers : this.vertexBuffers;
                if (prim == PRIM_LINES) {
                    d.topology = PrimitiveTopology.lineList;
                    d.cullMode = CullMode.none;
                }
            }
        }
        return new GPUPipeline(d);
    }

    /// A 1 x 1 depth view standing in for a DepthTexture not rendered yet.
    private dummyDepth(): GPUTextureView {
        let v = this.dummyDepthView;
        if (v == null) {
            const d = new GPUTextureDesc();
            d.width = 1; d.height = 1;
            d.format = DEPTH_FORMAT;
            d.renderTarget = true;
            const vd = new GPUTextureViewDesc();
            vd.aspect = TextureAspect.depthOnly;
            v = new GPUTexture(d).view(vd);
            this.dummyDepthView = v;
        }
        return v!;
    }

    /// `target` plus one target per extra attachment of a multiple render
    /// target: written with `target`'s blending when `written` (the shader
    /// outputs every location), else masked (built-in materials write
    /// location 0 only, and WebGPU wants no writes where nothing is output).
    private colorTargets(target: GPUColorTargetDesc, written: bool): Array<GPUColorTargetDesc> {
        const out: Array<GPUColorTargetDesc> = [target];
        for (let i = 1; i < this.pipelineCount; i++) {
            const t = new GPUColorTargetDesc();
            t.format = target.format;
            if (written) {
                t.blend = target.blend;
                t.writeMask = target.writeMask;
            } else {
                t.writeMask = <u32>ColorWriteMask.none;
            }
            out.push(t);
        }
        return out;
    }

    /// The pipeline of a ShaderMaterial draw (null when its shader is
    /// missing: the draw is skipped, with one log line).
    /// customPipeline, remembered on the material's entry while the key,
    /// target and shader stay the same (no key string a frame).
    private customPipelineOf(entry: MaterialEntry, material: ShaderMaterial, key: i32): CustomPipeline? {
        const cached = entry.custom;
        if (cached != null && entry.customKey == key && entry.customFormat == this.pipelineFormat
                && entry.customCount == this.pipelineCount && entry.customShader == material.shader
                && entry.customVertex == material.vertexEntryPoint && entry.customFragment == material.fragmentEntryPoint
                && entry.customLights == material.lights) {
            return cached;
        }
        const cp = this.customPipeline(material, key);
        entry.custom = cp;
        entry.customKey = key;
        entry.customFormat = this.pipelineFormat;
        entry.customCount = this.pipelineCount;
        entry.customShader = material.shader;
        entry.customVertex = material.vertexEntryPoint;
        entry.customFragment = material.fragmentEntryPoint;
        entry.customLights = material.lights;
        return cp;
    }

    private customPipeline(material: ShaderMaterial, key: i32): CustomPipeline? {
        const name = material.shader + "|" + material.vertexEntryPoint + "|" + material.fragmentEntryPoint + "|"
            + key.toString() + "|" + this.pipelineFormat.toString() + "|" + this.pipelineCount.toString()
            + (material.lights ? "|lights" : "");
        if (this.customPipelines.has(name)) return this.customPipelines.get(name);
        let module: GPUShaderModule? = null;
        if (this.customModules.has(material.shader)) module = this.customModules.get(material.shader);
        else {
            module = this.context.shader(material.shader);
            const slash = material.shader.lastIndexOf("/");
            if (module == null && slash >= 0) module = this.context.shader(material.shader.substring(slash + 1));
            if (module != null) this.customModules.set(material.shader, module);
        }
        if (module == null) {
            if (!this.warnedShaders.has(material.shader)) {
                this.context.log("three: ShaderMaterial: no shader asset named '" + material.shader + "'");
                this.warnedShaders.set(material.shader, true);
            }
            return null;
        }
        const g0 = GPUBindGroupLayout.fromShader(module, 0);
        const g1 = GPUBindGroupLayout.fromShader(module, 1, [0]);
        if (g0 == null || g1 == null) return null;
        const hasUniforms = material.uniforms.size > 0;
        const g2 = hasUniforms ? GPUBindGroupLayout.fromShader(module, 2) : null;
        const target = new GPUColorTargetDesc();
        target.format = <TextureFormat>this.pipelineFormat;
        const ds = new GPUDepthStencilDesc();
        ds.format = DEPTH_FORMAT;
        const d = new GPUPipelineDesc();
        d.vertexModule = module;
        d.fragmentModule = module;
        d.vertexEntryPoint = material.vertexEntryPoint;
        d.fragmentEntryPoint = material.fragmentEntryPoint;
        d.sampleCount = (key & KEY_MSAA) != 0 ? this.samples : 1;
        d.depthStencil = ds;
        this.applyState(d, target, ds, key);
        d.vertexBuffers = this.vertexBuffers;
        d.bindGroupLayouts = g2 != null ? [g0, g1, g2] : [g0, g1];
        const p = new GPUPipeline(d);
        // `lights: true` binds every frame texture (placeholders here; the
        // real ones per render, customFullGroup).
        const frameGroup = material.lights
            ? this.makeFrameGroup(g0, this.frameUbo!, this.white!, this.dummyShadowView!, this.white!)
            : new GPUBindGroup(g0, [new GPUBindGroupUBO(0, this.frameUbo!)]);
        const cp = new CustomPipeline(p, g0, g1, frameGroup);
        cp.lights = material.lights;
        cp.layout2 = g2;
        this.customPipelines.set(name, cp);
        return cp;
    }

    /// The interned depthFunc/stencil/polygonOffset state of a material
    /// (0: three.js's defaults).
    private stateIndex(m: Material): i32 {
        if (m.depthFunc == LessEqualDepth && !m.stencilWrite && m.polygonOffset == false) return 0;
        const key = m.depthFunc.toString() + "|" + (m.stencilWrite ? "s" : "-") + m.stencilFunc.toString() + ","
            + m.stencilFuncMask.toString() + "," + m.stencilWriteMask.toString() + "," + m.stencilFail.toString() + ","
            + m.stencilZFail.toString() + "," + m.stencilZPass.toString() + "|"
            + (m.polygonOffset ? m.polygonOffsetFactor.toString() + "," + m.polygonOffsetUnits.toString() : "");
        if (this.passStateKeys.has(key)) return this.passStateKeys.get(key);
        const index = this.passStates.length;
        if (index > KEY_STATE_MASK) return 0;
        const st = new PassState();
        st.depthFunc = m.depthFunc;
        st.stencil = m.stencilWrite;
        st.stencilFunc = m.stencilFunc;
        st.stencilFuncMask = m.stencilFuncMask;
        st.stencilWriteMask = m.stencilWriteMask;
        st.stencilFail = m.stencilFail;
        st.stencilZFail = m.stencilZFail;
        st.stencilZPass = m.stencilZPass;
        if (m.polygonOffset) {
            st.polygonOffsetFactor = m.polygonOffsetFactor;
            st.polygonOffsetUnits = m.polygonOffsetUnits;
        }
        this.passStates.push(st);
        this.passStateKeys.set(key, index);
        return index;
    }

    /// Applies a key's interned state to a pipeline's depth-stencil.
    private applyPassState(ds: GPUDepthStencilDesc, key: i32): void {
        const index = (key >> KEY_STATE_SHIFT) & KEY_STATE_MASK;
        if (index == 0) return;
        const st = this.passStates[index];
        if ((key & KEY_DEPTH_TEST) != 0) ds.compare = depthCompare(st.depthFunc);
        if (st.stencil) {
            const faces: StaticArray<GPUStencilFaceState> = [ds.stencilFront, ds.stencilBack];
            for (let i = 0; i < 2; i++) {
                const f = faces[i];
                f.compare = stencilCompare(st.stencilFunc);
                f.failOp = stencilOp(st.stencilFail);
                f.depthFailOp = stencilOp(st.stencilZFail);
                f.passOp = stencilOp(st.stencilZPass);
            }
            ds.stencilReadMask = <u32>st.stencilFuncMask;
            ds.stencilWriteMask = <u32>st.stencilWriteMask;
        }
        if (st.polygonOffsetFactor != 0 || st.polygonOffsetUnits != 0) {
            ds.depthBias = <i32>st.polygonOffsetUnits;
            ds.depthBiasSlopeScale = <f32>st.polygonOffsetFactor;
        }
    }

    /// Blending, write mask, depth and culling from a pipeline key.
    private applyState(d: GPUPipelineDesc, target: GPUColorTargetDesc, ds: GPUDepthStencilDesc, key: i32): void {
        const cull = key & KEY_CULL_MASK;
        const blend = blendState((key >> KEY_BLEND_SHIFT) & 7);
        if (blend != null) target.blend = blend;
        if ((key & KEY_COLOR_WRITE) == 0) target.writeMask = <u32>ColorWriteMask.none;
        ds.compare = (key & KEY_DEPTH_TEST) != 0 ? CompareFunction.lessEqual : CompareFunction.always;
        ds.write = (key & KEY_DEPTH_WRITE) != 0;
        this.applyPassState(ds, key);
        d.colorTargets = this.colorTargets(target, true);
        d.cullMode = cull == 0 ? CullMode.back : cull == 2 ? CullMode.front : CullMode.none;
        d.winding = (key & KEY_MIRRORED) != 0 ? FaceWinding.clockwise : FaceWinding.counterClockwise;
        d.topology = PrimitiveTopology.triangleList;
    }

    /// Packs a ShaderMaterial's uniforms (WGSL alignment) and binds its
    /// textures; once a frame per material.
    private prepareCustomUniforms(material: ShaderMaterial, cp: CustomPipeline, frame: i32, canvas: GPUCanvas): CustomUniforms? {
        const layout = cp.layout2;
        if (layout == null) return null;
        let cu: CustomUniforms;
        if (this.customUniforms.has(material.id)) cu = this.customUniforms.get(material.id);
        else {
            cu = new CustomUniforms();
            this.customUniforms.set(material.id, cu);
        }
        if (cu.frame == frame) return cu;
        cu.frame = frame;
        const names = material.uniforms.keys();
        let size = 0;
        for (let i = 0; i < names.length; i++) {
            const u = material.uniforms.get(names[i]);
            const s = u.size();
            if (s == 0) continue;
            const a = u.align();
            size = (size + a - 1) / a * a + s;
        }
        size = max<i32>(16, (size + 15) & ~15);
        if (cu.staging.byteLength != size) {
            cu.staging = new ArrayBuffer(size);
            cu.f32 = Float32Array.wrap(cu.staging);
        }
        const f = cu.f32;
        let offset = 0;
        const views = this.customViews;
        views.length = 0;
        let firstTexture: Texture? = null;
        for (let i = 0; i < names.length; i++) {
            const u = material.uniforms.get(names[i]);
            const t = u.texture();
            if (t != null) {
                this.textures.update(t, frame);
                const v = this.textures.view(t, canvas);
                views.push(v != null ? v! : t instanceof DepthTexture ? this.dummyDepth() : this.white!);
                if (firstTexture == null) firstTexture = t;
                continue;
            }
            const s = u.size();
            if (s == 0) continue;
            const a = u.align();
            offset = (offset + a - 1) / a * a;
            u.write(f, offset);
            offset += s;
        }
        const hasValues = offset > 0;
        if (hasValues) {
            let buffer = cu.buffer;
            if (buffer == null || buffer.size != <u32>size) {
                if (buffer != null) buffer.release();
                const oldGroup = cu.group;
                if (oldGroup != null) oldGroup.release();
                buffer = new GPUBuffer(BufferUsage.uniform, <u32>size);
                cu.buffer = buffer;
                cu.group = null;
            }
            buffer.update(0, cu.staging);
        }
        let changed = cu.group == null || cu.views.length != views.length;
        for (let i = 0; i < views.length && !changed; i++) changed = cu.views[i] !== views[i];
        if (changed) {
            const ubos: Array<GPUBindGroupUBO> = [];
            if (hasValues) ubos.push(new GPUBindGroupUBO(0, cu.buffer!));
            const textures: Array<GPUBindGroupTexture> = [];
            for (let i = 0; i < views.length; i++) textures.push(new GPUBindGroupTexture(<u32>(i + 1), views[i]));
            const samplers: Array<GPUBindGroupSampler> = [];
            if (views.length > 0) {
                const t = firstTexture!;
                samplers.push(new GPUBindGroupSampler(<u32>(views.length + 1), this.sampler(t, this.textures.levels(t) > 1)));
            }
            const oldGroup = cu.group;
            if (oldGroup != null) oldGroup.release();
            cu.group = new GPUBindGroup(layout, ubos, textures, samplers);
            cu.views = views.slice();
        }
        return cu;
    }

    private sampler(t: Texture, mipmapped: bool): GPUSampler {
        const linearMin = !isNearest(t.minFilter);
        const linearMag = !isNearest(t.magFilter);
        const mipLinear = t.minFilter == LinearMipmapLinearFilter || t.minFilter == NearestMipmapLinearFilter;
        let aniso = min<i32>(max<i32>(1, t.anisotropy), this.maxAnisotropy);
        if (!(linearMin && linearMag && (mipLinear || !mipmapped))) aniso = 1;
        let a: u32 = 1;
        while (a * 2 <= <u32>aniso) a *= 2;
        const key = (t.wrapS - 1000) | ((t.wrapT - 1000) << 2) | (linearMag ? 16 : 0) | (linearMin ? 32 : 0)
            | (mipLinear ? 64 : 0) | (mipmapped ? 128 : 0) | (<i32>a << 8);
        if (this.samplers.has(key)) return this.samplers.get(key);
        const s = new GPUSampler(
            linearMin ? Filter.linear : Filter.nearest,
            linearMag ? Filter.linear : Filter.nearest,
            mipLinear ? Filter.linear : Filter.nearest,
            wrapOf(t.wrapS), wrapOf(t.wrapT),
            <CompareFunction>0xFFFFFFFF, a, 0, mipmapped ? 32 : 0);
        this.samplers.set(key, s);
        return s;
    }

    private defaultSampler(): GPUSampler {
        const key = -1;
        if (this.samplers.has(key)) return this.samplers.get(key);
        const s = new GPUSampler(Filter.linear, Filter.linear, Filter.nearest, WrapMode.clampToEdge, WrapMode.clampToEdge);
        this.samplers.set(key, s);
        return s;
    }

    /// Evicts draw states and material entries unused for STALE_FRAMES render
    /// calls (render calls, not display frames: each pass counts).
    private sweepStale(frame: i32): void {
        if (frame - this.lastSweep < 600) return;
        this.lastSweep = frame;
        const STALE_FRAMES = 4000;
        const keys = this.states.keys();
        for (let i = 0; i < keys.length; i++) {
            const st = this.states.get(keys[i]);
            if (st.frame < 0 || frame - st.frame < STALE_FRAMES) continue;
            if (st.slot >= 0) this.freeSlots.push(st.slot);
            const og = st.objGroup;
            if (og != null && og !== this.arenaGroup) og.release();
            st.objGroup = null;
            st.entry = null;
            this.states.delete(keys[i]);
        }
        const ids = this.materialEntries.keys();
        for (let i = 0; i < ids.length; i++) {
            const entry = this.materialEntries.get(ids[i]);
            let latest = -1;
            for (let v = 0; v < 8; v++) {
                const b = unchecked(entry.blocks[v]);
                if (b != null && b.frame > latest) latest = b.frame;
            }
            if (latest < 0 || frame - latest < STALE_FRAMES) continue;
            for (let v = 0; v < 8; v++) {
                const b = unchecked(entry.blocks[v]);
                if (b == null) continue;
                const mg = b.matGroup;
                if (mg != null) mg.release();
                const sg = b.samplerGroup;
                if (sg != null) sg.release();
                b.matGroup = null;
                b.samplerGroup = null;
                unchecked(entry.blocks[v] = null);
            }
            this.materialEntries.delete(ids[i]);
        }
        // Live states must not keep an evicted entry.
        const live = this.states.values();
        for (let i = 0; i < live.length; i++) {
            const e = live[i].entry;
            if (e != null && !this.materialEntries.has(e.material.id)) live[i].entry = null;
        }
    }

    private drainDisposed(): void {
        for (let i = 0; i < disposedGeometries.length; i++) {
            const id = disposedGeometries[i];
            this.geometries.dispose(id);
            if (this.morphTargets.has(id)) {
                const mt = this.morphTargets.get(id);
                const t = mt.texture;
                if (t != null) t.release();
                const job = mt.job;
                if (job != null) job.release();
                this.morphTargets.delete(id);
            }
        }
        disposedGeometries.length = 0;
        for (let i = 0; i < disposedTextures.length; i++) this.textures.dispose(disposedTextures[i]);
        disposedTextures.length = 0;
    }

    // ---------------------------------------------------------------- collect

    /// A draw item from the pool (items live until the next collect).
    private newItem(object: Object3D, material: Material, g: GeometryGPU?, state: DrawState, instances: GPUBuffer,
                    colors: GPUBuffer): DrawItem {
        const pool = this.itemPool;
        const i = this.itemsUsed++;
        if (i < pool.length) {
            const item = unchecked(pool[i]);
            item.reset(object, material, g, state, instances, colors);
            return item;
        }
        const item = new DrawItem(object, material, g, state, instances, colors);
        pool.push(item);
        return item;
    }

    /// The draw state of `object`'s part `part` (63: its shadow stand-in).
    private stateOf(key: i32): DrawState {
        const states = this.states;
        if (states.has(key)) return states.get(key);
        const state = new DrawState();
        states.set(key, state);
        return state;
    }

    private collect(scene: Object3D, camera: Camera, frame: i32): void {
        this.opaque.length = 0;
        this.transparent.length = 0;
        this.lights.length = 0;
        this.casterMeshes.length = 0;
        this.itemsUsed = 0;
        const renderables = this.renderables;
        renderables.length = 0;
        let tested = 0;
        const stack = this.stack;
        stack.length = 0;
        stack.push(scene);
        while (stack.length > 0) {
            const o = stack.pop();
            if (!o.visible) continue;
            if (o.layers.test(camera.layers)) {
                if (o instanceof LOD && (o as LOD).autoUpdate) (o as LOD).update(camera);
                if (o.castShadow && o instanceof Mesh && this.shadowMap.enabled) this.casterMeshes.push(o as Mesh);
                if (o instanceof Light) {
                    this.lights.push(o as Light);
                } else if (o instanceof Mesh || o instanceof Line || o instanceof Points || o instanceof Sprite) {
                    renderables.push(o);
                    if (o.frustumCulled && !this.noCull) tested++;
                }
            }
            const children = o.children;
            for (let i = children.length - 1; i >= 0; i--) stack.push(children[i]);
        }
        // Frustum culling: on every thread for big scenes (a parallel call),
        // else here; then the draws, in scene order.
        const n = renderables.length;
        const parallel = this.parallelCulling && cullParts(tested) > 1;
        if (parallel) {
            if (this.cullTest.length < n) this.cullTest = new Uint8Array(max<i32>(n, this.cullTest.length * 2));
            if (this.cullOut.length < n) this.cullOut = new SharedArray<u8>(max<i32>(n, this.cullOut.length * 2));
            const test = this.cullTest;
            for (let i = 0; i < n; i++) {
                const o = unchecked(renderables[i]);
                const t = o.frustumCulled && !this.noCull;
                unchecked(test[i] = t ? 1 : 0);
                if (t) prepareBounds(o);
            }
            const planes = this.cullPlanes;
            for (let p = 0; p < 6; p++) {
                const plane = _frustum.planes[p];
                planes[p * 4] = plane.normal.x; planes[p * 4 + 1] = plane.normal.y; planes[p * 4 + 2] = plane.normal.z;
                planes[p * 4 + 3] = plane.constant;
            }
            Parallel.run(cullObjects, renderables, test, planes, this.cullOut);
        }
        const out = this.cullOut;
        for (let i = 0; i < n; i++) {
            const o = unchecked(renderables[i]);
            const keep = parallel ? out[i] != 0 : !o.frustumCulled || this.noCull || this.inFrustum(o);
            if (keep) {
                this.collectObject(o, frame);
                if (!this.directing && !(o.noBeforeRender && o.noAfterRender)) this.drawnObjects.push(o);
            } else this.info.render.culled++;
        }
        renderables.length = 0;
    }

    private inFrustum(o: Object3D): bool {
        if (o instanceof Sprite) return intersectsSprite(o as Sprite);
        if (o instanceof SkinnedMesh) {
            // Posed bounds only when computed (computeBoundingSphere).
            const sm = o as SkinnedMesh;
            if (sm.boundingSphere == null) return true;
            _sphere.copy(sm.boundingSphere!).applyMatrix4(sm.matrixWorld);
            return _frustum.intersectsSphere(_sphere);
        }
        if (o instanceof InstancedMesh) {
            const im = o as InstancedMesh;
            if (im.boundingSphere == null) im.computeBoundingSphere();
            _sphere.copy(im.boundingSphere!).applyMatrix4(im.matrixWorld);
            return _frustum.intersectsSphere(_sphere);
        }
        if (o instanceof BatchedMesh) {
            const bm = o as BatchedMesh;
            if (bm.boundingSphere == null) bm.computeBoundingSphere();
            if (bm.boundingSphere!.isEmpty()) return false;
            _sphere.copy(bm.boundingSphere!).applyMatrix4(bm.matrixWorld);
            return _frustum.intersectsSphere(_sphere);
        }
        const geometry = geometryOf(o);
        if (geometry == null) return true;
        if (geometry.boundingSphere == null) geometry.computeBoundingSphere();
        const bounds = geometry.boundingSphere!;
        if (bounds.isEmpty()) return true;
        _sphere.copy(bounds).applyMatrix4(o.matrixWorld);
        return _frustum.intersectsSphere(_sphere);
    }

    private collectObject(o: Object3D, frame: i32): void {
        const override = this.overrideMaterial;
        if (o instanceof Sprite) {
            const sprite = o as Sprite;
            const item = this.addDraw(sprite, override != null ? override : sprite.material, null, 0, 0, 6, frame,
                PRIM_SPRITE);
            if (item != null) item.count = 6;
            return;
        }
        const geometry = geometryOf(o)!;
        const g = this.geometries.get(geometry, frame);
        if (g == null) return;
        const range = geometry.drawRange;
        const rangeStart = max<i32>(0, range.start);
        const rangeEnd = range.count < 0 ? g.count : min<i32>(g.count, rangeStart + range.count);

        if (o instanceof Points) {
            const points = o as Points;
            // One quad per vertex (indices ignored), from the vertex range.
            const vStart = max<i32>(0, range.start);
            const vEnd = range.count < 0 ? g.vertexCount : min<i32>(g.vertexCount, vStart + range.count);
            this.addDraw(points, override != null ? override : points.material, g, 0, vStart, vEnd, frame, PRIM_POINTS);
            return;
        }
        if (o instanceof Line) {
            const line = o as Line;
            const mode = o instanceof LineSegments ? LINE_SEGMENTS : o instanceof LineLoop ? LINE_LOOP : LINE_STRIP;
            if (!this.geometries.lines(geometry, g, mode)) return;
            let first = 0, count = g.lineCounts[mode];
            if (mode == LINE_SEGMENTS) {
                first = rangeStart;
                count = min<i32>(count - first, rangeEnd - rangeStart);
            } else if (rangeStart > 0 || rangeEnd < g.count) {
                // A strip's segment k joins vertices k and k + 1.
                first = rangeStart * 2;
                count = max<i32>(0, rangeEnd - rangeStart - 1) * 2;
            }
            const item = this.addDraw(line, override != null ? override : line.material, g, 0, first, first + count,
                frame, PRIM_LINES);
            if (item != null) {
                item.index = g.lineBuffers[mode];
                item.indexFormat = <u32>g.lineFormats[mode];
            }
            return;
        }

        const mesh = o as Mesh;
        if (mesh instanceof BatchedMesh) {
            // One instanced draw per geometry, from its slice of the instances.
            const bm = mesh as BatchedMesh;
            const bg = this.batchedBuffer(bm);
            const material = override != null ? override! : bm.material;
            const indexed = g.indexed;
            for (let k = 0; k < bg.count.length; k++) {
                if (bg.count[k] == 0) continue;
                const info = bm.geometryInfo[k];
                const start = indexed ? info.indexStart : info.vertexStart;
                const end = start + (indexed ? info.indexCount : info.vertexCount);
                this.addMeshDraw(mesh, material, geometry, g, 0, start, end, frame, bg.matrices!, bg.colors!,
                    <u32>bg.count[k], <u32>bg.first[k]);
            }
            return;
        }
        let instances = this.identityInstance!;
        let colors = this.identityColor!;
        let instanceCount: u32 = 1;
        if (mesh instanceof InstancedMesh) {
            const im = mesh as InstancedMesh;
            if (im.count <= 0) return;
            const ig = this.instanceBuffer(im);
            instances = ig.matrices!;
            colors = ig.colors!;
            instanceCount = <u32>im.count;
        }
        const groups = geometry.groups;
        if (override == null && mesh.materials.length > 0 && groups.length > 0) {
            for (let i = 0; i < groups.length; i++) {
                const group = groups[i];
                const mi = group.materialIndex;
                if (mi < 0 || mi >= mesh.materials.length) continue;
                const start = max<i32>(rangeStart, group.start);
                const end = min<i32>(rangeEnd, group.start + group.count);
                this.addMeshDraw(mesh, mesh.materials[mi], geometry, g, i + 1, start, end, frame, instances,
                    colors, instanceCount);
            }
        } else {
            this.addMeshDraw(mesh, override != null ? override : mesh.material, geometry, g, 0, rangeStart, rangeEnd,
                frame, instances, colors, instanceCount);
        }
    }

    private addMeshDraw(mesh: Mesh, material: Material, geometry: BufferGeometry, g: GeometryGPU, part: i32,
                        start: i32, end: i32, frame: i32, instances: GPUBuffer, colors: GPUBuffer,
                        instanceCount: u32, instanceFirst: u32 = 0): void {
        if (material.wireframe) {
            if (!this.geometries.lines(geometry, g, LINE_WIREFRAME)) return;
            // Each triangle's three edges: index range x2.
            const item = this.addDraw(mesh, material, g, part, start * 2, end * 2, frame, PRIM_LINES);
            if (item == null) return;
            item.index = g.lineBuffers[LINE_WIREFRAME];
            item.indexFormat = <u32>g.lineFormats[LINE_WIREFRAME];
            item.instances = instances;
            item.instanceColors = colors;
            item.instanceCount = instanceCount;
            item.instanceFirst = instanceFirst;
            return;
        }
        const item = this.addDraw(mesh, material, g, part, start, end, frame, PRIM_TRIANGLES);
        if (item == null) return;
        item.instances = instances;
        item.instanceColors = colors;
        item.instanceCount = instanceCount;
        item.instanceFirst = instanceFirst;
        if (g.indexed) {
            item.index = g.index;
            item.indexFormat = <u32>g.indexFormat;
        }
        if (item.entry!.kind == KIND_WIDE_LINE) {
            // Wide lines: the base quad once per segment.
            const segments = this.wideLineInstances(geometry, item);
            if (segments == 0) {
                item.instanceCount = 0;
                return;
            }
            item.instanceCount = <u32>segments;
            item.pipelineKey |= KEY_WIDE_LINE;
            return;
        }
        this.deform(mesh, geometry, g, item, frame);
    }

    /// Packs a LineSegmentsGeometry's segments as instances (start xyz +
    /// distance, end xyz + distance, start colour, end colour), re-uploaded
    /// when its attributes change. Returns the segment count.
    private wideLineInstances(geometry: BufferGeometry, item: DrawItem): i32 {
        const s = geometry.getAttribute("instanceStart");
        const e = geometry.getAttribute("instanceEnd");
        if (s == null || e == null || s.count == 0) return 0;
        const n = s.count;
        const cs = geometry.getAttribute("instanceColorStart");
        const ce = geometry.getAttribute("instanceColorEnd");
        const ds = geometry.getAttribute("instanceDistanceStart");
        const de = geometry.getAttribute("instanceDistanceEnd");
        const version = s.version * 31 + e.version * 17 + (cs != null ? cs.version * 7 : 0) + (ds != null ? ds.version : 0) + n * 1000003;
        let w: WideLineGPU;
        if (this.wideLines.has(geometry.id)) w = this.wideLines.get(geometry.id);
        else {
            w = new WideLineGPU();
            this.wideLines.set(geometry.id, w);
        }
        if (w.buffer == null || w.version != version) {
            if (w.data.length != n * 16) w.data = new Float32Array(n * 16);
            const d = w.data;
            for (let i = 0; i < n; i++) {
                const o = i * 16;
                d[o] = s.array[i * 3]; d[o + 1] = s.array[i * 3 + 1]; d[o + 2] = s.array[i * 3 + 2];
                d[o + 3] = ds != null ? ds.array[i] : 0;
                d[o + 4] = e.array[i * 3]; d[o + 5] = e.array[i * 3 + 1]; d[o + 6] = e.array[i * 3 + 2];
                d[o + 7] = de != null ? de.array[i] : 0;
                for (let k = 0; k < 3; k++) {
                    d[o + 8 + k] = cs != null ? cs.array[i * 3 + k] : 1;
                    d[o + 12 + k] = ce != null ? ce.array[i * 3 + k] : 1;
                }
                d[o + 11] = 1; d[o + 15] = 1;
            }
            w.buffer = uploadVertices(w.buffer, d);
            w.version = version;
        }
        item.instances = w.buffer!;
        item.instanceColors = this.white3(n);
        return n;
    }

    /// Morph targets and skinning for a mesh draw, on the GPU: the active
    /// targets' weights in the mesh's MorphU block over the geometry's
    /// morph texture (an InstancedMesh's morphTexture holds per-instance
    /// weights), bones in a uniform block or, above MAX_BONES, a bone
    /// texture. Morph textures too big for the device blend on the CPU.
    private deform(mesh: Mesh, geometry: BufferGeometry, g: GeometryGPU, item: DrawItem, frame: i32): void {
        let flags: u32 = 0;
        let count = 0;
        let mt: MorphTargetsGPU? = null;
        const morphs = geometry.morphAttributes.size > 0 && geometry.morphAttributes.has("position") && geometry.morphAttributes.get("position").length > 0;
        let instanceWeights: Texture? = null;
        if (morphs && mesh instanceof InstancedMesh) instanceWeights = (mesh as InstancedMesh).morphTexture;
        if (morphs && (mesh.morphTargetInfluences.length > 0 || instanceWeights != null)) {
            mt = this.morphTargetsOf(geometry);
            if (mt == null) {
                // CPU fallback (the texture would not fit).
                const m = this.morph(mesh, geometry);
                if (m != null) {
                    item.positionOverride = m.position;
                    item.normalOverride = m.normal;
                }
            } else if (instanceWeights != null) {
                this.textures.update(instanceWeights, frame);
                const v = this.textures.view(instanceWeights, this.canvas!);
                if (v != null) {
                    item.instanceMorphView = v;
                    flags |= MORPH_INSTANCED;
                    count = mt.targets;
                }
            } else {
                const infl = mesh.morphTargetInfluences;
                for (let i = 0; i < infl.length && i < mt.targets; i++) if (infl[i] != 0) count++;
            }
            if (count > 0) {
                if (mt!.normals) flags |= MORPH_NORMALS;
                item.morphView = mt!.view;
            }
        }
        let skeleton: Skeleton? = null;
        let bigSkeleton = false;
        if (mesh instanceof SkinnedMesh && g.skin != null) {
            skeleton = (mesh as SkinnedMesh).skeleton;
            if (skeleton != null) {
                if (skeleton.frame != frame) {
                    skeleton.update();
                    skeleton.frame = frame;
                }
                bigSkeleton = skeleton.bones.length > MAX_BONES;
                if (bigSkeleton) flags |= BONE_TEXTURE;
            }
        }
        if (count > 0 || bigSkeleton) {
            const d = this.deformOf(mesh);
            if (d.frame != frame) {
                d.frame = frame;
                this.writeMorphBlock(d, mesh, mt, count, flags, skeleton, frame);
            }
            item.morphed = true;
            item.morphOffset = d.offset;
            if ((flags & MORPH_INSTANCED) != 0) {
                item.pipelineKey |= KEY_MORPH_INSTANCED;
                item.morphRows = this.morphRowsFor(item.instanceCount);
            }
            if (bigSkeleton) item.boneView = d.boneView;
        }
        if (skeleton == null) return;
        if (bigSkeleton) {
            item.skinned = true;
            item.bones = this.dummyBones;
            item.pipelineKey |= KEY_SKINNED;
            return;
        }
        let bones: GPUBuffer;
        if (this.boneBuffers.has(mesh.id)) bones = this.boneBuffers.get(mesh.id);
        else {
            bones = new GPUBuffer(BufferUsage.uniform, <u32>BONES_BYTES);
            this.boneBuffers.set(mesh.id, bones);
        }
        const data = skeleton.boneMatrices;
        if (data.length > 0) bones.update(0, data.buffer, <u32>data.byteLength);
        item.skinned = true;
        item.bones = bones;
        item.pipelineKey |= KEY_SKINNED;
    }

    private deformOf(mesh: Mesh): DeformGPU {
        if (this.deforms.has(mesh.id)) return this.deforms.get(mesh.id);
        const d = new DeformGPU();
        this.deforms.set(mesh.id, d);
        return d;
    }

    /// Room for `bytes` more bytes in the morph arena at a 256-byte offset
    /// (grows it, keeping what this view wrote); returns that offset.
    private reserveMorph(bytes: i32): i32 {
        const offset = (this.morphUsed + 255) & ~255;
        const need = offset + bytes;
        if (need > this.morphCapacity || this.morphArena == null) {
            let capacity = max<i32>(4096, this.morphCapacity);
            while (capacity < need) capacity *= 2;
            // Room for a whole MorphU binding past the last block.
            const staging = new ArrayBuffer(capacity + MORPH_BYTES);
            const bytes8 = Uint8Array.wrap(staging);
            if (this.morphUsed > 0) bytes8.set(this.morphBytes.subarray(0, this.morphUsed));
            this.morphStaging = staging;
            this.morphBytes = bytes8;
            this.morphF32 = Float32Array.wrap(staging);
            this.morphU32 = Uint32Array.wrap(staging);
            // The old buffer may still be bound by passes recorded this
            // frame: it is left to the collector, not released.
            this.morphArena = new GPUBuffer(BufferUsage.uniform, <u32>(capacity + MORPH_BYTES));
            this.morphCapacity = capacity;
            this.morphFlushed = 0;
        }
        this.morphUsed = need;
        return offset;
    }

    /// Uploads the morph blocks written since the last flush (before a pass).
    private flushMorphs(): void {
        const arena = this.morphArena;
        if (arena == null || this.morphUsed <= this.morphFlushed) return;
        const from = this.morphFlushed;
        arena.update(<u32>from, this.morphStaging, <u32>(this.morphUsed - from), <u32>from);
        this.morphFlushed = this.morphUsed;
    }

    /// Writes a mesh's MorphU block (and bone texture) for this view into
    /// the morph arena: the header and its weighted targets only.
    private writeMorphBlock(d: DeformGPU, mesh: Mesh, mt: MorphTargetsGPU?, count: i32, flags: u32,
                            skeleton: Skeleton?, frame: i32): void {
        const weighted = mt != null && count > 0 && (flags & MORPH_INSTANCED) == 0;
        const most = weighted ? MORPH_ACTIVE + (min<i32>(count, MAX_ACTIVE_MORPHS) + 1) * 8 : MORPH_ACTIVE;
        const base = this.reserveMorph(most);
        d.offset = <u32>base;
        const u = this.morphU32;
        const f = this.morphF32;
        let active = 0;
        let bytes = MORPH_ACTIVE;
        if (weighted) {
            // The weighted targets, as (target, weight) pairs.
            const infl = mesh.morphTargetInfluences;
            const n = min<i32>(infl.length, mt!.targets);
            let o = (base + MORPH_ACTIVE) >> 2;
            for (let i = 0; i < n && active < MAX_ACTIVE_MORPHS; i++) {
                const w = infl[i];
                if (w == 0) continue;
                f[o++] = <f32>i;
                f[o++] = <f32>w;
                active++;
            }
            if ((active & 1) == 1) { f[o++] = 0; f[o++] = 0; }
            bytes = (o << 2) - base;
            count = active;
        }
        this.morphUsed = base + bytes;
        const ui = (base + MORPH_INFO) >> 2;
        u[ui] = <u32>count;
        u[ui + 1] = flags;
        u[ui + 2] = mt != null ? <u32>mt.width : 0;
        u[ui + 3] = mt != null ? <u32>mt.texelsPerTarget : 0;
        const ub = (base + MORPH_BONES) >> 2;
        u[ub] = 0; u[ub + 1] = 0; u[ub + 2] = 0; u[ub + 3] = 0;
        if (skeleton != null && (flags & BONE_TEXTURE) != 0) {
            this.writeBoneTexture(d, skeleton, frame);
            u[ub] = <u32>d.boneWidth;
        }
    }

    /// Uploads a big skeleton's bone matrices: six rgba16float texels a
    /// bone, its three affine rows as half floats plus their remainders.
    private writeBoneTexture(d: DeformGPU, skeleton: Skeleton, frame: i32): void {
        if (d.boneFrame == frame) return;
        d.boneFrame = frame;
        const n = skeleton.bones.length;
        const texels = n * BONE_TEXELS;
        const maxSize = <i32>this.context.features().maxTextureSize2D;
        const width = min<i32>(texels, maxSize);
        const height = (texels + width - 1) / width;
        let tex = d.boneTexture;
        if (tex == null || tex.width != <u32>width || tex.height != <u32>height) {
            if (tex != null) tex.release();
            const desc = new GPUTextureDesc();
            desc.width = <u32>width;
            desc.height = <u32>height;
            desc.format = TextureFormat.rgba16float;
            tex = new GPUTexture(desc);
            d.boneTexture = tex;
            d.boneView = tex.view();
            d.boneWidth = width;
            d.boneData = new Uint16Array(width * height * 4);
            d.boneCache = new Float32Array(0);
        }
        if (d.boneCache.length != n * 12) {
            d.boneCache = new Float32Array(n * 12);
            d.boneCache.fill(NaN);   // every bone differs from it
        }
        // Only the bones that moved since the last upload are converted, and
        // nothing is uploaded when none did.
        const m = skeleton.boneMatrices;
        const out = d.boneData;
        const cache = d.boneCache;
        let changed = false;
        for (let b = 0; b < n; b++) {
            const src = b * 16;
            const dst = b * BONE_TEXELS * 4;
            const kept = b * 12;
            let same = true;
            for (let r = 0; r < 3 && same; r++) {
                for (let c = 0; c < 4 && same; c++) same = unchecked(cache[kept + r * 4 + c]) == m[src + c * 4 + r];
            }
            if (same) continue;
            changed = true;
            for (let r = 0; r < 3; r++) {
                for (let c = 0; c < 4; c++) unchecked(cache[kept + r * 4 + c] = m[src + c * 4 + r]);
            }
            for (let r = 0; r < 3; r++) {
                for (let c = 0; c < 4; c++) {
                    const v = m[src + c * 4 + r];   // column-major: column c, row r
                    const hi = fastHalf(v);
                    const lo = fastHalf(v - fromHalf(hi));
                    out[dst + r * 8 + c] = hi;
                    out[dst + r * 8 + 4 + c] = lo;
                }
            }
        }
        if (!changed) return;
        uploadRegion.width = <u32>width;
        uploadRegion.height = <u32>height;
        tex.upload(uploadRegion, out.buffer);
    }

    /// A geometry's morph texture, built (or rebuilt after its attributes
    /// changed); null when it would exceed the device's texture size (the
    /// caller blends on the CPU). Big target sets convert to half floats in
    /// a Rive job started here, while the frame's other draws are collected
    /// and written; joinMorphJobs uploads them before the first pass.
    private morphTargetsOf(geometry: BufferGeometry): MorphTargetsGPU? {
        const position = geometry.getAttribute("position");
        if (position == null) return null;
        const targets = geometry.morphAttributes.get("position");
        const normal = geometry.getAttribute("normal");
        const normalTargets = geometry.morphAttributes.has("normal") ? geometry.morphAttributes.get("normal") : null;
        const normals = normal != null && normalTargets != null && normalTargets.length == targets.length;
        let key = position.version * 31 + targets.length;
        for (let i = 0; i < targets.length; i++) key = key * 31 + targets[i].version;
        if (normals) for (let i = 0; i < normalTargets!.length; i++) key = key * 31 + normalTargets![i].version;
        let mt: MorphTargetsGPU;
        if (this.morphTargets.has(geometry.id)) {
            mt = this.morphTargets.get(geometry.id);
            if (mt.key == key) {
                if (mt.job != null) this.awaitMorphJob(mt);
                return mt.texture != null ? mt : null;
            }
        } else {
            mt = new MorphTargetsGPU();
            this.morphTargets.set(geometry.id, mt);
        }
        mt.key = key;
        const pending = mt.job;
        if (pending != null) {
            pending.release();   // its attributes changed meanwhile
            mt.job = null;
        }
        const vertices = position.count;
        const stride = normals ? 2 : 1;
        const perTarget = vertices * stride;
        const total = perTarget * targets.length;
        const maxSize = <i32>this.context.features().maxTextureSize2D;
        const width = max<i32>(1, min<i32>(total, maxSize));
        const height = (total + width - 1) / width;
        if (height > maxSize) {
            if (!this.warnedMorphs) {
                this.context.log("three: morph targets too big for a texture blend on the CPU");
                this.warnedMorphs = true;
            }
            const old = mt.texture;
            if (old != null) old.release();
            mt.texture = null;
            mt.view = null;
            return null;
        }
        // The targets' arrays, flat, for morphTexels.
        const input = new MorphTexelInput();
        input.base = position.array;
        if (normals) input.baseNormal = normal!.array;
        let floats = 0;
        for (let t = 0; t < targets.length; t++) {
            floats += targets[t].array.length;
            if (normals) floats += normalTargets![t].array.length;
        }
        const data = new Float32Array(floats);
        const layout = new Int32Array(targets.length * 6);
        let at = 0;
        for (let t = 0; t < targets.length; t++) {
            const a = targets[t];
            data.set(a.array, at);
            layout[t * 6] = at; layout[t * 6 + 1] = a.itemSize; layout[t * 6 + 2] = a.count;
            at += a.array.length;
        }
        for (let t = 0; t < targets.length && normals; t++) {
            const n = normalTargets![t];
            data.set(n.array, at);
            layout[t * 6 + 3] = at; layout[t * 6 + 4] = n.itemSize; layout[t * 6 + 5] = n.count;
            at += n.array.length;
        }
        input.data = data;
        input.layout = layout;
        input.targets = targets.length;
        input.vertices = vertices;
        input.stride = stride;
        input.width = width;
        input.height = height;
        input.relative = geometry.morphTargetsRelative;
        mt.width = width;
        mt.targets = targets.length;
        mt.texelsPerTarget = perTarget;
        mt.normals = normals;
        // The texture (and so its view, which bind groups take now) first;
        // its texels follow.
        let tex = mt.texture;
        if (tex == null || tex.width != <u32>width || tex.height != <u32>height) {
            if (tex != null) tex.release();
            const desc = new GPUTextureDesc();
            desc.width = <u32>width;
            desc.height = <u32>height;
            desc.format = TextureFormat.rgba16float;
            tex = new GPUTexture(desc);
            mt.texture = tex;
            mt.view = tex.view();
        }
        if (total > MORPH_JOB_TEXELS) {
            mt.job = Jobs.run(morphTexels, input);
            mt.zeroed = false;
            this.awaitMorphJob(mt);
        } else {
            this.uploadMorphTexels(mt, morphTexels(input));
        }
        return mt;
    }

    /// Queues a running morph job for joinMorphJobs (once a view).
    private awaitMorphJob(mt: MorphTargetsGPU): void {
        if (mt.awaited == this.frameId) return;
        mt.awaited = this.frameId;
        this.pendingMorphs.push(mt);
    }

    /// Joins the morph texel jobs this view started or needs, and uploads
    /// their texels, then uploads the view's morph blocks; called before the
    /// view's first pass (and the shadow passes). A job still
    /// running when the call's budget would run out leaves its texture
    /// zero (the mesh unmorphed) until a later frame's join.
    private joinMorphJobs(): void {
        const pending = this.pendingMorphs;
        for (let i = 0; i < pending.length; i++) {
            const mt = pending[i];
            const job = mt.job;
            if (job == null) continue;
            const settled = job.join();
            if (settled == null) {
                if (!mt.zeroed) this.uploadMorphTexels(mt, new Uint16Array(<i32>(mt.texture!.width * mt.texture!.height * 4)));
                mt.zeroed = true;
                continue;
            }
            mt.job = null;
            if (settled.ok) this.uploadMorphTexels(mt, settled.value);
            else {
                this.context.log("three: morph texture job failed: " + settled.error);
                this.uploadMorphTexels(mt, new Uint16Array(<i32>(mt.texture!.width * mt.texture!.height * 4)));
            }
            job.release();
        }
        pending.length = 0;
        this.flushMorphs();
    }

    private uploadMorphTexels(mt: MorphTargetsGPU, texels: Uint16Array): void {
        const tex = mt.texture!;
        uploadRegion.width = tex.width;
        uploadRegion.height = tex.height;
        tex.upload(uploadRegion, texels.buffer);
    }

    /// Blends the morph targets into a per-mesh position (and normal)
    /// buffer, when the influences changed.
    private morph(mesh: Mesh, geometry: BufferGeometry): MorphGPU? {
        const position = geometry.getAttribute("position");
        if (position == null) return null;
        const influences = mesh.morphTargetInfluences;
        let active = false;
        for (let i = 0; i < influences.length; i++) if (influences[i] != 0) active = true;
        if (!active) return null;
        let m: MorphGPU;
        if (this.morphs.has(mesh.id)) m = this.morphs.get(mesh.id);
        else {
            m = new MorphGPU();
            this.morphs.set(mesh.id, m);
        }
        let same = m.position != null && m.influences.length == influences.length && m.geometryVersion == position.version;
        for (let i = 0; i < influences.length && same; i++) same = m.influences[i] == influences[i];
        if (same) return m;
        const kept = m.influences;
        kept.length = influences.length;
        for (let i = 0; i < influences.length; i++) kept[i] = influences[i];
        m.geometryVersion = position.version;
        const relative = geometry.morphTargetsRelative;
        m.positions = blend(position.array, geometry.morphAttributes.get("position"), influences, relative, m.positions);
        m.position = uploadVertices(m.position, m.positions);
        const normal = geometry.getAttribute("normal");
        if (normal != null && normal.count == position.count) {
            if (geometry.morphAttributes.has("normal")) {
                m.normals = blend(normal.array, geometry.morphAttributes.get("normal"), influences, relative, m.normals);
                const tangent = geometry.getAttribute("tangent");
                const t = tangent != null && tangent.count == position.count && tangent.itemSize == 4 ? tangent.array : null;
                m.normal = uploadVertices(m.normal, interleaveNormalTangent(m.normals, t, position.count));
            } else {
                m.normal = null;
            }
        }
        return m;
    }

    /// `material`'s entry (cached on the draw state).
    private entryOf(state: DrawState, material: Material): MaterialEntry {
        let entry = state.entry;
        if (entry != null && entry.material === material) return entry;
        const id = material.id;
        if (this.materialEntries.has(id)) entry = this.materialEntries.get(id);
        else {
            entry = new MaterialEntry(material);
            this.materialEntries.set(id, entry);
        }
        state.entry = entry;
        return entry!;
    }

    /// `material`'s entry, its textures updated for this view (once a view,
    /// however many draws use it).
    private prepareMaterial(state: DrawState, material: Material, frame: i32): MaterialEntry {
        const entry = this.entryOf(state, material);
        if (entry.prepared == frame) return entry;
        entry.prepared = frame;
        const u = this.uniforms;
        material.fillUniforms(u);
        for (let i = 0; i < TEXTURE_SLOTS; i++) {
            const t = u.textures[i];
            if (t != null) this.textures.update(t, frame);
        }
        for (let i = 0; i < ROLE_COUNT; i++) {
            const t = u.roles[i];
            if (t != null) this.textures.update(t, frame);
        }
        entry.kind = u.kind;
        entry.displaced = u.roles[ROLE_DISPLACEMENT] != null;
        entry.transmissive = u.kind == KIND_PHYSICAL && u.transmission > 0;
        // Its depth/stencil/offset state, interned again only when it changed.
        const m = material;
        if (entry.stateIndex < 0 || entry.depthFunc != m.depthFunc || entry.stencilWrite != m.stencilWrite
                || entry.stencilFunc != m.stencilFunc || entry.stencilFuncMask != m.stencilFuncMask
                || entry.stencilWriteMask != m.stencilWriteMask || entry.stencilFail != m.stencilFail
                || entry.stencilZFail != m.stencilZFail || entry.stencilZPass != m.stencilZPass
                || entry.polygonOffset != m.polygonOffset || entry.polygonOffsetFactor != m.polygonOffsetFactor
                || entry.polygonOffsetUnits != m.polygonOffsetUnits) {
            entry.stateIndex = this.stateIndex(m);
            entry.depthFunc = m.depthFunc;
            entry.stencilWrite = m.stencilWrite;
            entry.stencilFunc = m.stencilFunc;
            entry.stencilFuncMask = m.stencilFuncMask;
            entry.stencilWriteMask = m.stencilWriteMask;
            entry.stencilFail = m.stencilFail;
            entry.stencilZFail = m.stencilZFail;
            entry.stencilZPass = m.stencilZPass;
            entry.polygonOffset = m.polygonOffset;
            entry.polygonOffsetFactor = m.polygonOffsetFactor;
            entry.polygonOffsetUnits = m.polygonOffsetUnits;
        }
        return entry;
    }

    private addDraw(object: Object3D, material: Material, g: GeometryGPU?, part: i32, start: i32, end: i32,
                    frame: i32, prim: i32): DrawItem? {
        if (!material.visible || end <= start) return null;
        const state = this.stateOf(object.id * 64 + part);
        // Textures draw and upload now, before any pass (once a view per material).
        const entry = this.prepareMaterial(state, material, frame);
        const displaced = entry.displaced && prim == PRIM_TRIANGLES;
        const transmissive = entry.transmissive;

        const item = this.newItem(object, material, g, state, this.identityInstance!, this.identityColor!);
        item.entry = entry;
        item.prim = prim;
        item.first = start;
        item.count = end - start;
        const side = material.side;
        const cull = side == DoubleSide ? 1 : side == BackSide ? 2 : 0;
        const mirrored = object.matrixWorld.determinant() < 0;
        let blending = material.blending;
        if (blending == NormalBlending && !material.transparent) blending = NoBlending;
        item.pipelineKey = cull | (blending << KEY_BLEND_SHIFT)
            | (material.depthTest ? KEY_DEPTH_TEST : 0) | (material.depthWrite ? KEY_DEPTH_WRITE : 0)
            | (mirrored ? KEY_MIRRORED : 0) | (material.colorWrite ? KEY_COLOR_WRITE : 0) | (prim << KEY_PRIM_SHIFT)
            | (this.passSamples > 1 ? KEY_MSAA : 0) | (displaced ? KEY_DISPLACED : 0) | (this.logDepth ? KEY_LOG_DEPTH : 0)
            | (entry.stateIndex << KEY_STATE_SHIFT);
        item.stencilRef = material.stencilWrite ? <u32>material.stencilRef : 0;
        if (material instanceof ShaderMaterial) {
            if (prim != PRIM_TRIANGLES) return null;   // custom points/lines are not supported
            const cp = this.customPipelineOf(entry, material as ShaderMaterial, item.pipelineKey);
            if (cp == null) return null;
            item.custom = cp;
        }
        item.transmissive = transmissive;
        if (transmissive) this.hasTransmission = true;
        const e = object.matrixWorld.elements;
        _pos.set(e[12], e[13], e[14]).applyMatrix4(this.viewProj);
        item.depth = _pos.z;
        if (material.transparent) this.transparent.push(item);
        else this.opaque.push(item);
        return item;
    }

    /// The InstancedMesh's instances, packed as mat4 + RGBA, re-uploaded when
    /// instanceMatrix or instanceColor changed.
    private instanceBuffer(im: InstancedMesh): InstanceGPU {
        let ig: InstanceGPU;
        if (this.instanceBuffers.has(im.id)) ig = this.instanceBuffers.get(im.id);
        else {
            ig = new InstanceGPU();
            this.instanceBuffers.set(im.id, ig);
        }
        const capacity = im.instanceMatrix.count;
        const colors = im.instanceColor;
        const colorVersion = colors != null ? colors.version : -2;
        const resized = ig.count != capacity;
        if (resized || ig.matrixVersion != im.instanceMatrix.version || ig.matrices == null) {
            ig.matrices = uploadVertices(resized ? null : ig.matrices, im.instanceMatrix.array);
            ig.matrixVersion = im.instanceMatrix.version;
        }
        if (resized || ig.colorVersion != colorVersion || ig.colors == null) {
            if (colors != null) {
                ig.colors = uploadVertices(ig.ownColors && !resized ? ig.colors : null, colors.array);
                ig.ownColors = true;
            } else {
                ig.colors = this.white3(capacity);
                ig.ownColors = false;
            }
            ig.colorVersion = colorVersion;
        }
        ig.count = capacity;
        return ig;
    }

    /// A BatchedMesh's active, visible instances packed by geometry,
    /// re-packed when its instances change.
    private batchedBuffer(bm: BatchedMesh): BatchedGPU {
        let bg: BatchedGPU;
        if (this.batchedBuffers.has(bm.id)) bg = this.batchedBuffers.get(bm.id);
        else {
            bg = new BatchedGPU();
            this.batchedBuffers.set(bm.id, bg);
        }
        if (bg.version == bm.instancesVersion && bg.matrices != null) return bg;
        const n = max<i32>(1, bm.maxInstanceCount);
        if (bg.matrixData.length != n * 16) {
            bg.matrixData = new Float32Array(n * 16);
            bg.colorData = new Float32Array(n * 3);
        }
        const geometries = bm.geometryInfo.length;
        bg.first.length = 0;
        bg.count.length = 0;
        let next = 0;
        for (let k = 0; k < geometries; k++) {
            bg.first.push(next);
            if (bm.geometryInfo[k].active) {
                for (let i = 0; i < bm.instanceInfo.length; i++) {
                    const info = bm.instanceInfo[i];
                    if (!info.active || !info.visible || info.geometryIndex != k) continue;
                    for (let e = 0; e < 16; e++) bg.matrixData[next * 16 + e] = bm.matricesArray[i * 16 + e];
                    for (let e = 0; e < 3; e++) bg.colorData[next * 3 + e] = bm.colorsArray[i * 3 + e];
                    next++;
                }
            }
            bg.count.push(next - bg.first[k]);
        }
        bg.matrices = uploadVertices(bg.matrices, bg.matrixData);
        bg.colors = uploadVertices(bg.colors, bg.colorData);
        bg.version = bm.instancesVersion;
        return bg;
    }

    /// A white colour per instance for `count` instances (shared, grown).
    private white3(count: i32): GPUBuffer {
        if (this.whiteColors == null || this.whiteCount < count) {
            const n = max<i32>(count, max<i32>(1024, this.whiteCount * 2));
            const data = new Float32Array(n * 3);
            data.fill(1);
            this.whiteColors = new GPUBuffer(BufferUsage.vertex, <u32>(n * INSTANCE_COLOR_STRIDE), data.buffer, true);
            this.whiteCount = n;
        }
        return this.whiteColors!;
    }

    /// The instance rows of instanced morphs (0, 1, 2 ... as f32, an
    /// instance-step buffer at slot 7), for at least `count` instances
    /// (shared, grown). Draws bind it at offset 0 and start at instance 0,
    /// so instance i reads row i, as @builtin(instance_index) would.
    private morphRowsFor(count: u32): GPUBuffer {
        if (this.morphRows == null || this.morphRowCount < count) {
            const n = max<u32>(count, max<u32>(256, this.morphRowCount * 2));
            const data = new Float32Array(<i32>n);
            for (let i = 0; i < <i32>n; i++) data[i] = <f32>i;
            // The old buffer may still be bound by passes recorded this
            // frame: it is left to the collector.
            this.morphRows = new GPUBuffer(BufferUsage.vertex, n * MORPH_ROW_STRIDE, data.buffer, true);
            this.morphRowCount = n;
        }
        return this.morphRows!;
    }

    /// Prepares the background texture's bind group; true when there is
    /// one to draw.
    private prepareBackground(scene: Object3D, frame: i32, canvas: GPUCanvas): bool {
        this.bgTexture = null;
        if (!(scene instanceof Scene)) return false;
        const bg = (scene as Scene).background;
        if (bg == null || !(bg instanceof Texture)) return false;
        const t = bg as Texture;
        this.textures.update(t, frame);
        // A blurred environment background reads the PMREM, as three.js.
        let view: GPUTextureView? = null;
        this.bgPrefiltered = false;
        const surround = t instanceof CubeTexture || t.mapping == EquirectangularReflectionMapping
            || t.mapping == EquirectangularRefractionMapping;
        if (surround && (scene as Scene).backgroundBlurriness > 0) {
            view = this.textures.pmrem(t, canvas);
            this.bgPrefiltered = view != null;
        }
        if (view == null) view = this.textures.view(t, canvas);
        if (view == null) return false;
        this.bgTexture = t;
        this.bgView = view;
        this.bgMipmapped = this.bgPrefiltered || wantsMipmaps(t);
        return true;
    }

    /// A group 0 over `ubo`: the frame block, its textures and samplers, and
    /// the RectAreaLight tables. No sampler at binding 4: three.wgsl reads
    /// the shadow maps with textureLoad (a comparison sampler crashes Rive's
    /// web runtime; docs/DEVIATIONS.md).
    private makeFrameGroup(layout: GPUBindGroupLayout, ubo: GPUBuffer, env: GPUTextureView, shadow: GPUTextureView,
                           tr: GPUTextureView): GPUBindGroup {
        return new GPUBindGroup(layout, [new GPUBindGroupUBO(0, ubo), new GPUBindGroupUBO(7, this.ltcUbo!)],
            [new GPUBindGroupTexture(1, env), new GPUBindGroupTexture(3, shadow), new GPUBindGroupTexture(5, tr)],
            [new GPUBindGroupSampler(2, this.backgroundSampler(true)), new GPUBindGroupSampler(6, this.backgroundSampler(true))]);
    }

    /// The frame bind group: the frame block, the environment, the shadow
    /// maps and the transmission texture (rebuilt when one changes).
    private ensureFrameGroup(): void {
        const env = this.frameEnvView != null ? this.frameEnvView! : this.white!;
        const shadow = this.frameShadowView != null ? this.frameShadowView! : this.dummyShadowView!;
        const tr = this.transmissionView != null ? this.transmissionView! : this.white!;
        if (this.frameGroup != null && this.frameGroupView === env && this.frameGroupShadow === shadow
                && this.frameGroupTransmission === tr) return;
        this.frameGroup = this.makeFrameGroup(this.frameLayout!, this.frameUbo!, env, shadow, tr);
        this.frameGroupView = env;
        this.frameGroupShadow = shadow;
        this.frameGroupTransmission = tr;
    }

    /// three.js's transmission pass: the opaque, non-transmissive draws
    /// (and the background) into a linear HDR target the size of the pass,
    /// mipmapped, which transmissive materials then sample.
    private renderTransmission(canvas: GPUCanvas, scene: Object3D, background: bool, pw: u32, ph: u32, frame: i32): void {
        let rt = this.transmissionTarget;
        if (rt == null) {
            const o = new RenderTargetOptions();
            o.type = HalfFloatType;
            o.generateMipmaps = true;
            rt = new RenderTarget(pw, ph, o);
            rt.texture.minFilter = LinearMipmapLinearFilter;
            this.transmissionTarget = rt;
        }
        rt.setSize(pw, ph);
        const view = rt.ensureHDR();
        if (view == null) return;
        // Its frame block: the main one, written for linear output.
        let ubo = this.transmissionUbo;
        if (ubo == null) {
            ubo = new GPUBuffer(BufferUsage.uniform, <u32>FRAME_BYTES);
            this.transmissionUbo = ubo;
        }
        const f = this.frameF32;
        const flag = (FRAME_SHADOW_PARAMS >> 2) + 2;
        const was = f[flag];
        f[flag] = 1;
        ubo.update(0, this.frameStaging);
        f[flag] = was;
        const env = this.frameEnvView != null ? this.frameEnvView! : this.white!;
        const shadow = this.frameShadowView != null ? this.frameShadowView! : this.dummyShadowView!;
        const tv = this.transmissionGroupViews;
        let group = this.transmissionGroup;
        if (group == null || tv[0] !== env || tv[1] !== shadow) {
            group = this.makeFrameGroup(this.frameLayout!, ubo, env, shadow, this.white!);
            this.transmissionGroup = group;
            tv[0] = env;
            tv[1] = shadow;
        }
        this.ensureTargets(this.transmissionTargets, <u32>TextureFormat.rgba16float, pw, ph, 1);
        const depth = this.transmissionTargets.depthView;
        if (depth == null) return;
        const savedFormat = this.pipelineFormat;
        const savedCount = this.pipelineCount;
        this.pipelineCount = 1;
        this.pipelineFormat = <u32>TextureFormat.rgba16float;
        const color = this.transmissionColor;
        color.view = view;
        color.loadOp = LoadOp.clear;
        color.storeOp = StoreOp.store;
        color.clearR = 0; color.clearG = 0; color.clearB = 0; color.clearA = 0;
        if (scene instanceof Scene) {
            const bg = (scene as Scene).background;
            if (bg != null && bg instanceof Color) {
                const k = (scene as Scene).backgroundIntensity;
                const bc = bg as Color;
                color.clearR = <f32>(bc.r * k); color.clearG = <f32>(bc.g * k); color.clearB = <f32>(bc.b * k);
                color.clearA = 1;
            }
        }
        const pd = this.transmissionDesc;
        pd.label = "three transmission";
        const attachments = this.transmissionAttachments;
        attachments.length = 0;
        attachments.push(color);
        pd.color = attachments;
        pd.depthView = depth;
        pd.depthLoadOp = LoadOp.clear;
        pd.depthStoreOp = StoreOp.discard;
        pd.depthClearValue = 1;
        const pass = canvas.beginRenderPass(pd);
        if (background) {
            // The background module reads the frame block for linear output.
            let bgGroup = this.transmissionBgGroup;
            if (bgGroup == null || this.transmissionBgView !== this.bgGroupView
                    || this.transmissionBgMipmapped != this.bgMipmapped) {
                bgGroup = new GPUBindGroup(this.backgroundLayout!, [new GPUBindGroupUBO(0, ubo)],
                    [new GPUBindGroupTexture(1, this.bgGroupView!)],
                    [new GPUBindGroupSampler(2, this.backgroundSampler(this.bgMipmapped))]);
                this.transmissionBgGroup = bgGroup;
                this.transmissionBgView = this.bgGroupView;
                this.transmissionBgMipmapped = this.bgMipmapped;
            }
            pass.setPipeline(this.pipeline(KEY_BACKGROUND));
            pass.setBindGroup(0, bgGroup!);
            pass.draw(3);
        }
        this.drawList(pass, this.opaque, group);
        pass.finish();
        this.pipelineFormat = savedFormat;
        this.pipelineCount = savedCount;
        // Its mip chain (drawn now, before the main pass).
        rt.texture.version++;
        this.transmissionView = this.textures.view(rt.texture, canvas);
    }

    /// The environment map (scene.environment, else the first material
    /// envMap seen) and the frame bind group that samples it.
    private prepareEnvironment(scene: Object3D, frame: i32, canvas: GPUCanvas): void {
        let env: Texture? = scene instanceof Scene ? (scene as Scene).environment : null;
        let view: GPUTextureView? = null;
        if (env != null) {
            env.generateMipmaps = true;
            if (env.minFilter != LinearMipmapLinearFilter) env.minFilter = LinearMipmapLinearFilter;
            this.textures.update(env, frame);
            view = this.textures.pmrem(env, canvas);
            this.envPrefiltered = view != null;
            if (view == null) view = this.textures.view(env, canvas);
        }
        this.envTexture = view != null ? env : null;
        this.envLevels = env != null && view != null
            ? (this.envPrefiltered ? this.textures.pmremLevels(env) : this.textures.levels(env)) : 1;
        const bind = view != null ? view! : this.white!;
        const shadow = this.tileCount > 0 && this.shadowView != null ? this.shadowView! : this.dummyShadowView!;
        this.frameEnvView = bind;
        this.frameShadowView = shadow;
        this.ensureFrameGroup();
        // The background pass's own group: the frame block and the texture.
        const bg = this.bgTexture != null && this.bgView != null ? this.bgView! : this.white!;
        if (this.bgGroup == null || this.bgGroupView !== bg || this.bgGroupMipmapped != this.bgMipmapped) {
            this.bgGroup = new GPUBindGroup(this.backgroundLayout!, [new GPUBindGroupUBO(0, this.frameUbo!)],
                [new GPUBindGroupTexture(1, bg)], [new GPUBindGroupSampler(2, this.backgroundSampler(this.bgMipmapped))]);
            this.bgGroupView = bg;
            this.bgGroupMipmapped = this.bgMipmapped;
        }
    }

    /// Assigns shadow map layers to the lights that cast shadows (directional
    /// and spot: one, point: six; at most MAX_SHADOW_TILES) and computes their
    /// light cameras.
    private planShadows(): void {
        this.tileCount = 0;
        this.lightFirstTile.clear();
        if (!this.shadowMap.enabled) return;
        let lightSlot = 0;
        let mapSize: f64 = 0;
        for (let i = 0; i < this.lights.length; i++) {
            const light = this.lights[i];
            const point = light instanceof PointLight;
            const directional = light instanceof DirectionalLight;
            const spot = light instanceof SpotLight;
            if (!directional && !spot && !point) continue;
            if (lightSlot++ >= MAX_LIGHTS) break;
            if (!light.castShadow) continue;
            const need = point ? 6 : 1;
            if (this.tileCount + need > MAX_SHADOW_TILES) continue;
            const first = this.tileCount;
            this.lightFirstTile.set(light.id, first);
            light.getWorldPosition(_pos);
            if (directional) {
                const d = light as DirectionalLight;
                const cam = d.shadow.camera;
                d.target.getWorldPosition(_dir);
                this.lookFrom(cam, _pos, _dir, 0, 1, 0);
                this.setTile(first, cam, d.shadow);
                mapSize = Math.max(mapSize, Math.max(d.shadow.mapSize.x, d.shadow.mapSize.y));
            } else if (spot) {
                const sl = light as SpotLight;
                const cam = sl.shadow.camera as PerspectiveCamera;
                cam.fov = 2 * sl.angle * sl.shadow.focus * 180 / Math.PI;
                cam.aspect = 1;
                if (sl.distance > 0) cam.far = sl.distance;
                cam.updateProjectionMatrix();
                sl.target.getWorldPosition(_dir);
                this.lookFrom(cam, _pos, _dir, 0, 1, 0);
                this.setTile(first, cam, sl.shadow);
                mapSize = Math.max(mapSize, Math.max(sl.shadow.mapSize.x, sl.shadow.mapSize.y));
            } else {
                const pl = light as PointLight;
                const cam = pl.shadow.camera as PerspectiveCamera;
                // A little over 90 degrees, so filter taps near a face's edge
                // stay inside it (the face is still picked by direction).
                cam.fov = 98;
                cam.aspect = 1;
                cam.updateProjectionMatrix();
                for (let f = 0; f < 6; f++) {
                    const axis = f / 2;
                    const sign: f64 = (f & 1) == 0 ? 1 : -1;
                    _dir.copy(_pos);
                    if (axis == 0) _dir.x += sign; else if (axis == 1) _dir.y += sign; else _dir.z += sign;
                    if (axis == 1) this.lookFrom(cam, _pos, _dir, 0, 0, sign);
                    else this.lookFrom(cam, _pos, _dir, 0, 1, 0);
                    this.setTile(first + f, cam, pl.shadow);
                }
                mapSize = Math.max(mapSize, Math.max(pl.shadow.mapSize.x, pl.shadow.mapSize.y));
            }
            this.tileCount += need;
        }
        if (this.tileCount > 0) {
            // The largest mapSize, halved until the layers fit 64 MB.
            let size = <u32>Math.max(256, Math.min(2048, mapSize));
            while (size > 256 && <f64>size * <f64>size * 4 * <f64>this.tileCount > 64 * 1024 * 1024) size >>= 1;
            this.ensureShadowTexture(size, <u32>this.tileCount);
        }
    }

    private lookFrom(cam: Camera, from: Vector3, to: Vector3, ux: f64, uy: f64, uz: f64): void {
        cam.position.copy(from);
        cam.up.set(ux, uy, uz);
        cam.lookAt(to);
        cam.updateMatrixWorld();
    }

    private setTile(index: i32, cam: Camera, shadow: LightShadow): void {
        while (this.tiles.length <= index) this.tiles.push(new ShadowTile());
        this.tiles[index].matrix.multiplyMatrices(cam.projectionMatrix, cam.matrixWorldInverse);
        shadow.matrix.copy(this.tiles[index].matrix);
    }

    private ensureShadowTexture(size: u32, layers: u32): void {
        const maxSize = this.context.features().maxTextureSize2D;
        if (size > maxSize) size = maxSize;
        if (this.shadowTex != null && this.shadowSize == size && this.shadowLayers >= layers) return;
        if (!this.context.features().textureArrays) {
            if (!this.shadowsWarned) {
                this.context.log("three: shadows disabled: texture arrays are not supported here");
                this.shadowsWarned = true;
            }
            this.tileCount = 0;
            return;
        }
        releaseTex(this.shadowTex);
        const d = new GPUTextureDesc();
        d.width = size;
        d.height = size;
        d.depthOrArrayLayers = max<u32>(layers, this.shadowLayers);
        d.format = TextureFormat.depth32float;
        d.textureType = TextureType.array2D;
        d.renderTarget = true;
        const tex = new GPUTexture(d);
        this.shadowTex = tex;
        this.shadowSize = size;
        this.shadowLayers = d.depthOrArrayLayers;
        const sv = new GPUTextureViewDesc();
        sv.dimension = TextureViewDimension.array2D;
        sv.aspect = TextureAspect.depthOnly;
        this.shadowView = tex.view(sv);
        this.shadowLayerViews = [];
        for (let i: u32 = 0; i < this.shadowLayers; i++) {
            const lv = new GPUTextureViewDesc();
            lv.dimension = TextureViewDimension.texture2D;
            lv.baseLayer = i;
            lv.layerCount = 1;
            this.shadowLayerViews.push(tex.view(lv));
        }
    }

    /// The depth passes: every caster, once per shadow layer.
    private renderShadows(canvas: GPUCanvas, frame: i32): void {
        if (this.tileCount == 0 || this.shadowTex == null) return;
        if (!this.shadowMap.autoUpdate && !this.shadowMap.needsUpdate) return;
        this.shadowMap.needsUpdate = false;
        // Caster draws share the main draws' per-object blocks.
        const items = this.casterItems;
        items.length = 0;
        for (let i = 0; i < this.casterMeshes.length; i++) this.collectCaster(this.casterMeshes[i], frame, items);
        this.writeDraws(items, frame, canvas);
        this.joinMorphJobs();
        // A frame block per layer, holding its view-projection.
        while (this.tileUbos.length < this.tileCount) {
            const ubo = new GPUBuffer(BufferUsage.uniform, <u32>FRAME_BYTES);
            this.tileUbos.push(ubo);
            this.tileGroups.push(this.makeFrameGroup(this.frameLayout!, ubo, this.white!, this.dummyShadowView!, this.white!));
        }
        for (let t = 0; t < this.tileCount; t++) {
            this.tiles[t].matrix.mat4.writeToBuffer(this.tileStaging, FRAME_VIEW_PROJ);
            this.tileUbos[t].update(0, this.tileStaging, 64);
            const pd = this.shadowPassDesc;
            pd.label = "three shadow";
            pd.color = this.noAttachments;
            pd.depthView = this.shadowLayerViews[t];
            pd.depthLoadOp = LoadOp.clear;
            pd.depthStoreOp = StoreOp.store;
            pd.depthClearValue = 1;
            const pass = canvas.beginRenderPass(pd);
            let lastKey = -1;
            for (let i = 0; i < items.length; i++) {
                const item = items[i];
                const g = item.geometry!;
                const state = item.state;
                if (state.frame != frame) continue;
                const key = item.pipelineKey;
                if (key != lastKey) {
                    pass.setPipeline(this.shadowPipeline(key));
                    pass.setBindGroup(0, this.tileGroups[t]);
                    lastKey = key;
                }
                pass.setBindGroup(1, this.objGroupOf(item), this.dynamicOffsets);
                if ((key & (KEY_DISPLACED | KEY_CUTOUT_SHADOW)) != 0) {
                    if (state.matGroup == null || state.samplerGroup == null) continue;
                    pass.setBindGroup(2, state.matGroup!);
                    pass.setBindGroup(3, state.samplerGroup!);
                }
                const pos = item.positionOverride;
                pass.setVertexBuffer(0, pos != null ? pos : g.position!);
                pass.setVertexBuffer(1, g.normal!);
                pass.setVertexBuffer(2, g.uv!);
                pass.setVertexBuffer(3, g.color!);
                pass.setVertexBuffer(4, item.instances, item.instanceFirst * <u32>INSTANCE_MATRIX_STRIDE);
                pass.setVertexBuffer(5, item.instanceColors, item.instanceFirst * <u32>INSTANCE_COLOR_STRIDE);
                pass.setVertexBuffer(6, g.uv1!);
                if (item.skinned) {
                    pass.setVertexBuffer(7, g.skin!);
                } else if (item.morphRows != null) {
                    pass.setVertexBuffer(7, item.morphRows!);
                }
                const index = item.index;
                if (index != null) {
                    pass.setIndexBuffer(index, item.indexFormat);
                    pass.drawIndexed(<u32>item.count, item.instanceCount, <u32>item.first);
                } else {
                    pass.draw(<u32>item.count, item.instanceCount, <u32>item.first);
                }
            }
            pass.finish();
        }
    }

    /// Shadow draws of a caster (triangles only), with its deformation.
    private collectCaster(mesh: Mesh, frame: i32, out: Array<DrawItem>): void {
        const geometry = mesh.geometry;
        const g = this.geometries.get(geometry, frame);
        if (g == null) return;
        // customDepthMaterial (or customDistanceMaterial) stands in.
        let custom = mesh.customDepthMaterial;
        if (custom == null) custom = mesh.customDistanceMaterial;
        const material = custom != null ? custom! : mesh.material;
        let instances = this.identityInstance!;
        let colors = this.identityColor!;
        let instanceCount: u32 = 1;
        if (mesh instanceof InstancedMesh) {
            const im = mesh as InstancedMesh;
            if (im.count <= 0) return;
            const ig = this.instanceBuffer(im);
            instances = ig.matrices!;
            colors = ig.colors!;
            instanceCount = <u32>im.count;
        }
        // Its own object block when another material stands in.
        const state = this.stateOf(mesh.id * 64 + (custom != null ? 63 : 0));
        if (custom != null) this.prepareMaterial(state, custom, frame);
        const item = this.newItem(mesh, material, g, state, instances, colors);
        item.instanceCount = instanceCount;
        item.first = 0;
        item.count = g.count;
        if (g.indexed) {
            item.index = g.index;
            item.indexFormat = <u32>g.indexFormat;
        }
        // three.js renders back faces of front-sided casters (shadowSide
        // picks the side itself).
        const side = material.side;
        const shadowSide = material.shadowSide;
        if (shadowSide >= 0) item.pipelineKey = shadowSide == DoubleSide ? 1 : shadowSide == BackSide ? 2 : 0;
        else item.pipelineKey = side == DoubleSide ? 1 : side == BackSide ? 0 : 2;
        if (material.alphaTest > 0 || material.alphaHash || material.alphaToCoverage) item.pipelineKey |= KEY_CUTOUT_SHADOW;
        if (material.displacementMapOf() != null) item.pipelineKey |= KEY_DISPLACED;
        const clips = material.clipShadows && ((this.localClippingEnabled && material.clippingPlanes != null
            && material.clippingPlanes!.length > 0) || this.clippingPlanes.length > 0);
        if (clips) item.pipelineKey |= KEY_CLIP_SHADOW;
        if (mesh instanceof BatchedMesh) {
            const bm = mesh as BatchedMesh;
            const bg = this.batchedBuffer(bm);
            for (let k = 0; k < bg.count.length; k++) {
                if (bg.count[k] == 0) continue;
                const info = bm.geometryInfo[k];
                const part = this.newItem(mesh, material, g, state, bg.matrices!, bg.colors!);
                part.pipelineKey = item.pipelineKey;
                part.index = item.index;
                part.indexFormat = item.indexFormat;
                part.first = g.indexed ? info.indexStart : info.vertexStart;
                part.count = g.indexed ? info.indexCount : info.vertexCount;
                part.instanceCount = <u32>bg.count[k];
                part.instanceFirst = <u32>bg.first[k];
                out.push(part);
            }
            return;
        }
        this.deform(mesh, geometry, g, item, frame);
        out.push(item);
    }

    private shadowPipeline(key: i32): GPUPipeline {
        if (this.shadowPipelines.has(key)) return this.shadowPipelines.get(key);
        const ds = new GPUDepthStencilDesc();
        ds.format = TextureFormat.depth32float;
        ds.compare = CompareFunction.lessEqual;
        ds.write = true;
        ds.depthBias = 2;
        ds.depthBiasSlopeScale = 1.5;
        const d = new GPUPipelineDesc();
        d.vertexModule = this.module;
        const skinned = (key & KEY_SKINNED) != 0;
        const displaced = (key & KEY_DISPLACED) != 0;
        const rows = (key & KEY_MORPH_INSTANCED) != 0;
        d.vertexEntryPoint = (skinned ? "vs_skinned" : rows ? "vs_morph_instanced" : "vs_main")
            + (displaced ? "_displaced" : "");
        d.colorTargets = [];
        const cutout = (key & KEY_CUTOUT_SHADOW) != 0;
        if (cutout) {
            d.fragmentModule = this.module;
            d.fragmentEntryPoint = "fs_shadow_cutout";
        } else if ((key & KEY_CLIP_SHADOW) != 0) {
            d.fragmentModule = this.module;
            d.fragmentEntryPoint = "fs_clip";
        }
        d.vertexBuffers = skinned ? this.skinBuffers : rows ? this.morphRowBuffers : this.vertexBuffers;
        d.bindGroupLayouts = displaced || cutout ? [this.frameLayout, this.objLayout, this.matLayout, this.samplerLayout]
            : [this.frameLayout, this.objLayout];
        const cull = key & KEY_CULL_MASK;
        d.cullMode = cull == 0 ? CullMode.back : cull == 2 ? CullMode.front : CullMode.none;
        d.winding = FaceWinding.counterClockwise;
        d.depthStencil = ds;
        d.sampleCount = 1;
        const p = new GPUPipeline(d);
        this.shadowPipelines.set(key, p);
        return p;
    }

    private backgroundSampler(mipmapped: bool): GPUSampler {
        const key = mipmapped ? -3 : -2;
        if (this.samplers.has(key)) return this.samplers.get(key);
        const s = new GPUSampler(Filter.linear, Filter.linear, Filter.linear, WrapMode.repeat, WrapMode.clampToEdge,
            <CompareFunction>0xFFFFFFFF, 1, 0, mipmapped ? 32 : 0);
        this.samplers.set(key, s);
        return s;
    }

    // ------------------------------------------------------------- uniforms

    private writeFrame(scene: Object3D, camera: Camera): void {
        const buf = this.frameStaging;
        const f = this.frameF32;
        const u = this.frameU32;
        this.viewProj.mat4.writeToBuffer(buf, FRAME_VIEW_PROJ);
        camera.matrixWorldInverse.mat4.writeToBuffer(buf, FRAME_VIEW);
        this.invViewProj.mat4.writeToBuffer(buf, FRAME_INV_VIEW_PROJ);
        camera.projectionMatrix.mat4.writeToBuffer(buf, FRAME_PROJ);
        // w: logarithmic depth's 1 / log2(far + 1) (0: off; orthographic too, as three.js).
        let logFc: f64 = 0;
        if (this.logDepth) {
            const far = camera instanceof PerspectiveCamera ? (camera as PerspectiveCamera).far : 0;
            if (far > 0) logFc = 1 / Math.log2(far + 1);
        }
        put4(f, FRAME_VIEWPORT, <f64>this.vpW, <f64>this.vpH, this.passRatio, logFc);
        const cw = camera.matrixWorld.elements;
        let o = FRAME_CAMERA_POS >> 2;
        f[o] = cw[12]; f[o + 1] = cw[13]; f[o + 2] = cw[14];
        f[o + 3] = camera instanceof OrthographicCamera ? 1 : 0;
        camera.getWorldDirection(_dir);
        o = FRAME_CAMERA_DIR >> 2;
        f[o] = <f32>_dir.x; f[o + 1] = <f32>_dir.y; f[o + 2] = <f32>_dir.z; f[o + 3] = 0;

        // Lights.
        const probe = _probe;
        probe.fill(0);
        let ar: f64 = 0, ag: f64 = 0, ab: f64 = 0;
        let sr: f64 = 0, sg: f64 = 0, sb: f64 = 0, gr: f64 = 0, gg: f64 = 0, gb: f64 = 0;
        let hemi = false;
        let count = 0;
        const lights = this.lights;
        for (let i = 0; i < lights.length; i++) {
            const light = lights[i];
            const k = light.intensity;
            if (light instanceof AmbientLight) {
                ar += light.color.r * k; ag += light.color.g * k; ab += light.color.b * k;
                continue;
            }
            if (light instanceof HemisphereLight) {
                const h = light as HemisphereLight;
                sr += h.color.r * k; sg += h.color.g * k; sb += h.color.b * k;
                gr += h.groundColor.r * k; gg += h.groundColor.g * k; gb += h.groundColor.b * k;
                if (!hemi) {
                    h.getWorldPosition(_hemiDir);
                    _hemiDir.normalize();
                    hemi = true;
                }
                continue;
            }
            if (light instanceof LightProbe) {
                const c = (light as LightProbe).sh.coefficients;
                for (let j = 0; j < 9; j++) {
                    const pb = (FRAME_PROBE >> 2) + j * 4;
                    probe[j * 3] += c[j].x * k; probe[j * 3 + 1] += c[j].y * k; probe[j * 3 + 2] += c[j].z * k;
                    f[pb + 3] = 0;
                }
                continue;
            }
            const directional = light instanceof DirectionalLight;
            const spot = light instanceof SpotLight;
            const rect = light instanceof RectAreaLight;
            if (!directional && !spot && !rect && !(light instanceof PointLight)) continue;
            if (count >= MAX_LIGHTS) {
                if (!this.warnedLights) {
                    this.context.log("three: more than " + MAX_LIGHTS.toString() + " lights; the rest are ignored");
                    this.warnedLights = true;
                }
                continue;
            }
            const base = (FRAME_LIGHTS + count * LIGHT_BYTES) >> 2;
            this.writeLightShadow(f, base, light);
            light.getWorldPosition(_pos);
            // For per-object culling: position, reach (-1: everywhere) and a
            // brightness to rank by.
            const fl = this.frameLights;
            fl[count * 5] = _pos.x; fl[count * 5 + 1] = _pos.y; fl[count * 5 + 2] = _pos.z;
            const reach = directional || rect ? -1 : spot ? (light as SpotLight).distance : (light as PointLight).distance;
            fl[count * 5 + 3] = reach > 0 ? reach : -1;
            fl[count * 5 + 4] = k * Math.max(light.color.r, Math.max(light.color.g, light.color.b));
            if (directional) fl[count * 5 + 4] = Infinity;
            f[base] = <f32>_pos.x; f[base + 1] = <f32>_pos.y; f[base + 2] = <f32>_pos.z;
            f[base + 8] = <f32>(light.color.r * k);
            f[base + 9] = <f32>(light.color.g * k);
            f[base + 10] = <f32>(light.color.b * k);
            f[base + 13] = 0; f[base + 14] = 0; f[base + 15] = 0;
            if (rect) {
                // Half extents along the light's world axes (three.js's
                // halfWidth / halfHeight, rotation only).
                const ra = light as RectAreaLight;
                _rectRot.extractRotation(light.matrixWorld);
                _dir.set(ra.width * 0.5, 0, 0).applyMatrix4(_rectRot);
                f[base + 3] = LIGHT_RECT;
                f[base + 4] = <f32>_dir.x; f[base + 5] = <f32>_dir.y; f[base + 6] = <f32>_dir.z; f[base + 7] = 0;
                _dir.set(0, ra.height * 0.5, 0).applyMatrix4(_rectRot);
                f[base + 11] = 0;
                f[base + 12] = <f32>_dir.x; f[base + 13] = <f32>_dir.y; f[base + 14] = <f32>_dir.z; f[base + 15] = 0;
            } else if (directional) {
                f[base + 3] = LIGHT_DIRECTIONAL;
                (light as DirectionalLight).target.getWorldPosition(_dir);
                _dir.subVectors(_pos, _dir).normalize();
                f[base + 4] = <f32>_dir.x; f[base + 5] = <f32>_dir.y; f[base + 6] = <f32>_dir.z; f[base + 7] = 0;
                f[base + 11] = 0;
                f[base + 12] = 0;
            } else if (spot) {
                const s = light as SpotLight;
                f[base + 3] = LIGHT_SPOT;
                s.target.getWorldPosition(_dir);
                _dir.subVectors(_pos, _dir).normalize();
                f[base + 4] = <f32>_dir.x; f[base + 5] = <f32>_dir.y; f[base + 6] = <f32>_dir.z;
                f[base + 7] = <f32>Math.cos(s.angle);
                f[base + 11] = <f32>s.distance;
                f[base + 12] = <f32>s.decay;
                f[base + 13] = <f32>Math.cos(s.angle * (1 - s.penumbra));
            } else {
                const p = light as PointLight;
                f[base + 3] = LIGHT_POINT;
                f[base + 4] = 0; f[base + 5] = 0; f[base + 6] = 0; f[base + 7] = 0;
                f[base + 11] = <f32>p.distance;
                f[base + 12] = <f32>p.decay;
            }
            this.frameLightTypes[count] = <i32>f[base + 3];
            count++;
        }
        o = FRAME_AMBIENT >> 2;
        f[o] = <f32>ar; f[o + 1] = <f32>ag; f[o + 2] = <f32>ab; f[o + 3] = <f32>count;
        this.frameLightCount = count;
        for (let j = 0; j < 9; j++) {
            const pb = (FRAME_PROBE >> 2) + j * 4;
            f[pb] = <f32>probe[j * 3]; f[pb + 1] = <f32>probe[j * 3 + 1]; f[pb + 2] = <f32>probe[j * 3 + 2]; f[pb + 3] = 0;
        }
        o = FRAME_HEMI_SKY >> 2;
        f[o] = <f32>sr; f[o + 1] = <f32>sg; f[o + 2] = <f32>sb; f[o + 3] = 0;
        o = FRAME_HEMI_GROUND >> 2;
        f[o] = <f32>gr; f[o + 1] = <f32>gg; f[o + 2] = <f32>gb; f[o + 3] = 0;
        o = FRAME_HEMI_DIR >> 2;
        f[o] = <f32>_hemiDir.x; f[o + 1] = <f32>_hemiDir.y; f[o + 2] = <f32>_hemiDir.z; f[o + 3] = hemi ? 1 : 0;

        // Fog.
        o = FRAME_FOG_COLOR >> 2;
        f[o + 3] = 0;
        if (scene instanceof Scene) {
            const fog = (scene as Scene).fog;
            if (fog != null) {
                f[o] = <f32>fog.color.r; f[o + 1] = <f32>fog.color.g; f[o + 2] = <f32>fog.color.b;
                const p = FRAME_FOG_PARAMS >> 2;
                if (fog instanceof Fog) {
                    f[o + 3] = FOG_LINEAR;
                    f[p] = <f32>(fog as Fog).near; f[p + 1] = <f32>(fog as Fog).far; f[p + 2] = 0;
                } else if (fog instanceof FogExp2) {
                    f[o + 3] = FOG_EXP2;
                    f[p] = 0; f[p + 1] = 0; f[p + 2] = <f32>(fog as FogExp2).density;
                }
            }
        }

        // Output and background.
        o = FRAME_OUTPUT >> 2;
        f[o] = <f32>this.toneMapping;
        f[o + 1] = <f32>this.toneMappingExposure;
        const bt = this.bgTexture;
        if (bt != null && scene instanceof Scene) {
            const s = scene as Scene;
            f[o + 2] = <f32>s.backgroundIntensity;
            const levels = this.bgPrefiltered ? this.textures.pmremLevels(bt) : this.textures.levels(bt);
            f[o + 3] = <f32>(Math.max(0, Math.min(1, s.backgroundBlurriness)) * <f64>(levels - 1));
            _euler.set(-s.backgroundRotation.x, -s.backgroundRotation.y, -s.backgroundRotation.z,
                s.backgroundRotation.order);
            _bgRotation.makeRotationFromEuler(_euler);
            _bgRotation.mat4.writeToBuffer(buf, FRAME_BG_ROTATION);
            const b = FRAME_BG_FLAGS >> 2;
            const cube = bt instanceof CubeTexture || this.bgPrefiltered;
            const equirect = cube || bt.mapping == EquirectangularReflectionMapping
                || bt.mapping == EquirectangularRefractionMapping;
            u[b] = equirect ? <u32>EquirectangularReflectionMapping : 0;
            // Cube textures sample their conversion: linear, straight, top row first.
            u[b + 1] = !cube && bt.colorSpace == SRGBColorSpace ? 1 : 0;
            u[b + 2] = cube || bt.flipY ? 1 : 0;
            u[b + 3] = !cube && bt.premultiplyAlpha ? 1 : 0;
        }
        // Shadow layers.
        o = FRAME_SHADOW_PARAMS >> 2;
        const type = this.shadowMap.type;
        f[o] = type == BasicShadowMap ? 0 : type == PCFShadowMap ? 1 : 2;
        f[o + 1] = this.shadowSize > 0 ? <f32>(1.0 / <f64>this.shadowSize) : 0;
        f[o + 2] = this.linearOutput ? 1 : 0;   // HDR target: no tone mapping, no sRGB
        for (let t = 0; t < this.tileCount; t++) {
            this.tiles[t].matrix.mat4.writeToBuffer(buf, FRAME_SHADOW_TILES + t * SHADOW_TILE_BYTES);
        }

        // Environment.
        o = FRAME_ENV >> 2;
        const et = this.envTexture;
        if (et != null) {
            const intensity = scene instanceof Scene ? (scene as Scene).environmentIntensity : 1;
            f[o] = 1; f[o + 1] = <f32>intensity;
            f[o + 2] = <f32>(this.envPrefiltered ? <f64>this.envLevels - 1 : Math.max(0, <f64>this.envLevels - 2));
            f[o + 3] = this.envPrefiltered ? 1 : 0;
            if (scene instanceof Scene) {
                const r = (scene as Scene).environmentRotation;
                _euler.set(-r.x, -r.y, -r.z, r.order);
            } else {
                _euler.set(0, 0, 0);
            }
            _bgRotation.makeRotationFromEuler(_euler);
            _bgRotation.mat4.writeToBuffer(buf, FRAME_ENV_ROTATION);
            const b = FRAME_ENV_FLAGS >> 2;
            const cube = et instanceof CubeTexture || this.envPrefiltered;
            u[b] = !cube && et.colorSpace == SRGBColorSpace ? 1 : 0;
            u[b + 1] = cube || et.flipY ? 1 : 0;
            u[b + 2] = !cube && et.premultiplyAlpha ? 1 : 0;
            u[b + 3] = 0;
        } else {
            f[o] = 0;
        }
        // The frame's share of the program key: fog type, hemisphere light,
        // scene environment, linear output.
        this.frameVariantBits = <i32>f[(FRAME_FOG_COLOR >> 2) + 3] | (f[(FRAME_HEMI_DIR >> 2) + 3] > 0.5 ? 4 : 0)
            | (f[FRAME_ENV >> 2] > 0.5 ? 8 : 0) | (f[(FRAME_SHADOW_PARAMS >> 2) + 2] > 0.5 ? 16 : 0);
        this.frameUbo!.update(0, buf);
    }

    /// A light's shadow fields (Light.shadow, Light.shadow2 in the shader).
    private writeLightShadow(f: Float32Array, base: i32, light: Light): void {
        const s = base + 16;
        f[s] = -1; f[s + 1] = 0; f[s + 2] = 0; f[s + 3] = 1;
        f[s + 4] = 0; f[s + 5] = 0; f[s + 6] = 0; f[s + 7] = 0;
        if (light instanceof DirectionalLight) {
            const d = light as DirectionalLight;
            f[s + 6] = <f32>d.cascadeNear;
            f[s + 7] = <f32>d.cascadeFar;
        }
        if (!this.lightFirstTile.has(light.id)) return;
        let shadow: LightShadow;
        if (light instanceof DirectionalLight) shadow = (light as DirectionalLight).shadow;
        else if (light instanceof SpotLight) shadow = (light as SpotLight).shadow;
        else shadow = (light as PointLight).shadow;
        f[s] = <f32>this.lightFirstTile.get(light.id);
        f[s + 1] = <f32>shadow.bias;
        f[s + 2] = <f32>shadow.normalBias;
        f[s + 3] = <f32>(this.shadowMap.type == BasicShadowMap ? 1 : shadow.radius);
        f[s + 4] = <f32>shadow.intensity;
        f[s + 5] = light instanceof PointLight ? 1 : 0;
    }

    /// Room for `count` more slots in the arena: grows it (keeping every
    /// slot's block, uploaded whole at the next flush).
    private reserveArena(count: i32): void {
        const need = this.slotCount + count;
        if (need <= this.arenaCapacity && this.arena != null) return;
        let capacity = max<i32>(64, this.arenaCapacity);
        while (capacity < need) capacity *= 2;
        const staging = new ArrayBuffer(capacity * OBJ_BYTES);
        const bytes = Uint8Array.wrap(staging);
        if (this.slotCount > 0) bytes.set(this.arenaBytes.subarray(0, this.slotCount * OBJ_BYTES));
        const dirty = new Uint8Array(capacity);
        if (this.slotDirty.length > 0) dirty.set(this.slotDirty);
        this.slotDirty = dirty;
        this.arenaStaging = staging;
        this.arenaBytes = bytes;
        this.arenaF32 = Float32Array.wrap(staging);
        this.arenaU32 = Uint32Array.wrap(staging);
        // The old buffer may still be bound by passes recorded this frame:
        // it is left to the collector, not released.
        this.arena = new GPUBuffer(BufferUsage.uniform, <u32>(capacity * OBJ_BYTES));
        this.arenaCapacity = capacity;
        this.arenaGroup = null;
        this.uploadAll = true;
    }

    /// Marks a slot for upload at the next flush.
    private markSlot(slot: i32): void {
        unchecked(this.slotDirty[slot] = 1);
        if (slot < this.dirtyLo) this.dirtyLo = slot;
        if (slot > this.dirtyHi) this.dirtyHi = slot;
    }

    /// Uploads the slots written since the last flush: runs of them (short
    /// gaps included) as one update each, or everything after the arena grew.
    private flushArena(): void {
        const arena = this.arena;
        if (arena == null) return;
        const staging = this.arenaStaging;
        const dirty = this.slotDirty;
        if (this.uploadAll) {
            if (this.slotCount > 0) arena.update(0, staging, <u32>(this.slotCount * OBJ_BYTES), 0);
            if (this.dirtyHi >= this.dirtyLo) dirty.fill(0, this.dirtyLo, this.dirtyHi + 1);
        } else if (this.dirtyHi >= this.dirtyLo) {
            const hi = this.dirtyHi;
            let s = this.dirtyLo;
            while (s <= hi) {
                if (unchecked(dirty[s]) == 0) { s++; continue; }
                // A run: dirty slots with gaps of at most two clean ones.
                let end = s;
                let k = s + 1;
                while (k <= hi && k - end <= 3) {
                    if (unchecked(dirty[k]) != 0) end = k;
                    k++;
                }
                for (let j = s; j <= end; j++) unchecked(dirty[j] = 0);
                const offset = <u32>(s * OBJ_BYTES);
                arena.update(offset, staging, <u32>((end - s + 1) * OBJ_BYTES), offset);
                s = end + 1;
            }
        }
        this.uploadAll = false;
        this.dirtyLo = 0x7fffffff;
        this.dirtyHi = -1;
    }

    /// The group 1 of a draw: the shared arena group, or for a skinned
    /// draw one with its bones (both read the block at state.objOffset).
    /// Sets `dynamicOffsets` (its object block, its morph block).
    private objGroupOf(item: DrawItem): GPUBindGroup {
        const arena = this.arena!;
        const state = item.state;
        const offsets = this.dynamicOffsets;
        unchecked(offsets[0] = state.objOffset);
        unchecked(offsets[1] = item.morphed ? item.morphOffset : 0);
        const skinned = item.skinned && item.bones != null;
        const morph = item.morphed ? this.morphArena! : this.dummyMorph!;
        if (!skinned && state.xcount == 0 && !item.morphed) {
            let g = this.arenaGroup;
            if (g == null) {
                const white = this.white!;
                g = new GPUBindGroup(this.objLayout!, [new GPUBindGroupUBO(0, arena, 0, <u32>OBJ_BYTES),
                    new GPUBindGroupUBO(1, this.dummyBones!), new GPUBindGroupUBO(7, this.dummyMorph!, 0, <u32>MORPH_BYTES)],
                    extraTextures(null, white));
                this.arenaGroup = g;
            }
            return g;
        }
        // Its own group: bones, morphs and/or extra maps.
        const bones = skinned ? item.bones! : this.dummyBones!;
        let changed = state.objGroup == null || state.arena !== arena || state.bones !== bones || state.morph !== morph;
        for (let i = 0; i < EXTRA_SLOTS && !changed; i++) changed = state.xgroupViews[i] !== state.xviews[i];
        if (changed) {
            const oldObj = state.objGroup;
            if (oldObj != null && oldObj !== this.arenaGroup) oldObj.release();
            state.objGroup = new GPUBindGroup(this.objLayout!, [new GPUBindGroupUBO(0, arena, 0, <u32>OBJ_BYTES),
                new GPUBindGroupUBO(1, bones), new GPUBindGroupUBO(7, morph, 0, <u32>MORPH_BYTES)],
                extraTextures(state.xviews, this.white!));
            state.arena = arena;
            state.bones = bones;
            state.morph = morph;
            for (let i = 0; i < EXTRA_SLOTS; i++) state.xgroupViews[i] = state.xviews[i];
        }
        return state.objGroup!;
    }

    /// A `lights: true` ShaderMaterial's group 0: the frame block (the pass's
    /// own in the transmission pass) and every frame texture.
    private customFullGroup(cp: CustomPipeline, frameGroup: GPUBindGroup): GPUBindGroup {
        if (frameGroup !== this.frameGroup) return frameGroup;
        const env = this.frameEnvView != null ? this.frameEnvView! : this.white!;
        const shadow = this.frameShadowView != null ? this.frameShadowView! : this.dummyShadowView!;
        const tr = this.transmissionView != null ? this.transmissionView! : this.white!;
        const v = cp.fullViews;
        if (cp.fullGroup == null || v[0] !== env || v[1] !== shadow || v[2] !== tr) {
            cp.fullGroup = this.makeFrameGroup(cp.layout0, this.frameUbo!, env, shadow, tr);
            v[0] = env; v[1] = shadow; v[2] = tr;
        }
        return cp.fullGroup!;
    }

    /// A ShaderMaterial pipeline's group 1 over the arena.
    private customObjGroup(cp: CustomPipeline): GPUBindGroup {
        const arena = this.arena!;
        if (cp.objGroup == null || cp.objArena !== arena) {
            cp.objGroup = new GPUBindGroup(cp.layout1, [new GPUBindGroupUBO(0, arena, 0, <u32>OBJ_BYTES)]);
            cp.objArena = arena;
        }
        return cp.objGroup!;
    }

    /// The extra maps (MaterialUniforms roles) of a draw: distinct textures
    /// get the six extra slots (group 1 bindings 2-7), each with its uv
    /// transform and a sampler borrowed from group 3 (an identical one, or
    /// the binding of an empty base slot).
    /// Writes into a material block: `variant` says which slots the draw's
    /// vertex textures borrow (1 morph texture, 2 bone texture, 4 instance
    /// morphs), whose views each draw sets itself.
    private writeExtraMaps(b: MaterialBlock, variant: i32, mu: MaterialUniforms, f: Float32Array, u: Uint32Array,
                           present: u32, canvas: GPUCanvas): void {
        const samplers = _samplers;
        let xpresent: u32 = 0, xsrgb: u32 = 0, xpremul: u32 = 0, xflip: u32 = 0;
        let roles0: u32 = 0xffffffff, roles1: u32 = 0xffffffff;
        let used: u32 = 0;            // extra slots taken
        let count = 0;
        for (let i = 0; i < EXTRA_SLOTS; i++) {
            b.xviews[i] = null;
            _xtex[i] = null;
        }
        // Vertex data borrows its slots first (read with textureLoad).
        if ((variant & 1) != 0) { used |= <u32>1 << <u32>X_SLOT_MORPH; count++; }
        if ((variant & 2) != 0) { used |= <u32>1 << <u32>X_SLOT_BONES; count++; }
        if ((variant & 4) != 0) { used |= <u32>1 << <u32>X_SLOT_MORPH_INSTANCES; count++; }
        for (let r = 0; r < ROLE_COUNT; r++) {
            const t = mu.roles[r];
            if (t == null) continue;
            let slot = -1;
            for (let k = 0; k < EXTRA_SLOTS; k++) if (_xtex[k] === t) slot = k;
            if (slot < 0) {
                if (used == (1 << EXTRA_SLOTS) - 1) {
                    if (!this.warnedExtraMaps) {
                        this.context.log("three: a material uses more than " + EXTRA_SLOTS.toString()
                            + " distinct extra maps; the rest are ignored");
                        this.warnedExtraMaps = true;
                    }
                    continue;
                }
                const v = this.textures.view(t, canvas);
                if (v == null) continue;
                // Extra slot k samples with base slot k's sampler: take a
                // slot whose base sampler matches or is free (its base slot
                // empty), else any (that map then shares the base sampler).
                const smp = this.sampler(t, this.textures.levels(t) > 1);
                for (let k = 0; k < EXTRA_SLOTS && slot < 0; k++) {
                    if (((used >> <u32>k) & 1) == 0 && ((present >> <u32>k) & 1) != 0 && samplers[k] === smp) slot = k;
                }
                for (let k = 0; k < EXTRA_SLOTS && slot < 0; k++) {
                    if (((used >> <u32>k) & 1) == 0 && ((present >> <u32>k) & 1) == 0) slot = k;
                }
                for (let k = 0; k < EXTRA_SLOTS && slot < 0; k++) if (((used >> <u32>k) & 1) == 0) slot = k;
                if (((present >> <u32>slot) & 1) == 0) samplers[slot] = smp;
                used |= <u32>1 << <u32>slot;
                count++;
                _xtex[slot] = t;
                b.xviews[slot] = v;
                const bit: u32 = 1 << <u32>slot;
                xpresent |= bit;
                if (t.colorSpace == SRGBColorSpace) xsrgb |= bit;
                if (t.premultiplyAlpha) xpremul |= bit;
                if (t.flipY) xflip |= bit;
                if (t.matrixAutoUpdate) t.updateMatrix();
                const e = t.matrix.elements;
                const o = (OBJ_X_UV >> 2) + slot * 8;
                f[o] = <f32>e[0]; f[o + 1] = <f32>e[3]; f[o + 2] = <f32>e[6]; f[o + 3] = t.channel > 0 ? 1 : 0;
                f[o + 4] = <f32>e[1]; f[o + 5] = <f32>e[4]; f[o + 6] = <f32>e[7]; f[o + 7] = 0;
            }
            const shift = <u32>((r & 7) * 4);
            if (r < 8) roles0 = (roles0 & ~(<u32>0xf << shift)) | (<u32>slot << shift);
            else roles1 = (roles1 & ~(<u32>0xf << shift)) | (<u32>slot << shift);
        }
        b.xcount = count;
        let o = OBJ_X_FLAGS >> 2;
        u[o] = xpresent; u[o + 1] = xsrgb; u[o + 2] = xpremul; u[o + 3] = xflip;
        o = OBJ_X_ROLES >> 2;
        // z (the geometry has tangents) is the draw's.
        u[o] = roles0; u[o + 1] = roles1; u[o + 2] = 0; u[o + 3] = 0;
        put4(f, OBJ_X_PARAMS, mu.bumpScale, mu.displacementScale, mu.displacementBias, mu.lightMapIntensity);
        put4(f, OBJ_X_PARAMS2, <f64>mu.normalMapType, <f64>mu.combine, mu.reflectivity, mu.refractionRatio);
        const env = mu.textures[SLOT_ENV];
        const refract = env != null && (env.mapping == CubeRefractionMapping || env.mapping == EquirectangularRefractionMapping);
        put4(f, OBJ_X_PARAMS3, mu.clearcoatNormalScaleX, mu.clearcoatNormalScaleY, refract ? 1 : 0, 0);
    }

    /// Clipping planes: the renderer's, then the material's (when
    /// localClippingEnabled); clipIntersection makes the material's an
    /// intersection (three.js's clipping_planes_fragment).
    private writeClipping(f: Float32Array, m: Material): void {
        let n = 0;
        const global = this.clippingPlanes;
        for (let i = 0; i < global.length && n < MAX_CLIP_PLANES; i++) {
            const p = global[i];
            put4(f, OBJ_CLIP_PLANES + n * 16, p.normal.x, p.normal.y, p.normal.z, p.constant);
            n++;
        }
        let union = n;
        const local = this.localClippingEnabled && !(m instanceof ShaderMaterial) ? m.clippingPlanes : null;
        if (local != null) {
            for (let i = 0; i < local.length && n < MAX_CLIP_PLANES; i++) {
                const p = local[i];
                put4(f, OBJ_CLIP_PLANES + n * 16, p.normal.x, p.normal.y, p.normal.z, p.constant);
                n++;
            }
            if (!m.clipIntersection) union = n;
        }
        put4(f, OBJ_CLIP, <f64>union, <f64>n, 0, 0);
    }

    /// The lights reaching `object`: those whose range meets its world
    /// bounding sphere (all when unknown), the strongest first, at most
    /// MAX_OBJECT_LIGHTS.
    /// Into `lightWords`: OBJ_LIGHTS's two vec4 of u8s.
    private writeLightList(object: Object3D): void {
        const u = this.lightWords;
        const n = this.frameLightCount;
        const fl = this.frameLights;
        let everywhere = n <= MAX_OBJECT_LIGHTS;
        for (let i = 0; i < n && everywhere; i++) everywhere = fl[i * 5 + 3] <= 0;
        if (everywhere) {
            // Every light reaches every object, in frame order (the loop
            // below gives the same without a bounding sphere).
            for (let w = 0; w < 8; w++) unchecked(u[w] = 0);
            u[0] = <u32>n;
            for (let k = 0; k < n; k++) {
                const b = k + 1;
                u[b / 4] |= <u32>k << <u32>((b % 4) * 8);
            }
            return;
        }
        const known = worldSphere(object, _lightSphere);
        const c = _lightSphere.center;
        const r = _lightSphere.radius;
        let found = 0;
        for (let i = 0; i < n; i++) {
            const reach = fl[i * 5 + 3];
            let score = fl[i * 5 + 4];
            if (known && score != Infinity) {
                const dx = fl[i * 5] - c.x, dy = fl[i * 5 + 1] - c.y, dz = fl[i * 5 + 2] - c.z;
                const d = Math.max(0, Math.sqrt(dx * dx + dy * dy + dz * dz) - r);
                if (reach > 0 && d > reach) continue;
                score = score / (1 + d * d);
                // Among lights equally close (a big object), nearer the camera first.
                const cx = fl[i * 5] - this.cameraPos.x, cy = fl[i * 5 + 1] - this.cameraPos.y;
                const cz = fl[i * 5 + 2] - this.cameraPos.z;
                score = score / (1 + 0.001 * (cx * cx + cy * cy + cz * cz));
            }
            this.lightScores[found] = score;
            this.lightOrder[found] = i;
            found++;
        }
        // Keep the strongest (insertion sort; at most 32).
        if (found > MAX_OBJECT_LIGHTS) {
            for (let i = 1; i < found; i++) {
                const s = this.lightScores[i], o = this.lightOrder[i];
                let j = i - 1;
                while (j >= 0 && this.lightScores[j] < s) {
                    this.lightScores[j + 1] = this.lightScores[j];
                    this.lightOrder[j + 1] = this.lightOrder[j];
                    j--;
                }
                this.lightScores[j + 1] = s;
                this.lightOrder[j + 1] = o;
            }
            found = MAX_OBJECT_LIGHTS;
        }
        for (let w = 0; w < 8; w++) unchecked(u[w] = 0);
        u[0] = <u32>found;
        for (let k = 0; k < found; k++) {
            const b = k + 1;
            u[b / 4] |= <u32>this.lightOrder[k] << <u32>((b % 4) * 8);
        }
    }

    // ------------------------------------------------------- baked variants

    /// A draw's baked variant (-1: the uber-shader), chosen again only when
    /// its material block, shadow flag, lights or the frame's share changed.
    private variantOf(state: DrawState, b: MaterialBlock, patch: i32, entry: i32): i32 {
        const words = this.lightWords;
        const frameBits = this.frameVariantBits;
        let same = state.vblock === b && state.vversion == b.version && state.vpatch == patch && state.vframe == frameBits
            && state.ventry == entry;
        for (let k = 0; k < 8 && same; k++) same = unchecked(state.vlights[k]) == unchecked(words[k]);
        if (same) return this.useBakedShaders ? state.variant : -1;
        state.vblock = b;
        state.vversion = b.version;
        state.vpatch = patch;
        state.vframe = frameBits;
        state.ventry = entry;
        for (let k = 0; k < 8; k++) unchecked(state.vlights[k] = words[k]);
        const key = this.programKey(b, patch, entry);
        const known = this.variantByKey;
        state.variant = known.has(key) ? known.get(key) : this.findVariant(key);
        return this.useBakedShaders ? state.variant : -1;
    }

    /// Looks up `key`'s baked variant once: the shader asset
    /// threeas_baked/v_<h> (gpu/ShaderVariants), in the project or any
    /// library it imports. Not there (no bake, a key the bake did not see,
    /// or a bake of another three.wgsl): -1, the uber-shader.
    private findVariant(key: string): i32 {
        const name = bakedShaderName(key);
        let variant = -1;
        const module = this.context.shader(name);
        if (module != null) {
            variant = this.variantModules.length;
            this.variantModules.push(module);
            this.variantPipelines.push(new Map<i64, GPUPipeline>());
        }
        this.variantByKey.set(key, variant);
        if (this.recordKeys) {
            this.context.log("three shader key: " + key + " " + name + (variant >= 0 ? " baked" : " uber"));
        } else if (!isDefined(THREE_RELEASE)) {
            // A project with a bake that misses keys: say which, to rebake.
            const misses = this.variantMisses;
            if (variant < 0) misses.push(key);
            if (this.variantModules.length > 0) {
                for (let i = 0; i < misses.length; i++) {
                    this.context.log("three: no baked shader for " + misses[i] + " (uber-shader; rerun tools/threeas_bake.sh)");
                }
                misses.length = 0;
            }
        }
        return variant;
    }

    /// three.js's getProgramCacheKey for the fragment stage: what the
    /// shader's v_* functions answer (three.wgsl's variant block), as
    /// tools/threeas_bake.sh reads it back.
    programKey(b: MaterialBlock, patch: i32, entry: i32): string {
        const words = this.lightWords;
        const count = <i32>(words[0] & 0xff);
        let lights = "";
        for (let k = 0; k < count; k++) {
            const w = k + 1;
            const index = <i32>((words[w / 4] >> <u32>((w % 4) * 8)) & 0xff);
            const type = this.frameLightTypes[index];
            lights += type == 0 ? "d" : type == 1 ? "p" : type == 2 ? "s" : "r";
        }
        const fb = this.frameVariantBits;
        const flags = b.vflags | ((patch & 1) != 0 ? FLAG_RECEIVE_SHADOW : 0);
        return "kind=" + b.vkind.toString() + ";present=" + b.vpresent.toString() + ";roles=" + b.vroles.toString()
            + ";flags=" + flags.toString() + ";cutout=" + (b.vcutout ? "1" : "0") + ";flat=" + (b.vflat ? "1" : "0")
            + ";env=" + (b.vownEnv ? "1" : "0") + ";scene=" + ((fb & 8) != 0 ? "1" : "0") + ";fog=" + (fb & 3).toString()
            + ";hemi=" + ((fb & 4) != 0 ? "1" : "0") + ";linear=" + ((fb & 16) != 0 ? "1" : "0")
            + ";lights=" + (lights.length > 0 ? lights : "-") + ";vs=" + vertexEntry(entry) + ";fs="
            + ((entry & KEY_LOG_DEPTH) != 0 ? "fs_main_logdepth" : "fs_main");
    }

    /// The pipeline of a draw: its baked variant's, or the uber-shader's.
    private drawPipeline(key: i32, variant: i32): GPUPipeline {
        if (variant < 0) return this.pipeline(key);
        const cache = unchecked(this.variantPipelines[variant]);
        const cacheKey = (<i64>this.pipelineCount << 56) | (<i64>this.pipelineFormat << 32) | <i64><u32>key;
        if (cache.has(cacheKey)) return cache.get(cacheKey);
        const p = this.buildPipeline(key, unchecked(this.variantModules[variant]));
        cache.set(cacheKey, p);
        return p;
    }

    /// The material block of `item` for this view: written once a view per
    /// material (and borrowed vertex texture slots), its version bumped when
    /// its bytes change; its bind groups rebuilt when its views do.
    private materialBlock(item: DrawItem, frame: i32, canvas: GPUCanvas): MaterialBlock {
        const entry = item.entry != null ? item.entry! : this.entryOf(item.state, item.material);
        const variant = (item.morphView != null ? 1 : 0) | (item.boneView != null ? 2 : 0)
            | (item.instanceMorphView != null ? 4 : 0);
        let b = unchecked(entry.blocks[variant]);
        if (b == null) {
            b = new MaterialBlock();
            unchecked(entry.blocks[variant] = b);
        }
        if (b.frame == frame) return b;
        b.frame = frame;
        const buf = this.objStaging;
        const f = this.objF32;
        const u = this.objU32;
        const mu = this.uniforms;
        const material = item.material;
        material.fillUniforms(mu);
        // The draw's own fields (world and normal matrices, sprite centre,
        // bind matrices, light list) are written per draw; zero here.
        this.objU8.fill(0);
        put4(f, OBJ_COLOR, mu.r, mu.g, mu.b, mu.opacity);
        put4(f, OBJ_EMISSIVE, mu.emissiveR, mu.emissiveG, mu.emissiveB, mu.alphaTest);
        put4(f, OBJ_PBR, mu.roughness, mu.metalness, mu.flatShading ? 1 : 0, mu.aoMapIntensity);
        put4(f, OBJ_SPECULAR, mu.specularR, mu.specularG, mu.specularB, mu.shininess);
        put4(f, OBJ_EXTRA, mu.normalScaleX, mu.normalScaleY, mu.envMapIntensity, mu.ior);
        put4(f, OBJ_PHYSICAL0, mu.clearcoat, mu.clearcoatRoughness, mu.sheenRoughness, mu.specularIntensity);
        put4(f, OBJ_PHYSICAL1, mu.sheenR * mu.sheen, mu.sheenG * mu.sheen, mu.sheenB * mu.sheen, 0);
        put4(f, OBJ_PHYSICAL2, mu.specularColorR, mu.specularColorG, mu.specularColorB, 0);
        put4(f, OBJ_POINTS, mu.size, mu.sizeAttenuation ? 1 : 0, mu.rotation, <f64>this.vpH * 0.5);
        put4(f, OBJ_DASH, mu.dashSize, mu.gapSize, mu.dashScale, mu.dashOffset);
        put4(f, OBJ_PHYSICAL3, mu.transmission, mu.thickness,
            isFinite(mu.attenuationDistance) ? mu.attenuationDistance : 0, mu.dispersion);
        put4(f, OBJ_PHYSICAL4, mu.attenuationR, mu.attenuationG, mu.attenuationB, mu.iridescence);
        put4(f, OBJ_PHYSICAL5, mu.iridescenceIOR, mu.iridescenceThicknessMin, mu.iridescenceThicknessMax,
            mu.anisotropy);
        put4(f, OBJ_PHYSICAL6, Math.cos(mu.anisotropyRotation), Math.sin(mu.anisotropyRotation), 0, 0);
        this.writeClipping(f, material);
        put4(f, OBJ_MISC0, mu.referenceX, mu.referenceY, mu.referenceZ, mu.nearDistance);
        put4(f, OBJ_MISC1, mu.farDistance, mu.alphaHash ? 1 : 0, mu.dashed ? 1 : 0, 0);

        // Textures: per slot a view, a sampler, flags and the uv transform
        // (texture.matrix and channel).
        let present: u32 = 0, srgb: u32 = 0, flip: u32 = 0, premul: u32 = 0;
        const views = _views;
        const samplers = _samplers;
        const white = this.white;
        const defaultSampler = this.defaultSampler();
        for (let s = 0; s < TEXTURE_SLOTS; s++) {
            views[s] = white;
            samplers[s] = defaultSampler;
            let o = (OBJ_UV_MATRIX >> 2) + s * 8;
            f[o] = 1; f[o + 5] = 1;
            const t = mu.textures[s];
            if (t == null) continue;
            if (t instanceof DepthTexture) {
                // A depth view cannot bind where a float texture is declared.
                if (!this.warnedDepthMap) {
                    this.context.log("three: a DepthTexture is for ShaderMaterials; built-in materials ignore it");
                    this.warnedDepthMap = true;
                }
                continue;
            }
            const envSlot = s == SLOT_ENV;
            if (envSlot) {
                // Environments read their mip chain by roughness.
                t.generateMipmaps = true;
                if (t.minFilter != LinearMipmapLinearFilter) t.minFilter = LinearMipmapLinearFilter;
                this.textures.update(t, frame);
            }
            // envMap reads its PMREM (the plain chain if that fails).
            let v: GPUTextureView? = envSlot ? this.textures.pmrem(t, canvas) : null;
            const prefiltered = v != null;
            if (v == null) v = this.textures.view(t, canvas);
            if (v == null) continue;
            views[s] = v;
            const levels = prefiltered ? this.textures.pmremLevels(t) : this.textures.levels(t);
            samplers[s] = envSlot ? this.backgroundSampler(true) : this.sampler(t, levels > 1);
            if (envSlot) {
                put4(f, OBJ_ENV, 1, prefiltered ? <f64>levels - 1 : Math.max(0, <f64>levels - 2),
                    prefiltered ? 1 : 0, 0);
            }
            const bit: u32 = 1 << <u32>s;
            present |= bit;
            // Cube textures and PMREMs are linear, straight, top row first.
            const cube = t instanceof CubeTexture || prefiltered;
            if (!cube && t.colorSpace == SRGBColorSpace) srgb |= bit;
            if (cube || t.flipY) flip |= bit;
            if (!cube && t.premultiplyAlpha) premul |= bit;
            if (t.matrixAutoUpdate) t.updateMatrix();
            const e = t.matrix.elements;   // column-major 3x3
            f[o] = <f32>e[0]; f[o + 1] = <f32>e[3]; f[o + 2] = <f32>e[6]; f[o + 3] = t.channel > 0 ? 1 : 0;
            f[o + 4] = <f32>e[1]; f[o + 5] = <f32>e[4]; f[o + 6] = <f32>e[7];
        }
        this.writeExtraMaps(b, variant, mu, f, u, present, canvas);
        let o = OBJ_TEX_FLAGS >> 2;
        u[o] = <u32>mu.kind; u[o + 1] = present; u[o + 2] = srgb; u[o + 3] = flip;
        let flags: u32 = 0;
        if (mu.vertexColors) flags |= FLAG_VERTEX_COLORS;
        if (mu.fog) flags |= FLAG_FOG;
        if (material.transparent) flags |= FLAG_TRANSPARENT;
        if (material.toneMapped && this.toneMapping != NoToneMapping) flags |= FLAG_TONE_MAPPED;
        o = OBJ_FLAGS >> 2;
        u[o] = premul; u[o + 1] = flags;
        // A new version when the bytes changed.
        const now = this.objI64, was = b.i64;
        let same = true;
        for (let k = 0; k < (OBJ_USED >> 3) && same; k++) same = unchecked(now[k]) == unchecked(was[k]);
        if (!same) {
            b.u8.set(this.objU8);
            b.version++;
            // Its share of the program key, as the shader's v_* read it.
            o = OBJ_TEX_FLAGS >> 2;
            b.vkind = u[o];
            b.vpresent = u[o + 1];
            b.vflags = u[(OBJ_FLAGS >> 2) + 1];
            const xpresent = u[OBJ_X_FLAGS >> 2];
            let roles: u32 = 0;
            for (let r = 0; r < ROLE_COUNT; r++) {
                const word = u[(OBJ_X_ROLES >> 2) + (r >= 8 ? 1 : 0)];
                const slot = (word >> <u32>((r % 8) * 4)) & 0xf;
                if (slot < 5 && ((xpresent >> slot) & 1) != 0) roles |= <u32>1 << <u32>r;
            }
            b.vroles = roles;
            b.vcutout = f[(OBJ_EMISSIVE >> 2) + 3] > 0 || f[(OBJ_MISC1 >> 2) + 1] > 0.5 || f[(OBJ_CLIP >> 2) + 1] > 0;
            b.vflat = f[(OBJ_PBR >> 2) + 2] > 0.5;
            b.vownEnv = f[OBJ_ENV >> 2] > 0.5;
        }
        for (let s = 0; s < TEXTURE_SLOTS; s++) {
            b.views[s] = views[s];
            b.samplers[s] = samplers[s];
        }
        if (item.custom != null) return b;
        let changed = b.matGroup == null;
        for (let s = 0; s < TEXTURE_SLOTS && !changed; s++) changed = b.groupViews[s] !== views[s];
        if (changed) {
            const entries: Array<GPUBindGroupTexture> = [];
            for (let s = 0; s < TEXTURE_SLOTS; s++) {
                entries.push(new GPUBindGroupTexture(<u32>s, views[s]!));
                b.groupViews[s] = views[s];
            }
            const oldMat = b.matGroup;
            if (oldMat != null) oldMat.release();
            b.matGroup = new GPUBindGroup(this.matLayout!, [], entries);
        }
        changed = b.samplerGroup == null;
        for (let s = 0; s < TEXTURE_SLOTS && !changed; s++) changed = b.groupSamplers[s] !== samplers[s];
        if (changed) {
            const entries: Array<GPUBindGroupSampler> = [];
            for (let s = 0; s < TEXTURE_SLOTS; s++) {
                entries.push(new GPUBindGroupSampler(<u32>s, samplers[s]!));
                b.groupSamplers[s] = samplers[s];
            }
            const oldSampler = b.samplerGroup;
            if (oldSampler != null) oldSampler.release();
            b.samplerGroup = new GPUBindGroup(this.samplerLayout!, [], [], entries);
        }
        return b;
    }

    /// Each draw's object block in its arena slot: its material's block plus
    /// its own fields, rewritten (and uploaded at the end, in runs) only when
    /// one of them changed since the slot was last written.
    private writeDraws(list: Array<DrawItem>, frame: i32, canvas: GPUCanvas): void {
        this.reserveArena(list.length);
        const af = this.arenaF32;
        const au = this.arenaU32;
        const receives = this.tileCount > 0;
        const words = this.lightWords;
        // Program keys are looked up (and logged) unless baked variants are
        // off and not recording.
        const variants = this.recordKeys || this.useBakedShaders;
        for (let i = 0; i < list.length; i++) {
            const item = unchecked(list[i]);
            const state = item.state;
            if (state.frame == frame) {
                if (variants && item.custom == null) item.variant = this.useBakedShaders ? state.variant : -1;
                continue;
            }
            state.frame = frame;
            const object = item.object;
            const b = this.materialBlock(item, frame, canvas);
            // Its share of the extra slots: the material's maps, then the
            // vertex textures it borrows slots for.
            for (let k = 0; k < EXTRA_SLOTS; k++) state.xviews[k] = b.xviews[k];
            if (item.morphView != null) state.xviews[X_SLOT_MORPH] = item.morphView;
            if (item.boneView != null) state.xviews[X_SLOT_BONES] = item.boneView;
            if (item.instanceMorphView != null) state.xviews[X_SLOT_MORPH_INSTANCES] = item.instanceMorphView;
            state.xcount = b.xcount;
            state.matGroup = b.matGroup;
            state.samplerGroup = b.samplerGroup;

            // What only this draw has.
            const g = item.geometry;
            const patch = (object.receiveShadow && receives ? 1 : 0) | (g != null && g.hasTangents ? 2 : 0);
            this.writeLightList(object);
            if (variants) item.variant = item.custom != null ? -1 : this.variantOf(state, b, patch, item.pipelineKey & KEY_ENTRY_MASK);
            const me = object.matrixWorld.elements;
            let dirty = state.slot < 0 || state.block !== b || state.blockVersion != b.version || state.patch != patch
                || item.skinned;
            for (let k = 0; k < 16 && !dirty; k++) dirty = unchecked(state.model[k]) != unchecked(me[k]);
            for (let k = 0; k < 8 && !dirty; k++) dirty = unchecked(state.lights[k]) != unchecked(words[k]);
            const sprite = object instanceof Sprite;
            if (sprite && !dirty) {
                const c = (object as Sprite).center;
                dirty = c.x != state.spriteX || c.y != state.spriteY;
            }
            if (!dirty) continue;

            if (state.slot < 0) {
                state.slot = this.freeSlots.length > 0 ? this.freeSlots.pop() : this.slotCount++;
                state.objOffset = <u32>(state.slot * OBJ_BYTES);
            }
            const base = <i32>state.objOffset;
            const staging = this.arenaStaging;
            this.arenaBytes.set(b.u8, base);
            state.block = b;
            state.blockVersion = b.version;
            state.patch = patch;
            for (let k = 0; k < 16; k++) unchecked(state.model[k] = me[k]);
            for (let k = 0; k < 8; k++) unchecked(state.lights[k] = words[k]);
            object.matrixWorld.mat4.writeToBuffer(staging, <u32>(base + OBJ_MODEL));
            _normal.getNormalMatrix(object.matrixWorld);
            const ne = _normal.elements;
            let o = (base + OBJ_NORMAL) >> 2;
            for (let c = 0; c < 3; c++) {
                af[o + c * 4] = <f32>ne[c * 3];
                af[o + c * 4 + 1] = <f32>ne[c * 3 + 1];
                af[o + c * 4 + 2] = <f32>ne[c * 3 + 2];
                af[o + c * 4 + 3] = 0;
            }
            af[o + 12] = 0; af[o + 13] = 0; af[o + 14] = 0; af[o + 15] = 1;
            o = (base + OBJ_LIGHTS) >> 2;
            for (let k = 0; k < 8; k++) au[o + k] = unchecked(words[k]);
            if ((patch & 1) != 0) au[((base + OBJ_FLAGS) >> 2) + 1] |= FLAG_RECEIVE_SHADOW;
            if ((patch & 2) != 0) au[((base + OBJ_X_ROLES) >> 2) + 2] = 1;
            if (sprite) {
                const c = (object as Sprite).center;
                state.spriteX = c.x;
                state.spriteY = c.y;
                o = (base + OBJ_SPRITE) >> 2;
                af[o] = <f32>c.x; af[o + 1] = <f32>c.y; af[o + 2] = 0; af[o + 3] = 0;
            }
            if (item.skinned) {
                const sm = object as SkinnedMesh;
                sm.bindMatrix.mat4.writeToBuffer(staging, <u32>(base + OBJ_BIND_MATRIX));
                sm.bindMatrixInverse.mat4.writeToBuffer(staging, <u32>(base + OBJ_BIND_MATRIX_INVERSE));
            }
            this.markSlot(state.slot);
        }
        // ShaderMaterials' own uniforms (once a frame per material).
        for (let i = 0; i < list.length; i++) {
            const item = unchecked(list[i]);
            const cp = item.custom;
            if (cp != null) item.customUniforms = this.prepareCustomUniforms(item.material as ShaderMaterial, cp, frame, canvas);
        }
        this.flushArena();
    }

    // ------------------------------------------------------------------ draw

    /// Draws `list`. With `transmissionGroup` (the transmission pass): no
    /// MSAA, that frame group, and no transmissive or ShaderMaterial draws.
    private drawList(pass: GPURenderPass, list: Array<DrawItem>, transmissionGroup: GPUBindGroup? = null): void {
        const info = this.info.render;
        const transmissionPass = transmissionGroup != null;
        const frameGroup = transmissionPass ? transmissionGroup! : this.frameGroup!;
        let lastKey = -1;
        let lastVariant = -1;
        // Bindings already set (draws sharing a geometry or material skip them).
        let lastMat: GPUBindGroup? = null, lastSamplers: GPUBindGroup? = null;
        let lastStencilRef: u32 = 0;
        let lastPos: GPUBuffer? = null, lastNrm: GPUBuffer? = null, lastUv: GPUBuffer? = null;
        let lastColor: GPUBuffer? = null, lastInst: GPUBuffer? = null, lastIndex: GPUBuffer? = null;
        let lastInstFirst: u32 = 0;
        let lastSkin: GPUBuffer? = null;
        for (let i = 0; i < list.length; i++) {
            const item = list[i];
            const state = item.state;
            const cp = item.custom;
            if (transmissionPass && (cp != null || item.transmissive)) continue;
            if (cp != null) {
                const g = item.geometry!;
                pass.setPipeline(cp.pipeline);
                lastKey = -1;
                pass.setBindGroup(0, cp.lights ? this.customFullGroup(cp, frameGroup) : cp.frameGroup);
                lastMat = null; lastSamplers = null; lastPos = null; lastNrm = null; lastUv = null; lastColor = null;
                lastInst = null; lastIndex = null; lastSkin = null;
                this.dynamicOffset[0] = state.objOffset;
                pass.setBindGroup(1, this.customObjGroup(cp), this.dynamicOffset);
                const cu = item.customUniforms;
                if (cu != null && cu.group != null) pass.setBindGroup(2, cu.group!);
                pass.setVertexBuffer(0, g.position!);
                pass.setVertexBuffer(1, g.normal!);
                pass.setVertexBuffer(2, g.uv!);
                pass.setVertexBuffer(3, g.color!);
                pass.setVertexBuffer(4, item.instances, item.instanceFirst * <u32>INSTANCE_MATRIX_STRIDE);
                pass.setVertexBuffer(5, item.instanceColors, item.instanceFirst * <u32>INSTANCE_COLOR_STRIDE);
                pass.setVertexBuffer(6, g.uv1!);
                const index = item.index;
                if (index != null) {
                    pass.setIndexBuffer(index, item.indexFormat);
                    pass.drawIndexed(<u32>item.count, item.instanceCount, <u32>item.first);
                } else {
                    pass.draw(<u32>item.count, item.instanceCount, <u32>item.first);
                }
                info.calls++;
                info.triangles += (item.count / 3) * <i32>item.instanceCount;
                continue;
            }
            if (state.matGroup == null) continue;
            const key = transmissionPass ? item.pipelineKey & ~KEY_MSAA : item.pipelineKey;
            // The transmission pass writes linear colour from its own frame
            // block: the uber-shader (variants bake the main pass's output).
            const variant = transmissionPass ? -1 : item.variant;
            if (key != lastKey || variant != lastVariant) {
                pass.setPipeline(this.drawPipeline(key, variant));
                pass.setBindGroup(0, frameGroup);
                lastKey = key;
                lastVariant = variant;
            }
            if (item.stencilRef != lastStencilRef) {
                pass.setStencilReference(item.stencilRef);
                lastStencilRef = item.stencilRef;
            }
            pass.setBindGroup(1, this.objGroupOf(item), this.dynamicOffsets);
            const mat = state.matGroup!;
            if (mat !== lastMat) {
                pass.setBindGroup(2, mat);
                lastMat = mat;
            }
            const smp = state.samplerGroup!;
            if (smp !== lastSamplers) {
                pass.setBindGroup(3, smp);
                lastSamplers = smp;
            }
            const prim = item.prim;
            if (prim == PRIM_SPRITE) {
                pass.draw(6);
                info.calls++;
                info.triangles += 2;
                continue;
            }
            const g = item.geometry!;
            if (prim == PRIM_POINTS) {
                lastPos = null; lastColor = null;
                pass.setVertexBuffer(0, g.position!, <u32>(item.first * 12));
                pass.setVertexBuffer(1, g.color!, <u32>(item.first * 16));
                pass.draw(6, <u32>item.count);
                info.calls++;
                info.points += item.count;
                continue;
            }
            const po = item.positionOverride;
            const no = item.normalOverride;
            const pos = po != null ? po! : g.position!;
            const nrm = no != null ? no! : g.normal!;
            if (pos !== lastPos) { pass.setVertexBuffer(0, pos); lastPos = pos; }
            if (nrm !== lastNrm) { pass.setVertexBuffer(1, nrm); lastNrm = nrm; }
            const uv = g.uv!;
            if (uv !== lastUv) {
                pass.setVertexBuffer(2, uv);
                pass.setVertexBuffer(6, g.uv1!);
                lastUv = uv;
            }
            const color = g.color!;
            if (color !== lastColor) { pass.setVertexBuffer(3, color); lastColor = color; }
            const inst = item.instances;
            if (inst !== lastInst || item.instanceFirst != lastInstFirst) {
                pass.setVertexBuffer(4, inst, item.instanceFirst * <u32>INSTANCE_MATRIX_STRIDE);
                pass.setVertexBuffer(5, item.instanceColors, item.instanceFirst * <u32>INSTANCE_COLOR_STRIDE);
                lastInst = inst;
                lastInstFirst = item.instanceFirst;
            }
            if (item.skinned) {
                const si = g.skin!;
                if (si !== lastSkin) {
                    pass.setVertexBuffer(7, si);
                    lastSkin = si;
                }
            } else if (item.morphRows != null) {
                // Slot 7 holds the instance rows now, not a skin buffer.
                pass.setVertexBuffer(7, item.morphRows!);
                lastSkin = null;
            }
            const index = item.index;
            if (index != null) {
                if (index !== lastIndex) {
                    pass.setIndexBuffer(index, item.indexFormat);
                    lastIndex = index;
                }
                pass.drawIndexed(<u32>item.count, item.instanceCount, <u32>item.first);
            } else {
                pass.draw(<u32>item.count, item.instanceCount, <u32>item.first);
            }
            info.calls++;
            if (prim == PRIM_LINES) info.lines += (item.count / 2) * <i32>item.instanceCount;
            else info.triangles += (item.count / 3) * <i32>item.instanceCount;
        }
    }
}

/// base + sum(w_i x target_i) (relative) or base + sum(w_i x (target_i - base)).
function blend(base: Float32Array, targets: Array<BufferAttribute>, influences: Array<f64>, relative: bool,
               out: Float32Array): Float32Array {
    const n = base.length;
    if (out.length != n) out = new Float32Array(n);
    for (let k = 0; k < n; k++) out[k] = base[k];
    for (let i = 0; i < influences.length && i < targets.length; i++) {
        const w = <f32>influences[i];
        if (w == 0) continue;
        const t = targets[i].array;
        if (t.length < n) continue;
        if (relative) for (let k = 0; k < n; k++) out[k] += w * t[k];
        else for (let k = 0; k < n; k++) out[k] += w * (t[k] - base[k]);
    }
    return out;
}

function uploadVertices(existing: GPUBuffer?, data: Float32Array): GPUBuffer {
    const bytes = data.buffer;
    if (existing != null && existing.size == <u32>bytes.byteLength) {
        existing.update(0, bytes);
        return existing;
    }
    if (existing != null) existing.release();
    return new GPUBuffer(BufferUsage.vertex, <u32>bytes.byteLength, bytes);
}

function put4(f: Float32Array, byteOffset: i32, x: f64, y: f64, z: f64, w: f64): void {
    const o = byteOffset >> 2;
    f[o] = <f32>x; f[o + 1] = <f32>y; f[o + 2] = <f32>z; f[o + 3] = <f32>w;
}

function blendState(blending: i32): GPUBlendState? {
    if (blending == NoBlending) return null;
    // Premultiplied colour, as three.js with premultipliedAlpha.
    const b = new GPUBlendState();
    if (blending == AdditiveBlending) {
        b.srcColor = BlendFactor.one; b.dstColor = BlendFactor.one;
        b.srcAlpha = BlendFactor.one; b.dstAlpha = BlendFactor.one;
    } else if (blending == SubtractiveBlending) {
        b.srcColor = BlendFactor.zero; b.dstColor = BlendFactor.oneMinusSrcColor;
        b.srcAlpha = BlendFactor.zero; b.dstAlpha = BlendFactor.one;
    } else if (blending == MultiplyBlending) {
        b.srcColor = BlendFactor.zero; b.dstColor = BlendFactor.srcColor;
        b.srcAlpha = BlendFactor.zero; b.dstAlpha = BlendFactor.srcAlpha;
    } else {
        b.srcColor = BlendFactor.one; b.dstColor = BlendFactor.oneMinusSrcAlpha;
        b.srcAlpha = BlendFactor.one; b.dstAlpha = BlendFactor.oneMinusSrcAlpha;
    }
    return b;
}

function compareOpaque(a: DrawItem, b: DrawItem): i32 {
    const ro = a.object.renderOrder - b.object.renderOrder;
    if (ro != 0) return ro;
    if (a.pipelineKey != b.pipelineKey) return a.pipelineKey - b.pipelineKey;
    return a.depth < b.depth ? -1 : a.depth > b.depth ? 1 : a.object.id - b.object.id;
}

function compareTransparent(a: DrawItem, b: DrawItem): i32 {
    const ro = a.object.renderOrder - b.object.renderOrder;
    if (ro != 0) return ro;
    return a.depth > b.depth ? -1 : a.depth < b.depth ? 1 : a.object.id - b.object.id;
}

const _noMaterials: Array<Material> = [];

function materialOf(o: Object3D): Material? {
    if (o instanceof Mesh) return (o as Mesh).material;
    if (o instanceof Line) return (o as Line).material;
    if (o instanceof Points) return (o as Points).material;
    if (o instanceof Sprite) return (o as Sprite).material;
    return null;
}

function geometryOf(o: Object3D): BufferGeometry? {
    if (o instanceof Mesh) return (o as Mesh).geometry;
    if (o instanceof Line) return (o as Line).geometry;
    if (o instanceof Points) return (o as Points).geometry;
    return null;
}

/// three.js's Frustum.intersectsSprite.
function intersectsSprite(sprite: Sprite): bool {
    _sphere.center.set(0, 0, 0);
    const dx = 0.5 - sprite.center.x, dy = 0.5 - sprite.center.y;
    _sphere.radius = 0.7071067811865476 + Math.sqrt(dx * dx + dy * dy);
    _sphere.applyMatrix4(sprite.matrixWorld);
    return _frustum.intersectsSphere(_sphere);
}

function isNearest(filter: i32): bool {
    return filter == NearestFilter || filter == NearestMipmapNearestFilter || filter == NearestMipmapLinearFilter;
}

function wrapOf(wrap: i32): WrapMode {
    if (wrap == RepeatWrapping) return WrapMode.repeat;
    if (wrap == MirroredRepeatWrapping) return WrapMode.mirrorRepeat;
    return WrapMode.clampToEdge;
}

function vertexLayout(stride: u32, format: VertexFormat, location: u32): GPUVertexBufferLayout {
    const l = new GPUVertexBufferLayout();
    l.stride = stride;
    l.attributes = [new GPUVertexAttribute(format, location, 0)];
    return l;
}

function releaseTex(t: GPUTexture?): void {
    if (t != null) t.release();
}

const _pos: Vector3 = new Vector3();
const _dir: Vector3 = new Vector3();
const _hemiDir: Vector3 = new Vector3(0, 1, 0);
const _normal: Matrix3 = new Matrix3();
const _frustum: Frustum = new Frustum();
const _sphere: Sphere = new Sphere();
const _euler: Euler = new Euler();
const _bgRotation: Matrix4 = new Matrix4();
const _views: StaticArray<GPUTextureView?> = new StaticArray<GPUTextureView?>(TEXTURE_SLOTS);
const _samplers: StaticArray<GPUSampler?> = new StaticArray<GPUSampler?>(TEXTURE_SLOTS);
const _xtex: StaticArray<Texture?> = new StaticArray<Texture?>(EXTRA_SLOTS);

/// Group 1 texture entries for the extra map slots (bindings 2-7).
function extraTextures(views: StaticArray<GPUTextureView?>?, white: GPUTextureView): Array<GPUBindGroupTexture> {
    const out: Array<GPUBindGroupTexture> = [];
    for (let i = 0; i < EXTRA_SLOTS; i++) {
        const v = views != null ? views[i] : null;
        out.push(new GPUBindGroupTexture(<u32>(2 + i), v != null ? v! : white));
    }
    return out;
}

function depthCompare(func: i32): CompareFunction {
    if (func == NeverDepth) return CompareFunction.never;
    if (func == AlwaysDepth) return CompareFunction.always;
    if (func == LessDepth) return CompareFunction.less;
    if (func == EqualDepth) return CompareFunction.equal;
    if (func == GreaterEqualDepth) return CompareFunction.greaterEqual;
    if (func == GreaterDepth) return CompareFunction.greater;
    if (func == NotEqualDepth) return CompareFunction.notEqual;
    return CompareFunction.lessEqual;
}

function stencilCompare(func: i32): CompareFunction {
    if (func == NeverStencilFunc) return CompareFunction.never;
    if (func == LessStencilFunc) return CompareFunction.less;
    if (func == EqualStencilFunc) return CompareFunction.equal;
    if (func == LessEqualStencilFunc) return CompareFunction.lessEqual;
    if (func == GreaterStencilFunc) return CompareFunction.greater;
    if (func == NotEqualStencilFunc) return CompareFunction.notEqual;
    if (func == GreaterEqualStencilFunc) return CompareFunction.greaterEqual;
    return CompareFunction.always;
}

function stencilOp(op: i32): StencilOp {
    if (op == ZeroStencilOp) return StencilOp.zero;
    if (op == ReplaceStencilOp) return StencilOp.replace;
    if (op == IncrementStencilOp) return StencilOp.incrementClamp;
    if (op == DecrementStencilOp) return StencilOp.decrementClamp;
    if (op == IncrementWrapStencilOp) return StencilOp.incrementWrap;
    if (op == DecrementWrapStencilOp) return StencilOp.decrementWrap;
    if (op == InvertStencilOp) return StencilOp.invert;
    return StencilOp.keep;
}

const _lightSphere: Sphere = new Sphere();
const _probe: Float64Array = new Float64Array(27);
const _rectRot: Matrix4 = new Matrix4();

/// `o`'s world bounding sphere into `out`; false when unknown (posed
/// skins without bounds, morphed meshes, objects without geometry).
function worldSphere(o: Object3D, out: Sphere): bool {
    if (o instanceof Sprite) {
        out.center.set(0, 0, 0);
        out.radius = 0.75;
        out.applyMatrix4(o.matrixWorld);
        return true;
    }
    if (o instanceof SkinnedMesh) {
        const sm = o as SkinnedMesh;
        if (sm.boundingSphere == null) return false;
        out.copy(sm.boundingSphere!).applyMatrix4(sm.matrixWorld);
        return true;
    }
    if (o instanceof InstancedMesh) {
        const im = o as InstancedMesh;
        if (im.boundingSphere == null) im.computeBoundingSphere();
        out.copy(im.boundingSphere!).applyMatrix4(im.matrixWorld);
        return true;
    }
    if (o instanceof BatchedMesh) {
        const bm = o as BatchedMesh;
        if (bm.boundingSphere == null) bm.computeBoundingSphere();
        out.copy(bm.boundingSphere!).applyMatrix4(bm.matrixWorld);
        return true;
    }
    if (o instanceof Mesh && (o as Mesh).morphTargetInfluences.length > 0) return false;
    const geometry = geometryOf(o);
    if (geometry == null) return false;
    if (geometry.boundingSphere == null) geometry.computeBoundingSphere();
    const bounds = geometry.boundingSphere!;
    if (bounds.isEmpty()) return false;
    out.copy(bounds).applyMatrix4(o.matrixWorld);
    return true;
}
