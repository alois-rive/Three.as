// Frustum culling of many objects in a Rive parallel call (rive/parallel):
// GPURenderer.collect walks the scene, then tests the frustum-culled
// candidates on every thread the call gets. The test is exactly the
// renderer's inFrustum (three.js's Frustum.intersectsObject /
// intersectsSprite on world bounding spheres), in f64, without globals.

import { Parallel, Part, SharedArray } from "rive/parallel";
import { Object3D } from "../../core/Object3D";
import { BufferGeometry } from "../../core/BufferGeometry";
import { Mesh } from "../../objects/Mesh";
import { InstancedMesh } from "../../objects/InstancedMesh";
import { BatchedMesh } from "../../objects/BatchedMesh";
import { SkinnedMesh } from "../../objects/SkinnedMesh";
import { Line } from "../../objects/Line";
import { Points } from "../../objects/Points";
import { Sprite } from "../../objects/Sprite";
import { Sphere } from "../../math/Sphere";

/// Below this many candidates a view culls on the main lane: the bounds
/// pass and the call's start cost more than they save. Measured with the
/// Benchmark artboard compiled ahead of time on an M-series Mac: 1000
/// candidates culled in 0.10-0.12 ms on the main lane, 0.14-0.15 ms in
/// parallel; 8000 in 0.95 ms against 0.83 ms (interpreted, parallel wins
/// from 1000: 1.24 against 1.02 ms).
export const PARALLEL_CULL_MIN: i32 = 2048;

/// Computes the bounding spheres the test reads (lazily, as inFrustum
/// does), on the main lane before the parallel call: parts cannot allocate.
export function prepareBounds(o: Object3D): void {
    if (o instanceof Sprite || o instanceof SkinnedMesh) return;
    if (o instanceof InstancedMesh) {
        const im = o as InstancedMesh;
        if (im.boundingSphere == null) im.computeBoundingSphere();
        return;
    }
    if (o instanceof BatchedMesh) {
        const bm = o as BatchedMesh;
        if (bm.boundingSphere == null) bm.computeBoundingSphere();
        return;
    }
    const geometry = geometryOf(o);
    if (geometry != null && geometry.boundingSphere == null) geometry.computeBoundingSphere();
}

/// Writes 1 into out[i] where objects[i] is in the frustum (or not tested:
/// test[i] 0), else 0. `planes` holds the six planes (normal xyz,
/// constant).
@parallel export function cullObjects(part: Part, objects: Array<Object3D>, test: Uint8Array, planes: Float64Array,
                                      out: SharedArray<u8>): void {
    const n = objects.length;
    const end = part.end(n);
    for (let i = part.start(n); i < end; i++) {
        out[i] = test[i] == 0 || visible(unchecked(objects[i]), planes) ? 1 : 0;
    }
}

/// GPURenderer.inFrustum for one object, the bounds already computed.
export function visible(o: Object3D, planes: Float64Array): bool {
    if (o instanceof Sprite) {
        const sprite = o as Sprite;
        const dx = 0.5 - sprite.center.x, dy = 0.5 - sprite.center.y;
        return sphereVisible(o, 0, 0, 0, 0.7071067811865476 + Math.sqrt(dx * dx + dy * dy), planes);
    }
    let s: Sphere? = null;
    if (o instanceof SkinnedMesh) {
        s = (o as SkinnedMesh).boundingSphere;
        if (s == null) return true;
    } else if (o instanceof InstancedMesh) {
        s = (o as InstancedMesh).boundingSphere;
    } else if (o instanceof BatchedMesh) {
        s = (o as BatchedMesh).boundingSphere;
        if (s != null && s.isEmpty()) return false;
    } else {
        const geometry = geometryOf(o);
        if (geometry == null) return true;
        s = geometry.boundingSphere;
        if (s == null || s.isEmpty()) return true;
    }
    if (s == null) return true;
    const c = s.center;
    return sphereVisible(o, c.x, c.y, c.z, s.radius, planes);
}

// Sphere.applyMatrix4 then Frustum.intersectsSphere, operation for operation.
function sphereVisible(o: Object3D, x: f64, y: f64, z: f64, radius: f64, planes: Float64Array): bool {
    const e = o.matrixWorld.mat4.m;
    const w = 1 / (<f64>e[3] * x + <f64>e[7] * y + <f64>e[11] * z + <f64>e[15]);
    const cx = (<f64>e[0] * x + <f64>e[4] * y + <f64>e[8] * z + <f64>e[12]) * w;
    const cy = (<f64>e[1] * x + <f64>e[5] * y + <f64>e[9] * z + <f64>e[13]) * w;
    const cz = (<f64>e[2] * x + <f64>e[6] * y + <f64>e[10] * z + <f64>e[14]) * w;
    const sx = <f64>e[0] * e[0] + <f64>e[1] * e[1] + <f64>e[2] * e[2];
    const sy = <f64>e[4] * e[4] + <f64>e[5] * e[5] + <f64>e[6] * e[6];
    const sz = <f64>e[8] * e[8] + <f64>e[9] * e[9] + <f64>e[10] * e[10];
    const r = radius * Math.sqrt(Math.max(sx, Math.max(sy, sz)));
    const negRadius = -r;
    for (let i = 0; i < 6; i++) {
        const p = i * 4;
        if (planes[p] * cx + planes[p + 1] * cy + planes[p + 2] * cz + planes[p + 3] < negRadius) return false;
    }
    return true;
}

function geometryOf(o: Object3D): BufferGeometry? {
    if (o instanceof Mesh) return (o as Mesh).geometry;
    if (o instanceof Line) return (o as Line).geometry;
    if (o instanceof Points) return (o as Points).geometry;
    return null;
}

/// How many parts a cull of `n` candidates would get (1: on the main lane).
export function cullParts(n: i32): i32 {
    return n < PARALLEL_CULL_MIN ? 1 : Parallel.size();
}
