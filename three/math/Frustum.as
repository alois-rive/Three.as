// three.js Frustum: six planes, normals pointing inwards. Built from a
// [0, 1]-depth projection (three.js's WebGPUCoordinateSystem).

import { Plane } from "./Plane";
import { Vector3 } from "./Vector3";
import { Matrix4 } from "./Matrix4";
import { Sphere } from "./Sphere";
import { Box3 } from "./Box3";
import { Object3D } from "../core/Object3D";
import { geometryOf } from "../core/geometryOf";

export class Frustum {
    planes: Array<Plane>;

    constructor(p0: Plane = new Plane(), p1: Plane = new Plane(), p2: Plane = new Plane(),
                p3: Plane = new Plane(), p4: Plane = new Plane(), p5: Plane = new Plane()) {
        this.planes = [p0, p1, p2, p3, p4, p5];
    }

    set(p0: Plane, p1: Plane, p2: Plane, p3: Plane, p4: Plane, p5: Plane): Frustum {
        const planes = this.planes;
        planes[0].copy(p0); planes[1].copy(p1); planes[2].copy(p2);
        planes[3].copy(p3); planes[4].copy(p4); planes[5].copy(p5);
        return this;
    }

    copy(frustum: Frustum): Frustum {
        for (let i = 0; i < 6; i++) this.planes[i].copy(frustum.planes[i]);
        return this;
    }

    clone(): Frustum { return new Frustum().copy(this); }

    /// From a view-projection matrix (projection * matrixWorldInverse).
    setFromProjectionMatrix(m: Matrix4): Frustum {
        const planes = this.planes;
        const me = m.elements;
        const me0: f64 = me[0], me1: f64 = me[1], me2: f64 = me[2], me3: f64 = me[3];
        const me4: f64 = me[4], me5: f64 = me[5], me6: f64 = me[6], me7: f64 = me[7];
        const me8: f64 = me[8], me9: f64 = me[9], me10: f64 = me[10], me11: f64 = me[11];
        const me12: f64 = me[12], me13: f64 = me[13], me14: f64 = me[14], me15: f64 = me[15];
        planes[0].setComponents(me3 - me0, me7 - me4, me11 - me8, me15 - me12).normalize();
        planes[1].setComponents(me3 + me0, me7 + me4, me11 + me8, me15 + me12).normalize();
        planes[2].setComponents(me3 + me1, me7 + me5, me11 + me9, me15 + me13).normalize();
        planes[3].setComponents(me3 - me1, me7 - me5, me11 - me9, me15 - me13).normalize();
        planes[4].setComponents(me3 - me2, me7 - me6, me11 - me10, me15 - me14).normalize();
        planes[5].setComponents(me2, me6, me10, me14).normalize();
        return this;
    }

    /// Whether the object's geometry bounding sphere (world space) is in
    /// the frustum. Objects without geometry intersect.
    intersectsObject(object: Object3D): bool {
        const geometry = geometryOf(object);
        if (geometry == null) return true;
        if (geometry.boundingSphere == null) geometry.computeBoundingSphere();
        _sphere.copy(geometry.boundingSphere!).applyMatrix4(object.matrixWorld);
        return this.intersectsSphere(_sphere);
    }

    intersectsSphere(sphere: Sphere): bool {
        const negRadius = -sphere.radius;
        for (let i = 0; i < 6; i++) {
            if (this.planes[i].distanceToPoint(sphere.center) < negRadius) return false;
        }
        return true;
    }

    intersectsBox(box: Box3): bool {
        for (let i = 0; i < 6; i++) {
            const plane = this.planes[i];
            _vector.x = plane.normal.x > 0 ? box.max.x : box.min.x;
            _vector.y = plane.normal.y > 0 ? box.max.y : box.min.y;
            _vector.z = plane.normal.z > 0 ? box.max.z : box.min.z;
            if (plane.distanceToPoint(_vector) < 0) return false;
        }
        return true;
    }

    containsPoint(point: Vector3): bool {
        for (let i = 0; i < 6; i++) {
            if (this.planes[i].distanceToPoint(point) < 0) return false;
        }
        return true;
    }
}

const _sphere: Sphere = new Sphere();
const _vector: Vector3 = new Vector3();
