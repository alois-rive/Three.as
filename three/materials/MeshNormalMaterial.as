// three.js MeshNormalMaterial: the view-space normal as colour.

import { Material, MaterialParameters } from "./Material";

export class MeshNormalMaterial extends Material {
    readonly isMeshNormalMaterial: bool = true;

    constructor(parameters: MaterialParameters? = null) {
        super();
        this.type = "MeshNormalMaterial";
        if (parameters != null) this.setValues(parameters);
    }
}
