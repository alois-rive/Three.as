// three.js StereoCamera: a left and a right eye camera (off-axis
// projections, http://paulbourke.net/stereographics/stereorender/) that
// follow a PerspectiveCamera. Call `update(camera)` each frame, then render
// `cameraL` and `cameraR` into the two halves of the view (setViewport,
// setScissor), as three.js's StereoEffect.

import { Matrix4 } from "../math/Matrix4";
import { DEG2RAD } from "../math/MathUtils";
import { PerspectiveCamera } from "./PerspectiveCamera";

const _eyeRight = new Matrix4();
const _eyeLeft = new Matrix4();
const _projectionMatrix = new Matrix4();

export class StereoCamera {
    readonly type: string = "StereoCamera";
    /// Multiplies the followed camera's aspect (0.5 for side by side halves
    /// of a camera whose aspect is the whole view's).
    aspect: f64 = 1;
    /// Distance between the eyes, in world units.
    eyeSep: f64 = 0.064;
    cameraL: PerspectiveCamera = new PerspectiveCamera();
    cameraR: PerspectiveCamera = new PerspectiveCamera();

    private cacheFocus: f64 = NaN;
    private cacheFov: f64 = NaN;
    private cacheAspect: f64 = NaN;
    private cacheNear: f64 = NaN;
    private cacheFar: f64 = NaN;
    private cacheZoom: f64 = NaN;
    private cacheEyeSep: f64 = NaN;

    constructor() {
        this.cameraL.layers.enable(1);
        this.cameraL.matrixAutoUpdate = false;
        this.cameraR.layers.enable(2);
        this.cameraR.matrixAutoUpdate = false;
    }

    update(camera: PerspectiveCamera): void {
        const needsUpdate = this.cacheFocus != camera.focus || this.cacheFov != camera.fov
            || this.cacheAspect != camera.aspect * this.aspect || this.cacheNear != camera.near
            || this.cacheFar != camera.far || this.cacheZoom != camera.zoom || this.cacheEyeSep != this.eyeSep;
        if (needsUpdate) {
            this.cacheFocus = camera.focus;
            this.cacheFov = camera.fov;
            this.cacheAspect = camera.aspect * this.aspect;
            this.cacheNear = camera.near;
            this.cacheFar = camera.far;
            this.cacheZoom = camera.zoom;
            this.cacheEyeSep = this.eyeSep;

            _projectionMatrix.copy(camera.projectionMatrix);
            const eyeSepHalf = this.cacheEyeSep / 2;
            const eyeSepOnProjection = eyeSepHalf * this.cacheNear / this.cacheFocus;
            const ymax = (this.cacheNear * Math.tan(DEG2RAD * this.cacheFov * 0.5)) / this.cacheZoom;
            const e = _projectionMatrix.elements;

            _eyeLeft.elements[12] = <f32>-eyeSepHalf;
            _eyeRight.elements[12] = <f32>eyeSepHalf;

            // Left eye.
            let xmin = -ymax * this.cacheAspect + eyeSepOnProjection;
            let xmax = ymax * this.cacheAspect + eyeSepOnProjection;
            e[0] = <f32>(2 * this.cacheNear / (xmax - xmin));
            e[8] = <f32>((xmax + xmin) / (xmax - xmin));
            this.cameraL.projectionMatrix.copy(_projectionMatrix);
            this.cameraL.projectionMatrixInverse.copy(_projectionMatrix).invert();

            // Right eye.
            xmin = -ymax * this.cacheAspect - eyeSepOnProjection;
            xmax = ymax * this.cacheAspect - eyeSepOnProjection;
            e[0] = <f32>(2 * this.cacheNear / (xmax - xmin));
            e[8] = <f32>((xmax + xmin) / (xmax - xmin));
            this.cameraR.projectionMatrix.copy(_projectionMatrix);
            this.cameraR.projectionMatrixInverse.copy(_projectionMatrix).invert();
        }
        camera.updateMatrixWorld();
        this.cameraL.matrixWorld.copy(camera.matrixWorld).multiply(_eyeLeft);
        this.cameraR.matrixWorld.copy(camera.matrixWorld).multiply(_eyeRight);
        this.cameraL.matrixWorldInverse.copy(this.cameraL.matrixWorld).invert();
        this.cameraR.matrixWorldInverse.copy(this.cameraR.matrixWorld).invert();
    }
}
