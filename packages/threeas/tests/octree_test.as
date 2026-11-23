// Octree and OctreeHelper (three/addons/math/Octree,
// three/addons/helpers/OctreeHelper): rive . --test

import { Tests } from "rive/test";
import * as THREE from "../three/Three";
import { Capsule } from "../three/addons/math/Capsule";
import { Octree } from "../three/addons/math/Octree";
import { OctreeHelper } from "../three/addons/helpers/OctreeHelper";

function near(a: f64, b: f64, eps: f64 = 1e-9): bool { return Math.abs(a - b) < eps; }

function v(x: f64, y: f64, z: f64): THREE.Vector3 { return new THREE.Vector3(x, y, z); }

// The triangle (0,0,0) (0,0,1) (1,0,0), facing +y.
function floorTriangle(): THREE.Triangle {
    return new THREE.Triangle(v(0, 0, 0), v(0, 0, 1), v(1, 0, 0));
}

// A 10 x 10 floor at y = 0, facing +y (PlaneGeometry turned as games do).
function floorMesh(segments: i32 = 1): THREE.Mesh {
    const g = new THREE.PlaneGeometry(10, 10, segments, segments);
    g.rotateX(-Math.PI / 2);
    return new THREE.Mesh(g);
}

// The distinct triangles in the leaves, and checks on each node.
class Walk {
    triangles: Array<THREE.Triangle> = [];
    nodes: i32 = 0;
    maxDepth: i32 = 0;
    overfull: i32 = 0;   // leaves over trianglesPerLeaf below maxLevel
    mixed: i32 = 0;      // nodes with both triangles and subtrees
}

function walk(tree: Octree, depth: i32, w: Walk): void {
    for (let i = 0; i < tree.subTrees.length; i++) {
        const s = tree.subTrees[i];
        w.nodes++;
        if (depth + 1 > w.maxDepth) w.maxDepth = depth + 1;
        if (s.triangles.length > 0 && s.subTrees.length > 0) w.mixed++;
        if (s.triangles.length > s.trianglesPerLeaf && depth < s.maxLevel) w.overfull++;
        for (let j = 0; j < s.triangles.length; j++) {
            if (w.triangles.indexOf(s.triangles[j]) == -1) w.triangles.push(s.triangles[j]);
        }
        walk(s, depth + 1, w);
    }
}

