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
// Output is sRGB, premultiplied. Draw order: opaque front to back, then
// transparent back to front, each by renderOrder first.

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
    BufferUsage, TextureFormat, CompareFunction, CullMode, VertexFormat, LoadOp, StoreOp, Filter, WrapMode,
    BlendFactor, FaceWinding,
} from "rive/gpu_enums";
import { rive_gpu_texture_upload_v1 } from "rive/bindings";

import { Object3D } from "../core/Object3D";
import { disposedGeometries } from "../core/BufferGeometry";
import { Camera } from "../cameras/Camera";
import { OrthographicCamera } from "../cameras/OrthographicCamera";
import { Scene } from "../scenes/Scene";
import { Mesh } from "../objects/Mesh";
import { Light } from "../lights/Light";
import { AmbientLight } from "../lights/AmbientLight";
import { DirectionalLight } from "../lights/DirectionalLight";
import { PointLight } from "../lights/PointLight";
import { Material } from "../materials/Material";
import { MeshBasicMaterial } from "../materials/MeshBasicMaterial";
import { MeshNormalMaterial } from "../materials/MeshNormalMaterial";
import { MeshLambertMaterial } from "../materials/MeshLambertMaterial";
import { MeshStandardMaterial } from "../materials/MeshStandardMaterial";
import { Texture, disposedTextures } from "../textures/Texture";
import { Color, LinearToSRGB } from "../math/Color";
import { Vector2 } from "../math/Vector2";
import { Vector3 } from "../math/Vector3";
import { Matrix3 } from "../math/Matrix3";
import { Matrix4 } from "../math/Matrix4";
import { Frustum } from "../math/Frustum";
import { Sphere } from "../math/Sphere";
import {
    BackSide, DoubleSide, NearestFilter, NearestMipmapNearestFilter, NearestMipmapLinearFilter,
    RepeatWrapping, MirroredRepeatWrapping, SRGBColorSpace,
} from "../constants";
import { GPUGeometries, GeometryGPU } from "./gpu/GPUGeometries";

// --- layout (mirrors three/shaders/three.wgsl) --------------------------------

const MAX_LIGHTS: i32 = 8;
const FRAME_VIEW_PROJ: i32 = 0;
const FRAME_VIEW: i32 = 64;
const FRAME_CAMERA_POS: i32 = 128;
const FRAME_CAMERA_DIR: i32 = 144;
const FRAME_AMBIENT: i32 = 160;
const FRAME_LIGHTS: i32 = 176;
const LIGHT_BYTES: i32 = 64;
const FRAME_BYTES: i32 = FRAME_LIGHTS + MAX_LIGHTS * LIGHT_BYTES;   // 688

const OBJ_MODEL: i32 = 0;
const OBJ_NORMAL: i32 = 64;
const OBJ_COLOR: i32 = 128;
const OBJ_EMISSIVE: i32 = 144;
const OBJ_PBR: i32 = 160;
const OBJ_UV: i32 = 176;
const OBJ_FLAGS: i32 = 192;
const OBJ_BYTES: i32 = 256;

const KIND_BASIC: u32 = 0;
const KIND_NORMAL: u32 = 1;
const KIND_LAMBERT: u32 = 2;
const KIND_STANDARD: u32 = 3;

const MAP_ON: u32 = 1;
const MAP_SRGB: u32 = 2;
const MAP_FLIP_Y: u32 = 4;
const MAP_PREMULTIPLIED: u32 = 8;

const LIGHT_DIRECTIONAL: f32 = 0;
const LIGHT_POINT: f32 = 1;

// The shader asset: newer CLIs name it by path, 1.9.x by file name.
const SHADER_NAMES: Array<string> = ["three/shaders/three", "shaders/three", "three"];

const uploadRegion = new rive_gpu_texture_upload_v1();

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
    /// Meshes skipped by frustum culling this frame (not in three.js).
    culled: i32 = 0;
}

export class RendererInfo {
    render: RenderInfo = new RenderInfo();
}

