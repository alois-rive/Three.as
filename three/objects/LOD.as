// three.js LOD: shows one of its levels by distance to the camera. The
// renderer calls update(camera) each frame while autoUpdate.

import { Object3D } from "../core/Object3D";
import { Camera } from "../cameras/Camera";
import { PerspectiveCamera } from "../cameras/PerspectiveCamera";
import { Vector3 } from "../math/Vector3";

export class LODLevel {
    object: Object3D;
    distance: f64;
    hysteresis: f64;

    constructor(object: Object3D, distance: f64, hysteresis: f64) {
        this.object = object;
        this.distance = distance;
        this.hysteresis = hysteresis;
    }
}

export class LOD extends Object3D {
    readonly isLOD: bool = true;
    levels: Array<LODLevel> = [];
    autoUpdate: bool = true;
    private currentLevel: i32 = 0;

    constructor() {
        super();
        this.type = "LOD";
    }

    /// Shows `object` from `distance` on (levels sort by distance).
    addLevel(object: Object3D, distance: f64 = 0, hysteresis: f64 = 0): LOD {
        distance = Math.abs(distance);
        let l = 0;
        while (l < this.levels.length && distance >= this.levels[l].distance) l++;
        // Insert at l (AnimaScript's splice does not insert).
        const levels = this.levels;
        levels.push(new LODLevel(object, distance, hysteresis));
        for (let i = levels.length - 1; i > l; i--) {
            const t = levels[i];
            levels[i] = levels[i - 1];
            levels[i - 1] = t;
        }
        this.add(object);
        return this;
    }

    removeLevel(distance: f64): bool {
        for (let i = 0; i < this.levels.length; i++) {
            if (this.levels[i].distance == distance) {
                this.remove(this.levels[i].object);
                this.levels.splice(i, 1);
                return true;
            }
        }
        return false;
    }

    getCurrentLevel(): i32 { return this.currentLevel; }

    getObjectForDistance(distance: f64): Object3D? {
        const levels = this.levels;
        if (levels.length == 0) return null;
        let i = 1;
        for (; i < levels.length; i++) {
            let d = levels[i].distance;
            if (levels[i].object.visible) d -= d * levels[i].hysteresis;
            if (distance < d) break;
        }
        return levels[i - 1].object;
    }

    update(camera: Camera): void {
        const levels = this.levels;
        if (levels.length < 2) return;
        _v1.setFromMatrixPosition(camera.matrixWorld);
        _v2.setFromMatrixPosition(this.matrixWorld);
        let distance = _v1.distanceTo(_v2);
        if (camera instanceof PerspectiveCamera) distance /= (camera as PerspectiveCamera).zoom;
        levels[0].object.visible = true;
        let i = 1;
        for (; i < levels.length; i++) {
            let d = levels[i].distance;
            if (levels[i].object.visible) d -= d * levels[i].hysteresis;
            if (distance >= d) {
                levels[i - 1].object.visible = false;
                levels[i].object.visible = true;
            } else {
                break;
            }
        }
        this.currentLevel = i - 1;
        for (; i < levels.length; i++) levels[i].object.visible = false;
    }

    /// three.js's LOD.copy: the levels' objects cloned (not the children
    /// twice).
    override copy(source: Object3D, recursive: bool = true): Object3D {
        super.copy(source, false);
        if (source instanceof LOD) {
            const s = source as LOD;
            for (let i = 0; i < s.levels.length; i++) {
                const l = s.levels[i];
                this.addLevel(l.object.clone(true), l.distance, l.hysteresis);
            }
            this.autoUpdate = s.autoUpdate;
        }
        return this;
    }

    override clone(recursive: bool = true): Object3D {
        return new LOD().copy(this, recursive);
    }
}

const _v1: Vector3 = new Vector3();
const _v2: Vector3 = new Vector3();
