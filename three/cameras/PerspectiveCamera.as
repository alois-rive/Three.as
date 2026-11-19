// three.js PerspectiveCamera. Call updateProjectionMatrix() after changing
// fov, aspect, near, far, zoom or filmOffset (on resize, set aspect).

import { Object3D } from "../core/Object3D";
import { Camera } from "./Camera";
import { Mat4 } from "rive/mat4";
import { DEG2RAD, RAD2DEG } from "../math/MathUtils";
import { Dynamic } from "rive/dynamic";
import { JSONMeta, setNumber } from "../core/JSON";

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

    override toJSONObject(object: Dynamic, meta: JSONMeta): void {
        super.toJSONObject(object, meta);
        setNumber(object, "fov", this.fov);
        setNumber(object, "zoom", this.zoom);
        setNumber(object, "near", this.near);
        setNumber(object, "far", this.far);
        setNumber(object, "focus", this.focus);
        setNumber(object, "aspect", this.aspect);
        setNumber(object, "filmGauge", this.filmGauge);
        setNumber(object, "filmOffset", this.filmOffset);
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

    /// As Camera.setViewOffset; the aspect becomes fullWidth / fullHeight.
    override setViewOffset(fullWidth: f64, fullHeight: f64, x: f64, y: f64, width: f64, height: f64): void {
        this.aspect = fullWidth / fullHeight;
        super.setViewOffset(fullWidth, fullHeight, x, y, width, height);
    }

    override updateProjectionMatrix(): void {
        const near = this.near;
        const view = this.view;
        const offset = view != null && view.enabled;
        if (this.filmOffset == 0 && !offset) {
            Mat4.perspectiveInto(this.projectionMatrix.mat4, <f32>(this.getEffectiveFOV() * DEG2RAD),
                <f32>this.aspect, <f32>near, <f32>this.far);
        } else {
            let top = near * Math.tan(DEG2RAD * 0.5 * this.fov) / this.zoom;
            let height = 2 * top;
            let width = this.aspect * height;
            let left = -0.5 * width;
            if (offset) {
                const v = view!;
                left += v.offsetX * width / v.fullWidth;
                top -= v.offsetY * height / v.fullHeight;
                width *= v.width / v.fullWidth;
                height *= v.height / v.fullHeight;
            }
            if (this.filmOffset != 0) left += near * this.filmOffset / this.getFilmWidth();
            this.projectionMatrix.makePerspective(left, left + width, top, top - height, near, this.far);
        }
        this.projectionMatrixInverse.copy(this.projectionMatrix).invert();
    }

    override copy(source: Object3D, recursive: bool = true): Object3D {
        super.copy(source, recursive);
        if (source instanceof PerspectiveCamera) {
            const s = source as PerspectiveCamera;
            this.fov = s.fov;
            this.aspect = s.aspect;
            this.near = s.near;
            this.far = s.far;
            this.zoom = s.zoom;
            this.focus = s.focus;
            this.filmGauge = s.filmGauge;
            this.filmOffset = s.filmOffset;
        }
        return this;
    }

    override clone(recursive: bool = true): Object3D {
        return new PerspectiveCamera().copy(this, recursive);
    }
}