// One mesh's per-draw state, kept across frames.
class DrawState {
    ubo: GPUBuffer;
    group: GPUBindGroup? = null;
    view: GPUTextureView? = null;
    sampler: GPUSampler? = null;
    frame: i32 = -1;

    constructor() {
        this.ubo = new GPUBuffer(BufferUsage.uniform, <u32>OBJ_BYTES);
    }
}

// One draw of this frame.
class DrawItem {
    mesh: Mesh;
    geometry: GeometryGPU;
    state: DrawState;
    pipelineKey: i32 = 0;
    depth: f64 = 0;
    first: i32 = 0;
    count: i32 = 0;

    constructor(mesh: Mesh, geometry: GeometryGPU, state: DrawState) {
        this.mesh = mesh;
        this.geometry = geometry;
        this.state = state;
    }
}

export class GPURenderer {
    readonly context: Context;
    /// Clear the canvas before each render (else draw over the last one).
    autoClear: bool = true;
    /// Sort draws (opaque front to back, transparent back to front).
    sortObjects: bool = true;
    readonly info: RendererInfo = new RendererInfo();

    private canvas: GPUCanvas? = null;
    private width: f64 = 0;
    private height: f64 = 0;
    private pixelRatio: f64 = 1;
    private clearColor: Color = new Color(0, 0, 0);
    private clearAlpha: f64 = 1;
    private antialias: bool;
    private broken: bool = false;

    private module: GPUShaderModule? = null;
    private frameLayout: GPUBindGroupLayout? = null;
    private objLayout: GPUBindGroupLayout? = null;
    private vertexBuffers: Array<GPUVertexBufferLayout> = [];
    private pipelines: Map<i32, GPUPipeline> = new Map<i32, GPUPipeline>();
    private pipelineFormat: u32 = 0xFFFFFFFF;
    private samples: u32 = 1;

    private frameUbo: GPUBuffer? = null;
    private frameGroup: GPUBindGroup? = null;
    private frameStaging: ArrayBuffer = new ArrayBuffer(FRAME_BYTES);
    private objStaging: ArrayBuffer = new ArrayBuffer(OBJ_BYTES);
    private white: GPUTextureView? = null;
    private samplers: Map<i32, GPUSampler> = new Map<i32, GPUSampler>();

    private depthTex: GPUTexture? = null;
    private depthView: GPUTextureView? = null;
    private msaaTex: GPUTexture? = null;
    private msaaView: GPUTextureView? = null;
    private targetW: u32 = 0;
    private targetH: u32 = 0;
    private targetFormat: u32 = 0xFFFFFFFF;

    private geometries: GPUGeometries = new GPUGeometries();
    private states: Map<i32, DrawState> = new Map<i32, DrawState>();
    private textureFrames: Map<i32, i32> = new Map<i32, i32>();
    private opaque: Array<DrawItem> = [];
    private transparent: Array<DrawItem> = [];
    private lights: Array<Light> = [];
    private stack: Array<Object3D> = [];
    private warnedLights: bool = false;
    private colorAttachment: GPUColorAttachment = new GPUColorAttachment();
    private passDesc: GPUPassDesc = new GPUPassDesc();
    private viewProj: Matrix4 = new Matrix4();

