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
    GPUPassDesc, GPUSampler, GPUShaderModule, GPUBlendState, GPURenderPass,
} from "rive/gpu";
import {
    BufferUsage, TextureFormat, CompareFunction, CullMode, VertexFormat, VertexStepMode, LoadOp, StoreOp, Filter,
    WrapMode, BlendFactor, FaceWinding, PrimitiveTopology, ColorWriteMask,
} from "rive/gpu_enums";
import { rive_gpu_texture_upload_v1 } from "rive/bindings";

import { Object3D } from "../core/Object3D";
import { BufferGeometry, disposedGeometries } from "../core/BufferGeometry";
import { BufferAttribute } from "../core/BufferAttribute";
import { Camera } from "../cameras/Camera";
import { OrthographicCamera } from "../cameras/OrthographicCamera";
import { Scene } from "../scenes/Scene";
import { Fog, FogExp2 } from "../scenes/Fog";
import { Mesh } from "../objects/Mesh";
import { InstancedMesh } from "../objects/InstancedMesh";
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
import { MaterialUniforms, TEXTURE_SLOTS } from "../materials/MaterialUniforms";
import { ShaderMaterial } from "../materials/ShaderMaterial";
import { MeshStandardMaterial } from "../materials/MeshStandardMaterial";
import { Texture, disposedTextures } from "../textures/Texture";
import { Color, LinearToSRGB } from "../math/Color";
import { Euler } from "../math/Euler";
import { Vector2 } from "../math/Vector2";
import { Vector3 } from "../math/Vector3";
import { Matrix3 } from "../math/Matrix3";
import { Matrix4 } from "../math/Matrix4";
import { Frustum } from "../math/Frustum";
import { Sphere } from "../math/Sphere";
import {
    BackSide, DoubleSide, NearestFilter, NearestMipmapNearestFilter, NearestMipmapLinearFilter,
    LinearMipmapLinearFilter, RepeatWrapping, MirroredRepeatWrapping, SRGBColorSpace, NoToneMapping,
    NoBlending, NormalBlending, AdditiveBlending, SubtractiveBlending, MultiplyBlending,
    EquirectangularReflectionMapping, EquirectangularRefractionMapping,
} from "../constants";
import { GPUGeometries, GeometryGPU, LINE_STRIP, LINE_LOOP, LINE_SEGMENTS, LINE_WIREFRAME } from "./gpu/GPUGeometries";
import { GPUTextures, wantsMipmaps } from "./gpu/GPUTextures";
import { RenderTarget } from "./RenderTarget";
import {
    MAX_LIGHTS, FRAME_VIEW_PROJ, FRAME_VIEW, FRAME_INV_VIEW_PROJ, FRAME_CAMERA_POS, FRAME_CAMERA_DIR, FRAME_AMBIENT,
    FRAME_HEMI_SKY, FRAME_HEMI_GROUND, FRAME_HEMI_DIR, FRAME_FOG_COLOR, FRAME_FOG_PARAMS, FRAME_OUTPUT,
    FRAME_BG_ROTATION, FRAME_BG_FLAGS, FRAME_PROJ, FRAME_VIEWPORT, FRAME_LIGHTS, LIGHT_BYTES, FRAME_BYTES, OBJ_SPRITE,
    FRAME_ENV, FRAME_ENV_ROTATION, FRAME_ENV_FLAGS,
    OBJ_MODEL, OBJ_NORMAL, OBJ_COLOR, OBJ_EMISSIVE, OBJ_PBR, OBJ_UV, OBJ_SPECULAR, OBJ_EXTRA, OBJ_PHYSICAL0,
    OBJ_PHYSICAL1, OBJ_PHYSICAL2, OBJ_TEX_FLAGS, OBJ_FLAGS, OBJ_POINTS, OBJ_DASH, OBJ_BYTES,
    FLAG_VERTEX_COLORS, FLAG_FOG, FLAG_TRANSPARENT, FLAG_TONE_MAPPED, LIGHT_DIRECTIONAL, LIGHT_POINT, LIGHT_SPOT,
    FOG_LINEAR, FOG_EXP2, INSTANCE_STRIDE, OBJ_BIND_MATRIX, OBJ_BIND_MATRIX_INVERSE, MAX_BONES, BONES_BYTES,
} from "./gpu/Layout";

// The main shader: newer CLIs name assets by path, 1.9.x by file name.
const SHADER_NAMES: Array<string> = ["three/shaders/three", "shaders/three", "three"];

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

// An InstancedMesh's packed instance buffer.
class InstanceGPU {
    buffer: GPUBuffer? = null;
    matrixVersion: i32 = -1;
    colorVersion: i32 = -1;
    count: i32 = -1;
    staging: Float32Array = new Float32Array(0);
}

// -----------------------------------------------------------------------------

export class GPURendererParameters {
    /// 4x MSAA when the device has it.
    antialias: bool = false;
    /// Clear to transparent (clear alpha 0) by default, so the artboard
    /// shows behind the scene.
    alpha: bool = false;
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

export class RendererInfo {
    render: RenderInfo = new RenderInfo();
}

// One draw's state, kept across frames.
class DrawState {
    ubo: GPUBuffer;
    objGroup: GPUBindGroup? = null;
    bones: GPUBuffer? = null;
    customObjGroup: GPUBindGroup? = null;
    customLayout: GPUBindGroupLayout? = null;
    matGroup: GPUBindGroup? = null;
    views: StaticArray<GPUTextureView?> = new StaticArray<GPUTextureView?>(TEXTURE_SLOTS);
    sampler: GPUSampler? = null;
    frame: i32 = -1;

    constructor() {
        this.ubo = new GPUBuffer(BufferUsage.uniform, <u32>OBJ_BYTES);
    }
}

// One draw of this frame.
class DrawItem {
    object: Object3D;
    material: Material;
    geometry: GeometryGPU?;
    prim: i32 = PRIM_TRIANGLES;
    index: GPUBuffer? = null;
    indexFormat: u32 = 0;
    state: DrawState;
    pipelineKey: i32 = 0;
    depth: f64 = 0;
    first: i32 = 0;
    count: i32 = 0;
    instances: GPUBuffer;
    instanceCount: u32 = 1;
    skinned: bool = false;
    bones: GPUBuffer? = null;
    custom: CustomPipeline? = null;
    customUniforms: CustomUniforms? = null;
    positionOverride: GPUBuffer? = null;
    normalOverride: GPUBuffer? = null;

