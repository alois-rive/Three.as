// three.js MeshStandardMaterial: metallic-roughness PBR (GGX specular,
// Lambert diffuse), lit as three.js does.

import { TangentSpaceNormalMap } from "../constants";
import { Material, MaterialParameters } from "./Material";
import {
    MaterialUniforms, KIND_STANDARD, SLOT_MAP, SLOT_NORMAL, SLOT_AUX, SLOT_METALNESS, SLOT_AO, SLOT_EMISSIVE, SLOT_ALPHA, SLOT_ENV, ROLE_BUMP, ROLE_DISPLACEMENT, ROLE_LIGHT,
} from "./MaterialUniforms";
import { Color } from "../math/Color";
import { Vector2 } from "../math/Vector2";
import { Texture } from "../textures/Texture";
import { Dynamic } from "rive/dynamic";
import { JSONMeta, setNumber } from "../core/JSON";

export class MeshStandardMaterialParameters extends MaterialParameters {
    color: u32 = 0xFFFFFF;
    roughness: f64 = 1;
    metalness: f64 = 0;
    map: Texture? = null;
    roughnessMap: Texture? = null;
    metalnessMap: Texture? = null;
    emissive: u32 = 0x000000;
    emissiveIntensity: f64 = 1;
    emissiveMap: Texture? = null;
    normalMap: Texture? = null;
    normalScale: Vector2 = new Vector2(1, 1);
    aoMap: Texture? = null;
    aoMapIntensity: f64 = 1;
    alphaMap: Texture? = null;
    envMap: Texture? = null;
    envMapIntensity: f64 = 1;
    lightMap: Texture? = null;
    lightMapIntensity: f64 = 1;
    bumpMap: Texture? = null;
    bumpScale: f64 = 1;
    displacementMap: Texture? = null;
    displacementScale: f64 = 1;
    displacementBias: f64 = 0;
    normalMapType: i32 = TangentSpaceNormalMap;
}

export class MeshStandardMaterial extends Material {
    readonly isMeshStandardMaterial: bool = true;

    override toJSONProperties(data: Dynamic, meta: JSONMeta): void {
        super.toJSONProperties(data, meta);
        this.colorToJSON(data, "color", this.color);
        setNumber(data, "roughness", this.roughness);
        setNumber(data, "metalness", this.metalness);
        this.colorToJSON(data, "emissive", this.emissive);
        if (this.emissiveIntensity != 1) setNumber(data, "emissiveIntensity", this.emissiveIntensity);
        this.mapToJSON(data, "map", this.map, meta);
        this.mapToJSON(data, "alphaMap", this.alphaMap, meta);
        if (this.mapToJSON(data, "lightMap", this.lightMap, meta)) setNumber(data, "lightMapIntensity", this.lightMapIntensity);
        if (this.mapToJSON(data, "aoMap", this.aoMap, meta)) setNumber(data, "aoMapIntensity", this.aoMapIntensity);
        this.surfaceMapsToJSON(data, meta, this.normalMap, this.normalMapType, this.normalScale, this.bumpMap,
            this.bumpScale, this.displacementMap, this.displacementScale, this.displacementBias);
        this.mapToJSON(data, "roughnessMap", this.roughnessMap, meta);
        this.mapToJSON(data, "metalnessMap", this.metalnessMap, meta);
        this.mapToJSON(data, "emissiveMap", this.emissiveMap, meta);
        this.mapToJSON(data, "envMap", this.envMap, meta);
        setNumber(data, "envMapIntensity", this.envMapIntensity);
    }
    color: Color = new Color();
    roughness: f64 = 1;
    metalness: f64 = 0;
    map: Texture? = null;
    /// Green channel scales roughness.
    roughnessMap: Texture? = null;
    /// Blue channel scales metalness.
    metalnessMap: Texture? = null;
    emissive: Color = new Color(0, 0, 0);
    emissiveIntensity: f64 = 1;
    emissiveMap: Texture? = null;
    normalMap: Texture? = null;
    normalScale: Vector2 = new Vector2(1, 1);
    aoMap: Texture? = null;
    aoMapIntensity: f64 = 1;
    alphaMap: Texture? = null;
    /// Reflections (overrides scene.environment).
    envMap: Texture? = null;
    envMapIntensity: f64 = 1;

    lightMap: Texture? = null;
    lightMapIntensity: f64 = 1;
    bumpMap: Texture? = null;
    bumpScale: f64 = 1;
    displacementMap: Texture? = null;
    displacementScale: f64 = 1;
    displacementBias: f64 = 0;
    normalMapType: i32 = TangentSpaceNormalMap;

