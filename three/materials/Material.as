// three.js Material: the state every material shares. Parameter objects
// are typed classes filled by object literals:
//     new MeshBasicMaterial({ color: 0xff0000, transparent: true, opacity: 0.5 })

import { FrontSide } from "../constants";

let _materialId: i32 = 0;

export class MaterialParameters {
    name: string = "";
    side: i32 = FrontSide;
    transparent: bool = false;
    opacity: f64 = 1;
    depthTest: bool = true;
    depthWrite: bool = true;
    visible: bool = true;
    alphaTest: f64 = 0;
    toneMapped: bool = true;
}

export class Material {
    readonly isMaterial: bool = true;
    id: i32;
    name: string = "";
    type: string = "Material";
    /// FrontSide, BackSide or DoubleSide.
    side: i32 = FrontSide;
    /// Blended (premultiplied over) and drawn after opaque objects, back
    /// to front.
    transparent: bool = false;
    opacity: f64 = 1;
    depthTest: bool = true;
    depthWrite: bool = true;
    visible: bool = true;
    /// Fragments with alpha below this are discarded.
    alphaTest: f64 = 0;
    toneMapped: bool = true;
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
        this.depthTest = p.depthTest;
        this.depthWrite = p.depthWrite;
        this.visible = p.visible;
        this.alphaTest = p.alphaTest;
        this.toneMapped = p.toneMapped;
    }

    /// Nothing to free yet: pipelines are shared by the renderer.
    dispose(): void {}
}
