// three.js MeshLambertMaterial: diffuse only.

import { Material, MaterialParameters } from "./Material";
import { Color } from "../math/Color";
import { Texture } from "../textures/Texture";

export class MeshLambertMaterialParameters extends MaterialParameters {
    color: u32 = 0xFFFFFF;
    map: Texture? = null;
    emissive: u32 = 0x000000;
    emissiveIntensity: f64 = 1;
}

export class MeshLambertMaterial extends Material {
    readonly isMeshLambertMaterial: bool = true;
    color: Color = new Color();
    map: Texture? = null;
    emissive: Color = new Color(0, 0, 0);
    emissiveIntensity: f64 = 1;

    constructor(parameters: MeshLambertMaterialParameters? = null) {
        super();
        this.type = "MeshLambertMaterial";
        if (parameters != null) {
            this.setValues(parameters);
            this.color.setHex(parameters.color);
            this.map = parameters.map;
            this.emissive.setHex(parameters.emissive);
            this.emissiveIntensity = parameters.emissiveIntensity;
        }
    }
}
