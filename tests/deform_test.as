// Skinning and morph targets on the CPU side: rive . --test

import { Expect, Tests } from "rive/test";
import { Vector3 } from "../three/math/Vector3";
import { BufferGeometry } from "../three/core/BufferGeometry";
import { Float32BufferAttribute } from "../three/core/BufferAttribute";
import { Raycaster } from "../three/core/Raycaster";
import { Mesh } from "../three/objects/Mesh";
import { Bone, Skeleton } from "../three/objects/Skeleton";
import { SkinnedMesh } from "../three/objects/SkinnedMesh";
import { Group } from "../three/objects/Group";
import { PlaneGeometry } from "../three/geometries/PlaneGeometry";
import { BoxGeometry } from "../three/geometries/BoxGeometry";
import { InstancedMesh } from "../three/objects/InstancedMesh";
import { MeshBasicMaterial } from "../three/materials/MeshBasicMaterial";

const EPS: f64 = 1e-4;

@editTime
function near(expect: Expect, actual: f64, want: f64): void {
    expect.that(Math.abs(actual - want)).lessThan(EPS);
}

export class DeformTests extends Tests {
    override run(): void {
        group("morph targets", () => {
            test("absolute and relative targets", (expect) => {
                const g = new BufferGeometry();
                g.setAttribute("position", new Float32BufferAttribute([0, 0, 0], 3));
                const t = new Float32BufferAttribute([2, 0, 0], 3);
                t.name = "right";
                g.morphAttributes.set("position", [t]);
                const mesh = new Mesh(g);
                mesh.updateMorphTargets();
                expect.that(<f64>mesh.morphTargetDictionary.get("right")).is(0);
                mesh.morphTargetInfluences[0] = 0.25;
                near(expect, mesh.getVertexPosition(0, new Vector3()).x, 0.5);
                g.setAttribute("position", new Float32BufferAttribute([1, 0, 0], 3));
                near(expect, mesh.getVertexPosition(0, new Vector3()).x, 1.25);   // 1 + 0.25 * (2 - 1)
                g.morphTargetsRelative = true;
                near(expect, mesh.getVertexPosition(0, new Vector3()).x, 1.5);    // 1 + 0.25 * 2
            });
        });

        group("skinning", () => {
            test("a vertex follows its bone", (expect) => {
                const g = new BufferGeometry();
                g.setAttribute("position", new Float32BufferAttribute([0, 1, 0], 3));
                g.setAttribute("skinIndex", new Float32BufferAttribute([1, 0, 0, 0], 4));
                g.setAttribute("skinWeight", new Float32BufferAttribute([1, 0, 0, 0], 4));
                const root = new Bone();
                const tip = new Bone();
                tip.position.y = 1;
                root.add(tip);
                const mesh = new SkinnedMesh(g);
                const group = new Group();
                group.add(root);
                group.add(mesh);
                group.updateMatrixWorld(true);
                mesh.bind(new Skeleton([root, tip]));
                // Turn the root a quarter: the tip (and the vertex) swing to -x.
                root.rotation.z = Math.PI / 2;
                group.updateMatrixWorld(true);
                const v = mesh.getVertexPosition(0, new Vector3());
                near(expect, v.x, -1);
                near(expect, v.y, 0);
                const skeleton = mesh.skeleton!;
                skeleton.update();
                expect.that(<f64>skeleton.boneMatrices.length).is(32);
            });
            test("raycasts and bounds follow the pose", (expect) => {
                const g = new PlaneGeometry(1, 1);
                const n = g.getAttribute("position")!.count;
                const idx: Array<f64> = [], w: Array<f64> = [];
                for (let i = 0; i < n; i++) { idx.push(0); idx.push(0); idx.push(0); idx.push(0); w.push(1); w.push(0); w.push(0); w.push(0); }
                g.setAttribute("skinIndex", new Float32BufferAttribute(idx, 4));
                g.setAttribute("skinWeight", new Float32BufferAttribute(w, 4));
                const bone = new Bone();
                const mesh = new SkinnedMesh(g);
                const group = new Group();
                group.add(bone);
                group.add(mesh);
                group.updateMatrixWorld(true);
                mesh.bind(new Skeleton([bone]));
                bone.position.x = 5;
                group.updateMatrixWorld(true);
                const r = new Raycaster(new Vector3(5.1, 0.1, 5), new Vector3(0, 0, -1));
                expect.that(<f64>r.intersectObject(mesh).length).is(1);
                const r0 = new Raycaster(new Vector3(0.1, 0.1, 5), new Vector3(0, 0, -1));
                expect.that(<f64>r0.intersectObject(mesh).length).is(0);
                mesh.computeBoundingBox();
                near(expect, mesh.boundingBox!.min.x, 4.5);
            });
        });

        group("instanced morphs", () => {
            test("setMorphAt / getMorphAt", (expect) => {
                const g = new BoxGeometry();
                const n = g.getAttribute("position")!.count;
                const zeros: Array<f64> = new Array<f64>(n * 3);
                g.morphAttributes.set("position", [new Float32BufferAttribute(zeros, 3), new Float32BufferAttribute(zeros, 3)]);
                const im = new InstancedMesh(g, new MeshBasicMaterial(), 3);
                const probe = new Mesh(g);
                probe.updateMorphTargets();
                probe.morphTargetInfluences[0] = 0.25;
                probe.morphTargetInfluences[1] = 0.5;
                im.setMorphAt(2, probe);
                const t = im.morphTexture!;
                expect.that(<f64>t.dataWidth).is(3);
                expect.that(<f64>t.dataHeight).is(3);
                const data = t.data as Float32Array;
                near(expect, data[6], 0.25);    // 1 - (0.25 + 0.5): absolute targets
                near(expect, data[8], 0.5);
                probe.morphTargetInfluences[0] = 0;
                probe.morphTargetInfluences[1] = 0;
                im.getMorphAt(2, probe);
                near(expect, probe.morphTargetInfluences[1], 0.5);
                g.morphTargetsRelative = true;
                im.setMorphAt(0, probe);
                near(expect, data[0], 1);
            });
        });

        group("long skeletons", () => {
            test("inverses of a 400-bone chain", (expect) => {
                const bones: Array<Bone> = [];
                for (let i = 0; i < 400; i++) {
                    const b = new Bone();
                    if (i > 0) {
                        b.position.y = 0.5;
                        bones[i - 1].add(b);
                    }
                    bones.push(b);
                }
                const skeleton = new Skeleton(bones);
                // The last bone sits at y = 199.5: its inverse moves it back.
                const e = skeleton.boneInverses[399].elements;
                near(expect, <f64>e[13], -199.5);
                skeleton.update();
                expect.that(<f64>skeleton.boneMatrices.length).is(6400);
            });
        });
    }
}
