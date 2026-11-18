// three.js Material: the state every material shares. Parameter objects
// are typed classes filled by object literals:
//     new MeshBasicMaterial({ color: 0xff0000, transparent: true, opacity: 0.5 })

import { FrontSide, NormalBlending } from "../constants";
import { MaterialUniforms } from "./MaterialUniforms";

let _materialId: i32 = 0;

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
    }

    /// Fills what the renderer needs (internal). Subclasses call super first.
    fillUniforms(u: MaterialUniforms): void {
        u.reset();
        u.opacity = this.opacity;
        u.alphaTest = this.alphaTest;
        u.vertexColors = this.vertexColors;
        u.fog = this.fog;
        u.flatShading = this.flatShading;
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
