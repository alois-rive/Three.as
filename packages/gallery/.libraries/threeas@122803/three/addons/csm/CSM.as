// three.js examples/jsm/csm/CSM.js: cascaded shadow maps for a sun. One
// DirectionalLight per cascade, each with a shadow camera fitted (and
// texel-snapped) to its slice of the camera frustum every `update()`.
// three.js injects shader code so each fragment uses its cascade; here
// each cascade light carries its view depth range (DirectionalLight
// cascadeNear / cascadeFar) and the renderer lights a fragment only with
// the cascade covering it, so `setupMaterial` does nothing. `fade` is not
// supported (cascades switch hard).
//
//     const csm = new CSM({ camera: camera, parent: scene, cascades: 4, maxFar: 60 });
//     // each frame:
//     csm.update();

import { Object3D } from "../../core/Object3D";
import { Camera } from "../../cameras/Camera";
import { PerspectiveCamera } from "../../cameras/PerspectiveCamera";
import { OrthographicCamera } from "../../cameras/OrthographicCamera";
import { DirectionalLight } from "../../lights/DirectionalLight";
import { Vector3 } from "../../math/Vector3";
import { Matrix4 } from "../../math/Matrix4";
import { Box3 } from "../../math/Box3";
import { Material } from "../../materials/Material";
import { CSMFrustum } from "./CSMFrustum";

export class CSMParameters {
    camera: Camera? = null;
    parent: Object3D? = null;
    cascades: i32 = 3;
    maxFar: f64 = 100000;
    /// "practical", "uniform" or "logarithmic".
    mode: string = "practical";
    shadowMapSize: i32 = 2048;
    shadowBias: f64 = 0.000001;
    lightDirection: Vector3 = new Vector3(1, -1, 1).normalize();
    lightIntensity: f64 = 3;
    lightNear: f64 = 1;
    lightFar: f64 = 2000;
    lightMargin: f64 = 200;
}

const _up = new Vector3(0, 1, 0);
const _origin = new Vector3();
const _lightOrientation = new Matrix4();
const _lightOrientationInverse = new Matrix4();
const _cameraToLight = new Matrix4();
const _lightSpaceFrustum = new CSMFrustum();
const _center = new Vector3();
const _bbox = new Box3();

export class CSM {
    camera: Camera;
    parent: Object3D;
    cascades: i32;
    maxFar: f64;
    mode: string;
    shadowMapSize: i32;
    shadowBias: f64;
    lightDirection: Vector3;
    lightIntensity: f64;
    lightNear: f64;
    lightFar: f64;
    lightMargin: f64;
    fade: bool = false;
    mainFrustum: CSMFrustum = new CSMFrustum();
    frustums: Array<CSMFrustum> = [];
    breaks: Array<f64> = [];
    lights: Array<DirectionalLight> = [];

    constructor(data: CSMParameters) {
        this.camera = data.camera!;
        this.parent = data.parent!;
        this.cascades = data.cascades;
        this.maxFar = data.maxFar;
        this.mode = data.mode;
        this.shadowMapSize = data.shadowMapSize;
        this.shadowBias = data.shadowBias;
        this.lightDirection = data.lightDirection.clone();
        this.lightIntensity = data.lightIntensity;
        this.lightNear = data.lightNear;
        this.lightFar = data.lightFar;
        this.lightMargin = data.lightMargin;
        this.createLights();
        this.updateFrustums();
    }

    private createLights(): void {
        for (let i = 0; i < this.cascades; i++) {
            const light = new DirectionalLight(0xffffff, this.lightIntensity);
            light.castShadow = true;
            light.shadow.mapSize.set(<f64>this.shadowMapSize, <f64>this.shadowMapSize);
            const cam = light.shadow.camera as OrthographicCamera;
            cam.near = this.lightNear;
            cam.far = this.lightFar;
            light.shadow.bias = this.shadowBias;
            this.parent.add(light);
            this.parent.add(light.target);
            this.lights.push(light);
        }
    }

    private far(): f64 {
        const cam = this.camera;
        let far = this.maxFar;
        if (cam instanceof PerspectiveCamera) far = Math.min((cam as PerspectiveCamera).far, this.maxFar);
        else if (cam instanceof OrthographicCamera) far = Math.min((cam as OrthographicCamera).far, this.maxFar);
        return far;
    }

    private near(): f64 {
        const cam = this.camera;
        if (cam instanceof PerspectiveCamera) return (cam as PerspectiveCamera).near;
        if (cam instanceof OrthographicCamera) return (cam as OrthographicCamera).near;
        return 0.1;
    }

