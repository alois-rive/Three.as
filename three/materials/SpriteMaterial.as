// three.js SpriteMaterial: transparent by default, as three.js.

import { Material, MaterialParameters } from "./Material";
import { MaterialUniforms, KIND_BASIC, SLOT_MAP, SLOT_ALPHA } from "./MaterialUniforms";
import { Color } from "../math/Color";
import { Texture } from "../textures/Texture";

export class SpriteMaterialParameters extends MaterialParameters {
    color: u32 = 0xFFFFFF;
    map: Texture? = null;
    alphaMap: Texture? = null;
    rotation: f64 = 0;
    sizeAttenuation: bool = true;

    constructor() {
        super();
        this.transparent = true;   // three.js's SpriteMaterial default
    }
}

export class SpriteMaterial extends Material {
    readonly isSpriteMaterial: bool = true;
    color: Color = new Color();
    map: Texture? = null;
    alphaMap: Texture? = null;
    /// Radians, around the sprite's center.
    rotation: f64 = 0;
    sizeAttenuation: bool = true;

    constructor(parameters: SpriteMaterialParameters? = null) {
        super();
        this.type = "SpriteMaterial";
        this.transparent = true;
        if (parameters != null) {
            this.setValues(parameters);
            this.color.setHex(parameters.color);
            this.map = parameters.map;
            this.alphaMap = parameters.alphaMap;
            this.rotation = parameters.rotation;
            this.sizeAttenuation = parameters.sizeAttenuation;
        }
    }

    override fillUniforms(u: MaterialUniforms): void {
        super.fillUniforms(u);
        u.kind = KIND_BASIC;
        u.r = this.color.r; u.g = this.color.g; u.b = this.color.b;
        u.rotation = this.rotation;
        u.sizeAttenuation = this.sizeAttenuation;
        u.textures[SLOT_MAP] = this.map;
        u.textures[SLOT_ALPHA] = this.alphaMap;
    }
}
