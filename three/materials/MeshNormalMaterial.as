// three.js MeshNormalMaterial: the view-space normal as colour.

import { Material, MaterialParameters } from "./Material";
import { MaterialUniforms, KIND_NORMAL, SLOT_NORMAL } from "./MaterialUniforms";
import { Texture } from "../textures/Texture";
import { Vector2 } from "../math/Vector2";

export class MeshNormalMaterialParameters extends MaterialParameters {
    normalMap: Texture? = null;
    normalScale: Vector2 = new Vector2(1, 1);
}

export class MeshNormalMaterial extends Material {
    readonly isMeshNormalMaterial: bool = true;
    normalMap: Texture? = null;
    normalScale: Vector2 = new Vector2(1, 1);

    constructor(parameters: MeshNormalMaterialParameters? = null) {
        super();
        this.type = "MeshNormalMaterial";
        this.fog = false;
        if (parameters != null) {
            this.setValues(parameters);
            this.normalMap = parameters.normalMap;
            this.normalScale.copy(parameters.normalScale);
        }
    }

    override fillUniforms(u: MaterialUniforms): void {
        super.fillUniforms(u);
        u.kind = KIND_NORMAL;
        u.fog = false;
        u.normalScaleX = this.normalScale.x; u.normalScaleY = this.normalScale.y;
        u.textures[SLOT_NORMAL] = this.normalMap;
    }
}
