// three.js Camera: looks down its -Z. Projections map depth to [0, 1]
// (WebGPU), as three.js with WebGPUCoordinateSystem.

import { Object3D } from "../core/Object3D";
import { Matrix4 } from "../math/Matrix4";

export class Camera extends Object3D {
    readonly isCamera: bool = true;
    /// The inverse of matrixWorld (the view matrix).
    matrixWorldInverse: Matrix4 = new Matrix4();
    projectionMatrix: Matrix4 = new Matrix4();
    projectionMatrixInverse: Matrix4 = new Matrix4();

    constructor() {
        super();
        this.type = "Camera";
    }

    override facesNegativeZ(): bool { return true; }

    override updateMatrixWorld(force: bool = false): void {
        super.updateMatrixWorld(force);
        this.matrixWorldInverse.copy(this.matrixWorld).invert();
    }

    override updateWorldMatrix(updateParents: bool, updateChildren: bool): void {
        super.updateWorldMatrix(updateParents, updateChildren);
        this.matrixWorldInverse.copy(this.matrixWorld).invert();
    }

    /// Recomputes projectionMatrix after a parameter changed.
    updateProjectionMatrix(): void {}
}
