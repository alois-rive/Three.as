// ThreeLayout's pointer forwarding and ArtboardPicker: rive . --test
// ArtboardTextures need an artboard, which suites do not have: a picker
// subclass takes textures named "target" as targets instead.

import { Expect, Tests } from "rive/test";
import { PointerEvent } from "rive/events";
import { Vector } from "rive/vector";
import { clock } from "rive/os";
import { Jobs } from "rive/jobs";
import * as THREE from "../three/Three";

class TestPicker extends THREE.ArtboardPicker {
    picks: i32 = 0;
    override isTarget(map: THREE.Texture): bool { return map.name == "target"; }
    override mayHaveTargets(): bool { return true; }
    override pick(scene: THREE.Object3D, raycaster: THREE.Raycaster): bool {
        this.picks++;
        return super.pick(scene, raycaster);
    }
}

class TestLayout extends THREE.ThreeLayout {
    downs: i32 = 0;
    /// Moved to `moveTo` in onPointerDown (then invalidatePointer when `invalidate`).
    mover: THREE.Object3D? = null;
    moveTo: THREE.Vector3 = new THREE.Vector3();
    invalidate: bool = true;
    override onPointerDown(event: PointerEvent): void {
        this.downs++;
        const m = this.mover;
        if (m != null) {
            m.position.copy(this.moveTo);
            if (this.invalidate) this.invalidatePointer();
        }
    }
}

function ev(x: f64, y: f64): PointerEvent { return new PointerEvent(0, Vector.xy(<f32>x, <f32>y)); }

function ms(t0: f64): string { return (Math.round((clock() - t0) * 1e6) / 1000).toString(); }

function targetTexture(): THREE.Texture {
    const t = new THREE.Texture();
    t.name = "target";
    return t;
}

/// A 2 x 2 plane at z, mapping a target.
function targetPlane(z: f64): THREE.Mesh {
    const m = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), new THREE.MeshBasicMaterial({ map: targetTexture() }));
    m.position.z = z;
    return m;
}

/// A camera at z = 5 looking down -z, and a ray through NDC (x, y).
function aim(scene: THREE.Scene, x: f64, y: f64): THREE.Raycaster {
    const camera = new THREE.PerspectiveCamera(50, 1, 0.1, 100);
    camera.position.z = 5;
    scene.updateMatrixWorld();
    const r = new THREE.Raycaster();
    r.setFromCamera(new THREE.Vector2(x, y), camera);
    return r;
}

@editTime
function near(expect: Expect, actual: f64, want: f64): void {
    expect.that(Math.abs(actual - want)).lessThan(1e-4);
}

// ------------------------------------------------------------ stress scene

function skinned(x: f64): THREE.Object3D {
    const g = new THREE.CylinderGeometry(0.3, 0.3, 2, 64, 64);
    const pos = g.getAttribute("position")!;
    const n = pos.count;
    const idx: Array<f64> = [], w: Array<f64> = [];
    for (let i = 0; i < n; i++) {
        const t = (pos.getY(i) + 1) / 2;
        idx.push(0); idx.push(1); idx.push(0); idx.push(0);
        w.push(1 - t); w.push(t); w.push(0); w.push(0);
    }
    g.setAttribute("skinIndex", new THREE.Float32BufferAttribute(idx, 4));
    g.setAttribute("skinWeight", new THREE.Float32BufferAttribute(w, 4));
    const root = new THREE.Bone();
    root.position.y = -1;
    const tip = new THREE.Bone();
    tip.position.y = 2;
    root.add(tip);
    const mesh = new THREE.SkinnedMesh(g, new THREE.MeshStandardMaterial());
    const group = new THREE.Group();
    group.position.set(x, 0, 1);
    group.add(root);
    group.add(mesh);
    group.updateMatrixWorld(true);
    mesh.bind(new THREE.Skeleton([root, tip]));
    tip.rotation.z = 0.3;
    return group;
}

