// Helpers build their geometry: rive . --test

import { Tests } from "rive/test";
import * as THREE from "../three/Three";
import { VertexNormalsHelper } from "../three/addons/helpers/VertexNormalsHelper";

export class HelpersTests extends Tests {
    override run(): void {
        group("helpers", () => {
            test("axes, grids, boxes, planes, arrows", (expect) => {
                expect.that(new THREE.AxesHelper(2).geometry.getAttribute("position")!.count).is(6);
                expect.that(new THREE.GridHelper(10, 10).geometry.getAttribute("position")!.count).is(44);
                expect.that(new THREE.PolarGridHelper(10, 16, 8, 64).geometry.getAttribute("position")!.count).is(32 + 8 * 128);
                const mesh = new THREE.Mesh(new THREE.BoxGeometry(2, 4, 6));
                mesh.position.set(1, 0, 0);
                mesh.updateMatrixWorld();
                const box = new THREE.BoxHelper(mesh);
                const p = box.geometry.getAttribute("position")!.array;
                expect.that(<f64>p[0]).is(2);   // max.x
                expect.that(<f64>p[1]).is(2);   // max.y
                const b3 = new THREE.Box3Helper(new THREE.Box3(new THREE.Vector3(-1, -1, -1), new THREE.Vector3(3, 1, 1)));
                b3.updateMatrixWorld();
                expect.that(b3.position.x).is(1);
                expect.that(b3.scale.x).is(2);
                const ph = new THREE.PlaneHelper(new THREE.Plane(new THREE.Vector3(0, 1, 0), -2), 4);
                ph.updateMatrixWorld();
                expect.that(Math.abs(ph.position.y - 2) < 1e-9).is(true);
                expect.that(<f64>ph.fill.material.side).is(<f64>THREE.DoubleSide);
                // BoxHelper with null object does not reuse stale _box from previous BoxHelper.
                const emptyBox = new THREE.BoxHelper();
                const ep = emptyBox.geometry.getAttribute("position")!.array;
                expect.that(<f64>ep[0]).is(0);
                const arrow = new THREE.ArrowHelper(new THREE.Vector3(1, 0, 0), new THREE.Vector3(), 2);
                arrow.updateMatrixWorld();
                const tip = new THREE.Vector3(0, 2, 0).applyQuaternion(arrow.quaternion);
                expect.that(Math.abs(tip.x - 2) < 1e-9).is(true);
            });
            test("camera, lights, skeleton, normals", (expect) => {
                const cam = new THREE.PerspectiveCamera(60, 1, 1, 10);
                cam.updateMatrixWorld();
                const ch = new THREE.CameraHelper(cam);
                // n1 sits on the near plane: z = -1 in camera space.
                const a = ch.geometry.getAttribute("position")!.array;
                expect.that(Math.abs(<f64>a[2] + 1) < 1e-4).is(true);
                const sun = new THREE.DirectionalLight(0xffffff, 1);
                expect.that(new THREE.DirectionalLightHelper(sun, 1).lightPlane != null).is(true);
                expect.that(new THREE.PointLightHelper(new THREE.PointLight(), 0.5).geometry != null).is(true);
                const spot = new THREE.SpotLight(0xffffff, 1, 5, 0.5);
                const sh = new THREE.SpotLightHelper(spot);
                expect.that(Math.abs(sh.cone.scale.z - 5) < 1e-9).is(true);
                new THREE.HemisphereLightHelper(new THREE.HemisphereLight(0xffffff, 0x000000, 1), 1);
                const root = new THREE.Bone();
                const child = new THREE.Bone();
                child.position.set(0, 1, 0);
                root.add(child);
                root.updateMatrixWorld();
                const sk = new THREE.SkeletonHelper(root);
                sk.updateMatrixWorld();
                expect.that(sk.isSkeletonHelper).is(true);
                expect.that(sk.frustumCulled).is(false);
                expect.that(sk.geometry.getAttribute("position")!.count).is(2);
                const m = new THREE.Mesh(new THREE.PlaneGeometry(1, 1));
                expect.that(new VertexNormalsHelper(m, 0.5).geometry.getAttribute("position")!.count).is(8);
            });
        });
    }
}
