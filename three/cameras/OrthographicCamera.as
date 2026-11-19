// three.js OrthographicCamera. Call updateProjectionMatrix() after changing
// the frustum or zoom.

import { Object3D } from "../core/Object3D";
import { Camera } from "./Camera";
import { Dynamic } from "rive/dynamic";
import { JSONMeta, setNumber } from "../core/JSON";

export class OrthographicCamera extends Camera {
    readonly isOrthographicCamera: bool = true;
    left: f64;
    right: f64;
    top: f64;
    bottom: f64;
    near: f64;
    far: f64;
    zoom: f64 = 1;

    constructor(left: f64 = -1, right: f64 = 1, top: f64 = 1, bottom: f64 = -1, near: f64 = 0.1, far: f64 = 2000) {
        super();
        this.type = "OrthographicCamera";
        this.left = left;
        this.right = right;
        this.top = top;
        this.bottom = bottom;
        this.near = near;
        this.far = far;
        this.updateProjectionMatrix();
    }

    override toJSONObject(object: Dynamic, meta: JSONMeta): void {
        super.toJSONObject(object, meta);
        setNumber(object, "zoom", this.zoom);
        setNumber(object, "left", this.left);
        setNumber(object, "right", this.right);
        setNumber(object, "top", this.top);
        setNumber(object, "bottom", this.bottom);
        setNumber(object, "near", this.near);
        setNumber(object, "far", this.far);
    }

    override updateProjectionMatrix(): void {
        const dx = (this.right - this.left) / (2 * this.zoom);
        const dy = (this.top - this.bottom) / (2 * this.zoom);
        const cx = (this.right + this.left) / 2;
        const cy = (this.top + this.bottom) / 2;
        this.projectionMatrix.makeOrthographic(cx - dx, cx + dx, cy + dy, cy - dy, this.near, this.far);
        this.projectionMatrixInverse.copy(this.projectionMatrix).invert();
    }

    override copy(source: Object3D, recursive: bool = true): Object3D {
        super.copy(source, recursive);
        if (source instanceof OrthographicCamera) {
            const s = source as OrthographicCamera;
            this.left = s.left;
            this.right = s.right;
            this.top = s.top;
            this.bottom = s.bottom;
            this.near = s.near;
            this.far = s.far;
            this.zoom = s.zoom;
        }
        return this;
    }

    override clone(recursive: bool = true): Object3D {
        return new OrthographicCamera().copy(this, recursive);
    }
}
