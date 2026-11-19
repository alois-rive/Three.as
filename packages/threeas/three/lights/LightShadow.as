// three.js LightShadow and its per-light subclasses: the shadow camera and
// map settings of a light that casts shadows (castShadow = true).

import { Camera } from "../cameras/Camera";
import { PerspectiveCamera } from "../cameras/PerspectiveCamera";
import { OrthographicCamera } from "../cameras/OrthographicCamera";
import { Vector2 } from "../math/Vector2";
import { Matrix4 } from "../math/Matrix4";
import { Dynamic } from "rive/dynamic";
import { JSONMeta } from "../core/JSON";

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

    /// three.js's JSON: intensity, bias, normalBias, radius and mapSize
    /// when not the defaults, and the camera's object (without matrix).
    toJSON(): Dynamic {
        const object = Dynamic.newTable();
        if (this.intensity != 1) object.set("intensity", Dynamic.fromNumber(this.intensity));
        if (this.bias != 0) object.set("bias", Dynamic.fromNumber(this.bias));
        if (this.normalBias != 0) object.set("normalBias", Dynamic.fromNumber(this.normalBias));
        if (this.radius != 1) object.set("radius", Dynamic.fromNumber(this.radius));
        if (this.mapSize.x != 512 || this.mapSize.y != 512) {
            object.set("mapSize", Dynamic.fromNumbers(this.mapSize.toArray()));
        }
        const camera = this.camera.toJSON(new JSONMeta()).get("object");
        if (camera != null) camera.set("matrix", null);
        object.set("camera", camera);
        return object;
    }

    copy(source: LightShadow): LightShadow {
        this.camera = source.camera.clone(true) as Camera;
        this.bias = source.bias;
        this.normalBias = source.normalBias;
        this.radius = source.radius;
        this.blurSamples = source.blurSamples;
        this.mapSize.copy(source.mapSize);
        this.intensity = source.intensity;
        this.autoUpdate = source.autoUpdate;
        return this;
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
