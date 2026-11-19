// M14's non-visual parts: the morph texel job, half floats, the affine
// determinant, render timings: rive . --test

import { Expect, Tests } from "rive/test";
import { Matrix4 } from "../three/math/Matrix4";
import { Vector3 } from "../three/math/Vector3";
import { Quaternion } from "../three/math/Quaternion";
import { fromHalf, toHalf } from "../three/textures/DataUpload";
import { MorphTexelInput, morphTexels, fastHalf } from "../three/renderers/gpu/MorphTexels";
import { RenderTimings } from "../three/renderers/GPURenderer";
import { cullObjects, prepareBounds, visible } from "../three/renderers/gpu/Culling";
import { Parallel, SharedArray } from "rive/parallel";
import { PerspectiveCamera } from "../three/cameras/PerspectiveCamera";
import { Frustum } from "../three/math/Frustum";
import { Object3D } from "../three/core/Object3D";
import { Mesh } from "../three/objects/Mesh";
import { BoxGeometry } from "../three/geometries/BoxGeometry";

@editTime
function near(expect: Expect, actual: f64, want: f64, eps: f64): void {
    expect.that(Math.abs(actual - want)).lessThan(eps);
}

// The full 4x4 cofactor expansion (Matrix4.determinant before its affine
// shortcut).
function fullDeterminant(m: Matrix4): f64 {
    const te = m.mat4.m;
    const n11: f64 = te[0], n12: f64 = te[4], n13: f64 = te[8], n14: f64 = te[12];
    const n21: f64 = te[1], n22: f64 = te[5], n23: f64 = te[9], n24: f64 = te[13];
    const n31: f64 = te[2], n32: f64 = te[6], n33: f64 = te[10], n34: f64 = te[14];
    const n41: f64 = te[3], n42: f64 = te[7], n43: f64 = te[11], n44: f64 = te[15];
    return n41 * (+n14 * n23 * n32 - n13 * n24 * n32 - n14 * n22 * n33 + n12 * n24 * n33 + n13 * n22 * n34 - n12 * n23 * n34)
        + n42 * (+n11 * n23 * n34 - n11 * n24 * n33 + n14 * n21 * n33 - n13 * n21 * n34 + n13 * n24 * n31 - n14 * n23 * n31)
        + n43 * (+n11 * n24 * n32 - n11 * n22 * n34 - n14 * n21 * n32 + n12 * n21 * n34 + n14 * n22 * n31 - n12 * n24 * n31)
        + n44 * (-n13 * n22 * n31 - n11 * n23 * n32 + n11 * n22 * n33 + n13 * n21 * n32 - n12 * n21 * n33 + n12 * n23 * n31);
}

