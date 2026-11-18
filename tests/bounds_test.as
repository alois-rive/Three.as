// Bounds, rays and culling math: rive . --test

import { Expect, Tests } from "rive/test";
import { Vector2 } from "../three/math/Vector2";
import { Vector3 } from "../three/math/Vector3";
import { Matrix4 } from "../three/math/Matrix4";
import { Box3 } from "../three/math/Box3";
import { Sphere } from "../three/math/Sphere";
import { Plane } from "../three/math/Plane";
import { Line3 } from "../three/math/Line3";
import { Ray } from "../three/math/Ray";
import { Triangle } from "../three/math/Triangle";
import { Frustum } from "../three/math/Frustum";
import { Spherical } from "../three/math/Spherical";
import { Cylindrical } from "../three/math/Cylindrical";
import { Layers } from "../three/core/Layers";
import { Object3D } from "../three/core/Object3D";
import { Mesh } from "../three/objects/Mesh";
import { BoxGeometry } from "../three/geometries/BoxGeometry";
import { SphereGeometry } from "../three/geometries/SphereGeometry";
import { PerspectiveCamera } from "../three/cameras/PerspectiveCamera";

const EPS: f64 = 1e-5;

@editTime
function near(expect: Expect, actual: f64, want: f64): void {
    expect.that(Math.abs(actual - want)).lessThan(EPS);
}

@editTime
function nearVec(expect: Expect, v: Vector3, x: f64, y: f64, z: f64): void {
    near(expect, v.x, x);
    near(expect, v.y, y);
    near(expect, v.z, z);
}

@editTime
function viewFrustum(camera: PerspectiveCamera): Frustum {
    camera.updateMatrixWorld();
    const vp = new Matrix4().multiplyMatrices(camera.projectionMatrix, camera.matrixWorldInverse);
    return new Frustum().setFromProjectionMatrix(vp);
}