/// 3000 boxes, a sphere of 1M triangles at the centre, 4 skinned
/// cylinders, 10000 instances and 100000 points; with `withTargets`, a
/// small target panel up right (unoccluded) and a big one behind the
/// sphere. Camera at z = 6, layout 800 x 600: the sphere is under
/// (400, 300), the panel under (668, 139).
// The 1M-triangle sphere, shared by the stress cases (its tree builds in a
// job while they run).
let _bigSphere: THREE.BufferGeometry? = null;

function bigSphere(): THREE.BufferGeometry {
    let g = _bigSphere;
    if (g == null) {
        g = new THREE.SphereGeometry(1.5, 1000, 500);
        _bigSphere = g;
    }
    return g!;
}

function stress(l: THREE.ThreeLayout, withTargets: bool, sharedSphere: bool = true): void {
    l.resize(800, 600, 1);
    const scene = l.scene;
    const box = new THREE.BoxGeometry(0.2, 0.2, 0.2);
    const mats: Array<THREE.Material> = [];
    for (let i = 0; i < 8; i++) mats.push(new THREE.MeshStandardMaterial());
    for (let i = 0; i < 3000; i++) {
        const m = new THREE.Mesh(box, mats[i % 8]);
        m.position.set(<f64>(i % 60) * 0.3 - 9, <f64>((i / 60) % 50) * 0.3 - 7.5, -4);
        scene.add(m);
    }
    const big = new THREE.Mesh(sharedSphere ? bigSphere() : new THREE.SphereGeometry(1.5, 1000, 500),
        new THREE.MeshStandardMaterial());
    big.position.set(0, 0, -1);
    scene.add(big);
    for (let i = 0; i < 4; i++) scene.add(skinned(<f64>i * 1.5 - 2.25));
    const im = new THREE.InstancedMesh(new THREE.IcosahedronGeometry(0.05, 0), new THREE.MeshLambertMaterial(), 10000);
    const d = new THREE.Object3D();
    for (let i = 0; i < 10000; i++) {
        d.position.set(<f64>(i % 100) * 0.1 - 5, <f64>(i / 100) * 0.1 - 5, -2);
        d.updateMatrix();
        im.setMatrixAt(i, d.matrix);
    }
    scene.add(im);
    const pts: Array<f64> = [];
    for (let i = 0; i < 100000; i++) {
        pts.push(<f64>(i % 300) * 0.03 - 4.5); pts.push(<f64>((i / 300) % 300) * 0.03 - 4.5); pts.push(-3);
    }
    const pg = new THREE.BufferGeometry();
    pg.setAttribute("position", new THREE.Float32BufferAttribute(pts, 3));
    scene.add(new THREE.Points(pg, new THREE.PointsMaterial()));
    const panel = new THREE.Mesh(new THREE.PlaneGeometry(2, 1), new THREE.MeshBasicMaterial());
    if (withTargets) (panel.material as THREE.MeshBasicMaterial).map = targetTexture();
    panel.position.set(2.5, 1.5, 0);
    scene.add(panel);
    if (withTargets) {
        const back = new THREE.Mesh(new THREE.PlaneGeometry(6, 6), new THREE.MeshBasicMaterial({ map: targetTexture() }));
        back.position.z = -2.5;
        scene.add(back);
        l.picker = new TestPicker();
    }
    l.camera.position.z = 6;
}

