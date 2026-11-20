// three.js examples/jsm/helpers/VertexNormalsHelper.js: a line along each
// vertex normal of a mesh, `size` long, in world space. Call `update()`
// after the mesh moved.

import { LineSegments } from "../../objects/Line";
import { BufferGeometry } from "../../core/BufferGeometry";
import { BufferAttribute } from "../../core/BufferAttribute";
import { LineBasicMaterial } from "../../materials/LineBasicMaterial";
import { Mesh } from "../../objects/Mesh";
import { Matrix3 } from "../../math/Matrix3";
import { Vector3 } from "../../math/Vector3";

const _v1 = new Vector3();
const _v2 = new Vector3();
const _normalMatrix = new Matrix3();

export class VertexNormalsHelper extends LineSegments {
    object: Mesh;
    size: f64;

    constructor(object: Mesh, size: f64 = 1, color: u32 = 0xff0000) {
        const posAttr = object.geometry.getAttribute("position");
        const normAttr = object.geometry.getAttribute("normal");
        const count = posAttr != null && normAttr != null ? min<i32>(posAttr.count, normAttr.count) : 0;
        const geometry = new BufferGeometry();
        geometry.setAttribute("position", new BufferAttribute(new Float32Array(count * 2 * 3), 3));
        super(geometry, new LineBasicMaterial({ color: color, toneMapped: false }));
        this.object = object;
        this.size = size;
        this.type = "VertexNormalsHelper";
        this.matrixAutoUpdate = false;
        this.update();
    }

    update(): void {
        this.object.updateMatrixWorld(true);
        _normalMatrix.getNormalMatrix(this.object.matrixWorld);
        const matrixWorld = this.object.matrixWorld;
        const position = this.geometry.getAttribute("position")!;
        const objPos = this.object.geometry.getAttribute("position");
        const objNorm = this.object.geometry.getAttribute("normal");
        if (objPos == null || objNorm == null) return;
        const count = min<i32>(min<i32>(objPos.count, objNorm.count), position.count / 2);
        let idx = 0;
        for (let j = 0; j < count; j++) {
            _v1.fromBufferAttribute(objPos, j).applyMatrix4(matrixWorld);
            _v2.fromBufferAttribute(objNorm, j);
            _v2.applyMatrix3(_normalMatrix).normalize().multiplyScalar(this.size).add(_v1);
            position.setXYZ(idx, _v1.x, _v1.y, _v1.z);
            idx++;
            position.setXYZ(idx, _v2.x, _v2.y, _v2.z);
            idx++;
        }
        position.needsUpdate = true;
        this.geometry.computeBoundingSphere();
    }

    dispose(): void {
        this.geometry.dispose();
        this.material.dispose();
    }
}
