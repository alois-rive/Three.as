// three.js ShadowMaterial: transparent everywhere but where shadows fall,
// there `color` at `opacity` (receiveShadow must be set on the mesh).

import { Material, MaterialParameters } from "./Material";
import { MaterialUniforms, KIND_SHADOW } from "./MaterialUniforms";
import { Color } from "../math/Color";

export class ShadowMaterialParameters extends MaterialParameters {
    color: u32 = 0x000000;
    transparent: bool = true;
}

export class ShadowMaterial extends Material {
    readonly isShadowMaterial: bool = true;
    color: Color = new Color(0, 0, 0);

    constructor(parameters: ShadowMaterialParameters? = null) {
        super();
        this.type = "ShadowMaterial";
        this.transparent = true;
        if (parameters != null) {
            this.setValues(parameters);
            this.color.setHex(parameters.color);
        }
    }

    override fillUniforms(u: MaterialUniforms): void {
        super.fillUniforms(u);
        u.kind = KIND_SHADOW;
        u.r = this.color.r; u.g = this.color.g; u.b = this.color.b;
    }
}
