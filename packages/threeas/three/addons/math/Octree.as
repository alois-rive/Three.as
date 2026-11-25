// three.js examples/jsm/math/Octree.js: an octree of world triangles, for
// collisions in games (games_fps): spheres, capsules and boxes pushed out
// of the world, rays cast into it.
//
//     const octree = new Octree().fromGraphNode(scene);
//     const result = octree.capsuleIntersect(playerCollider);
//     if (result != null) playerCollider.translate(result.normal.multiplyScalar(result.depth));
//
// A node splits into eight while it holds more than `trianglesPerLeaf`
// triangles, down to `maxLevel` levels; a triangle is in every leaf its
// box touches. three.js's `{ normal, point, depth }` and `{ distance,
// triangle, position }` objects (or false) are OctreeCollision,
// OctreeTriangleCollision and OctreeRayHit (or null).

import { Vector3 } from "../../math/Vector3";
import { Box3 } from "../../math/Box3";
import { Line3 } from "../../math/Line3";
import { Plane } from "../../math/Plane";
import { Sphere } from "../../math/Sphere";
import { Triangle } from "../../math/Triangle";
import { Ray } from "../../math/Ray";
import { Layers } from "../../core/Layers";
import { Object3D } from "../../core/Object3D";
import { Mesh } from "../../objects/Mesh";
import { Capsule } from "./Capsule";

const _v1 = new Vector3();
const _v2 = new Vector3();
const _point1 = new Vector3();
const _point2 = new Vector3();
const _plane = new Plane();
const _line1 = new Line3();
const _line2 = new Line3();
const _box = new Box3();
const _sphere = new Sphere();
const _capsule = new Capsule();
const _center = new Vector3();

const _temp1 = new Vector3();
const _temp2 = new Vector3();
const _temp3 = new Vector3();
const _triangles: Array<Triangle> = [];
const _seen: Set<Triangle> = new Set<Triangle>();
const _triNormal = new Vector3();
const _bestPos = new Vector3();
const EPS: f64 = 1e-10;

/// The closest points of two segments, in `target1` (on `line1`) and
/// `target2` (on `line2`), either null to skip it.
function lineToLineClosestPoints(line1: Line3, line2: Line3, target1: Vector3? = null, target2: Vector3? = null): void {
    const r = _temp1.copy(line1.end).sub(line1.start);
    const s = _temp2.copy(line2.end).sub(line2.start);
    const w = _temp3.copy(line2.start).sub(line1.start);

    const a = r.dot(s),
        b = r.dot(r),
        c = s.dot(s),
        d = s.dot(w),
        e = r.dot(w);

    let t1: f64, t2: f64;
    const divisor = b * c - a * a;

    if (Math.abs(divisor) < EPS) {
        const d1 = -d / c;
        const d2 = (a - d) / c;

        t1 = (Math.abs(d1 - 0.5) < Math.abs(d2 - 0.5)) ? 0 : 1;
    } else {
        t1 = (e * c - d * a) / divisor;
    }

    // clamp to the segments. if the closest point on the second segment has
    // to be clamped, the one on the first segment must be recomputed

    t1 = Math.max(0, Math.min(1, t1));
    t2 = (t1 * a - d) / c;

    if (t2 < 0 || t2 > 1) {
        t2 = Math.max(0, Math.min(1, t2));

        if (b > EPS) t1 = Math.max(0, Math.min(1, (t2 * a + e) / b));
    }

    if (target1 != null) {
        target1.copy(r).multiplyScalar(t1).add(line1.start);
    }

    if (target2 != null) {
        target2.copy(s).multiplyScalar(t2).add(line2.start);
    }
}

function max3(a: f64, b: f64, c: f64): f64 { return Math.max(a, Math.max(b, c)); }
function min3(a: f64, b: f64, c: f64): f64 { return Math.min(a, Math.min(b, c)); }

/// What sphereIntersect, capsuleIntersect and boxIntersect return (three.js's
/// `{ normal, depth }`): move the collider by `normal * depth` to resolve it.
export class OctreeCollision {
    normal: Vector3;
    depth: f64;

