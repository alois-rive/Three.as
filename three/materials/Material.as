// three.js Material: the state every material shares. Parameter objects
// are typed classes filled by object literals:
//     new MeshBasicMaterial({ color: 0xff0000, transparent: true, opacity: 0.5 })

import { EventDispatcher, Event } from "../core/EventDispatcher";
import {
    FrontSide, NormalBlending, LessEqualDepth, AlwaysStencilFunc, KeepStencilOp,
} from "../constants";
import { Plane } from "../math/Plane";
import { MaterialUniforms, ROLE_DISPLACEMENT } from "./MaterialUniforms";
import { Texture } from "../textures/Texture";
import { Color } from "../math/Color";
import { Vector2 } from "../math/Vector2";
import { MathUtils } from "../math/MathUtils";
import { Dynamic } from "rive/dynamic";
import {
    JSONMeta, jsonMetadata, setNumber, setString, setBool, setNumbers, isEmptyTable, cloneDynamic,
} from "../core/JSON";

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

export class Material extends EventDispatcher {
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
    private _uuid: string = "";
    private _userData: Dynamic? = null;

    constructor() {
        super();
        this.id = _materialId++;
    }

    /// A random uuid, made on first use.
    get uuid(): string {
        if (this._uuid.length == 0) this._uuid = MathUtils.generateUUID();
        return this._uuid;
    }
    set uuid(value: string) { this._uuid = value; }

    /// A `Dynamic` table, as three.js's userData (see Object3D.userData).
    get userData(): Dynamic {
        let d = this._userData;
        if (d == null) {
            d = Dynamic.newTable();
            this._userData = d;
        }
        return d!;
    }
    set userData(value: Dynamic) { this._userData = value; }

    /// three.js's JSON: { metadata, uuid, type, name, the material's
    /// properties (colours as sRGB hex numbers, maps as texture uuids),
    /// the shared state where it is not the default, userData }. With no
    /// `meta`, the textures and images it uses are added as `textures` and
    /// `images`; with one, they go to `meta`. MaterialLoader reads it.
    toJSON(meta: JSONMeta? = null): Dynamic {
        const isRootObject = meta == null;
        const m = meta != null ? meta! : new JSONMeta();
        const data = Dynamic.newTable();
        data.set("metadata", jsonMetadata("Material", "Material.toJSON"));
        setString(data, "uuid", this.uuid);
        setString(data, "type", this.type);
        if (this.name != "") setString(data, "name", this.name);
        this.toJSONProperties(data, m);
        if (this.shadowSide >= 0) setNumber(data, "shadowSide", <f64>this.shadowSide);
        if (this.blending != NormalBlending) setNumber(data, "blending", <f64>this.blending);
        if (this.side != FrontSide) setNumber(data, "side", <f64>this.side);
        if (this.vertexColors) setBool(data, "vertexColors", true);
        if (this.opacity < 1) setNumber(data, "opacity", this.opacity);
        if (this.transparent) setBool(data, "transparent", true);
        if (this.depthFunc != LessEqualDepth) setNumber(data, "depthFunc", <f64>this.depthFunc);
        if (!this.depthTest) setBool(data, "depthTest", false);
        if (!this.depthWrite) setBool(data, "depthWrite", false);
        if (!this.colorWrite) setBool(data, "colorWrite", false);
        if (this.stencilWriteMask != 0xff) setNumber(data, "stencilWriteMask", <f64>this.stencilWriteMask);
        if (this.stencilFunc != AlwaysStencilFunc) setNumber(data, "stencilFunc", <f64>this.stencilFunc);
        if (this.stencilRef != 0) setNumber(data, "stencilRef", <f64>this.stencilRef);
        if (this.stencilFuncMask != 0xff) setNumber(data, "stencilFuncMask", <f64>this.stencilFuncMask);
        if (this.stencilFail != KeepStencilOp) setNumber(data, "stencilFail", <f64>this.stencilFail);
        if (this.stencilZFail != KeepStencilOp) setNumber(data, "stencilZFail", <f64>this.stencilZFail);
        if (this.stencilZPass != KeepStencilOp) setNumber(data, "stencilZPass", <f64>this.stencilZPass);
        if (this.stencilWrite) setBool(data, "stencilWrite", true);
        if (this.polygonOffset) setBool(data, "polygonOffset", true);
        if (this.polygonOffsetFactor != 0) setNumber(data, "polygonOffsetFactor", this.polygonOffsetFactor);
        if (this.polygonOffsetUnits != 0) setNumber(data, "polygonOffsetUnits", this.polygonOffsetUnits);
        if (this.alphaTest > 0) setNumber(data, "alphaTest", this.alphaTest);
        if (this.alphaHash) setBool(data, "alphaHash", true);
        if (this.alphaToCoverage) setBool(data, "alphaToCoverage", true);
        if (this.wireframe) setBool(data, "wireframe", true);
        if (this.flatShading) setBool(data, "flatShading", true);
        if (!this.visible) setBool(data, "visible", false);
        if (!this.toneMapped) setBool(data, "toneMapped", false);
        if (!this.fog) setBool(data, "fog", false);
        if (!isEmptyTable(this._userData)) data.set("userData", this._userData);
        if (isRootObject) {
            const textures = JSONMeta.extract(m.textures);
            if (textures != null) data.set("textures", textures!);
            const images = JSONMeta.extract(m.images);
            if (images != null) data.set("images", images!);
        }
        return data;
    }

    /// Writes this class's own properties (colours, maps, factors) into
    /// `data`, maps through `meta`; subclasses call super first. Internal
    /// to toJSON (three.js tests each property in Material.toJSON).
    toJSONProperties(data: Dynamic, meta: JSONMeta): void {}

    /// Writes `color` as its sRGB hex number (internal: toJSONProperties).
    protected colorToJSON(data: Dynamic, key: string, color: Color): void {
        setNumber(data, key, <f64>color.getHex());
    }

    /// Writes `texture`'s uuid (and the texture into `meta`), when set
    /// (internal: toJSONProperties).
    protected mapToJSON(data: Dynamic, key: string, texture: Texture?, meta: JSONMeta): bool {
        if (texture == null) return false;
        texture.toJSON(meta);
        setString(data, key, texture.uuid);
        return true;
    }

    /// The normal map group three.js writes: normalMap, normalMapType,
    /// normalScale; the bump map with bumpScale; the displacement map with
    /// its scale and bias (internal).
    protected surfaceMapsToJSON(data: Dynamic, meta: JSONMeta, normalMap: Texture?, normalMapType: i32,
                                normalScale: Vector2, bumpMap: Texture?, bumpScale: f64,
                                displacementMap: Texture?, displacementScale: f64, displacementBias: f64): void {
        if (this.mapToJSON(data, "normalMap", normalMap, meta)) {
            setNumber(data, "normalMapType", <f64>normalMapType);
            setNumbers(data, "normalScale", [normalScale.x, normalScale.y]);
        }
        if (this.mapToJSON(data, "bumpMap", bumpMap, meta)) setNumber(data, "bumpScale", bumpScale);
        if (this.mapToJSON(data, "displacementMap", displacementMap, meta)) {
            setNumber(data, "displacementScale", displacementScale);
            setNumber(data, "displacementBias", displacementBias);
        }
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
        const userData = source._userData;
        this._userData = userData != null ? cloneDynamic(userData) : null;
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
    dispose(): void {
        if (this.hasListeners("dispose")) this.dispatchEvent(new Event("dispose"));
    }
}
