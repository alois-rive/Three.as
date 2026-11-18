// three.js Scene: the root of what a renderer draws.

import { Object3D } from "../core/Object3D";
import { ColorOrTexture } from "../core/ColorOrTexture";
import { Euler } from "../math/Euler";
import { FogBase } from "./Fog";
import { Texture } from "../textures/Texture";
import { Material } from "../materials/Material";

export class Scene extends Object3D {
    readonly isScene: bool = true;
    /// A Color, a Texture (drawn to fill the view, or around it with
    /// EquirectangularReflectionMapping), or null for the clear colour.
    background: ColorOrTexture? = null;
    backgroundIntensity: f64 = 1;
    backgroundBlurriness: f64 = 0;
    backgroundRotation: Euler = new Euler();
    /// The environment map lighting every MeshStandardMaterial without an
    /// envMap of its own (M5).
    environment: Texture? = null;
    environmentIntensity: f64 = 1;
    environmentRotation: Euler = new Euler();
    fog: FogBase? = null;
    /// Overrides every object's material when set.
    overrideMaterial: Material? = null;

    constructor() {
        super();
        this.type = "Scene";
    }
}