    constructor(normal: Vector3, depth: f64) {
        this.normal = normal;
        this.depth = depth;
    }
}

/// What triangleCapsuleIntersect, triangleSphereIntersect and
/// triangleBoxIntersect return (three.js's `{ normal, point, depth }`).
export class OctreeTriangleCollision extends OctreeCollision {
    point: Vector3;

    constructor(normal: Vector3, point: Vector3, depth: f64) {
        super(normal, depth);
        this.point = point;
    }
}

/// What rayIntersect returns (three.js's `{ distance, triangle, position }`).
export class OctreeRayHit {
    distance: f64;
    triangle: Triangle;
    position: Vector3;

    constructor(distance: f64, triangle: Triangle, position: Vector3) {
        this.distance = distance;
        this.triangle = triangle;
        this.position = position;
    }
}

export class Octree {
    /// The base box that encloses the entire Octree (null until built, and
    /// after `clear()`).
    box: Box3?;
    /// The bounds of the Octree. Compared to `box`, no margin is applied.
    bounds: Box3 = new Box3();
    /// Can be used for layers configuration for refine testing
    /// (`fromGraphNode` takes the meshes it shares a layer with).
    layers: Layers = new Layers();
    /// The number of triangles a leaf can store before it is split.
    trianglesPerLeaf: i32 = 8;
    /// The maximum level of the Octree: its maximum hierarchical depth.
    maxLevel: i32 = 16;

    subTrees: Array<Octree> = [];
    triangles: Array<Triangle> = [];

    constructor(box: Box3? = null) {
        this.box = box;
    }

    /// Adds `triangle` (kept, not copied) and grows `bounds` around it.
    addTriangle(triangle: Triangle): Octree {
        const b = this.bounds;
        b.min.x = Math.min(b.min.x, min3(triangle.a.x, triangle.b.x, triangle.c.x));
        b.min.y = Math.min(b.min.y, min3(triangle.a.y, triangle.b.y, triangle.c.y));
        b.min.z = Math.min(b.min.z, min3(triangle.a.z, triangle.b.z, triangle.c.z));
        b.max.x = Math.max(b.max.x, max3(triangle.a.x, triangle.b.x, triangle.c.x));
        b.max.y = Math.max(b.max.y, max3(triangle.a.y, triangle.b.y, triangle.c.y));
        b.max.z = Math.max(b.max.z, max3(triangle.a.z, triangle.b.z, triangle.c.z));

        this.triangles.push(triangle);

        return this;
    }

    /// Prepares `box` for the build.
    calcBox(): Octree {
        const box = this.bounds.clone();

        // offset small amount to account for regular grid
        box.min.x -= 0.01;
        box.min.y -= 0.01;
        box.min.z -= 0.01;

        this.box = box;
        return this;
    }