export class BoundsTests extends Tests {
    override run(): void {
        group("Box3", () => {
            test("geometry bounds", (expect) => {
                const g = new BoxGeometry(2, 4, 6);
                g.computeBoundingBox();
                const box = g.boundingBox!;
                nearVec(expect, box.min, -1, -2, -3);
                nearVec(expect, box.max, 1, 2, 3);
                nearVec(expect, box.getSize(new Vector3()), 2, 4, 6);
            });
            test("setFromObject follows the world transform", (expect) => {
                const parent = new Object3D();
                const mesh = new Mesh(new BoxGeometry(1, 1, 1));
                parent.add(mesh);
                parent.position.set(10, 0, 0);
                mesh.scale.set(2, 2, 2);
                parent.updateMatrixWorld();
                const box = new Box3().setFromObject(parent);
                nearVec(expect, box.min, 9, -1, -1);
                nearVec(expect, box.max, 11, 1, 1);
                const precise = new Box3().setFromObject(parent, true);
                expect.that(precise.equals(box)).is(true);
            });
            test("empty, union, intersect", (expect) => {
                const a = new Box3(new Vector3(0, 0, 0), new Vector3(2, 2, 2));
                const b = new Box3(new Vector3(1, 1, 1), new Vector3(3, 3, 3));
                expect.that(new Box3().isEmpty()).is(true);
                expect.that(a.intersectsBox(b)).is(true);
                nearVec(expect, a.clone().intersect(b).min, 1, 1, 1);
                nearVec(expect, a.clone().union(b).max, 3, 3, 3);
                expect.that(a.containsPoint(new Vector3(1, 1, 1))).is(true);
                expect.that(a.containsPoint(new Vector3(3, 1, 1))).is(false);
            });
            test("intersects a triangle", (expect) => {
                const box = new Box3(new Vector3(-1, -1, -1), new Vector3(1, 1, 1));
                const hit = new Triangle(new Vector3(-2, 0, 0), new Vector3(2, 0, 0), new Vector3(0, 2, 0));
                const miss = new Triangle(new Vector3(-2, 0, 5), new Vector3(2, 0, 5), new Vector3(0, 2, 5));
                expect.that(box.intersectsTriangle(hit)).is(true);
                expect.that(box.intersectsTriangle(miss)).is(false);
            });
        });

        group("Sphere", () => {
            test("geometry bounds", (expect) => {
                const g = new SphereGeometry(2, 16, 8);
                g.computeBoundingSphere();
                near(expect, g.boundingSphere!.radius, 2);
                nearVec(expect, g.boundingSphere!.center, 0, 0, 0);
            });
            test("expand and union", (expect) => {
                const s = new Sphere().expandByPoint(new Vector3(1, 0, 0));
                near(expect, s.radius, 0);
                s.expandByPoint(new Vector3(-1, 0, 0));
                near(expect, s.radius, 1);
                nearVec(expect, s.center, 0, 0, 0);
                s.union(new Sphere(new Vector3(3, 0, 0), 1));
                near(expect, s.radius, 2.5);
            });
        });

        group("Plane and Line3", () => {
            test("distance and projection", (expect) => {
                const p = new Plane().setFromNormalAndCoplanarPoint(new Vector3(0, 1, 0), new Vector3(0, 2, 0));
                near(expect, p.distanceToPoint(new Vector3(5, 5, 5)), 3);
                nearVec(expect, p.projectPoint(new Vector3(1, 7, 1), new Vector3()), 1, 2, 1);
            });
            test("line intersection", (expect) => {
                const p = new Plane(new Vector3(0, 1, 0), 0);
                const hit = p.intersectLine(new Line3(new Vector3(0, -1, 0), new Vector3(0, 3, 0)), new Vector3());
                expect.that(hit != null).is(true);
                nearVec(expect, hit!, 0, 0, 0);
                expect.that(p.intersectLine(new Line3(new Vector3(0, 1, 0), new Vector3(0, 3, 0)), new Vector3()) == null).is(true);
            });
            test("transform keeps the plane through the moved point", (expect) => {
                const p = new Plane(new Vector3(0, 1, 0), 0);
                p.applyMatrix4(new Matrix4().makeTranslation(0, 4, 0));
                near(expect, p.distanceToPoint(new Vector3(0, 4, 0)), 0);
            });
        });

        group("Ray", () => {
            test("hits a sphere, a box, a plane and a triangle", (expect) => {
                const ray = new Ray(new Vector3(0, 0, 10), new Vector3(0, 0, -1));
                nearVec(expect, ray.intersectSphere(new Sphere(new Vector3(), 1), new Vector3())!, 0, 0, 1);
                nearVec(expect, ray.intersectBox(new Box3(new Vector3(-1, -1, -1), new Vector3(1, 1, 1)), new Vector3())!, 0, 0, 1);
                near(expect, ray.distanceToPlane(new Plane(new Vector3(0, 0, 1), 0)), 10);
                const t = ray.intersectTriangle(new Vector3(-1, -1, 0), new Vector3(1, -1, 0), new Vector3(0, 1, 0), true, new Vector3());
                nearVec(expect, t!, 0, 0, 0);
                // The same triangle seen from behind is culled.
                expect.that(ray.intersectTriangle(new Vector3(-1, -1, 0), new Vector3(0, 1, 0), new Vector3(1, -1, 0), true, new Vector3()) == null).is(true);
            });
            test("misses", (expect) => {
                const ray = new Ray(new Vector3(0, 5, 10), new Vector3(0, 0, -1));
                expect.that(ray.intersectSphere(new Sphere(new Vector3(), 1), new Vector3()) == null).is(true);
                expect.that(ray.intersectsBox(new Box3(new Vector3(-1, -1, -1), new Vector3(1, 1, 1)))).is(false);
                near(expect, ray.distanceToPlane(new Plane(new Vector3(0, 0, 1), -20)), -1);
            });
            test("distance to a segment", (expect) => {
                const ray = new Ray(new Vector3(0, 0, 0), new Vector3(1, 0, 0));
                const onRay = new Vector3(), onSeg = new Vector3();
                const d = ray.distanceSqToSegment(new Vector3(5, 2, -1), new Vector3(5, 2, 1), onRay, onSeg);
                near(expect, d, 4);
                nearVec(expect, onRay, 5, 0, 0);
                nearVec(expect, onSeg, 5, 2, 0);
            });
        });

        group("Triangle", () => {
            test("barycentric coordinates and interpolation", (expect) => {
                const a = new Vector3(0, 0, 0), b = new Vector3(1, 0, 0), c = new Vector3(0, 1, 0);
                const p = new Vector3(0.25, 0.25, 0);
                nearVec(expect, Triangle.getBarycoord(p, a, b, c, new Vector3())!, 0.5, 0.25, 0.25);
                const uv = Triangle.getInterpolation<Vector2>(p, a, b, c,
                    new Vector2(0, 0), new Vector2(1, 0), new Vector2(0, 1), new Vector2());
                near(expect, uv.x, 0.25);
                near(expect, uv.y, 0.25);
                expect.that(Triangle.containsPoint(new Vector3(0.9, 0.9, 0), a, b, c)).is(false);
                near(expect, new Triangle(a, b, c).getArea(), 0.5);
            });
            test("closest point", (expect) => {
                const t = new Triangle(new Vector3(0, 0, 0), new Vector3(1, 0, 0), new Vector3(0, 1, 0));
                nearVec(expect, t.closestPointToPoint(new Vector3(2, -1, 0), new Vector3()), 1, 0, 0);
                nearVec(expect, t.closestPointToPoint(new Vector3(0.2, 0.2, 5), new Vector3()), 0.2, 0.2, 0);
                nearVec(expect, t.closestPointToPoint(new Vector3(1, 1, 0), new Vector3()), 0.5, 0.5, 0);
            });
        });

        group("Frustum", () => {
            test("culls what the camera cannot see", (expect) => {
                const camera = new PerspectiveCamera(60, 1, 1, 100);
                camera.position.set(0, 0, 10);
                const f = viewFrustum(camera);
                expect.that(f.intersectsSphere(new Sphere(new Vector3(0, 0, 0), 1))).is(true);
                expect.that(f.intersectsSphere(new Sphere(new Vector3(0, 0, 20), 1))).is(false);   // behind
                expect.that(f.intersectsSphere(new Sphere(new Vector3(0, 0, -200), 1))).is(false); // past far
                expect.that(f.intersectsSphere(new Sphere(new Vector3(50, 0, 0), 1))).is(false);   // aside
                expect.that(f.intersectsSphere(new Sphere(new Vector3(0, 0, 9.5), 1))).is(true);   // across near
                expect.that(f.containsPoint(new Vector3(0, 0, 9.5))).is(false);                     // before near
                expect.that(f.intersectsBox(new Box3(new Vector3(-1, -1, -1), new Vector3(1, 1, 1)))).is(true);
            });
            test("intersectsObject uses the world bounds", (expect) => {
                const camera = new PerspectiveCamera(60, 1, 1, 100);
                camera.position.set(0, 0, 10);
                const f = viewFrustum(camera);
                const mesh = new Mesh(new BoxGeometry(1, 1, 1));
                mesh.updateMatrixWorld();
                expect.that(f.intersectsObject(mesh)).is(true);
                mesh.position.set(0, 0, 30);
                mesh.updateMatrixWorld();
                expect.that(f.intersectsObject(mesh)).is(false);
            });
        });

        group("Coordinates and layers", () => {
            test("spherical round trip", (expect) => {
                const v = new Vector3(1, 2, 3);
                const s = new Spherical().setFromVector3(v);
                nearVec(expect, new Vector3().setFromSpherical(s), 1, 2, 3);
                const c = new Cylindrical().setFromVector3(v);
                nearVec(expect, new Vector3().setFromCylindrical(c), 1, 2, 3);
            });
            test("layers", (expect) => {
                const a = new Layers(), b = new Layers();
                expect.that(a.test(b)).is(true);
                b.set(3);
                expect.that(a.test(b)).is(false);
                a.enable(3);
                expect.that(a.test(b)).is(true);
                expect.that(a.isEnabled(0)).is(true);
                a.disable(0);
                expect.that(a.isEnabled(0)).is(false);
            });
        });
    }
}