export class PerformanceTests extends Tests {
    override run(): void {
        group("half floats", () => {
            test("fastHalf matches toHalf on exact values", (expect) => {
                const values: StaticArray<f32> = [0, 1, -1, 0.5, 2, -0.25, 1024, 65504];
                for (let i = 0; i < values.length; i++) {
                    expect.that(<i32>fastHalf(values[i])).is(<i32>toHalf(values[i]));
                }
            });
            test("fastHalf truncates within a half ulp", (expect) => {
                const v: f32 = 0.123456;
                near(expect, <f64>fromHalf(fastHalf(v)), <f64>v, 1e-3);
            });
        });

        group("morph texels (the job)", () => {
            test("absolute targets become deltas, normals in the second texel", (expect) => {
                // Two vertices, one target, with normals.
                const input = new MorphTexelInput();
                input.base = new Float32Array(6);
                input.base[0] = 1; input.base[3] = 2;
                input.baseNormal = new Float32Array(6);
                input.baseNormal[2] = 1; input.baseNormal[5] = 1;
                const data = new Float32Array(12);
                data[0] = 1.5; data[3] = 2; data[4] = 0.5;          // positions
                data[6] = 0; data[7] = 1; data[8] = 1;              // normals (target)
                data[9] = 0; data[10] = 0; data[11] = 1;
                input.data = data;
                const layout = new Int32Array(6);
                layout[0] = 0; layout[1] = 3; layout[2] = 2;
                layout[3] = 6; layout[4] = 3; layout[5] = 2;
                input.layout = layout;
                input.targets = 1;
                input.vertices = 2;
                input.stride = 2;
                input.width = 4;
                input.height = 1;
                const texels = morphTexels(input);
                expect.that(texels.length).is(16);
                near(expect, <f64>fromHalf(texels[0]), 0.5, 1e-6);   // vertex 0 position x
                near(expect, <f64>fromHalf(texels[5]), 1, 1e-6);     // vertex 0 normal y
                near(expect, <f64>fromHalf(texels[6]), 0, 1e-6);     // vertex 0 normal z: 1 - 1
                near(expect, <f64>fromHalf(texels[9]), 0.5, 1e-6);   // vertex 1 position y
                near(expect, <f64>fromHalf(texels[8]), 0, 1e-6);     // vertex 1 position x: 2 - 2
            });
            test("relative targets are kept as they are", (expect) => {
                const input = new MorphTexelInput();
                input.base = new Float32Array(3);
                input.base[0] = 5;
                const data = new Float32Array(3);
                data[0] = 0.25;
                input.data = data;
                const layout = new Int32Array(6);
                layout[1] = 3; layout[2] = 1;
                input.layout = layout;
                input.targets = 1;
                input.vertices = 1;
                input.width = 1;
                input.relative = true;
                const texels = morphTexels(input);
                near(expect, <f64>fromHalf(texels[0]), 0.25, 1e-6);
            });
        });

        group("Matrix4.determinant", () => {
            test("the affine shortcut equals the full expansion", (expect) => {
                const m = new Matrix4().compose(new Vector3(1, -2, 3),
                    new Quaternion().setFromAxisAngle(new Vector3(0.3, 0.8, 0.5).normalize(), 0.7), new Vector3(-1.5, 2, 0.25));
                expect.that(m.determinant()).is(fullDeterminant(m));
                expect.that(m.determinant() < 0).is(true);   // mirrored by the negative scale
            });
            test("projective matrices still take the full expansion", (expect) => {
                const m = new Matrix4().makePerspective(-1, 1, 1, -1, 0.5, 10);
                expect.that(m.determinant()).is(fullDeterminant(m));
            });
        });

        group("parallel culling", () => {
            test("cullObjects agrees with Frustum.intersectsObject", (expect) => {
                const camera = new PerspectiveCamera(60, 1.5, 0.1, 50);
                camera.position.set(0, 0, 10);
                camera.updateMatrixWorld();
                const vp = new Matrix4().multiplyMatrices(camera.projectionMatrix, camera.matrixWorldInverse);
                const frustum = new Frustum().setFromProjectionMatrix(vp);
                const planes = new Float64Array(24);
                for (let p = 0; p < 6; p++) {
                    const plane = frustum.planes[p];
                    planes[p * 4] = plane.normal.x; planes[p * 4 + 1] = plane.normal.y;
                    planes[p * 4 + 2] = plane.normal.z; planes[p * 4 + 3] = plane.constant;
                }
                const geometry = new BoxGeometry(1, 1, 1);
                const objects: Array<Object3D> = [];
                for (let i = 0; i < 400; i++) {
                    const m = new Mesh(geometry);
                    m.position.set(<f64>(i % 20) * 1.7 - 17, <f64>((i / 20) % 20) * 1.3 - 13, -<f64>(i % 7) * 6);
                    m.scale.setScalar(0.5 + <f64>(i % 5) * 0.4);
                    m.updateMatrixWorld();
                    prepareBounds(m);
                    objects.push(m);
                }
                const test = new Uint8Array(objects.length);
                test.fill(1);
                const out = new SharedArray<u8>(objects.length);
                Parallel.run(cullObjects, objects, test, planes, out);
                let inside = 0, agree = 0;
                for (let i = 0; i < objects.length; i++) {
                    const want = frustum.intersectsObject(objects[i]);
                    if (want) inside++;
                    if ((out[i] != 0) == want && visible(objects[i], planes) == want) agree++;
                }
                expect.that(agree).is(objects.length);
                expect.that(inside > 0 && inside < objects.length).is(true);
            });
        });

        group("RenderTimings", () => {
            test("summary averages per render, reset clears", (expect) => {
                const t = new RenderTimings();
                t.renders = 2;
                t.collect = 0.004;
                expect.that(t.summary().indexOf("collect 2") >= 0).is(true);
                t.reset();
                expect.that(t.renders).is(0);
                expect.that(t.collect).is(0);
            });
        });
    }
}