    /// Splits the Octree; used recursively by `build`.
    split(level: i32): Octree {
        const thisBox = this.box;
        if (thisBox == null) return this;

        const subTrees: Array<Octree> = [];
        const halfsize = _v2.copy(thisBox.max).sub(thisBox.min).multiplyScalar(0.5);

        for (let x = 0; x < 2; x++) {
            for (let y = 0; y < 2; y++) {
                for (let z = 0; z < 2; z++) {
                    const box = new Box3();
                    const v = _v1.set(<f64>x, <f64>y, <f64>z);

                    box.min.copy(thisBox.min).add(v.multiply(halfsize));
                    box.max.copy(box.min).add(halfsize);
                    // The upper halves end at the parent's max exactly:
                    // min + 2 * (half) can round below it (three.js's
                    // does), which drops the triangles lying on the max
                    // faces (a floor at the top of the bounds).
                    if (x == 1) box.max.x = thisBox.max.x;
                    if (y == 1) box.max.y = thisBox.max.y;
                    if (z == 1) box.max.z = thisBox.max.z;

                    const subTree = new Octree(box);
                    subTree.trianglesPerLeaf = this.trianglesPerLeaf;
                    subTree.maxLevel = this.maxLevel;

                    subTrees.push(subTree);
                }
            }
        }

        // three.js pops the triangles: last first. The triangle's bounds
        // are tested first (Box3.intersectsTriangle's box axes, without its
        // nine cross products), which rejects most of the eight cells.
        const triangles = this.triangles;
        for (let t = triangles.length - 1; t >= 0; t--) {
            const triangle = triangles[t];
            const a = triangle.a, b = triangle.b, c = triangle.c;
            const minX = min3(a.x, b.x, c.x), maxX = max3(a.x, b.x, c.x);
            const minY = min3(a.y, b.y, c.y), maxY = max3(a.y, b.y, c.y);
            const minZ = min3(a.z, b.z, c.z), maxZ = max3(a.z, b.z, c.z);
            for (let i = 0; i < subTrees.length; i++) {
                const box = subTrees[i].box!;
                if (maxX < box.min.x || minX > box.max.x || maxY < box.min.y || minY > box.max.y
                        || maxZ < box.min.z || minZ > box.max.z) continue;
                if (box.intersectsTriangle(triangle)) {
                    subTrees[i].triangles.push(triangle);
                }
            }
        }
        triangles.length = 0;

        for (let i = 0; i < subTrees.length; i++) {
            const len = subTrees[i].triangles.length;

            if (len > this.trianglesPerLeaf && level < this.maxLevel) {
                subTrees[i].split(level + 1);
            }

            if (len != 0) {
                this.subTrees.push(subTrees[i]);
            }
        }

        return this;
    }

    /// Builds the Octree from the triangles added.
    build(): Octree {
        this.calcBox();
        this.split(0);

        return this;
    }

    /// Adds to `triangles` those that may intersect `ray` (each once).
    getRayTriangles(ray: Ray, triangles: Array<Triangle>): void {
        _seen.clear();
        for (let i = 0; i < triangles.length; i++) _seen.add(triangles[i]);
        this.collectRayTriangles(ray, triangles, _seen);
        _seen.clear();
    }

    private collectRayTriangles(ray: Ray, triangles: Array<Triangle>, seen: Set<Triangle>): void {
        const subTrees = this.subTrees;
        for (let i = 0; i < subTrees.length; i++) {
            const subTree = unchecked(subTrees[i]);
            if (!ray.intersectsBox(subTree.box!)) continue;

            const tris = subTree.triangles;
            if (tris.length > 0) {
                for (let j = 0; j < tris.length; j++) {
                    const t = unchecked(tris[j]);
                    if (!seen.has(t)) {
                        seen.add(t);
                        triangles.push(t);
                    }
                }
            } else {
                subTree.collectRayTriangles(ray, triangles, seen);
            }
        }
    }

    /// The intersection of `capsule` and `triangle`, or null.
    triangleCapsuleIntersect(capsule: Capsule, triangle: Triangle): OctreeTriangleCollision? {
        triangle.getPlane(_plane);

        const d1 = _plane.distanceToPoint(capsule.start) - capsule.radius;
        const d2 = _plane.distanceToPoint(capsule.end) - capsule.radius;

        if ((d1 > 0 && d2 > 0) || (d1 < -capsule.radius && d2 < -capsule.radius)) {
            return null;
        }

        const delta = Math.abs(d1 / (Math.abs(d1) + Math.abs(d2)));
        const intersectPoint = _v1.copy(capsule.start).lerp(capsule.end, delta);

        if (triangle.containsPoint(intersectPoint)) {
            return new OctreeTriangleCollision(_plane.normal.clone(), intersectPoint.clone(), Math.abs(Math.min(d1, d2)));
        }

        const r2 = capsule.radius * capsule.radius;

        const line1 = _line1.set(capsule.start, capsule.end);

        for (let i = 0; i < 3; i++) {
            const a = i == 0 ? triangle.a : i == 1 ? triangle.b : triangle.c;
            const b = i == 0 ? triangle.b : i == 1 ? triangle.c : triangle.a;
            const line2 = _line2.set(a, b);

            lineToLineClosestPoints(line1, line2, _point1, _point2);

            if (_point1.distanceToSquared(_point2) < r2) {
                return new OctreeTriangleCollision(
                    _point1.clone().sub(_point2).normalize(),
                    _point2.clone(),
                    capsule.radius - _point1.distanceTo(_point2));
            }
        }

        return null;
    }

