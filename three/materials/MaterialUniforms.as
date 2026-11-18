// What a material asks of the renderer (internal): every material fills one
// with `fillUniforms`, and GPURenderer turns it into its uniform block and
// texture bindings. Keeps the renderer free of per-class code.

import { Texture } from "../textures/Texture";

// Shading models (the shader's kind).
export const KIND_BASIC: i32 = 0;
export const KIND_NORMAL: i32 = 1;
export const KIND_LAMBERT: i32 = 2;
export const KIND_STANDARD: i32 = 3;
export const KIND_PHONG: i32 = 4;
export const KIND_TOON: i32 = 5;
export const KIND_MATCAP: i32 = 6;
export const KIND_DEPTH: i32 = 7;
export const KIND_PHYSICAL: i32 = 8;
export const KIND_LINE_DASHED: i32 = 9;

// Texture slots (the material bind group's bindings 0..6).
export const SLOT_MAP: i32 = 0;
export const SLOT_NORMAL: i32 = 1;
/// roughnessMap, or Phong's specularMap, Toon's gradientMap, Matcap's matcap.
export const SLOT_AUX: i32 = 2;
export const SLOT_METALNESS: i32 = 3;
export const SLOT_AO: i32 = 4;
export const SLOT_EMISSIVE: i32 = 5;
export const SLOT_ALPHA: i32 = 6;
/// envMap (Standard/Physical): the material's own environment, over
/// scene.environment.
export const SLOT_ENV: i32 = 7;
export const TEXTURE_SLOTS: i32 = 8;

export class MaterialUniforms {
    kind: i32 = KIND_BASIC;
    r: f64 = 1; g: f64 = 1; b: f64 = 1;
    opacity: f64 = 1;
    alphaTest: f64 = 0;
    emissiveR: f64 = 0; emissiveG: f64 = 0; emissiveB: f64 = 0;
    roughness: f64 = 1;
    metalness: f64 = 0;
    aoMapIntensity: f64 = 1;
    specularR: f64 = 0; specularG: f64 = 0; specularB: f64 = 0;
    shininess: f64 = 30;
    normalScaleX: f64 = 1; normalScaleY: f64 = 1;
    flatShading: bool = false;
    vertexColors: bool = false;
    fog: bool = true;
    envMapIntensity: f64 = 1;
    // MeshPhysicalMaterial
    clearcoat: f64 = 0;
    clearcoatRoughness: f64 = 0;
    sheen: f64 = 0;
    sheenR: f64 = 0; sheenG: f64 = 0; sheenB: f64 = 0;
    sheenRoughness: f64 = 1;
    ior: f64 = 1.5;
    specularIntensity: f64 = 1;
    specularColorR: f64 = 1; specularColorG: f64 = 1; specularColorB: f64 = 1;
    // Points and sprites
    size: f64 = 1;
    sizeAttenuation: bool = true;
    rotation: f64 = 0;
    // Dashed lines
    dashSize: f64 = 0;
    gapSize: f64 = 0;
    dashScale: f64 = 1;
    textures: StaticArray<Texture?> = new StaticArray<Texture?>(TEXTURE_SLOTS);

    reset(): void {
        this.kind = KIND_BASIC;
        this.r = 1; this.g = 1; this.b = 1;
        this.opacity = 1;
        this.alphaTest = 0;
        this.emissiveR = 0; this.emissiveG = 0; this.emissiveB = 0;
        this.roughness = 1;
        this.metalness = 0;
        this.aoMapIntensity = 1;
        this.specularR = 0; this.specularG = 0; this.specularB = 0;
        this.shininess = 30;
        this.normalScaleX = 1; this.normalScaleY = 1;
        this.flatShading = false;
        this.vertexColors = false;
        this.fog = true;
        this.envMapIntensity = 1;
        this.clearcoat = 0; this.clearcoatRoughness = 0;
        this.sheen = 0; this.sheenR = 0; this.sheenG = 0; this.sheenB = 0; this.sheenRoughness = 1;
        this.ior = 1.5; this.specularIntensity = 1;
        this.specularColorR = 1; this.specularColorG = 1; this.specularColorB = 1;
        this.size = 1; this.sizeAttenuation = true; this.rotation = 0;
        this.dashSize = 0; this.gapSize = 0; this.dashScale = 1;
        for (let i = 0; i < TEXTURE_SLOTS; i++) this.textures[i] = null;
    }
}
