// three.js examples/jsm/csm/CSMFrustum.js: a camera frustum's corners in
// view space, split along depth into cascades. Clip depth is [0, 1] here
// (WebGPU), so the near corners come from z = 0.

import { Vector3 } from "../../math/Vector3";
import { Matrix4 } from "../../math/Matrix4";

const _inverse = new Matrix4();

export class CSMFrustum {
    /// Corners 0 (+x +y), 1 (+x -y), 2 (-x -y), 3 (-x +y).
    near: Array<Vector3> = [new Vector3(), new Vector3(), new Vector3(), new Vector3()];
    far: Array<Vector3> = [new Vector3(), new Vector3(), new Vector3(), new Vector3()];

    setFromProjectionMatrix(projectionMatrix: Matrix4, maxFar: f64): CSMFrustum {
        const orthographic = projectionMatrix.elements[11] == 0;
        _inverse.copy(projectionMatrix).invert();
        const xs: StaticArray<f64> = [1, 1, -1, -1];
        const ys: StaticArray<f64> = [1, -1, -1, 1];
        for (let i = 0; i < 4; i++) {
            this.near[i].set(xs[i], ys[i], 0).applyMatrix4(_inverse);
            const v = this.far[i].set(xs[i], ys[i], 1).applyMatrix4(_inverse);
            const absZ = Math.abs(v.z);
            if (orthographic) v.z *= Math.min(maxFar / absZ, 1.0);
            else v.multiplyScalar(Math.min(maxFar / absZ, 1.0));
        }
        return this;
    }

    /// Splits at `breaks` (fractions of the far distance) into `target`.
    split(breaks: Array<f64>, target: Array<CSMFrustum>): void {
        while (target.length < breaks.length) target.push(new CSMFrustum());
        target.length = breaks.length;
        for (let i = 0; i < breaks.length; i++) {
            const c = target[i];
            for (let j = 0; j < 4; j++) {
                if (i == 0) c.near[j].copy(this.near[j]);
                else c.near[j].lerpVectors(this.near[j], this.far[j], breaks[i - 1]);
                if (i == breaks.length - 1) c.far[j].copy(this.far[j]);
                else c.far[j].lerpVectors(this.near[j], this.far[j], breaks[i]);
            }
        }
    }

    toSpace(cameraMatrix: Matrix4, target: CSMFrustum): void {
        for (let i = 0; i < 4; i++) {
            target.near[i].copy(this.near[i]).applyMatrix4(cameraMatrix);
            target.far[i].copy(this.far[i]).applyMatrix4(cameraMatrix);
        }
    }
}