    /// The intersection of `box` and `triangle`, or null: the plane's
    /// normal, the depth of the box's deepest corner, that corner projected
    /// onto the plane.
    triangleBoxIntersect(box: Box3, triangle: Triangle): OctreeTriangleCollision? {
        // cheap check

        if (max3(triangle.a.x, triangle.b.x, triangle.c.x) < box.min.x ||
                min3(triangle.a.x, triangle.b.x, triangle.c.x) > box.max.x ||
                max3(triangle.a.y, triangle.b.y, triangle.c.y) < box.min.y ||
                min3(triangle.a.y, triangle.b.y, triangle.c.y) > box.max.y ||
                max3(triangle.a.z, triangle.b.z, triangle.c.z) < box.min.z ||
                min3(triangle.a.z, triangle.b.z, triangle.c.z) > box.max.z) {
            return null;
        }

        // expensive check

        if (!box.intersectsTriangle(triangle)) return null;

        // there is an intersection, now compute collision data

        triangle.getPlane(_plane);

        // determine which corner of the box is "deepest" into the plane

        _v1.x = (_plane.normal.x > 0) ? box.min.x : box.max.x;
        _v1.y = (_plane.normal.y > 0) ? box.min.y : box.max.y;
        _v1.z = (_plane.normal.z > 0) ? box.min.z : box.max.z;

        // Calculate the distance from the plane to that corner (the distance
        // will be negative because of the intersection)

        const distance = _plane.distanceToPoint(_v1);

        const intersection = new OctreeTriangleCollision(_plane.normal.clone(), _v1.clone(), -distance); // Flip sign so depth is positive

        // project the point onto the triangle surface
        intersection.point.addScaledVector(intersection.normal, -distance);

        return intersection;
    }

    /// The intersection of `sphere` and `triangle`, or null.
    triangleSphereIntersect(sphere: Sphere, triangle: Triangle): OctreeTriangleCollision? {
        triangle.getPlane(_plane);

        if (!sphere.intersectsPlane(_plane)) return null;

        const r2 = sphere.radius * sphere.radius;

        const plainPoint = _plane.projectPoint(sphere.center, _v1);

        if (triangle.containsPoint(sphere.center)) {
            return new OctreeTriangleCollision(_plane.normal.clone(), plainPoint.clone(), Math.abs(_plane.distanceToSphere(sphere)));
        }

        for (let i = 0; i < 3; i++) {
            const a = i == 0 ? triangle.a : i == 1 ? triangle.b : triangle.c;
            const b = i == 0 ? triangle.b : i == 1 ? triangle.c : triangle.a;
            _line1.set(a, b);
            _line1.closestPointToPoint(plainPoint, true, _v2);

            const d = _v2.distanceToSquared(sphere.center);

            if (d < r2) {
                return new OctreeTriangleCollision(sphere.center.clone().sub(_v2).normalize(), _v2.clone(), sphere.radius - Math.sqrt(d));
            }
        }

        return null;
    }

    /// Adds to `triangles` those that may intersect `sphere` (each once).
    getSphereTriangles(sphere: Sphere, triangles: Array<Triangle>): void {
        _seen.clear();
        for (let i = 0; i < triangles.length; i++) _seen.add(triangles[i]);
        this.collectSphereTriangles(sphere, triangles, _seen);
        _seen.clear();
    }

