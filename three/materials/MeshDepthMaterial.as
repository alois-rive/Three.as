// three.js MeshDepthMaterial: depth as grey, white near, black far
// (BasicDepthPacking only).

import { Material, MaterialParameters } from "./Material";
import { MaterialUniforms, KIND_DEPTH, SLOT_MAP, SLOT_ALPHA } from "./MaterialUniforms";
import { Texture } from "../textures/Texture";
import { BasicDepthPacking } from "../constants";

export class MeshDepthMaterialParameters extends MaterialParameters {
    depthPacking: i32 = BasicDepthPacking;
    map: Texture? = null;
    alphaMap: Texture? = null;
}

export class MeshDepthMaterial extends Material {
    readonly isMeshDepthMaterial: bool = true;
    depthPacking: i32 = BasicDepthPacking;
    map: Texture? = null;
    alphaMap: Texture? = null;

    constructor(parameters: MeshDepthMaterialParameters? = null) {
        super();
        this.type = "MeshDepthMaterial";
        this.fog = false;
        if (parameters != null) {
            this.setValues(parameters);
            this.depthPacking = parameters.depthPacking;
            this.map = parameters.map;
            this.alphaMap = parameters.alphaMap;
        }
    }

    override fillUniforms(u: MaterialUniforms): void {
        super.fillUniforms(u);
        u.kind = KIND_DEPTH;
        u.fog = false;
        u.textures[SLOT_MAP] = this.map;
        u.textures[SLOT_ALPHA] = this.alphaMap;
    }
}
