// Raycasting, controls and clocks: rive . --test

import { Expect, Tests } from "rive/test";
import { Vector2 } from "../three/math/Vector2";
import { Vector3 } from "../three/math/Vector3";
import { Matrix4 } from "../three/math/Matrix4";
import { Object3D } from "../three/core/Object3D";
import { Raycaster } from "../three/core/Raycaster";
import { BufferGeometry } from "../three/core/BufferGeometry";
import { Float32BufferAttribute } from "../three/core/BufferAttribute";
import { Clock, Timer } from "../three/core/Clock";
import { Mesh } from "../three/objects/Mesh";
import { InstancedMesh } from "../three/objects/InstancedMesh";
import { LOD } from "../three/objects/LOD";
import { Line } from "../three/objects/Line";
import { Points } from "../three/objects/Points";
import { Sprite } from "../three/objects/Sprite";
import { PlaneGeometry } from "../three/geometries/PlaneGeometry";
import { BoxGeometry } from "../three/geometries/BoxGeometry";
import { MeshBasicMaterial } from "../three/materials/MeshBasicMaterial";
import { PerspectiveCamera } from "../three/cameras/PerspectiveCamera";
import { OrthographicCamera } from "../three/cameras/OrthographicCamera";
import { OrbitControls } from "../three/addons/controls/OrbitControls";
import { DoubleSide } from "../three/constants";

const EPS: f64 = 1e-4;

@editTime
function near(expect: Expect, actual: f64, want: f64): void {
    expect.that(Math.abs(actual - want)).lessThan(EPS);
}

@editTime
function rayDown(): Raycaster {
    // Off the diagonal the plane's two triangles share (a ray on it hits both).
    return new Raycaster(new Vector3(0.3, 0.1, 5), new Vector3(0, 0, -1));
}