    private collectSphereTriangles(sphere: Sphere, triangles: Array<Triangle>, seen: Set<Triangle>): void {
        const subTrees = this.subTrees;
        for (let i = 0; i < subTrees.length; i++) {
            const subTree = unchecked(subTrees[i]);
            if (!sphere.intersectsBox(subTree.box!)) continue;

            const tris = subTree.triangles;
            if (tris.length > 0) {
                for (let j = 0; j < tris.length; j++) {
                    const t = unchecked(tris[j]);
                    if (!seen.has(t)) {
                        seen.add(t);
                        triangles.push(t);
                    }
                }
            } else {
                subTree.collectSphereTriangles(sphere, triangles, seen);
            }
        }
    }

    /// Adds to `triangles` those that may intersect `box` (each once).
    getBoxTriangles(box: Box3, triangles: Array<Triangle>): void {
        _seen.clear();
        for (let i = 0; i < triangles.length; i++) _seen.add(triangles[i]);
        this.collectBoxTriangles(box, triangles, _seen);
        _seen.clear();
    }

    private collectBoxTriangles(box: Box3, triangles: Array<Triangle>, seen: Set<Triangle>): void {
        const subTrees = this.subTrees;
        for (let i = 0; i < subTrees.length; i++) {
            const subTree = unchecked(subTrees[i]);
            if (!box.intersectsBox(subTree.box!)) continue;

            const tris = subTree.triangles;
            if (tris.length > 0) {
                for (let j = 0; j < tris.length; j++) {
                    const t = unchecked(tris[j]);
                    if (!seen.has(t)) {
                        seen.add(t);
                        triangles.push(t);
                    }
                }
            } else {
                subTree.collectBoxTriangles(box, triangles, seen);
            }
        }
    }

    /// Adds to `triangles` those that may intersect `capsule` (each once).
    getCapsuleTriangles(capsule: Capsule, triangles: Array<Triangle>): void {
        _seen.clear();
        for (let i = 0; i < triangles.length; i++) _seen.add(triangles[i]);
        this.collectCapsuleTriangles(capsule, triangles, _seen);
        _seen.clear();
    }

    private collectCapsuleTriangles(capsule: Capsule, triangles: Array<Triangle>, seen: Set<Triangle>): void {
        const subTrees = this.subTrees;
        for (let i = 0; i < subTrees.length; i++) {
            const subTree = unchecked(subTrees[i]);
            if (!capsule.intersectsBox(subTree.box!)) continue;

            const tris = subTree.triangles;
            if (tris.length > 0) {
                for (let j = 0; j < tris.length; j++) {
                    const t = unchecked(tris[j]);
                    if (!seen.has(t)) {
                        seen.add(t);
                        triangles.push(t);
                    }
                }
            } else {
                subTree.collectCapsuleTriangles(capsule, triangles, seen);
            }
        }
    }

    // Allocation-free triangle resolution helpers for boxIntersect / sphereIntersect / capsuleIntersect.
    private resolveTriangleBox(box: Box3, triangle: Triangle): bool {
        if (max3(triangle.a.x, triangle.b.x, triangle.c.x) < box.min.x ||
                min3(triangle.a.x, triangle.b.x, triangle.c.x) > box.max.x ||
                max3(triangle.a.y, triangle.b.y, triangle.c.y) < box.min.y ||
                min3(triangle.a.y, triangle.b.y, triangle.c.y) > box.max.y ||
                max3(triangle.a.z, triangle.b.z, triangle.c.z) < box.min.z ||
                min3(triangle.a.z, triangle.b.z, triangle.c.z) > box.max.z) {
            return false;
        }
        if (!box.intersectsTriangle(triangle)) return false;
        triangle.getPlane(_plane);
        _v1.x = (_plane.normal.x > 0) ? box.min.x : box.max.x;
        _v1.y = (_plane.normal.y > 0) ? box.min.y : box.max.y;
        _v1.z = (_plane.normal.z > 0) ? box.min.z : box.max.z;
        const depth = -_plane.distanceToPoint(_v1);
        _triNormal.copy(_plane.normal).multiplyScalar(depth);
        box.translate(_triNormal);
        return true;
    }

