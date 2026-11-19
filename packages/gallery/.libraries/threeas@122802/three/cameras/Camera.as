// three.js Camera: looks down its -Z. Projections map depth to [0, 1]
// (WebGPU), as three.js with WebGPUCoordinateSystem.

import { Object3D } from "../core/Object3D";
import { Matrix4 } from "../math/Matrix4";
import { Vector4 } from "../math/Vector4";

/// A camera's view offset (setViewOffset): a sub-rectangle of a larger
/// view, for multi-monitor setups and jittered (TAA / SSAA) renders.
export class CameraView {
    enabled: bool = true;
    fullWidth: f64 = 1;
    fullHeight: f64 = 1;
    offsetX: f64 = 0;
    offsetY: f64 = 0;
    width: f64 = 1;
    height: f64 = 1;

    copy(source: CameraView): CameraView {
        this.enabled = source.enabled;
        this.fullWidth = source.fullWidth;
        this.fullHeight = source.fullHeight;
        this.offsetX = source.offsetX;
        this.offsetY = source.offsetY;
        this.width = source.width;
        this.height = source.height;
        return this;
    }
}

export class Camera extends Object3D {
    readonly isCamera: bool = true;
    /// The inverse of matrixWorld (the view matrix).
    matrixWorldInverse: Matrix4 = new Matrix4();
    projectionMatrix: Matrix4 = new Matrix4();
    projectionMatrixInverse: Matrix4 = new Matrix4();
    /// The view offset of PerspectiveCamera / OrthographicCamera
    /// (setViewOffset), or null.
    view: CameraView? = null;
    /// An ArrayCamera sub-camera's viewport, in drawing-buffer pixels from
    /// the bottom left (x, y, width, height), or null.
    viewport: Vector4? = null;

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

    /// Renders only the sub-rectangle (x, y, width, height) of a
    /// fullWidth x fullHeight view (y from the top), as three.js.
    setViewOffset(fullWidth: f64, fullHeight: f64, x: f64, y: f64, width: f64, height: f64): void {
        let v = this.view;
        if (v == null) {
            v = new CameraView();
            this.view = v;
        }
        v.enabled = true;
        v.fullWidth = fullWidth;
        v.fullHeight = fullHeight;
        v.offsetX = x;
        v.offsetY = y;
        v.width = width;
        v.height = height;
        this.updateProjectionMatrix();
    }

    clearViewOffset(): void {
        const v = this.view;
        if (v != null) v.enabled = false;
        this.updateProjectionMatrix();
    }

    override copy(source: Object3D, recursive: bool = true): Object3D {
        super.copy(source, recursive);
        if (source instanceof Camera) {
            const s = source as Camera;
            this.matrixWorldInverse.copy(s.matrixWorldInverse);
            this.projectionMatrix.copy(s.projectionMatrix);
            this.projectionMatrixInverse.copy(s.projectionMatrixInverse);
            const v = s.view;
            this.view = v != null ? new CameraView().copy(v!) : null;
            const vp = s.viewport;
            this.viewport = vp != null ? vp!.clone() : null;
        }
        return this;
    }

    override clone(recursive: bool = true): Object3D {
        return new Camera().copy(this, recursive);
    }
}
