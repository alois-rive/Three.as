// three.js BoxHelper: the world-axis-aligned box around an object; call
// `update()` after the object moved or deformed.

import { LineSegments } from "../objects/Line";
import { BufferGeometry } from "../core/BufferGeometry";
import { BufferAttribute } from "../core/BufferAttribute";
import { LineBasicMaterial } from "../materials/LineBasicMaterial";
import { Object3D } from "../core/Object3D";
import { Box3 } from "../math/Box3";

const _box = new Box3();

export class BoxHelper extends LineSegments {
    object: Object3D?;

    constructor(object: Object3D? = null, color: u32 = 0xffff00) {
        const geometry = new BufferGeometry();
        geometry.setIndex([0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7]);
        geometry.setAttribute("position", new BufferAttribute(new Float32Array(8 * 3), 3));
        super(geometry, new LineBasicMaterial({ color: color, toneMapped: false }));
        this.object = object;
        this.type = "BoxHelper";
        this.matrixAutoUpdate = false;
        this.update();
    }

    update(): void {
        const object = this.object;
        if (object != null) _box.setFromObject(object);
        if (_box.isEmpty()) return;
        const min = _box.min, max = _box.max;
        const a = this.geometry.getAttribute("position")!;
        const p = a.array;
        const xs: StaticArray<f64> = [max.x, min.x, min.x, max.x, max.x, min.x, min.x, max.x];
        const ys: StaticArray<f64> = [max.y, max.y, min.y, min.y, max.y, max.y, min.y, min.y];
        const zs: StaticArray<f64> = [max.z, max.z, max.z, max.z, min.z, min.z, min.z, min.z];
        for (let i = 0; i < 8; i++) {
            p[i * 3] = <f32>xs[i]; p[i * 3 + 1] = <f32>ys[i]; p[i * 3 + 2] = <f32>zs[i];
        }
        a.needsUpdate = true;
        this.geometry.computeBoundingSphere();
    }

    setFromObject(object: Object3D): BoxHelper {
        this.object = object;
        this.update();
        return this;
    }

    dispose(): void {
        this.geometry.dispose();
        this.material.dispose();
    }
}