    constructor(parameters: MeshStandardMaterialParameters? = null) {
        super();
        this.type = "MeshStandardMaterial";
        if (parameters != null) this.setStandardValues(parameters);
    }

    protected setStandardValues(p: MeshStandardMaterialParameters): void {
        this.setValues(p);
        this.lightMap = p.lightMap;
        this.lightMapIntensity = p.lightMapIntensity;
        this.bumpMap = p.bumpMap;
        this.bumpScale = p.bumpScale;
        this.displacementMap = p.displacementMap;
        this.displacementScale = p.displacementScale;
        this.displacementBias = p.displacementBias;
        this.normalMapType = p.normalMapType;
        this.color.setHex(p.color);
        this.roughness = p.roughness;
        this.metalness = p.metalness;
        this.map = p.map;
        this.roughnessMap = p.roughnessMap;
        this.metalnessMap = p.metalnessMap;
        this.emissive.setHex(p.emissive);
        this.emissiveIntensity = p.emissiveIntensity;
        this.emissiveMap = p.emissiveMap;
        this.normalMap = p.normalMap;
        this.normalScale.copy(p.normalScale);
        this.aoMap = p.aoMap;
        this.aoMapIntensity = p.aoMapIntensity;
        this.alphaMap = p.alphaMap;
        this.envMap = p.envMap;
        this.envMapIntensity = p.envMapIntensity;
    }

    override fillUniforms(u: MaterialUniforms): void {
        super.fillUniforms(u);
        u.kind = KIND_STANDARD;
        u.r = this.color.r; u.g = this.color.g; u.b = this.color.b;
        u.roughness = this.roughness;
        u.metalness = this.metalness;
        const k = this.emissiveIntensity;
        u.emissiveR = this.emissive.r * k; u.emissiveG = this.emissive.g * k; u.emissiveB = this.emissive.b * k;
        u.normalScaleX = this.normalScale.x; u.normalScaleY = this.normalScale.y;
        u.aoMapIntensity = this.aoMapIntensity;
        u.envMapIntensity = this.envMapIntensity;
        u.textures[SLOT_ENV] = this.envMap;
        u.textures[SLOT_MAP] = this.map;
        u.textures[SLOT_NORMAL] = this.normalMap;
        u.textures[SLOT_AUX] = this.roughnessMap;
        u.textures[SLOT_METALNESS] = this.metalnessMap;
        u.textures[SLOT_AO] = this.aoMap;
        u.textures[SLOT_EMISSIVE] = this.emissiveMap;
        u.textures[SLOT_ALPHA] = this.alphaMap;
        u.roles[ROLE_LIGHT] = this.lightMap;
        u.lightMapIntensity = this.lightMapIntensity;
        u.roles[ROLE_BUMP] = this.bumpMap;
        u.bumpScale = this.bumpScale;
        u.roles[ROLE_DISPLACEMENT] = this.displacementMap;
        u.displacementScale = this.displacementScale;
        u.displacementBias = this.displacementBias;
        u.normalMapType = this.normalMapType;
    }

    override copy(source: Material): Material {
        super.copy(source);
        if (source instanceof MeshStandardMaterial) {
            const s = source as MeshStandardMaterial;
            this.color.copy(s.color);
            this.roughness = s.roughness;
            this.metalness = s.metalness;
            this.map = s.map;
            this.roughnessMap = s.roughnessMap;
            this.metalnessMap = s.metalnessMap;
            this.emissive.copy(s.emissive);
            this.emissiveIntensity = s.emissiveIntensity;
            this.emissiveMap = s.emissiveMap;
            this.normalMap = s.normalMap;
            this.normalScale.copy(s.normalScale);
            this.aoMap = s.aoMap;
            this.aoMapIntensity = s.aoMapIntensity;
            this.alphaMap = s.alphaMap;
            this.envMap = s.envMap;
            this.envMapIntensity = s.envMapIntensity;
            this.lightMap = s.lightMap;
            this.lightMapIntensity = s.lightMapIntensity;
            this.bumpMap = s.bumpMap;
            this.bumpScale = s.bumpScale;
            this.displacementMap = s.displacementMap;
            this.displacementScale = s.displacementScale;
            this.displacementBias = s.displacementBias;
            this.normalMapType = s.normalMapType;
        }
        return this;
    }

    override clone(): Material {
        return new MeshStandardMaterial().copy(this);
    }
}
