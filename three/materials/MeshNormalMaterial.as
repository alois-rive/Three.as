// three.js MeshNormalMaterial: the view-space normal as colour.

import { TangentSpaceNormalMap } from "../constants";
import { Material, MaterialParameters } from "./Material";
import {
    MaterialUniforms, KIND_NORMAL, SLOT_NORMAL, ROLE_BUMP, ROLE_DISPLACEMENT,
} from "./MaterialUniforms";
import { Texture } from "../textures/Texture";
import { Vector2 } from "../math/Vector2";

export class MeshNormalMaterialParameters extends MaterialParameters {
    normalMap: Texture? = null;
    normalScale: Vector2 = new Vector2(1, 1);
    bumpMap: Texture? = null;
    bumpScale: f64 = 1;
    displacementMap: Texture? = null;
    displacementScale: f64 = 1;
    displacementBias: f64 = 0;
    normalMapType: i32 = TangentSpaceNormalMap;
}

export class MeshNormalMaterial extends Material {
    readonly isMeshNormalMaterial: bool = true;
    normalMap: Texture? = null;
    normalScale: Vector2 = new Vector2(1, 1);

    bumpMap: Texture? = null;
    bumpScale: f64 = 1;
    displacementMap: Texture? = null;
    displacementScale: f64 = 1;
    displacementBias: f64 = 0;
    normalMapType: i32 = TangentSpaceNormalMap;

    constructor(parameters: MeshNormalMaterialParameters? = null) {
        super();
        this.type = "MeshNormalMaterial";
        this.fog = false;
        if (parameters != null) {
            this.setValues(parameters);
            this.bumpMap = parameters.bumpMap;
            this.bumpScale = parameters.bumpScale;
            this.displacementMap = parameters.displacementMap;
            this.displacementScale = parameters.displacementScale;
            this.displacementBias = parameters.displacementBias;
            this.normalMapType = parameters.normalMapType;
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
        u.roles[ROLE_BUMP] = this.bumpMap;
        u.bumpScale = this.bumpScale;
        u.roles[ROLE_DISPLACEMENT] = this.displacementMap;
        u.displacementScale = this.displacementScale;
        u.displacementBias = this.displacementBias;
        u.normalMapType = this.normalMapType;
    }
}
