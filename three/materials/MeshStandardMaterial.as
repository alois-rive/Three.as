// three.js MeshStandardMaterial: metallic-roughness PBR (GGX specular,
// Lambert diffuse), lit as three.js does. Without an environment map,
// metals only reflect the direct lights, as in three.js.

import { Material, MaterialParameters } from "./Material";
import { Color } from "../math/Color";
import { Texture } from "../textures/Texture";

export class MeshStandardMaterialParameters extends MaterialParameters {
    color: u32 = 0xFFFFFF;
    roughness: f64 = 1;
    metalness: f64 = 0;
    map: Texture? = null;
    emissive: u32 = 0x000000;
    emissiveIntensity: f64 = 1;
    flatShading: bool = false;
}

export class MeshStandardMaterial extends Material {
    readonly isMeshStandardMaterial: bool = true;
    color: Color = new Color();
    roughness: f64 = 1;
    metalness: f64 = 0;
    map: Texture? = null;
    emissive: Color = new Color(0, 0, 0);
    emissiveIntensity: f64 = 1;
    flatShading: bool = false;

    constructor(parameters: MeshStandardMaterialParameters? = null) {
        super();
        this.type = "MeshStandardMaterial";
        if (parameters != null) {
            this.setValues(parameters);
            this.color.setHex(parameters.color);
            this.roughness = parameters.roughness;
            this.metalness = parameters.metalness;
            this.map = parameters.map;
            this.emissive.setHex(parameters.emissive);
            this.emissiveIntensity = parameters.emissiveIntensity;
            this.flatShading = parameters.flatShading;
        }
    }
}