    constructor(object: Object3D, material: Material, geometry: GeometryGPU?, state: DrawState, instances: GPUBuffer) {
        this.object = object;
        this.material = material;
        this.geometry = geometry;
        this.state = state;
        this.instances = instances;
    }
}

export class GPURenderer {
    readonly context: Context;
    /// Clear the canvas before each render (else draw over the last one).
    autoClear: bool = true;
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

    private canvas: GPUCanvas? = null;
    private width: f64 = 0;
    private height: f64 = 0;
    private pixelRatio: f64 = 1;
    private clearColor: Color = new Color(0, 0, 0);
    private clearAlpha: f64 = 1;
    private antialias: bool;
    private broken: bool = false;
    private maxAnisotropy: i32 = 1;

    private module: GPUShaderModule? = null;
    private frameLayout: GPUBindGroupLayout? = null;
    private objLayout: GPUBindGroupLayout? = null;
    private matLayout: GPUBindGroupLayout? = null;
    private bgLayout: GPUBindGroupLayout? = null;
    private vertexBuffers: Array<GPUVertexBufferLayout> = [];
    private pointBuffers: Array<GPUVertexBufferLayout> = [];
    private skinBuffers: Array<GPUVertexBufferLayout> = [];
    private dummyBones: GPUBuffer? = null;
    private boneBuffers: Map<i32, GPUBuffer> = new Map<i32, GPUBuffer>();
    private morphs: Map<i32, MorphGPU> = new Map<i32, MorphGPU>();
    private customPipelines: Map<string, CustomPipeline> = new Map<string, CustomPipeline>();
    private customModules: Map<string, GPUShaderModule> = new Map<string, GPUShaderModule>();
    private customUniforms: Map<i32, CustomUniforms> = new Map<i32, CustomUniforms>();
    private warnedShaders: Map<string, bool> = new Map<string, bool>();
    private warnedBones: bool = false;
    private instanceBuffers: Map<i32, InstanceGPU> = new Map<i32, InstanceGPU>();
    private pipelines: Map<i32, GPUPipeline> = new Map<i32, GPUPipeline>();
    private pipelineFormat: u32 = 0xFFFFFFFF;
    private samples: u32 = 1;

    private frameUbo: GPUBuffer? = null;
    private frameGroup: GPUBindGroup? = null;
    private frameStaging: ArrayBuffer = new ArrayBuffer(FRAME_BYTES);
    private objStaging: ArrayBuffer = new ArrayBuffer(OBJ_BYTES);
    private white: GPUTextureView? = null;
    private identityInstance: GPUBuffer? = null;
    private samplers: Map<i32, GPUSampler> = new Map<i32, GPUSampler>();
    private bgGroup: GPUBindGroup? = null;
    private bgView: GPUTextureView? = null;
    private bgTexture: Texture? = null;
    private envTexture: Texture? = null;
    private envCandidate: Texture? = null;
    private envView: GPUTextureView? = null;
    private envLevels: u32 = 1;
    private frameGroupView: GPUTextureView? = null;

    private mainTargets: PassTargets = new PassTargets();
    private rtTargets: Map<i32, PassTargets> = new Map<i32, PassTargets>();
    private renderTarget: RenderTarget? = null;
    // The destination of the render in progress.
    private passSamples: u32 = 1;
    private passWidth: u32 = 0;
    private passHeight: u32 = 0;
    private passRatio: f64 = 1;

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

    constructor(context: Context, parameters: GPURendererParameters? = null) {
        this.context = context;
        this.textures = new GPUTextures(context);
        this.antialias = parameters != null ? parameters.antialias : false;
        if (parameters != null && parameters.alpha) this.clearAlpha = 0;
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

    /// The size in points (the layout's size).
    setSize(width: f64, height: f64): void {
        this.width = width;
        this.height = height;
    }

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
        this.clearColor.set<T>(color);
        this.clearAlpha = alpha;
    }

    /// Renders into `target` from now on (null: the canvas presented).
    setRenderTarget(target: RenderTarget?): void { this.renderTarget = target; }
    getRenderTarget(): RenderTarget? { return this.renderTarget; }

    getClearColor(target: Color): Color { return target.copy(this.clearColor); }
    getClearAlpha(): f64 { return this.clearAlpha; }
    setClearAlpha(alpha: f64): void { this.clearAlpha = alpha; }

    // ----------------------------------------------------------------- render