export class OctreeTests extends Tests {
    override run(): void {
        group("octree", () => {
            test("Box3.intersectsTriangle (the split's test)", (expect) => {
                const b = new THREE.Box3(v(0, 0, 0), v(1, 1, 1));
                // Inside, through, touching a face.
                expect.that(b.intersectsTriangle(new THREE.Triangle(v(0.2, 0.2, 0.2), v(0.8, 0.2, 0.2), v(0.2, 0.8, 0.2)))).is(true);
                expect.that(b.intersectsTriangle(new THREE.Triangle(v(-5, 0.5, -5), v(-5, 0.5, 5), v(5, 0.5, 0)))).is(true);
                expect.that(b.intersectsTriangle(new THREE.Triangle(v(0, 1, 0), v(0, 1, 1), v(1, 1, 0)))).is(true);
                // Beside (a box axis), beyond the corner (the normal), cutting
                // the corner, and a wall past the corner (the normal).
                expect.that(b.intersectsTriangle(new THREE.Triangle(v(1.1, 0, 0), v(2, 0, 0), v(2, 1, 0)))).is(false);
                expect.that(b.intersectsTriangle(new THREE.Triangle(v(3.5, 0, 0), v(0, 3.5, 0), v(0, 0, 3.5)))).is(false);
                expect.that(b.intersectsTriangle(new THREE.Triangle(v(3.5, 0, 0), v(0, 3.5, 0), v(0, 0, 1.5)))).is(true);
                expect.that(b.intersectsTriangle(new THREE.Triangle(v(2.2, 0, -1), v(0, 2.2, -1), v(0, 2.2, 2)))).is(false);
                expect.that(new THREE.Box3().intersectsTriangle(floorTriangle())).is(false);   // empty
            });

            test("triangleSphereIntersect: face, edge, miss", (expect) => {
                const o = new Octree();
                const t = floorTriangle();
                const face = o.triangleSphereIntersect(new THREE.Sphere(v(0.25, 0.1, 0.25), 0.3), t);
                expect.that(face != null).is(true);
                expect.that(near(face!.depth, 0.2)).is(true);
                expect.that(near(face!.normal.y, 1)).is(true);
                expect.that(near(face!.point.y, 0)).is(true);
                expect.that(near(face!.point.x, 0.25)).is(true);

                const edge = o.triangleSphereIntersect(new THREE.Sphere(v(-0.2, 0, 0.5), 0.3), t);
                expect.that(edge != null).is(true);
                expect.that(near(edge!.depth, 0.1)).is(true);
                expect.that(near(edge!.normal.x, -1)).is(true);
                expect.that(near(edge!.point.z, 0.5)).is(true);

                expect.that(o.triangleSphereIntersect(new THREE.Sphere(v(0.25, 0.5, 0.25), 0.3), t) == null).is(true);
                expect.that(o.triangleSphereIntersect(new THREE.Sphere(v(-0.5, 0, 0.5), 0.3), t) == null).is(true);
            });

            test("triangleCapsuleIntersect: face, edge, miss", (expect) => {
                const o = new Octree();
                const t = floorTriangle();
                // Standing in the triangle, 0.1 deep.
                const face = o.triangleCapsuleIntersect(new Capsule(v(0.25, 0.25, 0.25), v(0.25, 1, 0.25), 0.35), t);
                expect.that(face != null).is(true);
                expect.that(near(face!.depth, 0.1)).is(true);
                expect.that(near(face!.normal.y, 1)).is(true);
                expect.that(near(face!.point.y, 0.35)).is(true);
                // Upright beside the edge x = 0, 0.2 away.
                const edge = o.triangleCapsuleIntersect(new Capsule(v(-0.2, -1, 0.5), v(-0.2, 1, 0.5), 0.3), t);
                expect.that(edge != null).is(true);
                expect.that(near(edge!.depth, 0.1)).is(true);
                expect.that(near(edge!.normal.x, -1)).is(true);
                expect.that(near(edge!.point.x, 0)).is(true);
                expect.that(near(edge!.point.z, 0.5)).is(true);
                // Above, and beside out of reach.
                expect.that(o.triangleCapsuleIntersect(new Capsule(v(0.25, 0.5, 0.25), v(0.25, 1, 0.25), 0.35), t) == null).is(true);
                expect.that(o.triangleCapsuleIntersect(new Capsule(v(-0.5, -1, 0.5), v(-0.5, 1, 0.5), 0.3), t) == null).is(true);
            });

            test("triangleBoxIntersect", (expect) => {
                const o = new Octree();
                const t = floorTriangle();
                const r = o.triangleBoxIntersect(new THREE.Box3(v(0.1, -0.1, 0.1), v(0.3, 0.2, 0.3)), t);
                expect.that(r != null).is(true);
                expect.that(near(r!.depth, 0.1)).is(true);
                expect.that(near(r!.normal.y, 1)).is(true);
                expect.that(near(r!.point.x, 0.3) && near(r!.point.y, 0) && near(r!.point.z, 0.3)).is(true);
                expect.that(o.triangleBoxIntersect(new THREE.Box3(v(0.1, 0.1, 0.1), v(0.3, 0.2, 0.3)), t) == null).is(true);
                expect.that(o.triangleBoxIntersect(new THREE.Box3(v(0.8, -0.1, 0.8), v(1, 0.1, 1)), t) == null).is(true);
            });

            test("sphere, capsule and box against a floor", (expect) => {
                const o = new Octree().fromGraphNode(floorMesh());
                const s = o.sphereIntersect(new THREE.Sphere(v(1, 0.3, 1), 0.5));
                expect.that(s != null).is(true);
                expect.that(near(s!.depth, 0.2)).is(true);
                expect.that(near(s!.normal.y, 1)).is(true);
                expect.that(o.sphereIntersect(new THREE.Sphere(v(1, 0.6, 1), 0.5)) == null).is(true);

                const player = new Capsule(v(2, 0.25, 1), v(2, 1, 1), 0.35);
                const c = o.capsuleIntersect(player);
                expect.that(c != null).is(true);
                expect.that(near(c!.depth, 0.1)).is(true);
                expect.that(near(c!.normal.y, 1)).is(true);
                expect.that(player.start.y).is(0.25);   // the argument is not moved
                expect.that(o.capsuleIntersect(new Capsule(v(2, 0.4, 1), v(2, 1, 1), 0.35)) == null).is(true);
                // Off the floor's edge.
                expect.that(o.capsuleIntersect(new Capsule(v(6, 0.2, 1), v(6, 1, 1), 0.35)) == null).is(true);

                const b = o.boxIntersect(new THREE.Box3(v(1, -0.05, 1), v(2, 0.5, 2)));
                expect.that(b != null).is(true);
                expect.that(near(b!.depth, 0.05)).is(true);
                expect.that(near(b!.normal.y, 1)).is(true);
                expect.that(o.boxIntersect(new THREE.Box3(v(1, 0.1, 1), v(2, 0.5, 2))) == null).is(true);
            });

            test("capsule against a corner: pushed out of both walls", (expect) => {
                // Two walls, x = 0 facing +x and z = 0 facing +z, and a floor.
                const scene = new THREE.Group();
                const wx = new THREE.Mesh(new THREE.PlaneGeometry(4, 4));
                wx.rotation.y = Math.PI / 2;
                wx.position.set(0, 2, 2);
                const wz = new THREE.Mesh(new THREE.PlaneGeometry(4, 4));
                wz.position.set(2, 2, 0);
                scene.add(wx);
                scene.add(wz);
                const o = new Octree().fromGraphNode(scene);
                const player = new Capsule(v(0.3, 1, 0.3), v(0.3, 2, 0.3), 0.35);
                const r = o.capsuleIntersect(player);
                expect.that(r != null).is(true);
                player.translate(r!.normal.multiplyScalar(r!.depth));
                expect.that(near(player.start.x, 0.35, 1e-6)).is(true);
                expect.that(near(player.start.z, 0.35, 1e-6)).is(true);
                expect.that(near(player.start.y, 1, 1e-6)).is(true);
                expect.that(o.capsuleIntersect(player) == null || o.capsuleIntersect(player)!.depth < 1e-6).is(true);
            });

            test("rayIntersect: nearest front face", (expect) => {
                const scene = new THREE.Group();
                scene.add(floorMesh());
                const shelf = floorMesh();
                shelf.position.y = 2;
                shelf.scale.set(0.2, 1, 0.2);   // 2 x 2 at y = 2
                scene.add(shelf);
                const o = new Octree().fromGraphNode(scene);

                const down = o.rayIntersect(new THREE.Ray(v(0.5, 5, 0.5), v(0, -1, 0)));
                expect.that(down != null).is(true);
                expect.that(near(down!.distance, 3)).is(true);
                expect.that(near(down!.position.y, 2)).is(true);
                expect.that(near(down!.position.x, 0.5)).is(true);

                const beside = o.rayIntersect(new THREE.Ray(v(3, 5, 3), v(0, -1, 0)));
                expect.that(beside != null).is(true);
                expect.that(near(beside!.distance, 5)).is(true);
                expect.that(near(beside!.triangle.a.y, 0)).is(true);

                // From below: back faces are not hit (three.js culls them).
                expect.that(o.rayIntersect(new THREE.Ray(v(3, -5, 3), v(0, 1, 0))) == null).is(true);
                expect.that(o.rayIntersect(new THREE.Ray(v(30, 5, 3), v(0, -1, 0))) == null).is(true);
            });

            test("build and split: leaves, levels, each triangle once", (expect) => {
                const o = new Octree().fromGraphNode(floorMesh(8));   // 128 triangles
                expect.that(o.triangles.length).is(0);
                expect.that(o.box != null).is(true);
                expect.that(near(o.box!.min.x, -5.01)).is(true);
                expect.that(near(o.box!.max.x, 5)).is(true);
                expect.that(near(o.bounds.min.x, -5)).is(true);
                const w = new Walk();
                walk(o, 0, w);
                expect.that(w.triangles.length).is(128);
                expect.that(w.overfull).is(0);
                expect.that(w.mixed).is(0);
                expect.that(w.maxDepth > 1).is(true);

                // Within trianglesPerLeaf: one split, no deeper.
                const few = new Octree();
                few.addTriangle(floorTriangle());
                few.addTriangle(new THREE.Triangle(v(0, 0, 1), v(1, 0, 1), v(1, 0, 0)));
                few.build();
                const w2 = new Walk();
                walk(few, 0, w2);
                expect.that(w2.maxDepth).is(1);
                expect.that(w2.triangles.length).is(2);
                expect.that(few.subTrees.length <= 8 && few.subTrees.length > 0).is(true);

                // maxLevel 0: the root splits once, leaves may stay full.
                const flat = new Octree();
                flat.maxLevel = 0;
                flat.fromGraphNode(floorMesh(8));
                const w3 = new Walk();
                walk(flat, 0, w3);
                expect.that(w3.maxDepth).is(1);
                expect.that(w3.triangles.length).is(128);
                expect.that(flat.subTrees[0].maxLevel).is(0);

                // trianglesPerLeaf is passed down.
                const fine = new Octree();
                fine.trianglesPerLeaf = 2;
                fine.fromGraphNode(floorMesh(8));
                const w4 = new Walk();
                walk(fine, 0, w4);
                expect.that(w4.overfull).is(0);
                expect.that(w4.maxDepth >= w.maxDepth).is(true);
                expect.that(fine.subTrees[0].trianglesPerLeaf).is(2);
            });

            test("query triangles: each once, only nearby", (expect) => {
                const o = new Octree().fromGraphNode(floorMesh(8));
                const near0: Array<THREE.Triangle> = [];
                o.getSphereTriangles(new THREE.Sphere(v(0, 0, 0), 0.5), near0);
                expect.that(near0.length > 0 && near0.length < 128).is(true);
                for (let i = 0; i < near0.length; i++) {
                    expect.that(near0.indexOf(near0[i])).is(i);
                }
                const all: Array<THREE.Triangle> = [];
                o.getBoxTriangles(new THREE.Box3(v(-6, -1, -6), v(6, 1, 6)), all);
                expect.that(all.length).is(128);
                const cap: Array<THREE.Triangle> = [];
                o.getCapsuleTriangles(new Capsule(v(0, 0.2, 0), v(0, 1, 0), 0.35), cap);
                expect.that(cap.length > 0 && cap.length < 128).is(true);
                const ray: Array<THREE.Triangle> = [];
                o.getRayTriangles(new THREE.Ray(v(-6, -0.001, 0.1), v(1, 0, 0)), ray);
                expect.that(ray.length > 0 && ray.length < 128).is(true);
            });

            test("fromGraphNode: world transforms, indexed and not", (expect) => {
                const parent = new THREE.Group();
                parent.position.set(10, 0, 0);
                const g = new THREE.PlaneGeometry(1, 1);
                g.rotateX(-Math.PI / 2);
                const mesh = new THREE.Mesh(g);
                mesh.position.set(0, 2, 0);
                mesh.scale.set(2, 2, 2);
                parent.add(mesh);
                // A non-indexed triangle under the parent too.
                const tri = new THREE.BufferGeometry();
                tri.setAttribute("position", new THREE.Float32BufferAttribute([0, 0, 0, 0, 0, 1, 1, 0, 0], 3));
                const triMesh = new THREE.Mesh(tri);
                triMesh.position.set(0, -1, 0);
                parent.add(triMesh);

                // Matrices not updated before: fromGraphNode does it. The
                // plane lies on the max y face of the bounds, which the
                // split keeps (three.js can round it away).
                const o = new Octree().fromGraphNode(parent);
                expect.that(near(o.bounds.min.x, 9)).is(true);
                expect.that(near(o.bounds.max.x, 11)).is(true);
                expect.that(near(o.bounds.max.y, 2)).is(true);
                expect.that(near(o.bounds.min.y, -1)).is(true);
                expect.that(near(o.bounds.min.z, -1)).is(true);
                const w = new Walk();
                walk(o, 0, w);
                expect.that(w.triangles.length).is(3);
                const hit = o.rayIntersect(new THREE.Ray(v(10.5, 5, 0.5), v(0, -1, 0)));
                expect.that(hit != null && near(hit.distance, 3)).is(true);
                // An indexed box: 12 triangles.
                const box = new Octree().fromGraphNode(new THREE.Mesh(new THREE.BoxGeometry(1, 1, 1)));
                const wb = new Walk();
                walk(box, 0, wb);
                expect.that(wb.triangles.length).is(12);
            });

            test("layers filter the meshes", (expect) => {
                const scene = new THREE.Group();
                scene.add(floorMesh());
                const ghost = floorMesh();
                ghost.position.y = 3;
                ghost.layers.set(1);
                scene.add(ghost);

                const o = new Octree().fromGraphNode(scene);
                expect.that(near(o.bounds.max.y, 0)).is(true);
                const w = new Walk();
                walk(o, 0, w);
                expect.that(w.triangles.length).is(2);

                const both = new Octree();
                both.layers.enable(1);
                both.fromGraphNode(scene);
                expect.that(near(both.bounds.max.y, 3)).is(true);

                const only = new Octree();
                only.layers.set(1);
                only.fromGraphNode(scene);
                expect.that(near(only.bounds.min.y, 3)).is(true);
            });

            test("clear empties it; helper draws every box", (expect) => {
                const o = new Octree().fromGraphNode(floorMesh(8));
                const w = new Walk();
                walk(o, 0, w);
                const helper = new OctreeHelper(o);
                expect.that(helper.type).is("OctreeHelper");
                expect.that(helper.color).is(<u32>0xffff00);
                expect.that(helper.geometry.getAttribute("position")!.count).is(w.nodes * 24);

                o.clear();
                expect.that(o.box == null).is(true);
                expect.that(o.bounds.isEmpty()).is(true);
                expect.that(o.subTrees.length).is(0);
                expect.that(o.triangles.length).is(0);
                expect.that(o.rayIntersect(new THREE.Ray(v(1, 5, 1), v(0, -1, 0))) == null).is(true);
                expect.that(o.sphereIntersect(new THREE.Sphere(v(1, 0, 1), 1)) == null).is(true);
                helper.update();
                expect.that(helper.geometry.getAttribute("position")!.count).is(0);

                // Rebuilt after clear.
                o.fromGraphNode(floorMesh());
                expect.that(o.rayIntersect(new THREE.Ray(v(1, 5, 1), v(0, -1, 0))) != null).is(true);
                helper.dispose();
            });
        });
    }
}
