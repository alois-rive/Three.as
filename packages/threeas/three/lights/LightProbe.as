// three.js LightProbe: diffuse light from every direction as spherical
// harmonics (`sh`), summed into the lit materials' indirect light.

import { Object3D } from "../core/Object3D";
import { Light } from "./Light";
import { Dynamic } from "rive/dynamic";
import { JSONMeta } from "../core/JSON";
import { SphericalHarmonics3 } from "../math/SphericalHarmonics3";

export class LightProbe extends Light {
    readonly isLightProbe: bool = true;

    override toJSONObject(object: Dynamic, meta: JSONMeta): void {
        super.toJSONObject(object, meta);
        object.set("sh", Dynamic.fromNumbers(this.sh.toArray()));
    }
    sh: SphericalHarmonics3;

    constructor(sh: SphericalHarmonics3? = null, intensity: f64 = 1) {
        super(0xFFFFFF, intensity);
        this.type = "LightProbe";
        this.sh = sh != null ? sh! : new SphericalHarmonics3();
    }

    override copy(source: Object3D, recursive: bool = true): Object3D {
        super.copy(source, recursive);
        if (source instanceof LightProbe) {
            const s = source as LightProbe;
            this.sh.copy(s.sh);
        }
        return this;
    }

    override clone(recursive: bool = true): Object3D {
        return new LightProbe().copy(this, recursive);
    }
}
