// three.js InstancedMesh: `count` copies of a mesh in one draw, each with
// its own matrix (setMatrixAt) and optional colour (setColorAt). Set
// `instanceMatrix.needsUpdate = true` (and instanceColor's) after changes.

import { Object3D } from "../core/Object3D";
import { Mesh } from "./Mesh";
import { BufferGeometry } from "../core/BufferGeometry";
import { InstancedBufferAttribute } from "../core/InstancedBufferAttribute";
import { Material } from "../materials/Material";
import { MeshBasicMaterial } from "../materials/MeshBasicMaterial";
import { Matrix4 } from "../math/Matrix4";
import { Color } from "../math/Color";
import { Box3 } from "../math/Box3";
import { Sphere } from "../math/Sphere";
import { Raycaster, Intersection } from "../core/Raycaster";
import { raycastInstancedMesh } from "./raycasting";
import { Dynamic } from "rive/dynamic";
import { JSONMeta } from "../core/JSON";

export class InstancedMesh extends Mesh {
    readonly isInstancedMesh: bool = true;
    instanceMatrix: InstancedBufferAttribute;
    instanceColor: InstancedBufferAttribute? = null;
    /// Instances drawn (at most the count given to the constructor).
    count: i32;
    /// Bounds of every instance (computeBoundingBox/Sphere), for culling.
    boundingBox: Box3? = null;
    boundingSphere: Sphere? = null;

    constructor(geometry: BufferGeometry, material: Material = new MeshBasicMaterial(), count: i32 = 1) {
        super(geometry, material);
        this.type = "InstancedMesh";
        this.count = count;
        const m = new Float32Array(count * 16);
        for (let i = 0; i < count; i++) {
            m[i * 16] = 1; m[i * 16 + 5] = 1; m[i * 16 + 10] = 1; m[i * 16 + 15] = 1;
        }
        this.instanceMatrix = new InstancedBufferAttribute(m, 16);
        this.frustumCulled = true;
    }

    override toJSONObject(object: Dynamic, meta: JSONMeta): void {
        super.toJSONObject(object, meta);
        object.set("count", Dynamic.fromNumber(<f64>this.count));
        object.set("instanceMatrix", this.instanceMatrix.toJSON());
        const color = this.instanceColor;
        if (color != null) object.set("instanceColor", color.toJSON());
    }

    getMatrixAt(index: i32, matrix: Matrix4): void {
        const a = this.instanceMatrix.array, e = matrix.elements;
        for (let k = 0; k < 16; k++) e[k] = a[index * 16 + k];
    }

    setMatrixAt(index: i32, matrix: Matrix4): void {
        const a = this.instanceMatrix.array, e = matrix.elements;
        for (let k = 0; k < 16; k++) a[index * 16 + k] = e[k];
    }

    getColorAt(index: i32, color: Color): void {
        const c = this.instanceColor;
        if (c == null) return;
        color.setRGB(c.array[index * 3], c.array[index * 3 + 1], c.array[index * 3 + 2]);
    }

    /// Creates `instanceColor` (white) on first use.
    setColorAt(index: i32, color: Color): void {
        let c = this.instanceColor;
        if (c == null) {
            const a = new Float32Array(this.instanceMatrix.count * 3);
            a.fill(1);
            c = new InstancedBufferAttribute(a, 3);
            this.instanceColor = c;
        }
        c.array[index * 3] = <f32>color.r;
        c.array[index * 3 + 1] = <f32>color.g;
        c.array[index * 3 + 2] = <f32>color.b;
    }

    computeBoundingBox(): void {
        let box = this.boundingBox;
        if (box == null) {
            box = new Box3();
            this.boundingBox = box;
        }
        const geometry = this.geometry;
        if (geometry.boundingBox == null) geometry.computeBoundingBox();
        box.makeEmpty();
        for (let i = 0; i < this.count; i++) {
            this.getMatrixAt(i, _m);
            _box.copy(geometry.boundingBox!).applyMatrix4(_m);
            box.union(_box);
        }
    }

    computeBoundingSphere(): void {
        let sphere = this.boundingSphere;
        if (sphere == null) {
            sphere = new Sphere();
            this.boundingSphere = sphere;
        }
        const geometry = this.geometry;
        if (geometry.boundingSphere == null) geometry.computeBoundingSphere();
        sphere.makeEmpty();
        for (let i = 0; i < this.count; i++) {
            this.getMatrixAt(i, _m);
            _sphere.copy(geometry.boundingSphere!).applyMatrix4(_m);
            sphere.union(_sphere);
        }
    }

    override raycast(raycaster: Raycaster, intersects: Array<Intersection>): bool {
        raycastInstancedMesh(this, raycaster, intersects);
        return true;
    }

    dispose(): void {}

    override copy(source: Object3D, recursive: bool = true): Object3D {
        super.copy(source, recursive);
        if (source instanceof InstancedMesh) {
            const s = source as InstancedMesh;
            this.instanceMatrix.copy(s.instanceMatrix);
            const ic = s.instanceColor;
            if (ic != null) this.instanceColor = ic.clone() as InstancedBufferAttribute;
            this.count = s.count;
        }
        return this;
    }

    override clone(recursive: bool = true): Object3D {
        return new InstancedMesh(this.geometry, this.material, this.count).copy(this, recursive);
    }
}

const _m: Matrix4 = new Matrix4();
const _box: Box3 = new Box3();
const _sphere: Sphere = new Sphere();
