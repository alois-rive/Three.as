// three.js MeshBasicMaterial: unlit colour, times `map`.

import { Material, MaterialParameters } from "./Material";
import { Color } from "../math/Color";
import { Texture } from "../textures/Texture";

export class MeshBasicMaterialParameters extends MaterialParameters {
    /// sRGB hex (or a Rive Color).
    color: u32 = 0xFFFFFF;
    map: Texture? = null;
}

export class MeshBasicMaterial extends Material {
    readonly isMeshBasicMaterial: bool = true;
    color: Color = new Color();
    map: Texture? = null;

    constructor(parameters: MeshBasicMaterialParameters? = null) {
        super();
        this.type = "MeshBasicMaterial";
        if (parameters != null) {
            this.setValues(parameters);
            this.color.setHex(parameters.color);
            this.map = parameters.map;
        }
    }
}
