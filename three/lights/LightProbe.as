// three.js LightProbe: diffuse light from every direction as spherical
// harmonics (`sh`), summed into the lit materials' indirect light.

import { Light } from "./Light";
import { SphericalHarmonics3 } from "../math/SphericalHarmonics3";

export class LightProbe extends Light {
    readonly isLightProbe: bool = true;
    sh: SphericalHarmonics3;

    constructor(sh: SphericalHarmonics3? = null, intensity: f64 = 1) {
        super(0xFFFFFF, intensity);
        this.type = "LightProbe";
        this.sh = sh != null ? sh! : new SphericalHarmonics3();
    }
}
