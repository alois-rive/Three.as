// three.js LightShadow and its per-light subclasses: the shadow camera and
// map settings of a light that casts shadows (castShadow = true).

import { Camera } from "../cameras/Camera";
import { PerspectiveCamera } from "../cameras/PerspectiveCamera";
import { OrthographicCamera } from "../cameras/OrthographicCamera";
import { Vector2 } from "../math/Vector2";
import { Matrix4 } from "../math/Matrix4";

export class LightShadow {
    camera: Camera;
    /// Depth offset against acne (try -0.0005 ... 0.0005).
    bias: f64 = 0;
    /// Offset along the normal, in world units.
    normalBias: f64 = 0;
    /// PCF filter radius (PCFShadowMap).
    radius: f64 = 1;
    blurSamples: i32 = 8;
    /// Shadow map size in texels.
    mapSize: Vector2 = new Vector2(512, 512);
    intensity: f64 = 1;
    autoUpdate: bool = true;
    needsUpdate: bool = false;
    /// World to shadow map clip space, set by the renderer.
    matrix: Matrix4 = new Matrix4();

    constructor(camera: Camera = new OrthographicCamera(-5, 5, 5, -5, 0.5, 500)) {
        this.camera = camera;
    }
}

export class DirectionalLightShadow extends LightShadow {
    constructor() {
        super(new OrthographicCamera(-5, 5, 5, -5, 0.5, 500));
    }
}

export class SpotLightShadow extends LightShadow {
    /// Spot shadows keep the light's cone: focus scales the fov.
    focus: f64 = 1;

    constructor() {
        super(new PerspectiveCamera(50, 1, 0.5, 500));
    }
}

export class PointLightShadow extends LightShadow {
    constructor() {
        super(new PerspectiveCamera(90, 1, 0.5, 500));
    }
}
