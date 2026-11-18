// The raycast implementations of Mesh, InstancedMesh, Line, Points and
// Sprite (three.js's, internal). Each object's `raycast` calls these.

import { Raycaster, Intersection, Face } from "../core/Raycaster";
import { BufferGeometry } from "../core/BufferGeometry";
import { BufferAttribute } from "../core/BufferAttribute";
import { Material } from "../materials/Material";
import { Mesh } from "./Mesh";
import { InstancedMesh } from "./InstancedMesh";
import { Line, LineSegments, LineLoop } from "./Line";
import { Points } from "./Points";
import { Sprite } from "./Sprite";
import { PerspectiveCamera } from "../cameras/PerspectiveCamera";
import { Ray } from "../math/Ray";
import { Sphere } from "../math/Sphere";
import { Matrix4 } from "../math/Matrix4";
import { Vector2 } from "../math/Vector2";
import { Vector3 } from "../math/Vector3";
import { Triangle } from "../math/Triangle";
import { BackSide, FrontSide } from "../constants";

const _ray: Ray = new Ray();
const _sphere: Sphere = new Sphere();
const _inverse: Matrix4 = new Matrix4();
const _hitAt: Vector3 = new Vector3();
const _vA: Vector3 = new Vector3();
const _vB: Vector3 = new Vector3();
const _vC: Vector3 = new Vector3();
const _point: Vector3 = new Vector3();
const _onRay: Vector3 = new Vector3();
const _onSegment: Vector3 = new Vector3();
const _bary: Vector3 = new Vector3();
const _instanceWorld: Matrix4 = new Matrix4();
const _instanceLocal: Matrix4 = new Matrix4();

// ----------------------------------------------------------------- meshes

export function raycastMesh(mesh: Mesh, raycaster: Raycaster, intersects: Array<Intersection>,
                            matrixWorld: Matrix4, instanceId: i32): void {
    const geometry = mesh.geometry;
    if (geometry.boundingSphere == null) geometry.computeBoundingSphere();
    _sphere.copy(geometry.boundingSphere!).applyMatrix4(matrixWorld);
    _ray.copy(raycaster.ray).recast(raycaster.near);
    if (!_sphere.containsPoint(_ray.origin)) {
        if (_ray.intersectSphere(_sphere, _hitAt) == null) return;
        const range = raycaster.far - raycaster.near;
        if (_ray.origin.distanceToSquared(_hitAt) > range * range) return;
    }
    _inverse.copy(matrixWorld).invert();
    _ray.copy(raycaster.ray).applyMatrix4(_inverse);
    const box = geometry.boundingBox;
    if (box != null && !_ray.intersectsBox(box)) return;

    const position = geometry.getAttribute("position");
    if (position == null) return;
    const index = geometry.index;
    const count = index != null ? index.count : position.count;
    const rangeStart = max<i32>(0, geometry.drawRange.start);
    const rangeEnd = geometry.drawRange.count < 0 ? count : min<i32>(count, rangeStart + geometry.drawRange.count);
    const groups = geometry.groups;
    if (mesh.materials.length > 0 && groups.length > 0) {
        for (let g = 0; g < groups.length; g++) {
            const group = groups[g];
            if (group.materialIndex < 0 || group.materialIndex >= mesh.materials.length) continue;
            const material = mesh.materials[group.materialIndex];
            const start = max<i32>(group.start, rangeStart);
            const end = min<i32>(rangeEnd, group.start + group.count);
            meshTriangles(mesh, material, geometry, raycaster, intersects, matrixWorld, start, end, group.materialIndex,
                instanceId);
        }
    } else {
        meshTriangles(mesh, mesh.material, geometry, raycaster, intersects, matrixWorld, rangeStart, rangeEnd, 0,
            instanceId);
    }
}

