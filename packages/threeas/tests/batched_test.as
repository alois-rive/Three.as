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
        });
    }
}