    /// Renders `scene` from `camera` into the canvas. Call it from the
    /// script's `draw()`, then `present`.
    render(scene: Object3D, camera: Camera): void {
        const info = this.info.render;
        info.frame++;
        info.calls = 0;
        info.triangles = 0;
        info.culled = 0;
        info.lines = 0;
        info.points = 0;
        if (this.broken) return;
        // The destination: a render target, or the canvas presented.
        const rt = this.renderTarget;
        let canvas: GPUCanvas?;
        let pw: u32, ph: u32;
        let targets: PassTargets;
        if (rt != null) {
            pw = rt.width; ph = rt.height;
            if (pw == 0 || ph == 0) return;
            canvas = rt.ensureCanvas(this.context);
            if (!this.rtTargets.has(rt.id)) this.rtTargets.set(rt.id, new PassTargets());
            targets = this.rtTargets.get(rt.id);
            this.passRatio = 1;
        } else {
            pw = this.pixelWidth(); ph = this.pixelHeight();
            if (pw == 0 || ph == 0) return;
            canvas = this.ensureCanvas();
            if (canvas != null && (canvas.width != pw || canvas.height != ph)) {
                if (!canvas.resize(pw, ph)) return;
            }
            targets = this.mainTargets;
            this.passRatio = this.pixelRatio;
        }
        if (canvas == null) return;
        const target = canvas.view;
        if (target == null) return;
        if (!this.ensureSetup(canvas)) return;
        this.passSamples = rt != null ? (rt.samples > 1 ? this.samples : 1) : this.samples;
        this.passWidth = pw;
        this.passHeight = ph;
        this.ensureTargets(targets, canvas, pw, ph, this.passSamples);
        const depthView = targets.depthView;
        if (depthView == null) return;
        this.drainDisposed();

        // Matrices.
        if (scene.matrixWorldAutoUpdate) scene.updateMatrixWorld();
        if (camera.parent == null && camera.matrixWorldAutoUpdate) camera.updateMatrixWorld();
        else camera.updateWorldMatrix(true, false);
        Mat4.multiply(this.viewProj.mat4, camera.projectionMatrix.mat4, camera.matrixWorldInverse.mat4);
        this.invViewProj.copy(this.viewProj).invert();
        _frustum.setFromProjectionMatrix(this.viewProj);

        // Collect lights and draws (textures draw and upload here).
        this.overrideMaterial = scene instanceof Scene ? (scene as Scene).overrideMaterial : null;
        this.collect(scene, camera, info.frame);
        const background = this.prepareBackground(scene, info.frame, canvas);
        this.prepareEnvironment(scene, info.frame, canvas);
        this.writeFrame(scene, camera);
        if (this.sortObjects) {
            this.opaque.sort(compareOpaque);
            this.transparent.sort(compareTransparent);
        }
        // Per-draw blocks; mip chains render here, before the main pass.
        this.writeDraws(this.opaque, info.frame, canvas);
        this.writeDraws(this.transparent, info.frame, canvas);

        // The pass.
        const color = this.colorAttachment;
        let r: f64 = this.clearColor.r, g: f64 = this.clearColor.g, b: f64 = this.clearColor.b;
        let a = this.clearAlpha;
        if (scene instanceof Scene) {
            const bg = (scene as Scene).background;
            if (bg != null && bg instanceof Color) {
                const c = bg as Color;
                const k = (scene as Scene).backgroundIntensity;
                r = c.r * k; g = c.g * k; b = c.b * k; a = 1;
            }
        }
        color.clearR = <f32>(LinearToSRGB(r) * a);
        color.clearG = <f32>(LinearToSRGB(g) * a);
        color.clearB = <f32>(LinearToSRGB(b) * a);
        color.clearA = <f32>a;
        color.loadOp = this.autoClear ? LoadOp.clear : LoadOp.load;
        const msaa = targets.msaaView;
        if (msaa != null) {
            color.view = msaa;
            color.resolveTarget = target;
            color.storeOp = StoreOp.discard;
            // An MSAA texture cannot keep the last frame: always clear it.
            color.loadOp = LoadOp.clear;
        } else {
            color.view = null;
            color.resolveTarget = null;
            color.storeOp = StoreOp.store;
        }
        const pd = this.passDesc;
        pd.label = "three";
        pd.color = [color];
        pd.depthView = depthView;
        pd.depthLoadOp = LoadOp.clear;
        pd.depthStoreOp = StoreOp.discard;
        pd.depthClearValue = 1;
        const pass = canvas.beginRenderPass(pd);
        if (background) {
            pass.setPipeline(this.pipeline(KEY_BACKGROUND | (this.passSamples > 1 ? KEY_MSAA : 0)));
            pass.setBindGroup(0, this.frameGroup!);
            pass.setBindGroup(3, this.bgGroup!);
            pass.draw(3);
        }
        this.drawList(pass, this.opaque);
        this.drawList(pass, this.transparent);
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
        const states = this.states.values();
        for (let i = 0; i < states.length; i++) states[i].ubo.release();
        this.states.clear();
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
            if (module == null) return this.fail("shader asset 'three/shaders/three.wgsl' not found");
            this.module = module;
            const g0 = GPUBindGroupLayout.fromShader(module, 0);
            const g1 = GPUBindGroupLayout.fromShader(module, 1);
            const g2 = GPUBindGroupLayout.fromShader(module, 2);
            const g3 = GPUBindGroupLayout.fromShader(module, 3);
            if (g0 == null || g1 == null || g2 == null || g3 == null) return this.fail("bind group layouts rejected");
            this.frameLayout = g0;
            this.objLayout = g1;
            this.matLayout = g2;
            this.bgLayout = g3;

            const instance = new GPUVertexBufferLayout();
            instance.stride = INSTANCE_STRIDE;
            instance.stepMode = VertexStepMode.instance;
            instance.attributes = [
                new GPUVertexAttribute(VertexFormat.float4, 4, 0),
                new GPUVertexAttribute(VertexFormat.float4, 5, 16),
                new GPUVertexAttribute(VertexFormat.float4, 6, 32),
                new GPUVertexAttribute(VertexFormat.float4, 7, 48),
                new GPUVertexAttribute(VertexFormat.float4, 8, 64),
            ];
            this.vertexBuffers = [
                vertexLayout(12, VertexFormat.float3, 0),
                vertexLayout(12, VertexFormat.float3, 1),
                vertexLayout(8, VertexFormat.float2, 2),
                vertexLayout(16, VertexFormat.float4, 3),
                instance,
            ];
            const pointPosition = vertexLayout(12, VertexFormat.float3, 0);
            pointPosition.stepMode = VertexStepMode.instance;
            const pointColor = vertexLayout(16, VertexFormat.float4, 3);
            pointColor.stepMode = VertexStepMode.instance;
            this.pointBuffers = [pointPosition, pointColor];
            this.skinBuffers = this.vertexBuffers.concat([
                vertexLayout(16, VertexFormat.float4, 9),
                vertexLayout(16, VertexFormat.float4, 10),
            ]);
            this.dummyBones = new GPUBuffer(BufferUsage.uniform, <u32>BONES_BYTES);
            const features = this.context.features();
            this.samples = this.antialias && features.maxSamples >= 4 ? 4 : 1;
            this.maxAnisotropy = features.anisotropicFiltering ? 16 : 1;

            const ubo = new GPUBuffer(BufferUsage.uniform, <u32>FRAME_BYTES);
            this.frameUbo = ubo;

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
            const id = new Float32Array(20);
            id[0] = 1; id[5] = 1; id[10] = 1; id[15] = 1;
            id[16] = 1; id[17] = 1; id[18] = 1; id[19] = 1;
            this.identityInstance = new GPUBuffer(BufferUsage.vertex, <u32>INSTANCE_STRIDE, id.buffer, true);
        }
        if (this.pipelineFormat != canvas.format) {
            this.pipelines.clear();
            this.pipelineFormat = canvas.format;
        }
        return true;
    }

