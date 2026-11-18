// three.js MeshPhysicalMaterial (subset): MeshStandardMaterial plus
// clearcoat, sheen, ior and specular intensity/colour. Transmission,
// iridescence, anisotropy and the extra maps are not ported yet.

import { MeshStandardMaterial, MeshStandardMaterialParameters } from "./MeshStandardMaterial";
import { MaterialUniforms, KIND_PHYSICAL } from "./MaterialUniforms";
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

    constructor(parameters: MeshPhysicalMaterialParameters? = null) {
        super(null);
        this.type = "MeshPhysicalMaterial";
        if (parameters != null) {
            this.setStandardValues(parameters);
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
    }
}