    private resolveTriangleSphere(sphere: Sphere, triangle: Triangle): bool {
        triangle.getPlane(_plane);
        if (!sphere.intersectsPlane(_plane)) return false;
        const r2 = sphere.radius * sphere.radius;
        const plainPoint = _plane.projectPoint(sphere.center, _v1);
        if (triangle.containsPoint(sphere.center)) {
            const depth = Math.abs(_plane.distanceToSphere(sphere));
            sphere.center.addScaledVector(_plane.normal, depth);
            return true;
        }
        for (let i = 0; i < 3; i++) {
            const a = i == 0 ? triangle.a : i == 1 ? triangle.b : triangle.c;
            const b = i == 0 ? triangle.b : i == 1 ? triangle.c : triangle.a;
            _line1.set(a, b);
            _line1.closestPointToPoint(plainPoint, true, _v2);
            const d = _v2.distanceToSquared(sphere.center);
            if (d < r2) {
                const depth = sphere.radius - Math.sqrt(d);
                _triNormal.subVectors(sphere.center, _v2).normalize();
                sphere.center.addScaledVector(_triNormal, depth);
                return true;
            }
        }
        return false;
    }

    private resolveTriangleCapsule(capsule: Capsule, triangle: Triangle): bool {
        triangle.getPlane(_plane);
        const d1 = _plane.distanceToPoint(capsule.start) - capsule.radius;
        const d2 = _plane.distanceToPoint(capsule.end) - capsule.radius;
        if ((d1 > 0 && d2 > 0) || (d1 < -capsule.radius && d2 < -capsule.radius)) {
            return false;
        }
        const delta = Math.abs(d1 / (Math.abs(d1) + Math.abs(d2)));
        const intersectPoint = _v1.copy(capsule.start).lerp(capsule.end, delta);
        if (triangle.containsPoint(intersectPoint)) {
            const depth = Math.abs(Math.min(d1, d2));
            _triNormal.copy(_plane.normal).multiplyScalar(depth);
            capsule.translate(_triNormal);
            return true;
        }
        const r2 = capsule.radius * capsule.radius;
        const line1 = _line1.set(capsule.start, capsule.end);
        for (let i = 0; i < 3; i++) {
            const a = i == 0 ? triangle.a : i == 1 ? triangle.b : triangle.c;
            const b = i == 0 ? triangle.b : i == 1 ? triangle.c : triangle.a;
            const line2 = _line2.set(a, b);
            lineToLineClosestPoints(line1, line2, _point1, _point2);
            const d2sq = _point1.distanceToSquared(_point2);
            if (d2sq < r2) {
                const dist = Math.sqrt(d2sq);
                const depth = capsule.radius - dist;
                _triNormal.subVectors(_point1, _point2).normalize().multiplyScalar(depth);
                capsule.translate(_triNormal);
                return true;
            }
        }
        return false;
    }

    /// `box` against the world: how far, and which way, to move it out
    /// (its triangles resolved one after the other), or null.
    boxIntersect(box: Box3): OctreeCollision? {
        _box.copy(box);

        _triangles.length = 0;
        let hit = false;

        this.getBoxTriangles(box, _triangles);

        for (let i = 0; i < _triangles.length; i++) {
            if (this.resolveTriangleBox(_box, unchecked(_triangles[i]))) hit = true;
        }
        _triangles.length = 0;

        if (hit) {
            const collisionVector = _box.getCenter(_center).sub(box.getCenter(_v1));
            const depth = collisionVector.length();

            return new OctreeCollision(collisionVector.normalize().clone(), depth);
        }

        return null;
    }

    /// `sphere` against the world: how far, and which way, to move it out,
    /// or null.
    sphereIntersect(sphere: Sphere): OctreeCollision? {
        _sphere.copy(sphere);

        _triangles.length = 0;
        let hit = false;

        this.getSphereTriangles(sphere, _triangles);

        for (let i = 0; i < _triangles.length; i++) {
            if (this.resolveTriangleSphere(_sphere, unchecked(_triangles[i]))) hit = true;
        }
        _triangles.length = 0;

        if (hit) {
            const collisionVector = _sphere.center.clone().sub(sphere.center);
            const depth = collisionVector.length();

            return new OctreeCollision(collisionVector.normalize(), depth);
        }

        return null;
    }