    private ensureTargets(t: PassTargets, canvas: GPUCanvas, w: u32, h: u32, samples: u32): void {
        if (t.depthView != null && t.width == w && t.height == h && t.format == canvas.format && t.samples == samples) return;
        t.release();
        const dd = new GPUTextureDesc();
        dd.width = w; dd.height = h;
        dd.format = TextureFormat.depth32float;
        dd.renderTarget = true;
        dd.sampleCount = samples;
        const depth = new GPUTexture(dd);
        t.depthTex = depth;
        t.depthView = depth.view();
        if (samples > 1) {
            const md = new GPUTextureDesc();
            md.width = w; md.height = h;
            md.format = <TextureFormat>canvas.format;
            md.renderTarget = true;
            md.sampleCount = samples;
            const msaa = new GPUTexture(md);
            t.msaaTex = msaa;
            t.msaaView = msaa.view();
        }
        t.width = w;
        t.height = h;
        t.format = canvas.format;
        t.samples = samples;
    }

    private pipeline(key: i32): GPUPipeline {
        if (this.pipelines.has(key)) return this.pipelines.get(key);
        const target = new GPUColorTargetDesc();
        target.format = <TextureFormat>this.pipelineFormat;
        const ds = new GPUDepthStencilDesc();
        ds.format = TextureFormat.depth32float;
        const d = new GPUPipelineDesc();
        d.vertexModule = this.module;
        d.fragmentModule = this.module;
        d.sampleCount = (key & KEY_MSAA) != 0 ? this.samples : 1;
        d.depthStencil = ds;
        if ((key & KEY_BACKGROUND) != 0) {
            d.vertexEntryPoint = "vs_background";
            d.fragmentEntryPoint = "fs_background";
            ds.compare = CompareFunction.always;
            ds.write = false;
            d.colorTargets = [target];
            d.bindGroupLayouts = [this.frameLayout, null, null, this.bgLayout];
        } else {
            const cull = key & KEY_CULL_MASK;
            const blending = (key >> KEY_BLEND_SHIFT) & 7;
            const blend = blendState(blending);
            if (blend != null) target.blend = blend;
            if ((key & KEY_COLOR_WRITE) == 0) target.writeMask = <u32>ColorWriteMask.none;
            ds.compare = (key & KEY_DEPTH_TEST) != 0 ? CompareFunction.lessEqual : CompareFunction.always;
            ds.write = (key & KEY_DEPTH_WRITE) != 0;
            const prim = (key >> KEY_PRIM_SHIFT) & 3;
            d.fragmentEntryPoint = "fs_main";
            d.colorTargets = [target];
            d.bindGroupLayouts = [this.frameLayout, this.objLayout, this.matLayout];
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
                d.vertexEntryPoint = "vs_skinned";
                d.vertexBuffers = this.skinBuffers;
            } else {
                d.vertexEntryPoint = "vs_main";
                d.vertexBuffers = this.vertexBuffers;
                if (prim == PRIM_LINES) {
                    d.topology = PrimitiveTopology.lineList;
                    d.cullMode = CullMode.none;
                }
            }
        }
        const p = new GPUPipeline(d);
        this.pipelines.set(key, p);
        return p;
    }

    /// The pipeline of a ShaderMaterial draw (null when its shader is
    /// missing: the draw is skipped, with one log line).
    private customPipeline(material: ShaderMaterial, key: i32): CustomPipeline? {
        const name = material.shader + "|" + material.vertexEntryPoint + "|" + material.fragmentEntryPoint + "|"
            + key.toString();
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
        const g1 = GPUBindGroupLayout.fromShader(module, 1);
        if (g0 == null || g1 == null) return null;
        const hasUniforms = material.uniforms.size > 0;
        const g2 = hasUniforms ? GPUBindGroupLayout.fromShader(module, 2) : null;
        const target = new GPUColorTargetDesc();
        target.format = <TextureFormat>this.pipelineFormat;
        const ds = new GPUDepthStencilDesc();
        ds.format = TextureFormat.depth32float;
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
        const frameGroup = new GPUBindGroup(g0, [new GPUBindGroupUBO(0, this.frameUbo!)]);
        const cp = new CustomPipeline(p, g0, g1, frameGroup);
        cp.layout2 = g2;
        this.customPipelines.set(name, cp);
        return cp;
    }

    /// Blending, write mask, depth and culling from a pipeline key.
    private applyState(d: GPUPipelineDesc, target: GPUColorTargetDesc, ds: GPUDepthStencilDesc, key: i32): void {
        const cull = key & KEY_CULL_MASK;
        const blend = blendState((key >> KEY_BLEND_SHIFT) & 7);
        if (blend != null) target.blend = blend;
        if ((key & KEY_COLOR_WRITE) == 0) target.writeMask = <u32>ColorWriteMask.none;
        ds.compare = (key & KEY_DEPTH_TEST) != 0 ? CompareFunction.lessEqual : CompareFunction.always;
        ds.write = (key & KEY_DEPTH_WRITE) != 0;
        d.colorTargets = [target];
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
        if (cu.staging.byteLength != size) cu.staging = new ArrayBuffer(size);
        const f = Float32Array.wrap(cu.staging);
        let offset = 0;
        const views: Array<GPUTextureView> = [];
        let firstTexture: Texture? = null;
        for (let i = 0; i < names.length; i++) {
            const u = material.uniforms.get(names[i]);
            const t = u.texture();
            if (t != null) {
                this.textures.update(t, frame);
                const v = this.textures.view(t, canvas);
                views.push(v != null ? v : this.white!);
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
            cu.group = new GPUBindGroup(layout, ubos, textures, samplers);
            cu.views = views;
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

    private drainDisposed(): void {
        for (let i = 0; i < disposedGeometries.length; i++) this.geometries.dispose(disposedGeometries[i]);
        disposedGeometries.length = 0;
        for (let i = 0; i < disposedTextures.length; i++) this.textures.dispose(disposedTextures[i]);
        disposedTextures.length = 0;
    }

    // ---------------------------------------------------------------- collect

    private collect(scene: Object3D, camera: Camera, frame: i32): void {
        this.opaque.length = 0;
        this.transparent.length = 0;
        this.lights.length = 0;
        const stack = this.stack;
        stack.length = 0;
        stack.push(scene);
        while (stack.length > 0) {
            const o = stack.pop();
            if (!o.visible) continue;
            if (o.layers.test(camera.layers)) {
                if (o instanceof LOD && (o as LOD).autoUpdate) (o as LOD).update(camera);
                if (o instanceof Light) {
                    this.lights.push(o as Light);
                } else if (o instanceof Mesh || o instanceof Line || o instanceof Points || o instanceof Sprite) {
                    if (!o.frustumCulled || this.inFrustum(o)) this.collectObject(o, frame);
                    else this.info.render.culled++;
                }
            }
            const children = o.children;
            for (let i = children.length - 1; i >= 0; i--) stack.push(children[i]);
        }
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
        const g = this.geometries.get(geometry);
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
        let instances = this.identityInstance!;
        let instanceCount: u32 = 1;
        if (mesh instanceof InstancedMesh) {
            const im = mesh as InstancedMesh;
            if (im.count <= 0) return;
            instances = this.instanceBuffer(im);
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
                    instanceCount);
            }
        } else {
            this.addMeshDraw(mesh, override != null ? override : mesh.material, geometry, g, 0, rangeStart, rangeEnd,
                frame, instances, instanceCount);
        }
    }

    private addMeshDraw(mesh: Mesh, material: Material, geometry: BufferGeometry, g: GeometryGPU, part: i32,
                        start: i32, end: i32, frame: i32, instances: GPUBuffer, instanceCount: u32): void {
        if (material.wireframe) {
            if (!this.geometries.lines(geometry, g, LINE_WIREFRAME)) return;
            // Each triangle's three edges: index range x2.
            const item = this.addDraw(mesh, material, g, part, start * 2, end * 2, frame, PRIM_LINES);
            if (item == null) return;
            item.index = g.lineBuffers[LINE_WIREFRAME];
            item.indexFormat = <u32>g.lineFormats[LINE_WIREFRAME];
            item.instances = instances;
            item.instanceCount = instanceCount;
            return;
        }
        const item = this.addDraw(mesh, material, g, part, start, end, frame, PRIM_TRIANGLES);
        if (item == null) return;
        item.instances = instances;
        item.instanceCount = instanceCount;
        if (g.indexed) {
            item.index = g.index;
            item.indexFormat = <u32>g.indexFormat;
        }
        this.deform(mesh, geometry, g, item, frame);
    }

    /// Morph targets (CPU) and skinning (GPU) for a mesh draw.
    private deform(mesh: Mesh, geometry: BufferGeometry, g: GeometryGPU, item: DrawItem, frame: i32): void {
        if (mesh.morphTargetInfluences.length > 0 && geometry.morphAttributes.has("position")) {
            const m = this.morph(mesh, geometry);
            if (m != null) {
                item.positionOverride = m.position;
                item.normalOverride = m.normal;
            }
        }
        if (!(mesh instanceof SkinnedMesh)) return;
        const sm = mesh as SkinnedMesh;
        const skeleton = sm.skeleton;
        if (skeleton == null || g.skinIndex == null || g.skinWeight == null) return;
        if (skeleton.bones.length > MAX_BONES) {
            if (!this.warnedBones) {
                this.context.log("three: skeletons over " + MAX_BONES.toString() + " bones draw unskinned");
                this.warnedBones = true;
            }
            return;
        }
        if (skeleton.frame != frame) {
            skeleton.update();
            skeleton.frame = frame;
        }
        let bones: GPUBuffer;
        if (this.boneBuffers.has(sm.id)) bones = this.boneBuffers.get(sm.id);
        else {
            bones = new GPUBuffer(BufferUsage.uniform, <u32>BONES_BYTES);
            this.boneBuffers.set(sm.id, bones);
        }
        const data = skeleton.boneMatrices;
        if (data.length > 0) bones.update(0, data.buffer, <u32>data.byteLength);
        item.skinned = true;
        item.bones = bones;
        item.pipelineKey |= KEY_SKINNED;
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
        m.influences = influences.slice();
        m.geometryVersion = position.version;
        const relative = geometry.morphTargetsRelative;
        m.positions = blend(position.array, geometry.morphAttributes.get("position"), influences, relative, m.positions);
        m.position = uploadVertices(m.position, m.positions);
        const normal = geometry.getAttribute("normal");
        if (normal != null && normal.count == position.count) {
            if (geometry.morphAttributes.has("normal")) {
                m.normals = blend(normal.array, geometry.morphAttributes.get("normal"), influences, relative, m.normals);
                m.normal = uploadVertices(m.normal, m.normals);
            } else {
                m.normal = null;
            }
        }
        return m;
    }

    private addDraw(object: Object3D, material: Material, g: GeometryGPU?, part: i32, start: i32, end: i32,
                    frame: i32, prim: i32): DrawItem? {
        if (!material.visible || end <= start) return null;
        const stateKey = object.id * 64 + part;
        let state: DrawState;
        if (this.states.has(stateKey)) state = this.states.get(stateKey);
        else {
            state = new DrawState();
            this.states.set(stateKey, state);
        }
        if (this.envCandidate == null && material instanceof MeshStandardMaterial) {
            const em = (material as MeshStandardMaterial).envMap;
            if (em != null) this.envCandidate = em;
        }
        // Textures draw and upload now, before any pass.
        const u = this.uniforms;
        material.fillUniforms(u);
        for (let i = 0; i < TEXTURE_SLOTS; i++) {
            const t = u.textures[i];
            if (t != null) this.textures.update(t, frame);
        }

        const item = new DrawItem(object, material, g, state, this.identityInstance!);
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
            | (this.passSamples > 1 ? KEY_MSAA : 0);
        if (material instanceof ShaderMaterial) {
            if (prim != PRIM_TRIANGLES) return null;   // custom points/lines are not supported
            const cp = this.customPipeline(material as ShaderMaterial, item.pipelineKey);
            if (cp == null) return null;
            item.custom = cp;
        }
        const e = object.matrixWorld.elements;
        _pos.set(e[12], e[13], e[14]).applyMatrix4(this.viewProj);
        item.depth = _pos.z;
        if (material.transparent) this.transparent.push(item);
        else this.opaque.push(item);
        return item;
    }

    /// The InstancedMesh's instances, packed as mat4 + RGBA, re-uploaded when
    /// instanceMatrix or instanceColor changed.
    private instanceBuffer(im: InstancedMesh): GPUBuffer {
        let ig: InstanceGPU;
        if (this.instanceBuffers.has(im.id)) ig = this.instanceBuffers.get(im.id);
        else {
            ig = new InstanceGPU();
            this.instanceBuffers.set(im.id, ig);
        }
        const capacity = im.instanceMatrix.count;
        const colors = im.instanceColor;
        const colorVersion = colors != null ? colors.version : -2;
        if (ig.buffer != null && ig.matrixVersion == im.instanceMatrix.version && ig.colorVersion == colorVersion
                && ig.count == capacity) {
            return ig.buffer!;
        }
        const floats = <i32>INSTANCE_STRIDE / 4;
        if (ig.staging.length != capacity * floats) ig.staging = new Float32Array(capacity * floats);
        const out = ig.staging;
        const m = im.instanceMatrix.array;
        for (let i = 0; i < capacity; i++) {
            const o = i * floats;
            for (let k = 0; k < 16; k++) out[o + k] = m[i * 16 + k];
            if (colors != null) {
                out[o + 16] = colors.array[i * 3];
                out[o + 17] = colors.array[i * 3 + 1];
                out[o + 18] = colors.array[i * 3 + 2];
            } else {
                out[o + 16] = 1; out[o + 17] = 1; out[o + 18] = 1;
            }
            out[o + 19] = 1;
        }
        const bytes = out.buffer;
        const existing = ig.buffer;
        if (existing != null && existing.size == <u32>bytes.byteLength) existing.update(0, bytes);
        else {
            if (existing != null) existing.release();
            ig.buffer = new GPUBuffer(BufferUsage.vertex, <u32>bytes.byteLength, bytes);
        }
        ig.matrixVersion = im.instanceMatrix.version;
        ig.colorVersion = colorVersion;
        ig.count = capacity;
        return ig.buffer!;
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
        const view = this.textures.view(t, canvas);
        if (view == null) return false;
        this.bgTexture = t;
        if (this.bgGroup == null || this.bgView !== view) {
            const mipmapped = wantsMipmaps(t);
            this.bgGroup = new GPUBindGroup(this.bgLayout!, [],
                [new GPUBindGroupTexture(0, view)], [new GPUBindGroupSampler(1, this.backgroundSampler(mipmapped))]);
            this.bgView = view;
        }
        return true;
    }

    /// The environment map (scene.environment, else the first material
    /// envMap seen) and the frame bind group that samples it.
    private prepareEnvironment(scene: Object3D, frame: i32, canvas: GPUCanvas): void {
        let env: Texture? = scene instanceof Scene ? (scene as Scene).environment : null;
        if (env == null) env = this.envCandidate;
        this.envCandidate = null;
        let view: GPUTextureView? = null;
        if (env != null) {
            env.generateMipmaps = true;
            if (env.minFilter != LinearMipmapLinearFilter) env.minFilter = LinearMipmapLinearFilter;
            this.textures.update(env, frame);
            view = this.textures.view(env, canvas);
        }
        this.envTexture = view != null ? env : null;
        this.envLevels = env != null && view != null ? this.textures.levels(env) : 1;
        const bind = view != null ? view! : this.white!;
        if (this.frameGroup == null || this.frameGroupView !== bind) {
            this.frameGroup = new GPUBindGroup(this.frameLayout!, [new GPUBindGroupUBO(0, this.frameUbo!)],
                [new GPUBindGroupTexture(1, bind)], [new GPUBindGroupSampler(2, this.backgroundSampler(true))]);
            this.frameGroupView = bind;
        }
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
        const f = Float32Array.wrap(buf);
        const u = Uint32Array.wrap(buf);
        this.viewProj.mat4.writeToBuffer(buf, FRAME_VIEW_PROJ);
        camera.matrixWorldInverse.mat4.writeToBuffer(buf, FRAME_VIEW);
        this.invViewProj.mat4.writeToBuffer(buf, FRAME_INV_VIEW_PROJ);
        camera.projectionMatrix.mat4.writeToBuffer(buf, FRAME_PROJ);
        put4(f, FRAME_VIEWPORT, <f64>this.passWidth, <f64>this.passHeight, this.passRatio, 0);
        const cw = camera.matrixWorld.elements;
        let o = FRAME_CAMERA_POS >> 2;
        f[o] = cw[12]; f[o + 1] = cw[13]; f[o + 2] = cw[14];
        f[o + 3] = camera instanceof OrthographicCamera ? 1 : 0;
        camera.getWorldDirection(_dir);
        o = FRAME_CAMERA_DIR >> 2;
        f[o] = <f32>_dir.x; f[o + 1] = <f32>_dir.y; f[o + 2] = <f32>_dir.z; f[o + 3] = 0;

        // Lights.
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
            const directional = light instanceof DirectionalLight;
            const spot = light instanceof SpotLight;
            if (!directional && !spot && !(light instanceof PointLight)) continue;
            if (count >= MAX_LIGHTS) {
                if (!this.warnedLights) {
                    this.context.log("three: more than " + MAX_LIGHTS.toString() + " lights; the rest are ignored");
                    this.warnedLights = true;
                }
                continue;
            }
            const base = (FRAME_LIGHTS + count * LIGHT_BYTES) >> 2;
            light.getWorldPosition(_pos);
            f[base] = <f32>_pos.x; f[base + 1] = <f32>_pos.y; f[base + 2] = <f32>_pos.z;
            f[base + 8] = <f32>(light.color.r * k);
            f[base + 9] = <f32>(light.color.g * k);
            f[base + 10] = <f32>(light.color.b * k);
            f[base + 13] = 0; f[base + 14] = 0; f[base + 15] = 0;
            if (directional) {
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
            count++;
        }
        o = FRAME_AMBIENT >> 2;
        f[o] = <f32>ar; f[o + 1] = <f32>ag; f[o + 2] = <f32>ab; f[o + 3] = <f32>count;
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
            const levels = this.textures.levels(bt);
            f[o + 3] = <f32>(Math.max(0, Math.min(1, s.backgroundBlurriness)) * <f64>(levels - 1));
            _euler.set(-s.backgroundRotation.x, -s.backgroundRotation.y, -s.backgroundRotation.z,
                s.backgroundRotation.order);
            _bgRotation.makeRotationFromEuler(_euler);
            _bgRotation.mat4.writeToBuffer(buf, FRAME_BG_ROTATION);
            const b = FRAME_BG_FLAGS >> 2;
            const equirect = bt.mapping == EquirectangularReflectionMapping
                || bt.mapping == EquirectangularRefractionMapping;
            u[b] = equirect ? <u32>EquirectangularReflectionMapping : 0;
            u[b + 1] = bt.colorSpace == SRGBColorSpace ? 1 : 0;
            u[b + 2] = bt.flipY ? 1 : 0;
            u[b + 3] = bt.premultiplyAlpha ? 1 : 0;
        }
        // Environment.
        o = FRAME_ENV >> 2;
        const et = this.envTexture;
        if (et != null) {
            const intensity = scene instanceof Scene ? (scene as Scene).environmentIntensity : 1;
            f[o] = 1; f[o + 1] = <f32>intensity; f[o + 2] = <f32>Math.max(0, <f64>this.envLevels - 2); f[o + 3] = 0;
            if (scene instanceof Scene) {
                const r = (scene as Scene).environmentRotation;
                _euler.set(-r.x, -r.y, -r.z, r.order);
            } else {
                _euler.set(0, 0, 0);
            }
            _bgRotation.makeRotationFromEuler(_euler);
            _bgRotation.mat4.writeToBuffer(buf, FRAME_ENV_ROTATION);
            const b = FRAME_ENV_FLAGS >> 2;
            u[b] = et.colorSpace == SRGBColorSpace ? 1 : 0;
            u[b + 1] = et.flipY ? 1 : 0;
            u[b + 2] = et.premultiplyAlpha ? 1 : 0;
            u[b + 3] = 0;
        } else {
            f[o] = 0;
        }
        this.frameUbo!.update(0, buf);
    }

    private writeDraws(list: Array<DrawItem>, frame: i32, canvas: GPUCanvas): void {
        const buf = this.objStaging;
        const f = Float32Array.wrap(buf);
        const u = Uint32Array.wrap(buf);
        const mu = this.uniforms;
        for (let i = 0; i < list.length; i++) {
            const item = list[i];
            const state = item.state;
            if (state.frame == frame) continue;
            state.frame = frame;
            const object = item.object;
            item.material.fillUniforms(mu);

            object.matrixWorld.mat4.writeToBuffer(buf, OBJ_MODEL);
            _normal.getNormalMatrix(object.matrixWorld);
            const ne = _normal.elements;
            let o = OBJ_NORMAL >> 2;
            for (let c = 0; c < 3; c++) {
                f[o + c * 4] = <f32>ne[c * 3];
                f[o + c * 4 + 1] = <f32>ne[c * 3 + 1];
                f[o + c * 4 + 2] = <f32>ne[c * 3 + 2];
                f[o + c * 4 + 3] = 0;
            }
            f[o + 12] = 0; f[o + 13] = 0; f[o + 14] = 0; f[o + 15] = 1;
            put4(f, OBJ_COLOR, mu.r, mu.g, mu.b, mu.opacity);
            put4(f, OBJ_EMISSIVE, mu.emissiveR, mu.emissiveG, mu.emissiveB, mu.alphaTest);
            put4(f, OBJ_PBR, mu.roughness, mu.metalness, mu.flatShading ? 1 : 0, mu.aoMapIntensity);
            put4(f, OBJ_SPECULAR, mu.specularR, mu.specularG, mu.specularB, mu.shininess);
            put4(f, OBJ_EXTRA, mu.normalScaleX, mu.normalScaleY, mu.envMapIntensity, mu.ior);
            put4(f, OBJ_PHYSICAL0, mu.clearcoat, mu.clearcoatRoughness, mu.sheenRoughness, mu.specularIntensity);
            put4(f, OBJ_PHYSICAL1, mu.sheenR * mu.sheen, mu.sheenG * mu.sheen, mu.sheenB * mu.sheen, 0);
            put4(f, OBJ_PHYSICAL2, mu.specularColorR, mu.specularColorG, mu.specularColorB, 0);
            put4(f, OBJ_POINTS, mu.size, mu.sizeAttenuation ? 1 : 0, mu.rotation, <f64>this.passHeight * 0.5);
            put4(f, OBJ_DASH, mu.dashSize, mu.gapSize, mu.dashScale, 0);
            if (object instanceof Sprite) {
                const c = (object as Sprite).center;
                put4(f, OBJ_SPRITE, c.x, c.y, 0, 0);
            }

            // Textures: views, flags, the shared sampler and UV transform
            // (from the first texture present, `map` first).
            let present: u32 = 0, srgb: u32 = 0, flip: u32 = 0, premul: u32 = 0;
            let first: Texture? = null;
            let firstMipmapped = false;
            const views = _views;
            for (let s = 0; s < TEXTURE_SLOTS; s++) {
                views[s] = this.white;
                const t = mu.textures[s];
                if (t == null) continue;
                const v = this.textures.view(t, canvas);
                if (v == null) continue;
                views[s] = v;
                const bit: u32 = 1 << <u32>s;
                present |= bit;
                if (t.colorSpace == SRGBColorSpace) srgb |= bit;
                if (t.flipY) flip |= bit;
                if (t.premultiplyAlpha) premul |= bit;
                if (first == null) {
                    first = t;
                    firstMipmapped = this.textures.levels(t) > 1;
                }
            }
            let sampler: GPUSampler;
            if (first != null) {
                sampler = this.sampler(first, firstMipmapped);
                put4(f, OBJ_UV, first.offset.x, first.offset.y, first.repeat.x, first.repeat.y);
            } else {
                sampler = this.defaultSampler();
                put4(f, OBJ_UV, 0, 0, 1, 1);
            }
            o = OBJ_TEX_FLAGS >> 2;
            u[o] = <u32>mu.kind; u[o + 1] = present; u[o + 2] = srgb; u[o + 3] = flip;
            let flags: u32 = 0;
            if (mu.vertexColors) flags |= FLAG_VERTEX_COLORS;
            if (mu.fog) flags |= FLAG_FOG;
            if (item.material.transparent) flags |= FLAG_TRANSPARENT;
            if (item.material.toneMapped && this.toneMapping != NoToneMapping) flags |= FLAG_TONE_MAPPED;
            o = OBJ_FLAGS >> 2;
            u[o] = premul; u[o + 1] = flags; u[o + 2] = 0; u[o + 3] = 0;
            state.ubo.update(0, buf);

            if (item.skinned) {
                const sm = object as SkinnedMesh;
                sm.bindMatrix.mat4.writeToBuffer(buf, OBJ_BIND_MATRIX);
                sm.bindMatrixInverse.mat4.writeToBuffer(buf, OBJ_BIND_MATRIX_INVERSE);
                state.ubo.update(0, buf);
            }
            const cp = item.custom;
            if (cp != null) {
                if (state.customObjGroup == null || state.customLayout !== cp.layout1) {
                    state.customObjGroup = new GPUBindGroup(cp.layout1, [new GPUBindGroupUBO(0, state.ubo)]);
                    state.customLayout = cp.layout1;
                }
                item.customUniforms = this.prepareCustomUniforms(item.material as ShaderMaterial, cp, frame, canvas);
                continue;
            }
            const bones = item.bones != null ? item.bones! : this.dummyBones!;
            if (state.objGroup == null || state.bones !== bones) {
                state.objGroup = new GPUBindGroup(this.objLayout!,
                    [new GPUBindGroupUBO(0, state.ubo), new GPUBindGroupUBO(1, bones)]);
                state.bones = bones;
            }
            let changed = state.matGroup == null || state.sampler !== sampler;
            for (let s = 0; s < TEXTURE_SLOTS && !changed; s++) changed = state.views[s] !== views[s];
            if (changed) {
                const entries: Array<GPUBindGroupTexture> = [];
                for (let s = 0; s < TEXTURE_SLOTS; s++) {
                    entries.push(new GPUBindGroupTexture(<u32>s, views[s]!));
                    state.views[s] = views[s];
                }
                state.matGroup = new GPUBindGroup(this.matLayout!, [], entries,
                    [new GPUBindGroupSampler(<u32>TEXTURE_SLOTS, sampler)]);
                state.sampler = sampler;
            }
        }
    }

    // ------------------------------------------------------------------ draw

    private drawList(pass: GPURenderPass, list: Array<DrawItem>): void {
        const info = this.info.render;
        let lastKey = -1;
        for (let i = 0; i < list.length; i++) {
            const item = list[i];
            const state = item.state;
            const cp = item.custom;
            if (cp != null) {
                const g = item.geometry!;
                pass.setPipeline(cp.pipeline);
                lastKey = -1;
                pass.setBindGroup(0, cp.frameGroup);
                pass.setBindGroup(1, state.customObjGroup!);
                const cu = item.customUniforms;
                if (cu != null && cu.group != null) pass.setBindGroup(2, cu.group!);
                pass.setVertexBuffer(0, g.position!);
                pass.setVertexBuffer(1, g.normal!);
                pass.setVertexBuffer(2, g.uv!);
                pass.setVertexBuffer(3, g.color!);
                pass.setVertexBuffer(4, item.instances);
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
            if (state.objGroup == null || state.matGroup == null) continue;
            if (item.pipelineKey != lastKey) {
                pass.setPipeline(this.pipeline(item.pipelineKey));
                pass.setBindGroup(0, this.frameGroup!);
                lastKey = item.pipelineKey;
            }
            pass.setBindGroup(1, state.objGroup!);
            pass.setBindGroup(2, state.matGroup!);
            const prim = item.prim;
            if (prim == PRIM_SPRITE) {
                pass.draw(6);
                info.calls++;
                info.triangles += 2;
                continue;
            }
            const g = item.geometry!;
            if (prim == PRIM_POINTS) {
                pass.setVertexBuffer(0, g.position!, <u32>(item.first * 12));
                pass.setVertexBuffer(1, g.color!, <u32>(item.first * 16));
                pass.draw(6, <u32>item.count);
                info.calls++;
                info.points += item.count;
                continue;
            }
            const pos = item.positionOverride;
            const nrm = item.normalOverride;
            pass.setVertexBuffer(0, pos != null ? pos : g.position!);
            pass.setVertexBuffer(1, nrm != null ? nrm : g.normal!);
            pass.setVertexBuffer(2, g.uv!);
            pass.setVertexBuffer(3, g.color!);
            pass.setVertexBuffer(4, item.instances);
            if (item.skinned) {
                pass.setVertexBuffer(5, g.skinIndex!);
                pass.setVertexBuffer(6, g.skinWeight!);
            }
            const index = item.index;
            if (index != null) {
                pass.setIndexBuffer(index, item.indexFormat);
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
