// three.js OrthographicCamera. Call updateProjectionMatrix() after changing
// the frustum or zoom.

import { Camera } from "./Camera";

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

    override updateProjectionMatrix(): void {
        const dx = (this.right - this.left) / (2 * this.zoom);
        const dy = (this.top - this.bottom) / (2 * this.zoom);
        const cx = (this.right + this.left) / 2;
        const cy = (this.top + this.bottom) / 2;
        this.projectionMatrix.makeOrthographic(cx - dx, cx + dx, cy + dy, cy - dy, this.near, this.far);
        this.projectionMatrixInverse.copy(this.projectionMatrix).invert();
    }
}
