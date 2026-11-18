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
export const KIND_SHADOW: i32 = 10;
export const KIND_DISTANCE: i32 = 11;
/// LineMaterial (wide lines): the geometry's instanceStart / instanceEnd
/// segments widened in screen space.
export const KIND_WIDE_LINE: i32 = 12;

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

// Extra maps ("roles"): each has its own uv transform and lands in one of
// six extra texture bindings (maps sharing a texture share one).
export const ROLE_LIGHT: i32 = 0;
export const ROLE_BUMP: i32 = 1;
export const ROLE_DISPLACEMENT: i32 = 2;
/// Basic and Lambert specularMap (Phong's is SLOT_AUX).
export const ROLE_SPECULAR: i32 = 3;
export const ROLE_CLEARCOAT: i32 = 4;
export const ROLE_CLEARCOAT_ROUGHNESS: i32 = 5;
export const ROLE_CLEARCOAT_NORMAL: i32 = 6;
export const ROLE_SHEEN_COLOR: i32 = 7;
export const ROLE_SHEEN_ROUGHNESS: i32 = 8;
export const ROLE_SPECULAR_INTENSITY: i32 = 9;
export const ROLE_SPECULAR_COLOR: i32 = 10;
export const ROLE_TRANSMISSION: i32 = 11;
export const ROLE_THICKNESS: i32 = 12;
export const ROLE_IRIDESCENCE: i32 = 13;
export const ROLE_IRIDESCENCE_THICKNESS: i32 = 14;
export const ROLE_ANISOTROPY: i32 = 15;
export const ROLE_COUNT: i32 = 16;
export const EXTRA_SLOTS: i32 = 5;

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
    dashOffset: f64 = 0;
    dashed: bool = false;
    gapSize: f64 = 0;
    dashScale: f64 = 1;
    // Extra maps and their parameters.
    bumpScale: f64 = 1;
    displacementScale: f64 = 1;
    displacementBias: f64 = 0;
    lightMapIntensity: f64 = 1;
    normalMapType: i32 = 0;
    combine: i32 = 0;
    reflectivity: f64 = 1;
    refractionRatio: f64 = 0.98;
    clearcoatNormalScaleX: f64 = 1; clearcoatNormalScaleY: f64 = 1;
    // MeshPhysicalMaterial: transmission, volume, iridescence, anisotropy.
    transmission: f64 = 0;
    thickness: f64 = 0;
    attenuationDistance: f64 = Infinity;
    attenuationR: f64 = 1; attenuationG: f64 = 1; attenuationB: f64 = 1;
    dispersion: f64 = 0;
    iridescence: f64 = 0;
    iridescenceIOR: f64 = 1.3;
    iridescenceThicknessMin: f64 = 100;
    iridescenceThicknessMax: f64 = 400;
    anisotropy: f64 = 0;
    anisotropyRotation: f64 = 0;
    // alphaHash (and alphaToCoverage, emulated by it); MeshDistanceMaterial.
    alphaHash: bool = false;
    referenceX: f64 = 0; referenceY: f64 = 0; referenceZ: f64 = 0;
    nearDistance: f64 = 1;
    farDistance: f64 = 1000;
    textures: StaticArray<Texture?> = new StaticArray<Texture?>(TEXTURE_SLOTS);
    roles: StaticArray<Texture?> = new StaticArray<Texture?>(ROLE_COUNT);

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
        this.dashSize = 0; this.gapSize = 0; this.dashScale = 1; this.dashOffset = 0; this.dashed = false;
        this.bumpScale = 1; this.displacementScale = 1; this.displacementBias = 0; this.lightMapIntensity = 1;
        this.normalMapType = 0; this.combine = 0; this.reflectivity = 1; this.refractionRatio = 0.98;
        this.clearcoatNormalScaleX = 1; this.clearcoatNormalScaleY = 1;
        this.transmission = 0; this.thickness = 0; this.attenuationDistance = Infinity;
        this.attenuationR = 1; this.attenuationG = 1; this.attenuationB = 1; this.dispersion = 0;
        this.iridescence = 0; this.iridescenceIOR = 1.3; this.iridescenceThicknessMin = 100;
        this.iridescenceThicknessMax = 400; this.anisotropy = 0; this.anisotropyRotation = 0;
        this.alphaHash = false; this.referenceX = 0; this.referenceY = 0; this.referenceZ = 0;
        this.nearDistance = 1; this.farDistance = 1000;
        for (let i = 0; i < TEXTURE_SLOTS; i++) this.textures[i] = null;
        for (let i = 0; i < ROLE_COUNT; i++) this.roles[i] = null;
    }
}