    constructor(context: Context, parameters: GPURendererParameters? = null) {
        this.context = context;
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

    private pixelWidth(): u32 { return this.width > 0 ? <u32>Math.ceil(this.width * this.pixelRatio) : 0; }
    private pixelHeight(): u32 { return this.height > 0 ? <u32>Math.ceil(this.height * this.pixelRatio) : 0; }

    // ------------------------------------------------------------ clear colour

    /// `color` is an sRGB hex (or a Rive Color, alpha ignored), a CSS string
    /// or a Color.
    setClearColor<T>(color: T, alpha: f64 = 1): void {
        this.clearColor.set<T>(color);
        this.clearAlpha = alpha;
    }

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
        if (this.broken) return;
        const pw = this.pixelWidth(), ph = this.pixelHeight();
        if (pw == 0 || ph == 0) return;
        const canvas = this.ensureCanvas();
        if (canvas == null) return;
        if (canvas.width != pw || canvas.height != ph) {
            if (!canvas.resize(pw, ph)) return;
        }
        const target = canvas.view;
        if (target == null) return;
        if (!this.ensureSetup(canvas)) return;
        this.ensureTargets(canvas, pw, ph);
        const depthView = this.depthView;
        if (depthView == null) return;
        this.drainDisposed();

        // Matrices.
        if (scene.matrixWorldAutoUpdate) scene.updateMatrixWorld();
        if (camera.parent == null && camera.matrixWorldAutoUpdate) camera.updateMatrixWorld();
        else camera.updateWorldMatrix(true, false);
        Mat4.multiply(this.viewProj.mat4, camera.projectionMatrix.mat4, camera.matrixWorldInverse.mat4);

        // Collect lights and draws.
        _frustum.setFromProjectionMatrix(this.viewProj);
        this.collect(scene, camera, info.frame);
        this.writeFrame(camera);
        if (this.sortObjects) {
            this.opaque.sort(compareOpaque);
            this.transparent.sort(compareTransparent);
        }
        this.writeDraws(this.opaque, info.frame);
        this.writeDraws(this.transparent, info.frame);

        // The pass.
        const color = this.colorAttachment;
        let r: f64 = this.clearColor.r, g: f64 = this.clearColor.g, b: f64 = this.clearColor.b;
        let a = this.clearAlpha;
        if (scene instanceof Scene) {
            const bg = (scene as Scene).background;
            if (bg != null) {
                const k = (scene as Scene).backgroundIntensity;
                r = bg.r * k; g = bg.g * k; b = bg.b * k; a = 1;
            }
        }
        color.clearR = <f32>(LinearToSRGB(r) * a);
        color.clearG = <f32>(LinearToSRGB(g) * a);
        color.clearB = <f32>(LinearToSRGB(b) * a);
        color.clearA = <f32>a;
        color.loadOp = this.autoClear ? LoadOp.clear : LoadOp.load;
        const msaa = this.msaaView;
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
        releaseTex(this.depthTex); this.depthTex = null; this.depthView = null;
        releaseTex(this.msaaTex); this.msaaTex = null; this.msaaView = null;
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
            if (g0 == null || g1 == null) return this.fail("bind group layouts rejected");
            this.frameLayout = g0;
            this.objLayout = g1;

            this.vertexBuffers = [
                vertexLayout(12, VertexFormat.float3, 0),
                vertexLayout(12, VertexFormat.float3, 1),
                vertexLayout(8, VertexFormat.float2, 2),
            ];
            const features = this.context.features();
            this.samples = this.antialias && features.maxSamples >= 4 ? 4 : 1;

            const ubo = new GPUBuffer(BufferUsage.uniform, <u32>FRAME_BYTES);
            this.frameUbo = ubo;
            this.frameGroup = new GPUBindGroup(g0, [new GPUBindGroupUBO(0, ubo)]);

            const wd = new GPUTextureDesc();
            wd.width = 1; wd.height = 1;
            wd.format = TextureFormat.rgba8unorm;
            const white = new GPUTexture(wd);
            const px = new Uint8Array(4);
            px.fill(255);
            uploadRegion.width = 1; uploadRegion.height = 1;
            white.upload(uploadRegion, px.buffer);
            this.white = white.view();
        }
        if (this.pipelineFormat != canvas.format) {
            this.pipelines.clear();
            this.pipelineFormat = canvas.format;
        }
        return true;
    }

    private ensureTargets(canvas: GPUCanvas, w: u32, h: u32): void {
        if (this.depthView != null && this.targetW == w && this.targetH == h && this.targetFormat == canvas.format) return;
        releaseTex(this.depthTex);
        releaseTex(this.msaaTex);
        this.msaaTex = null;
        this.msaaView = null;
        const dd = new GPUTextureDesc();
        dd.width = w; dd.height = h;
        dd.format = TextureFormat.depth32float;
        dd.renderTarget = true;
        dd.sampleCount = this.samples;
        const depth = new GPUTexture(dd);
        this.depthTex = depth;
        this.depthView = depth.view();
        if (this.samples > 1) {
            const md = new GPUTextureDesc();
            md.width = w; md.height = h;
            md.format = <TextureFormat>canvas.format;
            md.renderTarget = true;
            md.sampleCount = this.samples;
            const msaa = new GPUTexture(md);
            this.msaaTex = msaa;
            this.msaaView = msaa.view();
        }
        this.targetW = w;
        this.targetH = h;
        this.targetFormat = canvas.format;
    }

    private pipeline(key: i32): GPUPipeline {
        if (this.pipelines.has(key)) return this.pipelines.get(key);
        const cull = key & 3;               // 0 back, 1 none, 2 front
        const blend = (key & 4) != 0;
        const depthTest = (key & 8) != 0;
        const depthWrite = (key & 16) != 0;
        const mirrored = (key & 32) != 0;

        const target = new GPUColorTargetDesc();
        target.format = <TextureFormat>this.pipelineFormat;
        if (blend) {
            const b = new GPUBlendState();   // premultiplied over
            b.srcColor = BlendFactor.one;
            b.dstColor = BlendFactor.oneMinusSrcAlpha;
            b.srcAlpha = BlendFactor.one;
            b.dstAlpha = BlendFactor.oneMinusSrcAlpha;
            target.blend = b;
        }
        const ds = new GPUDepthStencilDesc();
        ds.format = TextureFormat.depth32float;
        ds.compare = depthTest ? CompareFunction.lessEqual : CompareFunction.always;
        ds.write = depthWrite;

        const d = new GPUPipelineDesc();
        d.vertexModule = this.module;
        d.vertexEntryPoint = "vs_main";
        d.fragmentModule = this.module;
        d.fragmentEntryPoint = "fs_main";
        d.colorTargets = [target];
        d.vertexBuffers = this.vertexBuffers;
        d.bindGroupLayouts = [this.frameLayout, this.objLayout];
        d.cullMode = cull == 0 ? CullMode.back : cull == 2 ? CullMode.front : CullMode.none;
        // three.js flips the front face of mirrored (negative determinant)
        // objects, so front_facing stays true on their outside.
        d.winding = mirrored ? FaceWinding.clockwise : FaceWinding.counterClockwise;
        d.depthStencil = ds;
        d.sampleCount = this.samples;
        const p = new GPUPipeline(d);
        this.pipelines.set(key, p);
        return p;
    }

    private sampler(t: Texture): GPUSampler {
        const key = (t.wrapS - 1000) | ((t.wrapT - 1000) << 2)
            | (isNearest(t.magFilter) ? 0 : 16) | (isNearest(t.minFilter) ? 0 : 32);
        if (this.samplers.has(key)) return this.samplers.get(key);
        const s = new GPUSampler(
            isNearest(t.minFilter) ? Filter.nearest : Filter.linear,
            isNearest(t.magFilter) ? Filter.nearest : Filter.linear,
            Filter.nearest,
            wrapOf(t.wrapS), wrapOf(t.wrapT));
        this.samplers.set(key, s);
        return s;
    }

    private drainDisposed(): void {
        for (let i = 0; i < disposedGeometries.length; i++) this.geometries.dispose(disposedGeometries[i]);
        disposedGeometries.length = 0;
        for (let i = 0; i < disposedTextures.length; i++) this.textureFrames.delete(disposedTextures[i]);
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
                if (o instanceof Mesh) {
                    if (!o.frustumCulled || this.inFrustum(o as Mesh)) this.collectMesh(o as Mesh, frame);
                    else this.info.render.culled++;
                } else if (o instanceof Light) {
                    this.lights.push(o as Light);
                }
            }
            const children = o.children;
            for (let i = children.length - 1; i >= 0; i--) stack.push(children[i]);
        }
    }

    private inFrustum(mesh: Mesh): bool {
        const geometry = mesh.geometry;
        if (geometry.boundingSphere == null) geometry.computeBoundingSphere();
        const bounds = geometry.boundingSphere!;
        if (bounds.isEmpty()) return true;
        _sphere.copy(bounds).applyMatrix4(mesh.matrixWorld);
        return _frustum.intersectsSphere(_sphere);
    }

    private collectMesh(mesh: Mesh, frame: i32): void {
        const material = mesh.material;
        if (!material.visible) return;
        const g = this.geometries.get(mesh.geometry);
        if (g == null) return;
        let state: DrawState;
        if (this.states.has(mesh.id)) state = this.states.get(mesh.id);
        else {
            state = new DrawState();
            this.states.set(mesh.id, state);
        }
        const map = mapOf(material);
        if (map != null) this.updateTexture(map, frame);

        const item = new DrawItem(mesh, g, state);
        const range = mesh.geometry.drawRange;
        const start = max<i32>(0, range.start);
        const end = range.count < 0 ? g.count : min<i32>(g.count, start + range.count);
        item.first = start;
        item.count = max<i32>(0, end - start);
        if (item.count == 0) return;

        const side = material.side;
        const cull = side == DoubleSide ? 1 : side == BackSide ? 2 : 0;
        const mirrored = mesh.matrixWorld.determinant() < 0;
        item.pipelineKey = cull | (material.transparent ? 4 : 0) | (material.depthTest ? 8 : 0)
            | (material.depthWrite ? 16 : 0) | (mirrored ? 32 : 0);
        const e = mesh.matrixWorld.elements;
        _pos.set(e[12], e[13], e[14]).applyMatrix4(this.viewProj);
        item.depth = _pos.z;
        if (material.transparent) this.transparent.push(item);
        else this.opaque.push(item);
    }

    private updateTexture(t: Texture, frame: i32): void {
        if (this.textureFrames.has(t.id) && this.textureFrames.get(t.id) == frame) return;
        this.textureFrames.set(t.id, frame);
        t.update(this.context);
    }

    // ------------------------------------------------------------- uniforms

    private writeFrame(camera: Camera): void {
        const buf = this.frameStaging;
        const f = Float32Array.wrap(buf);
        this.viewProj.mat4.writeToBuffer(buf, FRAME_VIEW_PROJ);
        camera.matrixWorldInverse.mat4.writeToBuffer(buf, FRAME_VIEW);
        const cw = camera.matrixWorld.elements;
        let o = FRAME_CAMERA_POS >> 2;
        f[o] = cw[12]; f[o + 1] = cw[13]; f[o + 2] = cw[14];
        f[o + 3] = camera instanceof OrthographicCamera ? 1 : 0;
        camera.getWorldDirection(_dir);
        o = FRAME_CAMERA_DIR >> 2;
        f[o] = <f32>_dir.x; f[o + 1] = <f32>_dir.y; f[o + 2] = <f32>_dir.z; f[o + 3] = 0;

        let ar: f64 = 0, ag: f64 = 0, ab: f64 = 0;
        let count = 0;
        const lights = this.lights;
        for (let i = 0; i < lights.length; i++) {
            const light = lights[i];
            const k = light.intensity;
            if (light instanceof AmbientLight) {
                ar += light.color.r * k; ag += light.color.g * k; ab += light.color.b * k;
                continue;
            }
            if (!(light instanceof DirectionalLight) && !(light instanceof PointLight)) continue;
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
            if (light instanceof DirectionalLight) {
                f[base + 3] = LIGHT_DIRECTIONAL;
                (light as DirectionalLight).target.getWorldPosition(_dir);
                _dir.subVectors(_pos, _dir).normalize();
                f[base + 4] = <f32>_dir.x; f[base + 5] = <f32>_dir.y; f[base + 6] = <f32>_dir.z;
                f[base + 11] = 0;
                f[base + 12] = 0;
            } else {
                const p = light as PointLight;
                f[base + 3] = LIGHT_POINT;
                f[base + 4] = 0; f[base + 5] = 0; f[base + 6] = 0;
                f[base + 11] = <f32>p.distance;
                f[base + 12] = <f32>p.decay;
            }
            count++;
        }
        o = FRAME_AMBIENT >> 2;
        f[o] = <f32>ar; f[o + 1] = <f32>ag; f[o + 2] = <f32>ab; f[o + 3] = <f32>count;
        this.frameUbo!.update(0, buf);
    }

    private writeDraws(list: Array<DrawItem>, frame: i32): void {
        const buf = this.objStaging;
        const f = Float32Array.wrap(buf);
        const u = Uint32Array.wrap(buf);
        for (let i = 0; i < list.length; i++) {
            const item = list[i];
            const state = item.state;
            if (state.frame == frame) continue;   // a mesh drawn twice (not in M1)
            state.frame = frame;
            const mesh = item.mesh;
            const material = mesh.material;

            mesh.matrixWorld.mat4.writeToBuffer(buf, OBJ_MODEL);
            _normal.getNormalMatrix(mesh.matrixWorld);
            const ne = _normal.elements;
            let o = OBJ_NORMAL >> 2;
            for (let c = 0; c < 3; c++) {
                f[o + c * 4] = <f32>ne[c * 3];
                f[o + c * 4 + 1] = <f32>ne[c * 3 + 1];
                f[o + c * 4 + 2] = <f32>ne[c * 3 + 2];
                f[o + c * 4 + 3] = 0;
            }
            f[o + 12] = 0; f[o + 13] = 0; f[o + 14] = 0; f[o + 15] = 1;

            let kind = KIND_BASIC;
            let cr: f64 = 1, cg: f64 = 1, cb: f64 = 1;
            let er: f64 = 0, eg: f64 = 0, eb: f64 = 0;
            let roughness: f64 = 1, metalness: f64 = 0, flat: f32 = 0;
            if (material instanceof MeshStandardMaterial) {
                const m = material as MeshStandardMaterial;
                kind = KIND_STANDARD;
                cr = m.color.r; cg = m.color.g; cb = m.color.b;
                er = m.emissive.r * m.emissiveIntensity; eg = m.emissive.g * m.emissiveIntensity;
                eb = m.emissive.b * m.emissiveIntensity;
                roughness = m.roughness; metalness = m.metalness;
                flat = m.flatShading ? 1 : 0;
            } else if (material instanceof MeshLambertMaterial) {
                const m = material as MeshLambertMaterial;
                kind = KIND_LAMBERT;
                cr = m.color.r; cg = m.color.g; cb = m.color.b;
                er = m.emissive.r * m.emissiveIntensity; eg = m.emissive.g * m.emissiveIntensity;
                eb = m.emissive.b * m.emissiveIntensity;
            } else if (material instanceof MeshBasicMaterial) {
                const m = material as MeshBasicMaterial;
                cr = m.color.r; cg = m.color.g; cb = m.color.b;
            } else if (material instanceof MeshNormalMaterial) {
                kind = KIND_NORMAL;
            }
            o = OBJ_COLOR >> 2;
            f[o] = <f32>cr; f[o + 1] = <f32>cg; f[o + 2] = <f32>cb; f[o + 3] = <f32>material.opacity;
            o = OBJ_EMISSIVE >> 2;
            f[o] = <f32>er; f[o + 1] = <f32>eg; f[o + 2] = <f32>eb; f[o + 3] = <f32>material.alphaTest;
            o = OBJ_PBR >> 2;
            f[o] = <f32>roughness; f[o + 1] = <f32>metalness; f[o + 2] = flat; f[o + 3] = 0;

            // The map, its flags and the bind group.
            let mapFlags: u32 = 0;
            let view = this.white!;
            let sampler: GPUSampler;
            const map = mapOf(material);
            o = OBJ_UV >> 2;
            if (map != null) {
                const v = map.getView();
                sampler = this.sampler(map);
                if (v != null) {
                    view = v;
                    mapFlags = MAP_ON;
                    if (map.colorSpace == SRGBColorSpace) mapFlags |= MAP_SRGB;
                    if (map.flipY) mapFlags |= MAP_FLIP_Y;
                    if (map.premultiplyAlpha) mapFlags |= MAP_PREMULTIPLIED;
                }
                f[o] = <f32>map.offset.x; f[o + 1] = <f32>map.offset.y;
                f[o + 2] = <f32>map.repeat.x; f[o + 3] = <f32>map.repeat.y;
            } else {
                sampler = this.defaultSampler();
                f[o] = 0; f[o + 1] = 0; f[o + 2] = 1; f[o + 3] = 1;
            }
            o = OBJ_FLAGS >> 2;
            u[o] = kind; u[o + 1] = mapFlags; u[o + 2] = 0; u[o + 3] = material.transparent ? 1 : 0;
            state.ubo.update(0, buf);

            if (state.group == null || state.view !== view || state.sampler !== sampler) {
                state.group = new GPUBindGroup(this.objLayout!,
                    [new GPUBindGroupUBO(0, state.ubo)],
                    [new GPUBindGroupTexture(1, view)],
                    [new GPUBindGroupSampler(2, sampler)]);
                state.view = view;
                state.sampler = sampler;
            }
        }
    }

    private defaultSampler(): GPUSampler {
        const key = -1;
        if (this.samplers.has(key)) return this.samplers.get(key);
        const s = new GPUSampler(Filter.linear, Filter.linear, Filter.nearest, WrapMode.clampToEdge, WrapMode.clampToEdge);
        this.samplers.set(key, s);
        return s;
    }

    // ------------------------------------------------------------------ draw

    private drawList(pass: GPURenderPass, list: Array<DrawItem>): void {
        const info = this.info.render;
        let lastKey = -1;
        for (let i = 0; i < list.length; i++) {
            const item = list[i];
            const g = item.geometry;
            const group = item.state.group;
            if (group == null) continue;
            if (item.pipelineKey != lastKey) {
                pass.setPipeline(this.pipeline(item.pipelineKey));
                pass.setBindGroup(0, this.frameGroup!);
                lastKey = item.pipelineKey;
            }
            pass.setBindGroup(1, group);
            pass.setVertexBuffer(0, g.position!);
            pass.setVertexBuffer(1, g.normal!);
            pass.setVertexBuffer(2, g.uv!);
            if (g.indexed) {
                pass.setIndexBuffer(g.index!, <u32>g.indexFormat);
                pass.drawIndexed(<u32>item.count, 1, <u32>item.first);
            } else {
                pass.draw(<u32>item.count, 1, <u32>item.first);
            }
            info.calls++;
            info.triangles += item.count / 3;
        }
    }
}

function compareOpaque(a: DrawItem, b: DrawItem): i32 {
    const ro = a.mesh.renderOrder - b.mesh.renderOrder;
    if (ro != 0) return ro;
    return a.depth < b.depth ? -1 : a.depth > b.depth ? 1 : a.mesh.id - b.mesh.id;
}

function compareTransparent(a: DrawItem, b: DrawItem): i32 {
    const ro = a.mesh.renderOrder - b.mesh.renderOrder;
    if (ro != 0) return ro;
    return a.depth > b.depth ? -1 : a.depth < b.depth ? 1 : a.mesh.id - b.mesh.id;
}

function mapOf(material: Material): Texture? {
    if (material instanceof MeshStandardMaterial) return (material as MeshStandardMaterial).map;
    if (material instanceof MeshLambertMaterial) return (material as MeshLambertMaterial).map;
    if (material instanceof MeshBasicMaterial) return (material as MeshBasicMaterial).map;
    return null;
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
const _frustum: Frustum = new Frustum();
const _sphere: Sphere = new Sphere();
const _dir: Vector3 = new Vector3();
const _normal: Matrix3 = new Matrix3();
