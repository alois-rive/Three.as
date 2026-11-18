// three.js MeshPhongMaterial: Lambert diffuse with Blinn-Phong specular.

import { MultiplyOperation, TangentSpaceNormalMap } from "../constants";
import { Material, MaterialParameters } from "./Material";
import {
    MaterialUniforms, KIND_PHONG, SLOT_MAP, SLOT_NORMAL, SLOT_AUX, SLOT_AO, SLOT_EMISSIVE, SLOT_ALPHA, ROLE_BUMP, ROLE_DISPLACEMENT, ROLE_LIGHT, SLOT_ENV,
} from "./MaterialUniforms";
import { Color } from "../math/Color";
import { Vector2 } from "../math/Vector2";
import { Texture } from "../textures/Texture";

export class MeshPhongMaterialParameters extends MaterialParameters {
    color: u32 = 0xFFFFFF;
    specular: u32 = 0x111111;
    shininess: f64 = 30;
    map: Texture? = null;
    specularMap: Texture? = null;
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
    envMap: Texture? = null;
    combine: i32 = MultiplyOperation;
    reflectivity: f64 = 1;
    refractionRatio: f64 = 0.98;
}

export class MeshPhongMaterial extends Material {
    readonly isMeshPhongMaterial: bool = true;
    color: Color = new Color();
    specular: Color = new Color(0x111111);
    shininess: f64 = 30;
    map: Texture? = null;
    /// Red channel scales the specular.
    specularMap: Texture? = null;
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
    envMap: Texture? = null;
    combine: i32 = MultiplyOperation;
    reflectivity: f64 = 1;
    refractionRatio: f64 = 0.98;

    constructor(parameters: MeshPhongMaterialParameters? = null) {
        super();
        this.type = "MeshPhongMaterial";
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
            this.envMap = parameters.envMap;
            this.combine = parameters.combine;
            this.reflectivity = parameters.reflectivity;
            this.refractionRatio = parameters.refractionRatio;
            this.color.setHex(parameters.color);
            this.specular.setHex(parameters.specular);
            this.shininess = parameters.shininess;
            this.map = parameters.map;
            this.specularMap = parameters.specularMap;
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
        u.kind = KIND_PHONG;
        u.r = this.color.r; u.g = this.color.g; u.b = this.color.b;
        u.specularR = this.specular.r; u.specularG = this.specular.g; u.specularB = this.specular.b;
        u.shininess = Math.max(this.shininess, 1e-4);
        const k = this.emissiveIntensity;
        u.emissiveR = this.emissive.r * k; u.emissiveG = this.emissive.g * k; u.emissiveB = this.emissive.b * k;
        u.normalScaleX = this.normalScale.x; u.normalScaleY = this.normalScale.y;
        u.aoMapIntensity = this.aoMapIntensity;
        u.textures[SLOT_MAP] = this.map;
        u.textures[SLOT_NORMAL] = this.normalMap;
        u.textures[SLOT_AUX] = this.specularMap;
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
        u.textures[SLOT_ENV] = this.envMap;
        u.combine = this.combine;
        u.reflectivity = this.reflectivity;
        u.refractionRatio = this.refractionRatio;
    }
}