    /// `capsule` against the world: how far, and which way, to move it
    /// out, or null.
    capsuleIntersect(capsule: Capsule): OctreeCollision? {
        _capsule.copy(capsule);

        _triangles.length = 0;
        let hit = false;

        this.getCapsuleTriangles(_capsule, _triangles);

        for (let i = 0; i < _triangles.length; i++) {
            if (this.resolveTriangleCapsule(_capsule, unchecked(_triangles[i]))) hit = true;
        }
        _triangles.length = 0;

        if (hit) {
            const collisionVector = _capsule.getCenter(_center).sub(capsule.getCenter(_v1));
            const depth = collisionVector.length();

            return new OctreeCollision(collisionVector.normalize().clone(), depth);
        }

        return null;
    }

    /// The nearest triangle `ray` hits (front faces only, as three.js), or
    /// null.
    rayIntersect(ray: Ray): OctreeRayHit? {
        _triangles.length = 0;
        let triangle: Triangle? = null;
        let minDistSq: f64 = Infinity;

        this.getRayTriangles(ray, _triangles);

        for (let i = 0; i < _triangles.length; i++) {
            const tri = unchecked(_triangles[i]);
            const result = ray.intersectTriangle(tri.a, tri.b, tri.c, true, _v1);

            if (result != null) {
                const distSq = result.distanceToSquared(ray.origin);

                if (distSq < minDistSq) {
                    _bestPos.copy(result);
                    minDistSq = distSq;
                    triangle = tri;
                }
            }
        }
        _triangles.length = 0;

        return triangle != null ? new OctreeRayHit(Math.sqrt(minDistSq), triangle!, _bestPos.clone()) : null;
    }

    /// Builds the Octree from the meshes under `group` (itself included)
    /// that share a layer with `layers`, in world space.
    fromGraphNode(group: Object3D): Octree {
        group.updateWorldMatrix(true, true);

        this.addGraphNode(group);

        this.build();

        return this;
    }

    // three.js's traverse callback (no closures): every mesh, visible or not.
    private addGraphNode(obj: Object3D): void {
        if (obj instanceof Mesh) {
            const mesh = obj as Mesh;
            if (this.layers.test(mesh.layers)) this.addMeshTriangles(mesh);
        }
        const children = obj.children;
        for (let i = 0; i < children.length; i++) this.addGraphNode(children[i]);
    }

    // three.js reads `geometry.toNonIndexed()`; this reads through the
    // index instead, the same triangles without the copy.
    private addMeshTriangles(mesh: Mesh): void {
        const geometry = mesh.geometry;
        const positionAttribute = geometry.getAttribute("position");
        if (positionAttribute == null) return;
        const index = geometry.index;
        const count = index != null ? index.count : positionAttribute.count;
        const m = mesh.matrixWorld;

        for (let i = 0; i + 2 < count; i += 3) {
            const i0 = index != null ? <i32>index.getX(i) : i;
            const i1 = index != null ? <i32>index.getX(i + 1) : i + 1;
            const i2 = index != null ? <i32>index.getX(i + 2) : i + 2;
            const v1 = new Vector3().fromBufferAttribute(positionAttribute, i0);
            const v2 = new Vector3().fromBufferAttribute(positionAttribute, i1);
            const v3 = new Vector3().fromBufferAttribute(positionAttribute, i2);

            v1.applyMatrix4(m);
            v2.applyMatrix4(m);
            v3.applyMatrix4(m);

            this.addTriangle(new Triangle(v1, v2, v3));
        }
    }

    /// Empties the Octree.
    clear(): Octree {
        this.box = null;
        this.bounds.makeEmpty();

        this.subTrees.length = 0;
        this.triangles.length = 0;

        return this;
    }
}
