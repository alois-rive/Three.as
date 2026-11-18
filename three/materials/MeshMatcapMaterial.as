// three.js MeshMatcapMaterial: colour looked up in a "material capture"
// sphere image by the view-space normal. Unlit.

import { TangentSpaceNormalMap } from "../constants";
import { Material, MaterialParameters } from "./Material";
import {
    MaterialUniforms, KIND_MATCAP, SLOT_MAP, SLOT_NORMAL, SLOT_AUX, SLOT_ALPHA, ROLE_BUMP, ROLE_DISPLACEMENT,
} from "./MaterialUniforms";
import { Color } from "../math/Color";
import { Vector2 } from "../math/Vector2";
import { Texture } from "../textures/Texture";

export class MeshMatcapMaterialParameters extends MaterialParameters {
    color: u32 = 0xFFFFFF;
    matcap: Texture? = null;
    map: Texture? = null;
    normalMap: Texture? = null;
    normalScale: Vector2 = new Vector2(1, 1);
    alphaMap: Texture? = null;
    bumpMap: Texture? = null;
    bumpScale: f64 = 1;
    displacementMap: Texture? = null;
    displacementScale: f64 = 1;
    displacementBias: f64 = 0;
    normalMapType: i32 = TangentSpaceNormalMap;
}

export class MeshMatcapMaterial extends Material {
    readonly isMeshMatcapMaterial: bool = true;
    color: Color = new Color();
    matcap: Texture? = null;
    map: Texture? = null;
    normalMap: Texture? = null;
    normalScale: Vector2 = new Vector2(1, 1);
    alphaMap: Texture? = null;

    bumpMap: Texture? = null;
    bumpScale: f64 = 1;
    displacementMap: Texture? = null;
    displacementScale: f64 = 1;
    displacementBias: f64 = 0;
    normalMapType: i32 = TangentSpaceNormalMap;

    constructor(parameters: MeshMatcapMaterialParameters? = null) {
        super();
        this.type = "MeshMatcapMaterial";
        if (parameters != null) {
            this.setValues(parameters);
            this.bumpMap = parameters.bumpMap;
            this.bumpScale = parameters.bumpScale;
            this.displacementMap = parameters.displacementMap;
            this.displacementScale = parameters.displacementScale;
            this.displacementBias = parameters.displacementBias;
            this.normalMapType = parameters.normalMapType;
            this.color.setHex(parameters.color);
            this.matcap = parameters.matcap;
            this.map = parameters.map;
            this.normalMap = parameters.normalMap;
            this.normalScale.copy(parameters.normalScale);
            this.alphaMap = parameters.alphaMap;
        }
    }

    override fillUniforms(u: MaterialUniforms): void {
        super.fillUniforms(u);
        u.kind = KIND_MATCAP;
        u.r = this.color.r; u.g = this.color.g; u.b = this.color.b;
        u.normalScaleX = this.normalScale.x; u.normalScaleY = this.normalScale.y;
        u.textures[SLOT_MAP] = this.map;
        u.textures[SLOT_NORMAL] = this.normalMap;
        u.textures[SLOT_AUX] = this.matcap;
        u.textures[SLOT_ALPHA] = this.alphaMap;
        u.roles[ROLE_BUMP] = this.bumpMap;
        u.bumpScale = this.bumpScale;
        u.roles[ROLE_DISPLACEMENT] = this.displacementMap;
        u.displacementScale = this.displacementScale;
        u.displacementBias = this.displacementBias;
        u.normalMapType = this.normalMapType;
    }
}
