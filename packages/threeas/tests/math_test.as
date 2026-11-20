// Math round trips: rive . --test

import { Expect, Tests } from "rive/test";
import { Vector3 } from "../three/math/Vector3";
import { Quaternion } from "../three/math/Quaternion";
import { Euler } from "../three/math/Euler";
import { Matrix4 } from "../three/math/Matrix4";
import { Color } from "../three/math/Color";
import { Object3D } from "../three/core/Object3D";
import { PerspectiveCamera } from "../three/cameras/PerspectiveCamera";
import { BoxGeometry } from "../three/geometries/BoxGeometry";
import { SphereGeometry } from "../three/geometries/SphereGeometry";

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

export class MathTests extends Tests {
    override run(): void {
        group("Matrix4", () => {
            test("compose then decompose", (expect) => {
                const p = new Vector3(1, -2, 3);
                const q = new Quaternion().setFromEuler(new Euler(0.3, -0.7, 1.1, "XYZ"));
                const s = new Vector3(2, 0.5, 1.5);
                const m = new Matrix4().compose(p, q, s);
                const p2 = new Vector3(), q2 = new Quaternion(), s2 = new Vector3();
                m.decompose(p2, q2, s2);
                nearVec(expect, p2, 1, -2, 3);
                nearVec(expect, s2, 2, 0.5, 1.5);
                near(expect, Math.abs(q.dot(q2)), 1);
            });
            test("invert gives the identity", (expect) => {
                const m = new Matrix4().compose(new Vector3(4, 5, 6),
                    new Quaternion().setFromAxisAngle(new Vector3(0, 1, 0), 0.8), new Vector3(1, 2, 3));
                const r = m.clone().invert().multiply(m);
                const e = r.elements;
                for (let i = 0; i < 16; i++) near(expect, e[i], i % 5 == 0 ? 1 : 0);
            });
            test("set is row-major", (expect) => {
                const m = new Matrix4().set(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16);
                expect.that(<f64>m.elements[1]).is(5);
                expect.that(<f64>m.elements[12]).is(4);
            });
            test("multiply applies the right matrix first", (expect) => {
                const t = new Matrix4().makeTranslation(1, 0, 0);
                const r = new Matrix4().makeRotationZ(Math.PI / 2);
                const v = new Vector3(1, 0, 0).applyMatrix4(t.clone().multiply(r));
                nearVec(expect, v, 1, 1, 0);
            });
            test("multiplyMatrices and invert handle affine, projective and aliasing", (expect) => {
                const a = new Matrix4().compose(new Vector3(2, -3, 5),
                    new Quaternion().setFromEuler(new Euler(0.4, -0.5, 0.6)), new Vector3(1.5, 2, 0.5));
                const b = new Matrix4().compose(new Vector3(-1, 4, -2),
                    new Quaternion().setFromAxisAngle(new Vector3(0, 0, 1), 1.2), new Vector3(0.8, 1.2, 1));
                // Affine aliasing: out === a, out === b, out === a === b
                const ab = new Matrix4().multiplyMatrices(a, b);
                const aliasA = a.clone();
                aliasA.multiplyMatrices(aliasA, b);
                const aliasB = b.clone();
                aliasB.multiplyMatrices(a, aliasB);
                for (let i = 0; i < 16; i++) {
                    near(expect, aliasA.elements[i], ab.elements[i]);
                    near(expect, aliasB.elements[i], ab.elements[i]);
                }
                const aa = new Matrix4().multiplyMatrices(a, a);
                const aliasSelf = a.clone();
                aliasSelf.multiplyMatrices(aliasSelf, aliasSelf);
                for (let i = 0; i < 16; i++) near(expect, aliasSelf.elements[i], aa.elements[i]);
                // Projective (non-affine bottom row) multiply and invert
                const p = new Matrix4().makePerspective(-1, 1, 1, -1, 0.5, 50);
                const pv = p.clone().multiply(a);
                const pInv = p.clone().invert();
                const id = new Matrix4().multiplyMatrices(pInv, p);
                for (let i = 0; i < 16; i++) near(expect, id.elements[i], i % 5 == 0 ? 1 : 0);
                // Re-project through pInv * (p * a) == a
                const back = new Matrix4().multiplyMatrices(pInv, pv);
                for (let i = 0; i < 16; i++) near(expect, back.elements[i], a.elements[i]);
                // Singular affine matrix zeroes on invert
                const singular = new Matrix4().makeScale(0, 1, 1).invert();
                for (let i = 0; i < 16; i++) expect.that(<f64>singular.elements[i]).is(0);
            });
        });

        group("Euler and Quaternion", () => {
            test("stay linked on an Object3D", (expect) => {
                const o = new Object3D();
                o.rotation.y = Math.PI / 2;
                near(expect, o.quaternion.y, Math.sin(Math.PI / 4));
                o.quaternion.setFromAxisAngle(new Vector3(1, 0, 0), 0.5);
                near(expect, o.rotation.x, 0.5);
                near(expect, o.rotation.y, 0);
            });
            test("round trip in every order", (expect) => {
                const orders = ["XYZ", "YXZ", "ZXY", "ZYX", "YZX", "XZY"];
                for (let i = 0; i < orders.length; i++) {
                    const e = new Euler(0.2, -0.4, 0.9, orders[i]);
                    const back = new Euler(0, 0, 0, orders[i]).setFromQuaternion(new Quaternion().setFromEuler(e));
                    near(expect, back.x, 0.2);
                    near(expect, back.y, -0.4);
                    near(expect, back.z, 0.9);
                }
            });
        });

        group("Object3D", () => {
            test("world matrices follow the parent", (expect) => {
                const parent = new Object3D();
                const child = new Object3D();
                parent.add(child);
                parent.position.set(0, 1, 0);
                parent.rotation.y = Math.PI / 2;
                child.position.set(1, 0, 0);
                parent.updateMatrixWorld();
                nearVec(expect, child.getWorldPosition(new Vector3()), 0, 1, -1);
            });
            test("a camera's lookAt points its -Z at the target", (expect) => {
                const camera = new PerspectiveCamera();
                camera.position.set(3, 4, 5);
                camera.lookAt(new Vector3(0, 0, 0));
                const d = camera.getWorldDirection(new Vector3());
                const l = Math.sqrt(50.0);
                nearVec(expect, d, -3 / l, -4 / l, -5 / l);
            });
            test("project maps the target to the centre, depth in [0, 1]", (expect) => {
                const camera = new PerspectiveCamera(60, 1, 1, 10);
                camera.position.set(0, 0, 5);
                camera.updateMatrixWorld();
                const v = new Vector3(0, 0, 0).project(camera);
                near(expect, v.x, 0);
                near(expect, v.y, 0);
                expect.that(v.z).greaterThan(0);
                expect.that(v.z).lessThan(1);
                const nearPlane = new Vector3(0, 0, 4).project(camera);
                near(expect, nearPlane.z, 0);
            });
        });

        group("Color", () => {
            test("hex is sRGB, components are linear", (expect) => {
                const c = new Color(0x808080);
                near(expect, c.r, 0.2158605);
                expect.that(<f64>c.getHex()).is(<f64>0x808080);
            });
            test("accepts Rive colours", (expect) => {
                const c = new Color().set(<u32>0x80FF0000);
                expect.that(<f64>c.getHex()).is(<f64>0xFF0000);
                near(expect, Color.alphaOf(0x80FF0000), 128.0 / 255);
            });
            test("parses CSS", (expect) => {
                expect.that(<f64>Color.fromStyle("#f80").getHex()).is(<f64>0xFF8800);
                expect.that(<f64>Color.fromStyle("rgb(255, 0, 128)").getHex()).is(<f64>0xFF0080);
            });
        });

        group("Geometries", () => {
            test("box: 24 vertices, 36 indices, 6 groups", (expect) => {
                const g = new BoxGeometry();
                expect.that(<f64>g.getAttribute("position")!.count).is(24);
                expect.that(<f64>g.index!.count).is(36);
                expect.that(<f64>g.groups.length).is(6);
            });
            test("sphere: three.js vertex and index counts", (expect) => {
                const g = new SphereGeometry(1, 8, 6);
                expect.that(<f64>g.getAttribute("position")!.count).is(9 * 7);
                expect.that(<f64>g.index!.count).is(8 * 6 * 6 - 8 * 2 * 3);
            });
        });
    }
}
