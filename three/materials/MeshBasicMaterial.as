// three.js MeshBasicMaterial: unlit colour, times `map`.

import { MultiplyOperation } from "../constants";
import { Material, MaterialParameters } from "./Material";
import {
    MaterialUniforms, KIND_BASIC, SLOT_MAP, SLOT_ALPHA, SLOT_AO, ROLE_LIGHT, ROLE_SPECULAR, SLOT_ENV,
} from "./MaterialUniforms";
import { Color } from "../math/Color";
import { Texture } from "../textures/Texture";
import { Dynamic } from "rive/dynamic";
import { JSONMeta, setNumber } from "../core/JSON";

export class MeshBasicMaterialParameters extends MaterialParameters {
    /// sRGB hex (or a Rive Color).
    color: u32 = 0xFFFFFF;
    map: Texture? = null;
    alphaMap: Texture? = null;
    aoMap: Texture? = null;
    aoMapIntensity: f64 = 1;
    lightMap: Texture? = null;
    lightMapIntensity: f64 = 1;
    specularMap: Texture? = null;
    envMap: Texture? = null;
    combine: i32 = MultiplyOperation;
    reflectivity: f64 = 1;
    refractionRatio: f64 = 0.98;
}

export class MeshBasicMaterial extends Material {
    readonly isMeshBasicMaterial: bool = true;

    override toJSONProperties(data: Dynamic, meta: JSONMeta): void {
        super.toJSONProperties(data, meta);
        this.colorToJSON(data, "color", this.color);
        this.mapToJSON(data, "map", this.map, meta);
        this.mapToJSON(data, "alphaMap", this.alphaMap, meta);
        if (this.mapToJSON(data, "lightMap", this.lightMap, meta)) setNumber(data, "lightMapIntensity", this.lightMapIntensity);
        if (this.mapToJSON(data, "aoMap", this.aoMap, meta)) setNumber(data, "aoMapIntensity", this.aoMapIntensity);
        this.mapToJSON(data, "specularMap", this.specularMap, meta);
        if (this.mapToJSON(data, "envMap", this.envMap, meta)) setNumber(data, "combine", <f64>this.combine);
        setNumber(data, "reflectivity", this.reflectivity);
        setNumber(data, "refractionRatio", this.refractionRatio);
    }
    color: Color = new Color();
    map: Texture? = null;
    /// Green channel scales opacity.
    alphaMap: Texture? = null;
    aoMap: Texture? = null;
    aoMapIntensity: f64 = 1;

    lightMap: Texture? = null;
    lightMapIntensity: f64 = 1;
    specularMap: Texture? = null;
    envMap: Texture? = null;
    combine: i32 = MultiplyOperation;
    reflectivity: f64 = 1;
    refractionRatio: f64 = 0.98;

    constructor(parameters: MeshBasicMaterialParameters? = null) {
        super();
        this.type = "MeshBasicMaterial";
        if (parameters != null) {
            this.setValues(parameters);
            this.lightMap = parameters.lightMap;
            this.lightMapIntensity = parameters.lightMapIntensity;
            this.specularMap = parameters.specularMap;
            this.envMap = parameters.envMap;
            this.combine = parameters.combine;
            this.reflectivity = parameters.reflectivity;
            this.refractionRatio = parameters.refractionRatio;
            this.color.setHex(parameters.color);
            this.map = parameters.map;
            this.alphaMap = parameters.alphaMap;
            this.aoMap = parameters.aoMap;
            this.aoMapIntensity = parameters.aoMapIntensity;
        }
    }

    override fillUniforms(u: MaterialUniforms): void {
        super.fillUniforms(u);
        u.kind = KIND_BASIC;
        u.r = this.color.r; u.g = this.color.g; u.b = this.color.b;
        u.aoMapIntensity = this.aoMapIntensity;
        u.textures[SLOT_MAP] = this.map;
        u.textures[SLOT_ALPHA] = this.alphaMap;
        u.textures[SLOT_AO] = this.aoMap;
        u.roles[ROLE_LIGHT] = this.lightMap;
        u.lightMapIntensity = this.lightMapIntensity;
        u.roles[ROLE_SPECULAR] = this.specularMap;
        u.textures[SLOT_ENV] = this.envMap;
        u.combine = this.combine;
        u.reflectivity = this.reflectivity;
        u.refractionRatio = this.refractionRatio;
    }
}
