// BatchedMesh bookkeeping and raycasting: rive . --test

import { Tests } from "rive/test";
import * as THREE from "../three/Three";

export class BatchedTests extends Tests {
    override run(): void {
        group("BatchedMesh", () => {
            test("geometries share buffers, instances reuse freed ids", (expect) => {
                const box = new THREE.BoxGeometry(1, 1, 1);
                const ball = new THREE.SphereGeometry(0.5, 8, 6);
                const b = new THREE.BatchedMesh(4, 1000, 2000);
                const g0 = b.addGeometry(box);
                const g1 = b.addGeometry(ball);
                expect.that(g1).is(1);
                const r = b.getGeometryRangeAt(g1);
                expect.that(r.vertexStart).is(24);
                expect.that(r.indexStart).is(36);
                // Indices are rebased onto the shared vertex buffer.
                expect.that(<f64>b.geometry.index!.array[36]).is(<f64>(ball.index!.array[0] + 24));
                const a = b.addInstance(g0);
                const c = b.addInstance(g1);
                expect.that(b.instanceCount).is(2);
                b.deleteInstance(a);
                expect.that(b.addInstance(g1)).is(a);
                expect.that(b.getGeometryIdAt(c)).is(1);
                b.addInstance(g0); b.addInstance(g0);
                expect.that(b.addInstance(g0)).is(-1);   // full
                expect.that(b.unusedVertexCount).is(1000 - 24 - ball.getAttribute("position")!.count);
            });
            test("bounds and raycasting follow instance matrices", (expect) => {
                const b = new THREE.BatchedMesh(2, 100, 100);
                const g = b.addGeometry(new THREE.BoxGeometry(1, 1, 1));
                b.addInstance(g);
                const id = b.addInstance(g);
                b.setMatrixAt(id, new THREE.Matrix4().makeTranslation(5, 0, 0));
                b.computeBoundingBox();
                expect.that(Math.abs(b.boundingBox!.max.x - 5.5) < 1e-6).is(true);
                b.updateMatrixWorld();
                const rc = new THREE.Raycaster(new THREE.Vector3(5.2, 0.1, 10), new THREE.Vector3(0, 0, -1));
                const hits = rc.intersectObject(b, false);
                expect.that(hits.length).is(1);
                expect.that(hits[0].batchId).is(id);
                expect.that(Math.abs(hits[0].distance - 9.5) < 1e-6).is(true);
                b.setVisibleAt(id, false);
                expect.that(rc.intersectObject(b, false).length).is(0);
            });
            test("colours default to white", (expect) => {
                const b = new THREE.BatchedMesh(1, 100, 100);
                const id = b.addInstance(b.addGeometry(new THREE.BoxGeometry()));
                const c = b.getColorAt(id, new THREE.Color());
                expect.that(c.r + c.g + c.b).is(3);
            });
            test("clone and copy deep-copy geometry, info, instances and bounds", (expect) => {
                const b = new THREE.BatchedMesh(4, 200, 300);
                const g0 = b.addGeometry(new THREE.BoxGeometry(1, 1, 1), 30, 50);
                const id0 = b.addInstance(g0);
                b.setMatrixAt(id0, new THREE.Matrix4().makeTranslation(4, 0, 0));
                b.setColorAt(id0, new THREE.Color(0xff0000));
                b.computeBoundingSphere();

                const clone = b.clone() as THREE.BatchedMesh;
                expect.that(clone.geometry !== b.geometry).is(true);
                expect.that(clone.geometryInfo.length).is(1);
                expect.that(clone.geometryInfo[0] !== b.geometryInfo[0]).is(true);
                expect.that(clone.unusedVertexCount).is(b.unusedVertexCount);
                expect.that(clone.unusedIndexCount).is(b.unusedIndexCount);
                expect.that(clone.instanceCount).is(1);
                expect.that(clone.boundingSphere != null && clone.boundingSphere !== b.boundingSphere).is(true);

                // Adding a new geometry and modifying an instance on the clone leaves source intact.
                const g1 = clone.addGeometry(new THREE.BoxGeometry(2, 2, 2));
                expect.that(g1).is(1);
                expect.that(b.geometryInfo.length).is(1);
                clone.setMatrixAt(id0, new THREE.Matrix4().makeTranslation(-4, 0, 0));
                clone.setColorAt(id0, new THREE.Color(0x00ff00));
                clone.updateMatrixWorld();
                b.updateMatrixWorld();

                const origPos = new THREE.Vector3().setFromMatrixPosition(b.getMatrixAt(id0, new THREE.Matrix4()));
                expect.that(Math.abs(origPos.x - 4) < 1e-6).is(true);
                expect.that(b.getColorAt(id0, new THREE.Color()).r).is(1);
                expect.that(clone.getColorAt(id0, new THREE.Color()).g).is(1);

                // Raycasting works on the clone at its moved position (off face diagonal).
                const rc = new THREE.Raycaster(new THREE.Vector3(-3.8, 0.1, 10), new THREE.Vector3(0, 0, -1));
                const hits = rc.intersectObject(clone, false);
                expect.that(hits.length).is(1);
                expect.that(hits[0].batchId).is(id0);
                expect.that(rc.intersectObject(b, false).length).is(0);

                // Explicit copy into a different-capacity BatchedMesh also deep-copies.
                const target = new THREE.BatchedMesh(1, 10, 10);
                target.copy(b);
                expect.that(target.geometry !== b.geometry).is(true);
                expect.that(target.maxInstanceCount).is(4);
                expect.that(target.instanceCount).is(1);
            });
            test("setGeometryAt validates capacity and nulls before mutating buffers", (expect) => {
                const b = new THREE.BatchedMesh(2, 100, 100);
                const box = new THREE.BoxGeometry(1, 1, 1);
                const g0 = b.addGeometry(box, 24, 36);
                const posBefore = b.geometry.getAttribute("position")!.array.slice();
                const idxBefore = b.geometry.index!.array.slice();

                // Geometry that fits vertex count (4 <= 24) but overflows index count (42 > 36).
                const badIdx = new THREE.BufferGeometry();
                badIdx.setAttribute("position", new THREE.Float32BufferAttribute(
                    [9, 9, 9, 8, 8, 8, 7, 7, 7, 6, 6, 6], 3));
                const tooMany: Array<i32> = [];
                for (let i = 0; i < 42; i++) tooMany.push(i % 4);
                badIdx.setIndex(tooMany);
                expect.that(b.setGeometryAt(g0, badIdx)).is(-1);
                // Vertex buffer must NOT be corrupted!
                const posAfter = b.geometry.getAttribute("position")!.array;
                let diff = 0;
                for (let i = 0; i < posBefore.length; i++) if (posAfter[i] != posBefore[i]) diff++;
                expect.that(diff).is(0);
                const idxAfter = b.geometry.index!.array;
                for (let i = 0; i < idxBefore.length; i++) if (idxAfter[i] != idxBefore[i]) diff++;
                expect.that(diff).is(0);

                // Missing position or missing index returns -1 without trapping.
                const noPos = new THREE.BufferGeometry();
                expect.that(b.setGeometryAt(g0, noPos)).is(-1);
                const noIdx = new THREE.BufferGeometry();
                noIdx.setAttribute("position", new THREE.Float32BufferAttribute([1, 2, 3], 3));
                expect.that(b.setGeometryAt(g0, noIdx)).is(-1);
            });
            test("raycast culls per-instance sphere and skips mega-buffer BVH", (expect) => {
                // Capacity > GeometryBVH.AUTO_TRIANGLES * 3 so a naive raycast would build a BVH over empty slots.
                const b = new THREE.BatchedMesh(4, 20000, 30000);
                const g = b.addGeometry(new THREE.BoxGeometry(1, 1, 1));
                const i0 = b.addInstance(g);
                const i1 = b.addInstance(g);
                b.setMatrixAt(i0, new THREE.Matrix4().makeTranslation(-10, 0, 0));
                b.setMatrixAt(i1, new THREE.Matrix4().makeTranslation(10, 0, 0));
                b.updateMatrixWorld();

                const hitRay = new THREE.Raycaster(new THREE.Vector3(10.1, 0.05, 5), new THREE.Vector3(0, 0, -1));
                const hits = hitRay.intersectObject(b, false);
                expect.that(hits.length).is(1);
                expect.that(hits[0].batchId).is(i1);
                expect.that(THREE.GeometryBVH.get(b.geometry) == null).is(true);
                expect.that(THREE.GeometryBVH.pending(b.geometry)).is(false);
                // Ray between instances misses both instance spheres.
                const missRay = new THREE.Raycaster(new THREE.Vector3(0, 0, 5), new THREE.Vector3(0, 0, -1));
                expect.that(missRay.intersectObject(b, false).length).is(0);
            });
        });
    }
}
