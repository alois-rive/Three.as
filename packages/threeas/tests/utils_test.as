// Cloning, events, geometry utilities: rive . --test

import { Tests } from "rive/test";
import * as THREE from "../three/Three";
import * as BufferGeometryUtils from "../three/addons/utils/BufferGeometryUtils";
import * as SceneUtils from "../three/addons/utils/SceneUtils";
import * as SkeletonUtils from "../three/addons/utils/SkeletonUtils";

class Counter extends THREE.EventListener {
    count: i32 = 0;
    last: string = "";
    override handleEvent(event: THREE.Event): void {
        this.count++;
        this.last = event.type;
    }
}

export class UtilsTests extends Tests {
    override run(): void {
        group("clone and copy", () => {
            test("a hierarchy clones deeply, sharing geometry and material", (expect) => {
                const g = new THREE.BoxGeometry();
                const m = new THREE.MeshStandardMaterial({ color: 0xff0000 });
                const parent = new THREE.Group();
                parent.name = "root";
                const mesh = new THREE.Mesh(g, m);
                mesh.position.set(1, 2, 3);
                mesh.castShadow = true;
                parent.add(mesh);
                const light = new THREE.SpotLight(0xffffff, 5, 10, 0.4);
                parent.add(light);
                const c = parent.clone();
                expect.that(c instanceof THREE.Group).is(true);
                expect.that(c.name).is("root");
                expect.that(c.children.length).is(2);
                const cm = c.children[0] as THREE.Mesh;
                expect.that(cm !== mesh).is(true);
                expect.that(cm.geometry === g && cm.material === m).is(true);
                expect.that(cm.position.z).is(3);
                expect.that(cm.castShadow).is(true);
                const cl = c.children[1] as THREE.SpotLight;
                expect.that(cl.distance).is(10);
                expect.that(cl.angle).is(0.4);
                expect.that(cl.target !== light.target).is(true);
                expect.that(parent.clone(false).children.length).is(0);
            });
            test("geometry copy, clone and toNonIndexed", (expect) => {
                const g = new THREE.BoxGeometry(1, 1, 1);
                const c = g.clone();
                expect.that(c.getAttribute("position")!.array !== g.getAttribute("position")!.array).is(true);
                expect.that(c.index!.count).is(g.index!.count);
                const n = g.toNonIndexed();
                expect.that(n.index == null).is(true);
                expect.that(n.getAttribute("position")!.count).is(36);
            });
        });
        group("events", () => {
            test("added, removed, childadded and dispose", (expect) => {
                const parent = new THREE.Object3D();
                const child = new THREE.Object3D();
                const onChild = new Counter();
                const onParent = new Counter();
                child.addEventListener("added", onChild);
                child.addEventListener("removed", onChild);
                parent.addEventListener("childadded", onParent);
                parent.add(child);
                expect.that(onChild.count).is(1);
                expect.that(onChild.last).is("added");
                expect.that(onParent.count).is(1);
                parent.remove(child);
                expect.that(onChild.last).is("removed");
                child.removeEventListener("added", onChild);
                parent.add(child);
                expect.that(onChild.count).is(2);
                const mat = new THREE.MeshBasicMaterial();
                const onDispose = new Counter();
                mat.addEventListener("dispose", onDispose);
                mat.dispose();
                expect.that(onDispose.last).is("dispose");
            });
        });
        group("BufferGeometryUtils", () => {
            test("merge, weld, interleave", (expect) => {
                const a = new THREE.BoxGeometry(1, 1, 1);
                const b = new THREE.BoxGeometry(2, 2, 2);
                const m = BufferGeometryUtils.mergeGeometries([a, b], true);
                expect.that(m != null).is(true);
                if (m == null) return;
                expect.that(m.getAttribute("position")!.count).is(48);
                expect.that(m.index!.count).is(72);
                expect.that(m.groups.length).is(2);
                expect.that(<f64>m.index!.array[36]).is(24);   // b's indices offset by a's vertices
                // A box's 24 vertices share 8 positions; with normals and uvs they stay 24.
                const p = new THREE.BufferGeometry();
                p.setAttribute("position", a.getAttribute("position")!.clone());
                p.setIndex([]);
                p.index = a.index;
                const welded = BufferGeometryUtils.mergeVertices(p);
                expect.that(welded.getAttribute("position")!.count).is(8);
                const parts = BufferGeometryUtils.interleaveAttributes([a.getAttribute("position")!, a.getAttribute("uv")!]);
                expect.that(parts[0].data.stride).is(5);
                parts[0].setXYZ(0, 9, 8, 7);
                expect.that(<f64>parts[0].data.array[0]).is(9);
                expect.that(<f64>parts[1].array[0]).is(<f64>a.getAttribute("uv")!.array[0]);
            });
        });
        group("SceneUtils and SkeletonUtils", () => {
            test("instanced to meshes; skinned clones get their own skeleton", (expect) => {
                const im = new THREE.InstancedMesh(new THREE.BoxGeometry(), new THREE.MeshBasicMaterial(), 3);
                const mtx = new THREE.Matrix4().makeTranslation(5, 0, 0);
                im.setMatrixAt(2, mtx);
                const g = SceneUtils.createMeshesFromInstancedMesh(im);
                expect.that(g.children.length).is(3);
                expect.that(g.children[2].position.x).is(5);
                const root = new THREE.Bone();
                const tip = new THREE.Bone();
                tip.position.y = 1;
                root.add(tip);
                const skinned = new THREE.SkinnedMesh(new THREE.BoxGeometry(), new THREE.MeshBasicMaterial());
                skinned.add(root);
                skinned.updateMatrixWorld(true);
                skinned.bind(new THREE.Skeleton([root, tip]));
                const copy = SkeletonUtils.clone(skinned) as THREE.SkinnedMesh;
                expect.that(copy.skeleton !== skinned.skeleton).is(true);
                expect.that(copy.skeleton!.bones[1] !== tip).is(true);
                expect.that(copy.skeleton!.bones[1].position.y).is(1);
            });
        });
    }
}