function meshTriangles(mesh: Mesh, material: Material, geometry: BufferGeometry, raycaster: Raycaster,
                       intersects: Array<Intersection>, matrixWorld: Matrix4, start: i32, end: i32,
                       materialIndex: i32, instanceId: i32): void {
    const position = geometry.getAttribute("position")!;
    const index = geometry.index;
    const uv = geometry.getAttribute("uv");
    const normal = geometry.getAttribute("normal");
    for (let j = start; j + 2 < end; j += 3) {
        const a = index != null ? index.getX(j) : j;
        const b = index != null ? index.getX(j + 1) : j + 1;
        const c = index != null ? index.getX(j + 2) : j + 2;
        _vA.set(position.getX(a), position.getY(a), position.getZ(a));
        _vB.set(position.getX(b), position.getY(b), position.getZ(b));
        _vC.set(position.getX(c), position.getY(c), position.getZ(c));
        let hit: Vector3?;
        if (material.side == BackSide) hit = _ray.intersectTriangle(_vC, _vB, _vA, true, _point);
        else hit = _ray.intersectTriangle(_vA, _vB, _vC, material.side == FrontSide, _point);
        if (hit == null) continue;
        const world = _point.clone().applyMatrix4(matrixWorld);
        const distance = raycaster.ray.origin.distanceTo(world);
        if (distance < raycaster.near || distance > raycaster.far) continue;
        const intersection = new Intersection(distance, world, mesh);
        const bary = Triangle.getBarycoord(_point, _vA, _vB, _vC, new Vector3());
        if (bary != null) {
            intersection.barycoord = bary;
            if (uv != null) intersection.uv = interpolate2(uv, a, b, c, bary);
            if (normal != null) {
                const n = interpolate3(normal, a, b, c, bary);
                if (n.dot(_ray.direction) > 0) n.multiplyScalar(-1);
                intersection.normal = n;
            }
        }
        const face = new Face(a, b, c);
        Triangle.getNormal(_vA, _vB, _vC, face.normal);
        face.materialIndex = materialIndex;
        intersection.face = face;
        intersection.faceIndex = j / 3;
        intersection.instanceId = instanceId;
        intersects.push(intersection);
    }
}

function interpolate2(attr: BufferAttribute, a: i32, b: i32, c: i32, bary: Vector3): Vector2 {
    return new Vector2(
        attr.getX(a) * bary.x + attr.getX(b) * bary.y + attr.getX(c) * bary.z,
        attr.getY(a) * bary.x + attr.getY(b) * bary.y + attr.getY(c) * bary.z);
}

function interpolate3(attr: BufferAttribute, a: i32, b: i32, c: i32, bary: Vector3): Vector3 {
    return new Vector3(
        attr.getX(a) * bary.x + attr.getX(b) * bary.y + attr.getX(c) * bary.z,
        attr.getY(a) * bary.x + attr.getY(b) * bary.y + attr.getY(c) * bary.z,
        attr.getZ(a) * bary.x + attr.getZ(b) * bary.y + attr.getZ(c) * bary.z);
}

export function raycastInstancedMesh(mesh: InstancedMesh, raycaster: Raycaster, intersects: Array<Intersection>): void {
    if (mesh.boundingSphere == null) mesh.computeBoundingSphere();
    _sphere.copy(mesh.boundingSphere!).applyMatrix4(mesh.matrixWorld);
    if (!raycaster.ray.intersectsSphere(_sphere)) return;
    for (let i = 0; i < mesh.count; i++) {
        mesh.getMatrixAt(i, _instanceLocal);
        _instanceWorld.multiplyMatrices(mesh.matrixWorld, _instanceLocal);
        raycastMesh(mesh, raycaster, intersects, _instanceWorld, i);
    }
}

// ----------------------------------------------------------------- lines

export function raycastLine(line: Line, raycaster: Raycaster, intersects: Array<Intersection>): void {
    const geometry = line.geometry;
    const threshold = raycaster.params.Line.threshold;
    if (geometry.boundingSphere == null) geometry.computeBoundingSphere();
    _sphere.copy(geometry.boundingSphere!).applyMatrix4(line.matrixWorld);
    _sphere.radius += threshold;
    if (!raycaster.ray.intersectsSphere(_sphere)) return;
    _inverse.copy(line.matrixWorld).invert();
    _ray.copy(raycaster.ray).applyMatrix4(_inverse);
    const localThreshold = threshold / ((line.scale.x + line.scale.y + line.scale.z) / 3);
    const thresholdSq = localThreshold * localThreshold;
    const position = geometry.getAttribute("position");
    if (position == null) return;
    const index = geometry.index;
    const count = index != null ? index.count : position.count;
    const start = max<i32>(0, geometry.drawRange.start);
    const end = geometry.drawRange.count < 0 ? count : min<i32>(count, start + geometry.drawRange.count);
    const step = line instanceof LineSegments ? 2 : 1;
    for (let i = start; i < end - 1; i += step) {
        const a = index != null ? index.getX(i) : i;
        const b = index != null ? index.getX(i + 1) : i + 1;
        segmentHit(line, raycaster, intersects, position, thresholdSq, a, b, i);
    }
    if (line instanceof LineLoop && end - start > 2) {
        const a = index != null ? index.getX(end - 1) : end - 1;
        const b = index != null ? index.getX(start) : start;
        segmentHit(line, raycaster, intersects, position, thresholdSq, a, b, end - 1);
    }
}

function segmentHit(line: Line, raycaster: Raycaster, intersects: Array<Intersection>, position: BufferAttribute,
                    thresholdSq: f64, a: i32, b: i32, i: i32): void {
    _vA.set(position.getX(a), position.getY(a), position.getZ(a));
    _vB.set(position.getX(b), position.getY(b), position.getZ(b));
    const distSq = _ray.distanceSqToSegment(_vA, _vB, _onRay, _onSegment);
    if (distSq > thresholdSq) return;
    _onRay.applyMatrix4(line.matrixWorld);
    const distance = raycaster.ray.origin.distanceTo(_onRay);
    if (distance < raycaster.near || distance > raycaster.far) return;
    const hit = new Intersection(distance, _onSegment.clone().applyMatrix4(line.matrixWorld), line);
    hit.index = i;
    intersects.push(hit);
}

