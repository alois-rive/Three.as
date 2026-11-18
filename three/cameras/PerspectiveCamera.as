// three.js PerspectiveCamera. Call updateProjectionMatrix() after changing
// fov, aspect, near, far, zoom or filmOffset (on resize, set aspect).

import { Camera } from "./Camera";
import { Mat4 } from "rive/mat4";
import { DEG2RAD, RAD2DEG } from "../math/MathUtils";

export class PerspectiveCamera extends Camera {
    readonly isPerspectiveCamera: bool = true;
    /// Vertical field of view, degrees.
    fov: f64;
    aspect: f64;
    near: f64;
    far: f64;
    zoom: f64 = 1;
    focus: f64 = 10;
    /// Film width in millimetres (for setFocalLength).
    filmGauge: f64 = 35;
    /// Horizontal film offset, millimetres.
    filmOffset: f64 = 0;

    constructor(fov: f64 = 50, aspect: f64 = 1, near: f64 = 0.1, far: f64 = 2000) {
        super();
        this.type = "PerspectiveCamera";
        this.fov = fov;
        this.aspect = aspect;
        this.near = near;
        this.far = far;
        this.updateProjectionMatrix();
    }

    /// Sets fov from a focal length in millimetres (35mm film by default).
    setFocalLength(focalLength: f64): void {
        const vExtentSlope = 0.5 * this.getFilmHeight() / focalLength;
        this.fov = RAD2DEG * 2 * Math.atan(vExtentSlope);
        this.updateProjectionMatrix();
    }

    getFocalLength(): f64 {
        const vExtentSlope = Math.tan(DEG2RAD * 0.5 * this.fov);
        return 0.5 * this.getFilmHeight() / vExtentSlope;
    }

    /// The fov with zoom applied, degrees.
    getEffectiveFOV(): f64 {
        return RAD2DEG * 2 * Math.atan(Math.tan(DEG2RAD * 0.5 * this.fov) / this.zoom);
    }

    getFilmWidth(): f64 { return this.filmGauge * Math.min(this.aspect, 1); }
    getFilmHeight(): f64 { return this.filmGauge / Math.max(this.aspect, 1); }

    override updateProjectionMatrix(): void {
        const near = this.near;
        if (this.filmOffset == 0) {
            Mat4.perspectiveInto(this.projectionMatrix.mat4, <f32>(this.getEffectiveFOV() * DEG2RAD),
                <f32>this.aspect, <f32>near, <f32>this.far);
        } else {
            const top = near * Math.tan(DEG2RAD * 0.5 * this.fov) / this.zoom;
            const height = 2 * top;
            const width = this.aspect * height;
            const left = -0.5 * width + near * this.filmOffset / this.getFilmWidth();
            this.projectionMatrix.makePerspective(left, left + width, top, top - height, near, this.far);
        }
        this.projectionMatrixInverse.copy(this.projectionMatrix).invert();
    }
}
