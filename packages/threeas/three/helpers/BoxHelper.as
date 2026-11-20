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
        else _box.makeEmpty();
        if (_box.isEmpty()) return;
        const min = _box.min, max = _box.max;
        const a = this.geometry.getAttribute("position")!;
        const p = a.array;
        const minX = <f32>min.x, minY = <f32>min.y, minZ = <f32>min.z;
        const maxX = <f32>max.x, maxY = <f32>max.y, maxZ = <f32>max.z;
        p[0] = maxX; p[1] = maxY; p[2] = maxZ;
        p[3] = minX; p[4] = maxY; p[5] = maxZ;
        p[6] = minX; p[7] = minY; p[8] = maxZ;
        p[9] = maxX; p[10] = minY; p[11] = maxZ;
        p[12] = maxX; p[13] = maxY; p[14] = minZ;
        p[15] = minX; p[16] = maxY; p[17] = minZ;
        p[18] = minX; p[19] = minY; p[20] = minZ;
        p[21] = maxX; p[22] = minY; p[23] = minZ;
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
