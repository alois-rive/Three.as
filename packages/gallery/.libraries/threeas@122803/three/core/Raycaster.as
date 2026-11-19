// three.js Raycaster: casts a ray (from a camera through a point in
// normalized device coordinates, or set by hand) and lists what it hits,
// nearest first. Visibility is ignored, as three.js; layers are tested.

import { Ray } from "../math/Ray";
import { Vector2 } from "../math/Vector2";
import { Vector3 } from "../math/Vector3";
import { Layers } from "./Layers";
import { Object3D } from "./Object3D";
import { Camera } from "../cameras/Camera";
import { PerspectiveCamera } from "../cameras/PerspectiveCamera";
import { OrthographicCamera } from "../cameras/OrthographicCamera";

export class Face {
    a: i32;
    b: i32;
    c: i32;
    normal: Vector3 = new Vector3();
    materialIndex: i32 = 0;

    constructor(a: i32, b: i32, c: i32) {
        this.a = a;
        this.b = b;
        this.c = c;
    }
}

/// One hit. Fields three.js leaves undefined are null, or -1 for numbers.
export class Intersection {
    distance: f64;
    point: Vector3;
    object: Object3D;
    /// Points: the distance from the ray to the point.
    distanceToRay: f64 = -1;
    face: Face? = null;
    faceIndex: i32 = -1;
    /// Lines and points: the vertex (or segment start) index.
    index: i32 = -1;
    /// The interpolated "uv" at the hit (meshes, sprites).
    uv: Vector2? = null;
    /// The interpolated "normal" at the hit, facing the ray (object space).
    normal: Vector3? = null;
    barycoord: Vector3? = null;
    /// InstancedMesh: which instance.
    instanceId: i32 = -1;
    /// BatchedMesh: the instance hit.
    batchId: i32 = -1;

    constructor(distance: f64, point: Vector3, object: Object3D) {
        this.distance = distance;
        this.point = point;
        this.object = object;
    }
}

export class LineRaycastParams {
    threshold: f64 = 1;
}

export class PointsRaycastParams {
    threshold: f64 = 1;
}

export class RaycasterParameters {
    Line: LineRaycastParams = new LineRaycastParams();
    Points: PointsRaycastParams = new PointsRaycastParams();
}

export class Raycaster {
    ray: Ray;
    near: f64;
    far: f64;
    /// Set by setFromCamera; sprites need it.
    camera: Camera? = null;
    layers: Layers = new Layers();
    params: RaycasterParameters = new RaycasterParameters();

    constructor(origin: Vector3 = new Vector3(), direction: Vector3 = new Vector3(0, 0, -1), near: f64 = 0,
                far: f64 = Infinity) {
        this.ray = new Ray(origin, direction);
        this.near = near;
        this.far = far;
    }

    set(origin: Vector3, direction: Vector3): void {
        this.ray.set(origin, direction);
    }

    /// A ray from `camera` through `coords` (x and y in [-1, 1], y up).
    setFromCamera(coords: Vector2, camera: Camera): void {
        camera.updateMatrixWorld();
        if (camera instanceof PerspectiveCamera) {
            this.ray.origin.setFromMatrixPosition(camera.matrixWorld);
            this.ray.direction.set(coords.x, coords.y, 0.5).unproject(camera).sub(this.ray.origin).normalize();
        } else if (camera instanceof OrthographicCamera) {
            // On the near plane (depth 0 in [0, 1] clip space).
            this.ray.origin.set(coords.x, coords.y, 0).unproject(camera);
            this.ray.direction.set(0, 0, -1).transformDirection(camera.matrixWorld);
        }
        this.camera = camera;
    }

    intersectObject(object: Object3D, recursive: bool = true, intersects: Array<Intersection> = []): Array<Intersection> {
        intersect(object, this, intersects, recursive);
        intersects.sort(ascSort);
        return intersects;
    }

    intersectObjects(objects: Array<Object3D>, recursive: bool = true,
                     intersects: Array<Intersection> = []): Array<Intersection> {
        for (let i = 0; i < objects.length; i++) intersect(objects[i], this, intersects, recursive);
        intersects.sort(ascSort);
        return intersects;
    }
}

function ascSort(a: Intersection, b: Intersection): i32 {
    return a.distance < b.distance ? -1 : a.distance > b.distance ? 1 : 0;
}

function intersect(object: Object3D, raycaster: Raycaster, intersects: Array<Intersection>, recursive: bool): void {
    let propagate = true;
    if (object.layers.test(raycaster.layers)) propagate = object.raycast(raycaster, intersects);
    if (propagate && recursive) {
        const children = object.children;
        for (let i = 0; i < children.length; i++) intersect(children[i], raycaster, intersects, true);
    }
}
