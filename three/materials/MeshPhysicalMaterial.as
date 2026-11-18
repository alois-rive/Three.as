// three.js MeshPhysicalMaterial (subset): MeshStandardMaterial plus
// clearcoat, sheen, ior and specular intensity/colour. Transmission,
// iridescence, anisotropy and the extra maps are not ported yet.

import { Texture } from "../textures/Texture";
import { Vector2 } from "../math/Vector2";
import { MeshStandardMaterial, MeshStandardMaterialParameters } from "./MeshStandardMaterial";
import {
    MaterialUniforms, KIND_PHYSICAL, ROLE_CLEARCOAT, ROLE_CLEARCOAT_NORMAL, ROLE_CLEARCOAT_ROUGHNESS, ROLE_SHEEN_COLOR, ROLE_SHEEN_ROUGHNESS, ROLE_SPECULAR_COLOR, ROLE_SPECULAR_INTENSITY,
} from "./MaterialUniforms";
import { Color } from "../math/Color";

export class MeshPhysicalMaterialParameters extends MeshStandardMaterialParameters {
    clearcoat: f64 = 0;
    clearcoatRoughness: f64 = 0;
    sheen: f64 = 0;
    sheenColor: u32 = 0x000000;
    sheenRoughness: f64 = 1;
    ior: f64 = 1.5;
    specularIntensity: f64 = 1;
    specularColor: u32 = 0xFFFFFF;
    clearcoatMap: Texture? = null;
    clearcoatRoughnessMap: Texture? = null;
    clearcoatNormalMap: Texture? = null;
    clearcoatNormalScale: Vector2 = new Vector2(1, 1);
    sheenColorMap: Texture? = null;
    sheenRoughnessMap: Texture? = null;
    specularIntensityMap: Texture? = null;
    specularColorMap: Texture? = null;
}

export class MeshPhysicalMaterial extends MeshStandardMaterial {
    readonly isMeshPhysicalMaterial: bool = true;
    clearcoat: f64 = 0;
    clearcoatRoughness: f64 = 0;
    sheen: f64 = 0;
    sheenColor: Color = new Color(0, 0, 0);
    sheenRoughness: f64 = 1;
    ior: f64 = 1.5;
    specularIntensity: f64 = 1;
    specularColor: Color = new Color(1, 1, 1);

    clearcoatMap: Texture? = null;
    clearcoatRoughnessMap: Texture? = null;
    clearcoatNormalMap: Texture? = null;
    clearcoatNormalScale: Vector2 = new Vector2(1, 1);
    sheenColorMap: Texture? = null;
    sheenRoughnessMap: Texture? = null;
    specularIntensityMap: Texture? = null;
    specularColorMap: Texture? = null;

    constructor(parameters: MeshPhysicalMaterialParameters? = null) {
        super(null);
        this.type = "MeshPhysicalMaterial";
        if (parameters != null) {
            this.setStandardValues(parameters);
            this.clearcoatMap = parameters.clearcoatMap;
            this.clearcoatRoughnessMap = parameters.clearcoatRoughnessMap;
            this.clearcoatNormalMap = parameters.clearcoatNormalMap;
            this.clearcoatNormalScale.copy(parameters.clearcoatNormalScale);
            this.sheenColorMap = parameters.sheenColorMap;
            this.sheenRoughnessMap = parameters.sheenRoughnessMap;
            this.specularIntensityMap = parameters.specularIntensityMap;
            this.specularColorMap = parameters.specularColorMap;
            this.clearcoat = parameters.clearcoat;
            this.clearcoatRoughness = parameters.clearcoatRoughness;
            this.sheen = parameters.sheen;
            this.sheenColor.setHex(parameters.sheenColor);
            this.sheenRoughness = parameters.sheenRoughness;
            this.ior = parameters.ior;
            this.specularIntensity = parameters.specularIntensity;
            this.specularColor.setHex(parameters.specularColor);
        }
    }

    /// The F0 reflectivity in [0, 1], tied to ior as three.js.
    get reflectivity(): f64 {
        const x = (this.ior - 1) / (this.ior + 1);
        return Math.max(0, Math.min(1, 2.5 * (x * x)));
    }

    set reflectivity(value: f64) {
        const r = Math.max(0, Math.min(1, value));
        this.ior = (1 + 0.4 * r) / (1 - 0.4 * r);
    }

    override fillUniforms(u: MaterialUniforms): void {
        super.fillUniforms(u);
        u.kind = KIND_PHYSICAL;
        u.clearcoat = this.clearcoat;
        u.clearcoatRoughness = this.clearcoatRoughness;
        u.sheen = this.sheen;
        u.sheenR = this.sheenColor.r; u.sheenG = this.sheenColor.g; u.sheenB = this.sheenColor.b;
        u.sheenRoughness = this.sheenRoughness;
        u.ior = this.ior;
        u.specularIntensity = this.specularIntensity;
        u.specularColorR = this.specularColor.r; u.specularColorG = this.specularColor.g;
        u.specularColorB = this.specularColor.b;
        u.roles[ROLE_CLEARCOAT] = this.clearcoatMap;
        u.roles[ROLE_CLEARCOAT_ROUGHNESS] = this.clearcoatRoughnessMap;
        u.roles[ROLE_CLEARCOAT_NORMAL] = this.clearcoatNormalMap;
        u.clearcoatNormalScaleX = this.clearcoatNormalScale.x; u.clearcoatNormalScaleY = this.clearcoatNormalScale.y;
        u.roles[ROLE_SHEEN_COLOR] = this.sheenColorMap;
        u.roles[ROLE_SHEEN_ROUGHNESS] = this.sheenRoughnessMap;
        u.roles[ROLE_SPECULAR_INTENSITY] = this.specularIntensityMap;
        u.roles[ROLE_SPECULAR_COLOR] = this.specularColorMap;
    }
}
