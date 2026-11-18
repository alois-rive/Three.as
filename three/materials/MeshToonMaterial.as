// three.js MeshToonMaterial: diffuse light quantized by `gradientMap` (a
// strip of tones, sampled with NearestFilter), or a two-tone default.

import { Material, MaterialParameters } from "./Material";
import {
    MaterialUniforms, KIND_TOON, SLOT_MAP, SLOT_NORMAL, SLOT_AUX, SLOT_AO, SLOT_EMISSIVE, SLOT_ALPHA,
} from "./MaterialUniforms";
import { Color } from "../math/Color";
import { Vector2 } from "../math/Vector2";
import { Texture } from "../textures/Texture";

export class MeshToonMaterialParameters extends MaterialParameters {
    color: u32 = 0xFFFFFF;
    map: Texture? = null;
    gradientMap: Texture? = null;
    emissive: u32 = 0x000000;
    emissiveIntensity: f64 = 1;
    emissiveMap: Texture? = null;
    normalMap: Texture? = null;
    normalScale: Vector2 = new Vector2(1, 1);
    aoMap: Texture? = null;
    aoMapIntensity: f64 = 1;
    alphaMap: Texture? = null;
}

export class MeshToonMaterial extends Material {
    readonly isMeshToonMaterial: bool = true;
    color: Color = new Color();
    map: Texture? = null;
    gradientMap: Texture? = null;
    emissive: Color = new Color(0, 0, 0);
    emissiveIntensity: f64 = 1;
    emissiveMap: Texture? = null;
    normalMap: Texture? = null;
    normalScale: Vector2 = new Vector2(1, 1);
    aoMap: Texture? = null;
    aoMapIntensity: f64 = 1;
    alphaMap: Texture? = null;

    constructor(parameters: MeshToonMaterialParameters? = null) {
        super();
        this.type = "MeshToonMaterial";
        if (parameters != null) {
            this.setValues(parameters);
            this.color.setHex(parameters.color);
            this.map = parameters.map;
            this.gradientMap = parameters.gradientMap;
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
        u.kind = KIND_TOON;
        u.r = this.color.r; u.g = this.color.g; u.b = this.color.b;
        const k = this.emissiveIntensity;
        u.emissiveR = this.emissive.r * k; u.emissiveG = this.emissive.g * k; u.emissiveB = this.emissive.b * k;
        u.normalScaleX = this.normalScale.x; u.normalScaleY = this.normalScale.y;
        u.aoMapIntensity = this.aoMapIntensity;
        u.textures[SLOT_MAP] = this.map;
        u.textures[SLOT_NORMAL] = this.normalMap;
        u.textures[SLOT_AUX] = this.gradientMap;
        u.textures[SLOT_AO] = this.aoMap;
        u.textures[SLOT_EMISSIVE] = this.emissiveMap;
        u.textures[SLOT_ALPHA] = this.alphaMap;
    }
}
