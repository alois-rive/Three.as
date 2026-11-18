// three.js Material: the state every material shares. Parameter objects
// are typed classes filled by object literals:
//     new MeshBasicMaterial({ color: 0xff0000, transparent: true, opacity: 0.5 })

import {
    FrontSide, NormalBlending, LessEqualDepth, AlwaysStencilFunc, KeepStencilOp,
} from "../constants";
import { Plane } from "../math/Plane";
import { MaterialUniforms, ROLE_DISPLACEMENT } from "./MaterialUniforms";
import { Texture } from "../textures/Texture";

let _materialId: i32 = 0;
const _scratch = new MaterialUniforms();

export class MaterialParameters {
    name: string = "";
    side: i32 = FrontSide;
    transparent: bool = false;
    opacity: f64 = 1;
    blending: i32 = NormalBlending;
    depthTest: bool = true;
    depthWrite: bool = true;
    colorWrite: bool = true;
    visible: bool = true;
    alphaTest: f64 = 0;
    toneMapped: bool = true;
    vertexColors: bool = false;
    fog: bool = true;
    flatShading: bool = false;
    wireframe: bool = false;
    polygonOffset: bool = false;
    polygonOffsetFactor: f64 = 0;
    polygonOffsetUnits: f64 = 0;
    depthFunc: i32 = LessEqualDepth;
    stencilWrite: bool = false;
    stencilWriteMask: i32 = 0xff;
    stencilFunc: i32 = AlwaysStencilFunc;
    stencilRef: i32 = 0;
    stencilFuncMask: i32 = 0xff;
    stencilFail: i32 = KeepStencilOp;
    stencilZFail: i32 = KeepStencilOp;
    stencilZPass: i32 = KeepStencilOp;
    clippingPlanes: Array<Plane>? = null;
    clipIntersection: bool = false;
    clipShadows: bool = false;
    alphaHash: bool = false;
    alphaToCoverage: bool = false;
    shadowSide: i32 = -1;
}

export class Material {
    readonly isMaterial: bool = true;
    id: i32;
    name: string = "";
    type: string = "Material";
    /// FrontSide, BackSide or DoubleSide.
    side: i32 = FrontSide;
    /// Drawn after opaque objects, back to front, blended.
    transparent: bool = false;
    opacity: f64 = 1;
    /// NoBlending, NormalBlending, AdditiveBlending, SubtractiveBlending or
    /// MultiplyBlending (premultiplied, as three.js with premultipliedAlpha).
    blending: i32 = NormalBlending;
    depthTest: bool = true;
    depthWrite: bool = true;
    colorWrite: bool = true;
    visible: bool = true;
    /// Fragments with alpha below this are discarded.
    alphaTest: f64 = 0;
    toneMapped: bool = true;
    /// Multiply by the geometry's "color" attribute.
    vertexColors: bool = false;
    /// Affected by scene.fog.
    fog: bool = true;
    /// Face normals instead of interpolated ones (three.js has it on the
    /// lit materials; here it is on every material and ignored by unlit ones).
    flatShading: bool = false;
    /// Draw triangle edges as lines.
    wireframe: bool = false;
    polygonOffset: bool = false;
    polygonOffsetFactor: f64 = 0;
    polygonOffsetUnits: f64 = 0;
    /// Depth comparison (NeverDepth ... NotEqualDepth).
    depthFunc: i32 = LessEqualDepth;
    /// Stencil: stencilWrite turns the test and the writes on, as three.js.
    stencilWrite: bool = false;
    stencilWriteMask: i32 = 0xff;
    stencilFunc: i32 = AlwaysStencilFunc;
    stencilRef: i32 = 0;
    stencilFuncMask: i32 = 0xff;
    stencilFail: i32 = KeepStencilOp;
    stencilZFail: i32 = KeepStencilOp;
    stencilZPass: i32 = KeepStencilOp;
    /// World-space planes clipping this material (renderer.localClippingEnabled).
    clippingPlanes: Array<Plane>? = null;
    clipIntersection: bool = false;
    clipShadows: bool = false;
    /// Stochastic (hashed) alpha cut-out, as three.js's alphaHash.
    alphaHash: bool = false;
    /// Rive pipelines have no alpha to coverage: renders as alphaHash.
    alphaToCoverage: bool = false;
    /// The side shadow passes render (-1, three.js's null: the opposite of
    /// `side`, or both for DoubleSide).
    shadowSide: i32 = -1;
    version: i32 = 0;

    constructor() {
        this.id = _materialId++;
    }

    set needsUpdate(value: bool) { if (value) this.version++; }

    /// Applies the shared parameters (subclasses call it from their
    /// constructor).
    protected setValues(p: MaterialParameters): void {
        this.name = p.name;
        this.side = p.side;
        this.transparent = p.transparent;
        this.opacity = p.opacity;
        this.blending = p.blending;
        this.depthTest = p.depthTest;
        this.depthWrite = p.depthWrite;
        this.colorWrite = p.colorWrite;
        this.visible = p.visible;
        this.alphaTest = p.alphaTest;
        this.toneMapped = p.toneMapped;
        this.vertexColors = p.vertexColors;
        this.fog = p.fog;
        this.flatShading = p.flatShading;
        this.wireframe = p.wireframe;
        this.polygonOffset = p.polygonOffset;
        this.polygonOffsetFactor = p.polygonOffsetFactor;
        this.polygonOffsetUnits = p.polygonOffsetUnits;
        this.depthFunc = p.depthFunc;
        this.stencilWrite = p.stencilWrite;
        this.stencilWriteMask = p.stencilWriteMask;
        this.stencilFunc = p.stencilFunc;
        this.stencilRef = p.stencilRef;
        this.stencilFuncMask = p.stencilFuncMask;
        this.stencilFail = p.stencilFail;
        this.stencilZFail = p.stencilZFail;
        this.stencilZPass = p.stencilZPass;
        this.clippingPlanes = p.clippingPlanes;
        this.clipIntersection = p.clipIntersection;
        this.clipShadows = p.clipShadows;
        this.alphaHash = p.alphaHash;
        this.alphaToCoverage = p.alphaToCoverage;
        this.shadowSide = p.shadowSide;
    }

    /// The displacementMap, if the material has one (internal: shadow passes).
    displacementMapOf(): Texture? {
        const u = _scratch;
        this.fillUniforms(u);
        return u.roles[ROLE_DISPLACEMENT];
    }

    /// Fills what the renderer needs (internal). Subclasses call super first.
    fillUniforms(u: MaterialUniforms): void {
        u.reset();
        u.opacity = this.opacity;
        u.alphaTest = this.alphaTest;
        u.vertexColors = this.vertexColors;
        u.fog = this.fog;
        u.flatShading = this.flatShading;
        u.alphaHash = this.alphaHash || this.alphaToCoverage;
    }

    /// Copies the shared state of `source`.
    copy(source: Material): Material {
        this.name = source.name;
        this.side = source.side;
        this.transparent = source.transparent;
        this.opacity = source.opacity;
        this.blending = source.blending;
        this.depthTest = source.depthTest;
        this.depthWrite = source.depthWrite;
        this.colorWrite = source.colorWrite;
        this.visible = source.visible;
        this.alphaTest = source.alphaTest;
        this.toneMapped = source.toneMapped;
        this.vertexColors = source.vertexColors;
        this.fog = source.fog;
        this.flatShading = source.flatShading;
        this.wireframe = source.wireframe;
        return this;
    }

    /// Nothing to free: pipelines are shared by the renderer.
    dispose(): void {}
}