export class PointerTests extends Tests {
    override run(): void {
        group("ArtboardPicker", () => {
            test("finds the target and its uv (offset and repeat applied)", (expect) => {
                const scene = new THREE.Scene();
                const plane = targetPlane(0);
                const map = (plane.material as THREE.MeshBasicMaterial).map!;
                map.repeat.set(2, 1);
                map.offset.set(0.1, 0);
                scene.add(plane);
                const other = new THREE.Mesh(new THREE.BoxGeometry());
                other.position.set(5, 0, 0);
                scene.add(other);
                const p = new TestPicker();
                const r = aim(scene, 0, 0);
                expect.that(p.pick(scene, r)).is(true);
                expect.that(p.object === plane).is(true);
                near(expect, p.uv.x, 0.5 * 2 + 0.1);
                near(expect, p.uv.y, 0.5);
                near(expect, p.distance, 5);
                expect.that(p.candidateCount).is(1);
            });
            test("a mesh in front blocks, a points cloud and a line do not", (expect) => {
                const scene = new THREE.Scene();
                scene.add(targetPlane(0));
                const pg = new THREE.BufferGeometry();
                pg.setAttribute("position", new THREE.Float32BufferAttribute([0, 0, 1, 0.01, 0, 1], 3));
                scene.add(new THREE.Points(pg));
                const lg = new THREE.BufferGeometry();
                lg.setAttribute("position", new THREE.Float32BufferAttribute([-1, 0, 2, 1, 0, 2], 3));
                scene.add(new THREE.Line(lg));
                const p = new TestPicker();
                // The points and the line are within their thresholds of the ray.
                expect.that(<f64>aim(scene, 0, 0).intersectObject(scene).length).greaterThan(2);
                expect.that(p.pick(scene, aim(scene, 0, 0))).is(true);
                const box = new THREE.Mesh(new THREE.BoxGeometry(0.5, 0.5, 0.5));
                box.position.z = 1;
                scene.add(box);
                expect.that(p.pick(scene, aim(scene, 0, 0))).is(false);
                // Beside the box, still found.
                expect.that(p.pick(scene, aim(scene, 0.3, 0))).is(true);
            });
            test("a mesh behind the target does not block", (expect) => {
                const scene = new THREE.Scene();
                scene.add(targetPlane(0));
                const back = new THREE.Mesh(new THREE.PlaneGeometry(4, 4));
                back.position.z = -1;
                scene.add(back);
                const p = new TestPicker();
                expect.that(p.pick(scene, aim(scene, 0, 0))).is(true);
            });
            test("nothing is raycast without a candidate", (expect) => {
                const scene = new THREE.Scene();
                for (let i = 0; i < 20; i++) scene.add(new THREE.Mesh(new THREE.BoxGeometry()));
                const p = new TestPicker();
                expect.that(p.pick(scene, aim(scene, 0, 0))).is(false);
                expect.that(p.candidateCount).is(0);
                expect.that(p.raycasts).is(0);
                // And no walk at all without targets alive (no ArtboardTexture here).
                const q = new THREE.ArtboardPicker();
                scene.add(targetPlane(0));
                expect.that(q.pick(scene, aim(scene, 0, 0))).is(false);
                expect.that(q.rebuilds).is(0);
                expect.that(q.raycasts).is(0);
            });
            test("a miss of every candidate raycasts the candidates only", (expect) => {
                const scene = new THREE.Scene();
                const plane = targetPlane(0);
                plane.position.x = 3;
                scene.add(plane);
                for (let i = 0; i < 20; i++) scene.add(new THREE.Mesh(new THREE.BoxGeometry()));
                const p = new TestPicker();
                expect.that(p.pick(scene, aim(scene, 0, 0))).is(false);
                expect.that(p.raycasts).is(1);
            });
            test("invisible occluders and targets are ignored", (expect) => {
                const scene = new THREE.Scene();
                const plane = targetPlane(0);
                scene.add(plane);
                const group = new THREE.Group();
                const box = new THREE.Mesh(new THREE.BoxGeometry(0.5, 0.5, 0.5));
                box.position.z = 1;
                group.add(box);
                scene.add(group);
                const p = new TestPicker();
                expect.that(p.pick(scene, aim(scene, 0, 0))).is(false);
                group.visible = false;
                expect.that(p.pick(scene, aim(scene, 0, 0))).is(true);
                plane.visible = false;
                expect.that(p.pick(scene, aim(scene, 0, 0))).is(false);
            });
            test("a part of the candidate with another material hides what is behind", (expect) => {
                const scene = new THREE.Scene();
                const box = new THREE.Mesh(new THREE.BoxGeometry(1, 1, 1));
                for (let i = 0; i < 6; i++) {
                    const m = new THREE.MeshBasicMaterial();
                    if (i == 5) m.map = targetTexture();
                    box.materials.push(m);
                }
                scene.add(box);
                // +z (index 4) faces the camera: not a target.
                const p = new TestPicker();
                expect.that(p.pick(scene, aim(scene, 0, 0))).is(false);
                expect.that(p.candidateCount).is(1);
                // Turned around, the -z face (5) faces it.
                box.rotation.y = Math.PI;
                expect.that(p.pick(scene, aim(scene, 0, 0))).is(true);
            });
            test("occluders restricts what can hide a target", (expect) => {
                const scene = new THREE.Scene();
                scene.add(targetPlane(0));
                const box = new THREE.Mesh(new THREE.BoxGeometry(0.5, 0.5, 0.5));
                box.position.z = 1;
                scene.add(box);
                const p = new TestPicker();
                expect.that(p.pick(scene, aim(scene, 0, 0))).is(false);
                p.occluders = new THREE.Group();
                expect.that(p.pick(scene, aim(scene, 0, 0))).is(true);
            });
            test("candidates follow invalidate()", (expect) => {
                const scene = new THREE.Scene();
                const plane = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), new THREE.MeshBasicMaterial());
                scene.add(plane);
                const p = new TestPicker();
                expect.that(p.pick(scene, aim(scene, 0, 0))).is(false);
                (plane.material as THREE.MeshBasicMaterial).map = targetTexture();
                expect.that(p.pick(scene, aim(scene, 0, 0))).is(false);   // the list is kept
                p.invalidate();
                expect.that(p.pick(scene, aim(scene, 0, 0))).is(true);
            });
            test("occluded() stops at meshes and sprites", (expect) => {
                const scene = new THREE.Scene();
                const pg = new THREE.BufferGeometry();
                pg.setAttribute("position", new THREE.Float32BufferAttribute([0, 0, 1], 3));
                scene.add(new THREE.Points(pg));
                const r = aim(scene, 0, 0);
                expect.that(THREE.ArtboardPicker.occluded(scene, r)).is(false);
                const box = new THREE.Mesh(new THREE.BoxGeometry(0.5, 0.5, 0.5));
                scene.add(box);
                scene.updateMatrixWorld();
                expect.that(THREE.ArtboardPicker.occluded(scene, r)).is(true);
                r.far = 4;   // the box's front is 4.75 away
                expect.that(THREE.ArtboardPicker.occluded(scene, r)).is(false);
                // The any-hit mode is off again: a raycast lists both faces.
                r.far = Infinity;
                expect.that(<f64>r.intersectObject(box).length).is(2);
            });
        });

        group("GeometryBVH", () => {
            test("a tree finds what testing every triangle finds", (expect) => {
                const g = new THREE.TorusKnotGeometry(1, 0.3, 256, 32);   // 16384 triangles
                const mesh = new THREE.Mesh(g, new THREE.MeshBasicMaterial({ side: THREE.DoubleSide }));
                mesh.rotation.set(0.3, 0.2, 0.1);
                mesh.updateMatrixWorld();
                const rays: Array<THREE.Raycaster> = [];
                const want: Array<Array<THREE.Intersection>> = [];
                for (let i = 0; i < 24; i++) {
                    const a = <f64>i * 0.7, b = <f64>i * 0.3;
                    const origin = new THREE.Vector3(Math.cos(a) * 4, Math.sin(b) * 2, Math.sin(a) * 4);
                    const dir = new THREE.Vector3(Math.cos(<f64>i) * 0.4, Math.sin(<f64>i * 1.3) * 0.4, 0).sub(origin).normalize();
                    const r = new THREE.Raycaster(origin, dir);
                    rays.push(r);
                }
                // Axis-parallel rays too (the slab test's special case).
                rays.push(new THREE.Raycaster(new THREE.Vector3(0.5, 0, 5), new THREE.Vector3(0, 0, -1)));
                rays.push(new THREE.Raycaster(new THREE.Vector3(0, 1.1, 5), new THREE.Vector3(0, 0, -1)));
                THREE.GeometryBVH.dispose(g);
                expect.that(THREE.GeometryBVH.get(g) == null).is(true);
                // Without a tree (the first raycast only starts its job).
                for (let i = 0; i < rays.length; i++) want.push(rays[i].intersectObject(mesh));
                expect.that(THREE.GeometryBVH.build(g) != null).is(true);
                expect.that(THREE.GeometryBVH.get(g) != null).is(true);
                let total = 0;
                for (let i = 0; i < rays.length; i++) {
                    const got = rays[i].intersectObject(mesh);
                    expect.that(got.length).is(want[i].length);
                    for (let k = 0; k < got.length && k < want[i].length; k++) {
                        expect.that(Math.abs(got[k].distance - want[i][k].distance)).lessThan(1e-9);
                        expect.that(got[k].faceIndex).is(want[i][k].faceIndex);
                    }
                    total += got.length;
                }
                expect.that(total).greaterThan(20);
            });
            test("a tree follows its attributes and draw range", (expect) => {
                const g = new THREE.SphereGeometry(1, 128, 64);   // 16002 triangles
                const mesh = new THREE.Mesh(g);
                mesh.updateMatrixWorld();
                const r = new THREE.Raycaster(new THREE.Vector3(0.1, 0.2, 5), new THREE.Vector3(0, 0, -1));
                const d0 = r.intersectObject(mesh)[0].distance;   // every triangle
                expect.that(THREE.GeometryBVH.build(g) != null).is(true);
                near(expect, r.intersectObject(mesh)[0].distance, d0);
                // Moved vertices: the tree is stale until rebuilt.
                const pos = g.getAttribute("position")!;
                for (let i = 0; i < pos.count; i++) pos.setZ(i, pos.getZ(i) + 1);
                pos.needsUpdate = true;
                expect.that(THREE.GeometryBVH.get(g) == null).is(true);
                near(expect, r.intersectObject(mesh)[0].distance, d0 - 1);
                THREE.GeometryBVH.build(g);
                expect.that(THREE.GeometryBVH.get(g) != null).is(true);
                near(expect, r.intersectObject(mesh)[0].distance, d0 - 1);
                // A draw range of the first half (the top): the ray through the bottom misses.
                const low = new THREE.Raycaster(new THREE.Vector3(0.1, -0.5, 5), new THREE.Vector3(0, 0, -1));
                expect.that(low.intersectObject(mesh).length).is(1);
                g.setDrawRange(0, g.index!.count / 2 - (g.index!.count / 2) % 3);
                expect.that(low.intersectObject(mesh).length).is(0);
                g.dispose();
                expect.that(THREE.GeometryBVH.get(g) == null).is(true);
            });
            test("an occlusion test counts a geometry whose tree is building", (expect) => {
                const g = new THREE.SphereGeometry(1, 128, 64);
                const mesh = new THREE.Mesh(g);
                const scene = new THREE.Scene();
                scene.add(mesh);
                const r = aim(scene, 0.5, 0.5);   // past the sphere, through its bounding box
                expect.that(r.intersectObject(mesh).length).is(0);   // starts the job
                if (THREE.GeometryBVH.pending(g)) {
                    expect.that(THREE.ArtboardPicker.occluded(scene, r)).is(true);
                }
                THREE.GeometryBVH.build(g);
                expect.that(THREE.ArtboardPicker.occluded(scene, r)).is(false);
            });
            test("skinned meshes raycast from posed vertices", (expect) => {
                const group = skinned(0);
                const mesh = group.children[1] as THREE.SkinnedMesh;
                group.updateMatrixWorld(true);
                const r = new THREE.Raycaster(new THREE.Vector3(0.05, 0, 5), new THREE.Vector3(0, 0, -1));
                const hits = r.intersectObject(mesh);
                expect.that(hits.length).is(1);
                // On the triangle as getVertexPosition poses it.
                const face = hits[0].face!;
                const a = mesh.getVertexPosition(face.a, new THREE.Vector3()).applyMatrix4(mesh.matrixWorld);
                const b = mesh.getVertexPosition(face.b, new THREE.Vector3()).applyMatrix4(mesh.matrixWorld);
                const c = mesh.getVertexPosition(face.c, new THREE.Vector3()).applyMatrix4(mesh.matrixWorld);
                const n = THREE.Triangle.getNormal(a, b, c, new THREE.Vector3());
                near(expect, hits[0].point.clone().sub(a).dot(n), 0);
                expect.that(THREE.Triangle.containsPoint(hits[0].point, a, b, c)).is(true);
            });
        });

        group("ThreeLayout pointer", () => {
            test("forwards through the picker and reuses a move's answer", (expect) => {
                const l = new TestLayout();
                l.resize(400, 400, 1);
                l.camera.position.z = 5;
                l.scene.add(targetPlane(0));
                const p = new TestPicker();
                l.picker = p;
                l.pointerMove(ev(200, 200));
                expect.that(p.texture != null).is(true);
                near(expect, p.uv.x, 0.5);
                l.pointerMove(ev(200, 200));
                expect.that(p.picks).is(1);
                l.pointerMove(ev(210, 200));
                expect.that(p.picks).is(2);
                // A press and a release always pick.
                l.pointerDown(ev(210, 200));
                expect.that(p.picks).is(3);
                l.pointerUp(ev(210, 200));
                expect.that(p.picks).is(4);
                // A new frame picks again.
                l.advance(0.016);
                l.pointerMove(ev(210, 200));
                expect.that(p.picks).is(5);
            });
            test("an object moved in a pointer hook blocks once invalidated", (expect) => {
                const l = new TestLayout();
                l.resize(400, 400, 1);
                l.camera.position.z = 5;
                l.scene.add(targetPlane(0));
                const box = new THREE.Mesh(new THREE.BoxGeometry(0.5, 0.5, 0.5));
                box.position.set(3, 0, 1);
                l.scene.add(box);
                l.picker = new TestPicker();
                l.mover = box;
                l.moveTo.set(0, 0, 1);
                l.pointerMove(ev(200, 200));
                expect.that(l.picker.texture != null).is(true);
                l.pointerDown(ev(200, 200));   // moves the box in front
                l.pointerMove(ev(200, 200));
                expect.that(l.picker.texture == null).is(true);
                expect.that(l.downs).is(1);
                l.pointerUp(ev(200, 200));
            });
            test("matrices are updated once a frame", (expect) => {
                const l = new TestLayout();
                l.resize(400, 400, 1);
                l.camera.position.z = 5;
                const plane = targetPlane(0);
                l.scene.add(plane);
                l.picker = new TestPicker();
                l.pointerMove(ev(200, 200));
                expect.that(l.picker.texture != null).is(true);
                // Moved without invalidating: the next event of the frame
                // still sees the old matrices...
                plane.position.x = 3;
                l.pointerMove(ev(201, 200));
                expect.that(l.picker.texture != null).is(true);
                // ...the next frame's sees the move.
                l.advance(0.016);
                l.pointerMove(ev(201, 200));
                expect.that(l.picker.texture == null).is(true);
            });
        });

        // Timings (console): the per-event cost in a big scene. Each case
        // builds the scene (about 0.3 s interpreted) and must stay in the
        // case's budget.
        group("pointer stress", () => {
            test("no ArtboardTexture: move and press over a 1M-triangle mesh", (expect) => {
                const l = new TestLayout();
                stress(l, false);
                let t0 = clock();
                l.pointerMove(ev(400, 300));
                console.log("pointer stress: no target, move " + ms(t0));
                t0 = clock();
                l.pointerMove(ev(401, 300));
                console.log("pointer stress: no target, move again " + ms(t0));
                t0 = clock();
                l.pointerDown(ev(401, 300));
                console.log("pointer stress: no target, down " + ms(t0));
                l.pointerUp(ev(401, 300));
                expect.that(l.downs).is(1);
                expect.that(l.picker.raycasts).is(0);
                // For the cases below.
                THREE.GeometryBVH.request(bigSphere());
            });
            test("targets: over the unoccluded panel", (expect) => {
                const l = new TestLayout();
                stress(l, true);
                let t0 = clock();
                l.pointerMove(ev(668, 139));
                console.log("pointer stress: panel, first move (walk + bounds) " + ms(t0));
                t0 = clock();
                l.pointerMove(ev(669, 139));
                console.log("pointer stress: panel, move " + ms(t0));
                t0 = clock();
                l.pointerDown(ev(669, 139));
                console.log("pointer stress: panel, down " + ms(t0) + " raycasts " + l.picker.raycasts.toString());
                l.pointerUp(ev(669, 139));
                expect.that(l.picker.texture != null).is(true);
                l.advance(0.016);
                t0 = clock();
                l.pointerMove(ev(670, 139));
                console.log("pointer stress: panel, next frame move (matrices + walk) " + ms(t0));
            });
            test("targets: over the sphere hiding the back panel, its tree building", (expect) => {
                const l = new TestLayout();
                stress(l, true, false);
                let t0 = clock();
                l.pointerMove(ev(400, 300));
                console.log("pointer stress: behind sphere, first move (tree job started) " + ms(t0));
                expect.that(l.picker.texture == null).is(true);
                t0 = clock();
                l.pointerMove(ev(401, 300));
                console.log("pointer stress: behind sphere, move while the tree builds " + ms(t0));
                expect.that(l.picker.texture == null).is(true);
            });
            test("targets: over the sphere hiding the back panel, its tree built", (expect) => {
                const l = new TestLayout();
                stress(l, true);
                const sphere = bigSphere();
                // Requested two cases ago: done by now compiled; interpreted
                // it may still run (about 1.6 s).
                let t0 = clock();
                while (THREE.GeometryBVH.get(sphere) == null && clock() - t0 < 1) {}
                const tree = THREE.GeometryBVH.get(sphere);
                console.log("pointer stress: tree of 1M triangles " + (tree != null ? "ready" : "still building")
                    + " after waiting " + ms(t0) + " (job threads " + Jobs.threads().toString() + ")"
                    + (tree != null ? ", " + (tree.data!.nodes.length / 2).toString() + " nodes" : ""));
                if (tree == null) return;
                t0 = clock();
                l.pointerMove(ev(400, 300));
                console.log("pointer stress: behind sphere, first move (matrices + walk) " + ms(t0));
                t0 = clock();
                l.pointerMove(ev(401, 300));
                console.log("pointer stress: behind sphere, move " + ms(t0) + " raycasts " + l.picker.raycasts.toString());
                t0 = clock();
                l.pointerDown(ev(401, 300));
                console.log("pointer stress: behind sphere, down " + ms(t0));
                l.pointerUp(ev(401, 300));
                expect.that(l.picker.texture == null).is(true);
                // Between the sphere and the panel's edge: the panel, past the sphere's box.
                l.pointerMove(ev(565, 304));
                expect.that(l.picker.texture != null).is(true);
                t0 = clock();
                l.raycaster.intersectObject(l.scene.children[3000], false);
                console.log("pointer stress: Raycaster.intersectObject(sphere) with its tree " + ms(t0));
            });
            test("GeometryBVH.build of 250k triangles", (expect) => {
                const g = new THREE.SphereGeometry(1, 500, 250);
                const t0 = clock();
                THREE.GeometryBVH.build(g);
                console.log("pointer stress: GeometryBVH.build, 250k triangles, here " + ms(t0));
                expect.that(THREE.GeometryBVH.get(g) != null).is(true);
            });
            test("targets: over the boxes, beside the panels", (expect) => {
                const l = new TestLayout();
                stress(l, true);
                let t0 = clock();
                l.pointerMove(ev(30, 580));
                console.log("pointer stress: beside, first move " + ms(t0));
                t0 = clock();
                l.pointerMove(ev(31, 580));
                console.log("pointer stress: beside, move " + ms(t0) + " raycasts " + l.picker.raycasts.toString());
                expect.that(l.picker.texture == null).is(true);
            });
        });
    }
}