// ----------------------------------------------------------------- points

export function raycastPoints(points: Points, raycaster: Raycaster, intersects: Array<Intersection>): void {
    const geometry = points.geometry;
    const threshold = raycaster.params.Points.threshold;
    if (geometry.boundingSphere == null) geometry.computeBoundingSphere();
    _sphere.copy(geometry.boundingSphere!).applyMatrix4(points.matrixWorld);
    _sphere.radius += threshold;
    if (!raycaster.ray.intersectsSphere(_sphere)) return;
    _inverse.copy(points.matrixWorld).invert();
    _ray.copy(raycaster.ray).applyMatrix4(_inverse);
    const localThreshold = threshold / ((points.scale.x + points.scale.y + points.scale.z) / 3);
    const thresholdSq = localThreshold * localThreshold;
    const position = geometry.getAttribute("position");
    if (position == null) return;
    const start = max<i32>(0, geometry.drawRange.start);
    const end = geometry.drawRange.count < 0 ? position.count : min<i32>(position.count, start + geometry.drawRange.count);
    for (let i = start; i < end; i++) {
        _vA.set(position.getX(i), position.getY(i), position.getZ(i));
        const raySq = _ray.distanceSqToPoint(_vA);
        if (raySq >= thresholdSq) continue;
        const p = new Vector3();
        _ray.closestPointToPoint(_vA, p);
        p.applyMatrix4(points.matrixWorld);
        const distance = raycaster.ray.origin.distanceTo(p);
        if (distance < raycaster.near || distance > raycaster.far) continue;
        const hit = new Intersection(distance, p, points);
        hit.distanceToRay = Math.sqrt(raySq);
        hit.index = i;
        intersects.push(hit);
    }
}

// ----------------------------------------------------------------- sprites

const _worldScale: Vector3 = new Vector3();
const _mvPosition: Vector3 = new Vector3();
const _modelView: Matrix4 = new Matrix4();
const _uvA: Vector2 = new Vector2();
const _uvB: Vector2 = new Vector2();
const _uvC: Vector2 = new Vector2();

export function raycastSprite(sprite: Sprite, raycaster: Raycaster, intersects: Array<Intersection>): void {
    const camera = raycaster.camera;
    if (camera == null) return;   // three.js: "Raycaster.camera needs to be set"
    _worldScale.setFromMatrixScale(sprite.matrixWorld);
    _modelView.multiplyMatrices(camera.matrixWorldInverse, sprite.matrixWorld);
    _mvPosition.setFromMatrixPosition(_modelView);
    if (camera instanceof PerspectiveCamera && !sprite.material.sizeAttenuation) _worldScale.multiplyScalar(-_mvPosition.z);
    const rotation = sprite.material.rotation;
    const sin = Math.sin(rotation), cos = Math.cos(rotation);
    const center = sprite.center;
    corner(_vA.set(-0.5, -0.5, 0), center, sin, cos, camera.matrixWorld);
    corner(_vB.set(0.5, -0.5, 0), center, sin, cos, camera.matrixWorld);
    corner(_vC.set(0.5, 0.5, 0), center, sin, cos, camera.matrixWorld);
    _uvA.set(0, 0); _uvB.set(1, 0); _uvC.set(1, 1);
    let hit = raycaster.ray.intersectTriangle(_vA, _vB, _vC, false, _point);
    if (hit == null) {
        corner(_vB.set(-0.5, 0.5, 0), center, sin, cos, camera.matrixWorld);
        _uvB.set(0, 1);
        hit = raycaster.ray.intersectTriangle(_vA, _vC, _vB, false, _point);
        if (hit == null) return;
    }
    const distance = raycaster.ray.origin.distanceTo(_point);
    if (distance < raycaster.near || distance > raycaster.far) return;
    const intersection = new Intersection(distance, _point.clone(), sprite);
    intersection.uv = Triangle.getInterpolation<Vector2>(_point, _vA, _vB, _vC, _uvA, _uvB, _uvC, new Vector2());
    intersects.push(intersection);
}

function corner(v: Vector3, center: Vector2, sin: f64, cos: f64, viewWorld: Matrix4): void {
    const ax = (v.x - center.x + 0.5) * _worldScale.x;
    const ay = (v.y - center.y + 0.5) * _worldScale.y;
    v.copy(_mvPosition);
    v.x += cos * ax - sin * ay;
    v.y += sin * ax + cos * ay;
    v.applyMatrix4(viewWorld);
}