    /// Recomputes the splits and cascade frustums (after the camera's
    /// projection, `cascades`, `mode` or `maxFar` changed).
    updateFrustums(): void {
        this.getBreaks();
        this.initCascades();
        this.updateShadowBounds();
        this.updateCascadeRanges();
    }

    private initCascades(): void {
        this.mainFrustum.setFromProjectionMatrix(this.camera.projectionMatrix, this.maxFar);
        this.mainFrustum.split(this.breaks, this.frustums);
    }

    private updateShadowBounds(): void {
        for (let i = 0; i < this.frustums.length && i < this.lights.length; i++) {
            const cam = this.lights[i].shadow.camera as OrthographicCamera;
            const f = this.frustums[i];
            // The longest diagonal: across the far plane or the whole slice.
            const p1 = f.far[0];
            const p2 = p1.distanceTo(f.far[2]) > p1.distanceTo(f.near[2]) ? f.far[2] : f.near[2];
            const width = p1.distanceTo(p2);
            cam.left = -width / 2;
            cam.right = width / 2;
            cam.top = width / 2;
            cam.bottom = -width / 2;
            cam.updateProjectionMatrix();
        }
    }

    private updateCascadeRanges(): void {
        const far = this.far();
        for (let i = 0; i < this.lights.length; i++) {
            const prev = i == 0 ? 0 : this.breaks[i - 1];
            const next = i < this.breaks.length ? this.breaks[i] : 1;
            this.lights[i].cascadeNear = i == 0 ? 0 : prev * far;
            this.lights[i].cascadeFar = i == this.lights.length - 1 ? 1e30 : next * far;
        }
    }

    private getBreaks(): void {
        const near = this.near(), far = this.far();
        const amount = this.cascades;
        const breaks = this.breaks;
        breaks.length = 0;
        if (this.mode == "uniform") uniformSplit(amount, near, far, breaks);
        else if (this.mode == "logarithmic") logarithmicSplit(amount, near, far, breaks);
        else {
            const u: Array<f64> = [], l: Array<f64> = [];
            logarithmicSplit(amount, near, far, l);
            uniformSplit(amount, near, far, u);
            for (let i = 1; i < amount; i++) breaks.push(u[i - 1] + (l[i - 1] - u[i - 1]) * 0.5);
            breaks.push(1);
        }
    }

    /// Fits every cascade's shadow camera to its frustum slice (call each
    /// frame, after the camera moved).
    update(): void {
        this.camera.updateMatrixWorld();
        _lightOrientation.lookAt(_origin, this.lightDirection, _up);
        _lightOrientationInverse.copy(_lightOrientation).invert();
        for (let i = 0; i < this.frustums.length && i < this.lights.length; i++) {
            const light = this.lights[i];
            const cam = light.shadow.camera as OrthographicCamera;
            const texelWidth = (cam.right - cam.left) / <f64>this.shadowMapSize;
            const texelHeight = (cam.top - cam.bottom) / <f64>this.shadowMapSize;
            _cameraToLight.multiplyMatrices(_lightOrientationInverse, this.camera.matrixWorld);
            this.frustums[i].toSpace(_cameraToLight, _lightSpaceFrustum);
            _bbox.makeEmpty();
            for (let j = 0; j < 4; j++) {
                _bbox.expandByPoint(_lightSpaceFrustum.near[j]);
                _bbox.expandByPoint(_lightSpaceFrustum.far[j]);
            }
            _bbox.getCenter(_center);
            _center.z = _bbox.max.z + this.lightMargin;
            _center.x = Math.floor(_center.x / texelWidth) * texelWidth;
            _center.y = Math.floor(_center.y / texelHeight) * texelHeight;
            _center.applyMatrix4(_lightOrientation);
            light.position.copy(_center);
            light.target.position.copy(_center).add(this.lightDirection);
        }
    }

    /// three.js injects cascade selection here; the renderer does it.
    setupMaterial(material: Material): void {}

    remove(): void {
        for (let i = 0; i < this.lights.length; i++) {
            this.parent.remove(this.lights[i].target);
            this.parent.remove(this.lights[i]);
        }
    }

    dispose(): void {
        this.remove();
    }
}

function uniformSplit(amount: i32, near: f64, far: f64, target: Array<f64>): void {
    for (let i = 1; i < amount; i++) target.push((near + (far - near) * <f64>i / <f64>amount) / far);
    target.push(1);
}

function logarithmicSplit(amount: i32, near: f64, far: f64, target: Array<f64>): void {
    for (let i = 1; i < amount; i++) target.push((near * Math.pow(far / near, <f64>i / <f64>amount)) / far);
    target.push(1);
}
