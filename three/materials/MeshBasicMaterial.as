// three.js MeshBasicMaterial: unlit colour, times `map`.

import { Material, MaterialParameters } from "./Material";
import { MaterialUniforms, KIND_BASIC, SLOT_MAP, SLOT_ALPHA, SLOT_AO } from "./MaterialUniforms";
import { Color } from "../math/Color";
import { Texture } from "../textures/Texture";

export class MeshBasicMaterialParameters extends MaterialParameters {
    /// sRGB hex (or a Rive Color).
    color: u32 = 0xFFFFFF;
    map: Texture? = null;
    alphaMap: Texture? = null;
    aoMap: Texture? = null;
    aoMapIntensity: f64 = 1;
}

export class MeshBasicMaterial extends Material {
    readonly isMeshBasicMaterial: bool = true;
    color: Color = new Color();
    map: Texture? = null;
    /// Green channel scales opacity.
    alphaMap: Texture? = null;
    aoMap: Texture? = null;
    aoMapIntensity: f64 = 1;

    constructor(parameters: MeshBasicMaterialParameters? = null) {
        super();
        this.type = "MeshBasicMaterial";
        if (parameters != null) {
            this.setValues(parameters);
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
    }
}