export class RaycastTests extends Tests {
    override run(): void {
        group("Raycaster", () => {
            test("hits a plane with distance, point, uv and normal", (expect) => {
                const plane = new Mesh(new PlaneGeometry(2, 2));
                plane.updateMatrixWorld();
                const hits = rayDown().intersectObject(plane);
                expect.that(<f64>hits.length).is(1);
                near(expect, hits[0].distance, 5);
                near(expect, hits[0].uv!.x, 0.65);
                near(expect, hits[0].uv!.y, 0.55);
                near(expect, hits[0].normal!.z, 1);
                expect.that(hits[0].face != null).is(true);
            });
            test("follows the world transform and sorts by distance", (expect) => {
                const a = new Mesh(new PlaneGeometry(2, 2));
                const b = new Mesh(new PlaneGeometry(2, 2));
                b.position.z = 2;
                const root = new Object3D();
                root.add(a);
                root.add(b);
                root.updateMatrixWorld();
                const hits = rayDown().intersectObject(root, true);
                expect.that(<f64>hits.length).is(2);
                expect.that(hits[0].object === b).is(true);
                near(expect, hits[0].distance, 3);
            });
            test("back faces are culled for FrontSide only", (expect) => {
                const plane = new Mesh(new PlaneGeometry(2, 2));
                plane.rotation.y = Math.PI;
                plane.updateMatrixWorld();
                expect.that(<f64>rayDown().intersectObject(plane).length).is(0);
                (plane.material as MeshBasicMaterial).side = DoubleSide;
                expect.that(<f64>rayDown().intersectObject(plane).length).is(1);
            });
            test("reports the group's material index", (expect) => {
                const box = new Mesh(new BoxGeometry(1, 1, 1));
                for (let i = 0; i < 6; i++) box.materials.push(new MeshBasicMaterial());
                box.updateMatrixWorld();
                const hits = rayDown().intersectObject(box);
                expect.that(<f64>hits[0].face!.materialIndex).is(4);   // +z face
            });
            test("finds the instance", (expect) => {
                const im = new InstancedMesh(new BoxGeometry(0.5, 0.5, 0.5), new MeshBasicMaterial(), 3);
                const m = new Matrix4();
                for (let i = 0; i < 3; i++) im.setMatrixAt(i, m.makeTranslation(<f64>i * 2 - 2, 0, 0));
                im.updateMatrixWorld();
                const r = new Raycaster(new Vector3(2.1, 0.05, 5), new Vector3(0, 0, -1));
                const hits = r.intersectObject(im);
                expect.that(<f64>hits.length).is(1);
                expect.that(<f64>hits[0].instanceId).is(2);
            });
            test("lines within the threshold", (expect) => {
                const g = new BufferGeometry();
                g.setAttribute("position", new Float32BufferAttribute([-1, 0.1, 0, 1, 0.1, 0], 3));
                const line = new Line(g);
                line.updateMatrixWorld();
                const r = new Raycaster(new Vector3(0, 0, 5), new Vector3(0, 0, -1));
                r.params.Line.threshold = 0.2;
                expect.that(<f64>r.intersectObject(line).length).is(1);
                r.params.Line.threshold = 0.05;
                expect.that(<f64>r.intersectObject(line).length).is(0);
            });
            test("points within the threshold", (expect) => {
                const g = new BufferGeometry();
                g.setAttribute("position", new Float32BufferAttribute([0, 0, 0, 3, 0, 0], 3));
                const points = new Points(g);
                points.updateMatrixWorld();
                const r = new Raycaster(new Vector3(0.1, 0, 5), new Vector3(0, 0, -1));
                r.params.Points.threshold = 0.2;
                const hits = r.intersectObject(points);
                expect.that(<f64>hits.length).is(1);
                expect.that(<f64>hits[0].index).is(0);
                near(expect, hits[0].distanceToRay, 0.1);
            });
            test("sprites face the camera", (expect) => {
                const camera = new PerspectiveCamera(50, 1, 0.1, 100);
                camera.position.set(0, 0, 5);
                const sprite = new Sprite();
                sprite.updateMatrixWorld();
                const r = new Raycaster();
                r.setFromCamera(new Vector2(0, 0), camera);
                const hits = r.intersectObject(sprite);
                expect.that(<f64>hits.length).is(1);
                near(expect, hits[0].uv!.x, 0.5);
                near(expect, hits[0].uv!.y, 0.5);
            });
            test("setFromCamera aims through the pointer", (expect) => {
                const camera = new PerspectiveCamera(90, 1, 0.1, 100);
                camera.position.set(0, 0, 5);
                const r = new Raycaster();
                r.setFromCamera(new Vector2(1, 0), camera);
                // 90 degrees fov: the right edge is 45 degrees off axis.
                near(expect, r.ray.direction.x, Math.SQRT1_2);
                near(expect, r.ray.direction.z, -Math.SQRT1_2);
            });
            test("setFromCamera updates parented camera and places ortho ray on camera plane", (expect) => {
                const rig = new Object3D();
                rig.position.set(0, 0, 10);
                const ortho = new OrthographicCamera(-2, 2, 2, -2, 1, 100);
                rig.add(ortho);
                // Parent was never updated manually: setFromCamera updates ancestors.
                const r = new Raycaster();
                r.setFromCamera(new Vector2(0.5, 0), ortho);
                near(expect, r.ray.origin.x, 1);
                near(expect, r.ray.origin.y, 0);
                near(expect, r.ray.origin.z, 10);
                near(expect, r.ray.direction.z, -1);
                const plane = new Mesh(new PlaneGeometry(4, 4));
                plane.updateMatrixWorld();
                const hits = r.intersectObject(plane);
                expect.that(<f64>hits.length).is(1);
                near(expect, hits[0].distance, 10);
            });
            test("LOD.raycast hits only the active level and honours ortho zoom", (expect) => {
                const lod = new LOD();
                const high = new Mesh(new PlaneGeometry(2, 2));
                const low = new Mesh(new PlaneGeometry(2, 2));
                lod.addLevel(high, 0);
                lod.addLevel(low, 10);
                lod.updateMatrixWorld();

                const cam = new PerspectiveCamera(50, 1, 0.1, 100);
                cam.position.set(0, 0, 5);
                const r = new Raycaster();
                r.setFromCamera(new Vector2(0.1, 0.05), cam);
                let hits = r.intersectObject(lod, true);
                expect.that(<f64>hits.length).is(1);
                expect.that(hits[0].object === high).is(true);

                cam.position.set(0, 0, 15);
                r.setFromCamera(new Vector2(0.1, 0.05), cam);
                hits = r.intersectObject(lod, true);
                expect.that(<f64>hits.length).is(1);
                expect.that(hits[0].object === low).is(true);

                // OrthographicCamera zoom divides effective LOD distance.
                const ortho = new OrthographicCamera(-2, 2, 2, -2, 0.1, 100);
                ortho.position.set(0, 0, 15);
                ortho.zoom = 2;
                ortho.updateProjectionMatrix();
                ortho.updateMatrixWorld();
                lod.update(ortho);
                expect.that(<f64>lod.getCurrentLevel()).is(0);
                r.setFromCamera(new Vector2(0.1, 0.05), ortho);
                hits = r.intersectObject(lod, true);
                expect.that(<f64>hits.length).is(1);
                expect.that(hits[0].object === high).is(true);
            });
        });

        group("OrbitControls", () => {
            test("rotating keeps the distance to the target", (expect) => {
                const camera = new PerspectiveCamera();
                camera.position.set(0, 0, 10);
                const controls = new OrbitControls(camera);
                controls.rotateLeft(Math.PI / 2);
                controls.update();
                near(expect, camera.position.distanceTo(controls.target), 10);
                near(expect, camera.position.x, -10);
                const d = camera.getWorldDirection(new Vector3());
                near(expect, d.x, 1);
            });
            test("dolly and limits", (expect) => {
                const camera = new PerspectiveCamera();
                camera.position.set(0, 0, 10);
                const controls = new OrbitControls(camera);
                controls.dollyIn(0.5);
                controls.update();
                near(expect, controls.getDistance(), 5);
                controls.maxDistance = 8;
                controls.dollyOut(0.25);
                controls.update();
                near(expect, controls.getDistance(), 8);
            });
            test("polar angle is clamped", (expect) => {
                const camera = new PerspectiveCamera();
                camera.position.set(0, 0, 10);
                const controls = new OrbitControls(camera);
                controls.maxPolarAngle = Math.PI / 2;
                controls.rotateUp(-2);
                controls.update();
                expect.that(camera.position.y).greaterThanOrEqual(-1e-6);
            });
        });

        group("Clock and Timer", () => {
            test("advance-fed time", (expect) => {
                const clock = new Clock();
                clock.getDelta();
                clock.tick(0.5);
                near(expect, clock.getDelta(), 0.5);
                clock.tick(0.25);
                near(expect, clock.getElapsedTime(), 0.75);
                const timer = new Timer();
                timer.setTimescale(2);
                timer.update(0.1);
                near(expect, timer.getDelta(), 0.2);
                timer.update(0.1);
                near(expect, timer.getElapsed(), 0.4);
            });
        });
    }
}
