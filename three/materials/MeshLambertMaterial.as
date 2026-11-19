// three.js MeshLambertMaterial: diffuse only.

import { MultiplyOperation, TangentSpaceNormalMap } from "../constants";
import { Material, MaterialParameters } from "./Material";
import {
    MaterialUniforms, KIND_LAMBERT, SLOT_MAP, SLOT_NORMAL, SLOT_AO, SLOT_EMISSIVE, SLOT_ALPHA, ROLE_BUMP, ROLE_DISPLACEMENT, ROLE_LIGHT, ROLE_SPECULAR, SLOT_ENV,
} from "./MaterialUniforms";
import { Color } from "../math/Color";
import { Vector2 } from "../math/Vector2";
import { Texture } from "../textures/Texture";
import { Dynamic } from "rive/dynamic";
import { JSONMeta, setNumber } from "../core/JSON";

export class MeshLambertMaterialParameters extends MaterialParameters {
    color: u32 = 0xFFFFFF;
    map: Texture? = null;
    emissive: u32 = 0x000000;
    emissiveIntensity: f64 = 1;
    emissiveMap: Texture? = null;
    normalMap: Texture? = null;
    normalScale: Vector2 = new Vector2(1, 1);
    aoMap: Texture? = null;
    aoMapIntensity: f64 = 1;
    alphaMap: Texture? = null;
    lightMap: Texture? = null;
    lightMapIntensity: f64 = 1;
    bumpMap: Texture? = null;
    bumpScale: f64 = 1;
    displacementMap: Texture? = null;
    displacementScale: f64 = 1;
    displacementBias: f64 = 0;
    normalMapType: i32 = TangentSpaceNormalMap;
    specularMap: Texture? = null;
    envMap: Texture? = null;
    combine: i32 = MultiplyOperation;
    reflectivity: f64 = 1;
    refractionRatio: f64 = 0.98;
}

export class MeshLambertMaterial extends Material {
    readonly isMeshLambertMaterial: bool = true;

    override toJSONProperties(data: Dynamic, meta: JSONMeta): void {
        super.toJSONProperties(data, meta);
        this.colorToJSON(data, "color", this.color);
        this.colorToJSON(data, "emissive", this.emissive);
        if (this.emissiveIntensity != 1) setNumber(data, "emissiveIntensity", this.emissiveIntensity);
        this.mapToJSON(data, "map", this.map, meta);
        this.mapToJSON(data, "alphaMap", this.alphaMap, meta);
        if (this.mapToJSON(data, "lightMap", this.lightMap, meta)) setNumber(data, "lightMapIntensity", this.lightMapIntensity);
        if (this.mapToJSON(data, "aoMap", this.aoMap, meta)) setNumber(data, "aoMapIntensity", this.aoMapIntensity);
        this.surfaceMapsToJSON(data, meta, this.normalMap, this.normalMapType, this.normalScale, this.bumpMap,
            this.bumpScale, this.displacementMap, this.displacementScale, this.displacementBias);
        this.mapToJSON(data, "emissiveMap", this.emissiveMap, meta);
        this.mapToJSON(data, "specularMap", this.specularMap, meta);
        if (this.mapToJSON(data, "envMap", this.envMap, meta)) setNumber(data, "combine", <f64>this.combine);
        setNumber(data, "reflectivity", this.reflectivity);
        setNumber(data, "refractionRatio", this.refractionRatio);
    }
    color: Color = new Color();
    map: Texture? = null;
    emissive: Color = new Color(0, 0, 0);
    emissiveIntensity: f64 = 1;
    emissiveMap: Texture? = null;
    normalMap: Texture? = null;
    normalScale: Vector2 = new Vector2(1, 1);
    aoMap: Texture? = null;
    aoMapIntensity: f64 = 1;
    alphaMap: Texture? = null;

    lightMap: Texture? = null;
    lightMapIntensity: f64 = 1;
    bumpMap: Texture? = null;
    bumpScale: f64 = 1;
    displacementMap: Texture? = null;
    displacementScale: f64 = 1;
    displacementBias: f64 = 0;
    normalMapType: i32 = TangentSpaceNormalMap;
    specularMap: Texture? = null;
    envMap: Texture? = null;
    combine: i32 = MultiplyOperation;
    reflectivity: f64 = 1;
    refractionRatio: f64 = 0.98;

    constructor(parameters: MeshLambertMaterialParameters? = null) {
        super();
        this.type = "MeshLambertMaterial";
        if (parameters != null) {
            this.setValues(parameters);
            this.lightMap = parameters.lightMap;
            this.lightMapIntensity = parameters.lightMapIntensity;
            this.bumpMap = parameters.bumpMap;
            this.bumpScale = parameters.bumpScale;
            this.displacementMap = parameters.displacementMap;
            this.displacementScale = parameters.displacementScale;
            this.displacementBias = parameters.displacementBias;
            this.normalMapType = parameters.normalMapType;
            this.specularMap = parameters.specularMap;
            this.envMap = parameters.envMap;
            this.combine = parameters.combine;
            this.reflectivity = parameters.reflectivity;
            this.refractionRatio = parameters.refractionRatio;
            this.color.setHex(parameters.color);
            this.map = parameters.map;
            this.emissive.setHex(parameters.emissive);
            this.emissiveIntensity = parameters.emissiveIntensity;
            this.emissiveMap = parameters.emissiveMap;
            this.normalMap = parameters.normalMap;
            this.normalScale.copy(parameters.normalScale);
            this.aoMap = parameters.aoMap;
            this.aoMapIntensity = parameters.aoMapIntensity;
            this.alphaMap = parameters.alphaMap;
        }
    }

    override fillUniforms(u: MaterialUniforms): void {
        super.fillUniforms(u);
        u.kind = KIND_LAMBERT;
        u.r = this.color.r; u.g = this.color.g; u.b = this.color.b;
        const k = this.emissiveIntensity;
        u.emissiveR = this.emissive.r * k; u.emissiveG = this.emissive.g * k; u.emissiveB = this.emissive.b * k;
        u.normalScaleX = this.normalScale.x; u.normalScaleY = this.normalScale.y;
        u.aoMapIntensity = this.aoMapIntensity;
        u.textures[SLOT_MAP] = this.map;
        u.textures[SLOT_NORMAL] = this.normalMap;
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
        u.roles[ROLE_SPECULAR] = this.specularMap;
        u.textures[SLOT_ENV] = this.envMap;
        u.combine = this.combine;
        u.reflectivity = this.reflectivity;
        u.refractionRatio = this.refractionRatio;
    }
}
