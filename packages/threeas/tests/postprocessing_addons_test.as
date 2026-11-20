// Addons barrel compile-smoke, post-processing passes, controls fixes,
// addon objects, and CSM / CSMFrustum: rive . --test

import { Tests } from "rive/test";
import { PointerEvent } from "rive/events";
import { Vector } from "rive/vector";
import * as THREE from "../three/Three";
import * as ADDONS from "../three/addons/Addons";

function ev(x: f64, y: f64, id: f64 = 0): PointerEvent {
    return new PointerEvent(id, Vector.xy(<f32>x, <f32>y));
}

function approx(a: f64, b: f64, eps: f64 = 1e-4): bool {
    return Math.abs(a - b) <= eps;
}

class DragListener extends THREE.EventListener {
    calls: i32 = 0;
    lastValue: bool = false;
    override handleEvent(event: THREE.Event): void {
        this.calls++;
        this.lastValue = event.value;
    }
}

export class PostProcessingAddonsTests extends Tests {
    override run(): void {
        group("Addons barrel", () => {
            test("exports loaders, helpers, passes and shaders cleanly", (expect) => {
                const draco = new ADDONS.DRACOLoader();
                const ply = new ADDONS.PLYLoader();
                const stl = new ADDONS.STLLoader();
                const svg = new ADDONS.SVGLoader();
                const lutCube = new ADDONS.LUTCubeLoader();
                const lut3dl = new ADDONS.LUT3dlLoader();
                expect.that(draco != null && ply != null && stl != null).is(true);
                expect.that(svg != null && lutCube != null && lut3dl != null).is(true);

                const scene = new THREE.Scene();
                const cam = new THREE.PerspectiveCamera(50, 1, 0.1, 100);
                const rp = new ADDONS.RenderPass(scene, cam);
                const sp = new ADDONS.ShaderPass(ADDONS.CopyShader);
                const op = new ADDONS.OutputPass();
                const fxaa = new ADDONS.FXAAPass();
                const bloom = new ADDONS.UnrealBloomPass(new THREE.Vector2(64, 64), 0.5, 0.4, 0.85);
                const smaa = new ADDONS.SMAAPass(64, 64);
                const taa = new ADDONS.TAARenderPass(scene, cam);
                const ssaa = new ADDONS.SSAARenderPass(scene, cam);
                const bokeh = new ADDONS.BokehPass(scene, cam);
                const outline = new ADDONS.OutlinePass(new THREE.Vector2(64, 64), scene, cam);
                const pixel = new ADDONS.RenderPixelatedPass(4, scene, cam);
                const after = new ADDONS.AfterimagePass();
                const clear = new ADDONS.ClearPass();
                const dot = new ADDONS.DotScreenPass();
                const film = new ADDONS.FilmPass();
                const glitch = new ADDONS.GlitchPass();
                const halftone = new ADDONS.HalftonePass(64, 64);
                const lut = new ADDONS.LUTPass();
                const mask = new ADDONS.MaskPass(scene, cam);
                const clearMask = new ADDONS.ClearMaskPass();
                const texPass = new ADDONS.TexturePass();
                const vh = new ADDONS.ViewHelper(cam);
                expect.that(rp.clear).is(true);
                expect.that(sp.needsSwap).is(true);
                expect.that(op.needsSwap).is(true);
                expect.that(fxaa.needsSwap).is(true);
                expect.that(bloom.strength).is(0.5);
                expect.that(smaa.needsSwap).is(true);
                expect.that(taa.accumulate).is(false);
                expect.that(ssaa.sampleLevel).is(4);
                expect.that(bokeh != null && outline != null && pixel != null).is(true);
                expect.that(after != null && clear != null && dot != null && film != null).is(true);
                expect.that(glitch != null && halftone != null && lut != null).is(true);
                expect.that(mask != null && clearMask != null && texPass != null && vh != null).is(true);
                expect.that(ADDONS.SSAOShader.name).is("SSAOShader");
                expect.that(ADDONS.GTAOShader.name).is("GTAOShader");
                expect.that(ADDONS.SAOShader.name).is("SAOShader");
                expect.that(ADDONS.BokehShader.name).is("BokehShader");
                expect.that(ADDONS.MeshoptDecoder != null).is(true);
                bloom.dispose();
                smaa.dispose();
                taa.dispose();
                ssaa.dispose();
                bokeh.dispose();
                outline.dispose();
                pixel.dispose();
                after.dispose();
                dot.dispose();
                film.dispose();
                glitch.dispose();
                halftone.dispose();
                lut.dispose();
                mask.dispose();
                texPass.dispose();
                vh.dispose();
            });
        });

        group("Post-processing passes", () => {
            test("RenderPass clearDepth and EffectComposer mask transitions", (expect) => {
                const scene = new THREE.Scene();
                const cam = new THREE.PerspectiveCamera();
                const rp = new ADDONS.RenderPass(scene, cam);
                expect.that(rp.clear).is(true);
                expect.that(rp.clearDepth).is(false);
                expect.that(rp.needsSwap).is(false);
                rp.clearDepth = true;
                expect.that(rp.clearDepth).is(true);

                const mask = new ADDONS.MaskPass(scene, cam);
                const clearMask = new ADDONS.ClearMaskPass();
                expect.that(ADDONS.EffectComposer.maskActiveAfter(mask, false)).is(true);
                expect.that(ADDONS.EffectComposer.maskActiveAfter(rp, true)).is(true);
                expect.that(ADDONS.EffectComposer.maskActiveAfter(clearMask, true)).is(false);
                mask.dispose();
            });

            test("GTAOPass OUTPUT.Off constant and defaults", (expect) => {
                const pass = new ADDONS.GTAOPass(new THREE.Scene(), new THREE.PerspectiveCamera(), 32, 32);
                expect.that(<f64>ADDONS.GTAOPass.OUTPUT.Off).is(-1);
                pass.output = ADDONS.GTAOPass.OUTPUT.Off;
                expect.that(<f64>pass.output).is(-1);
                pass.dispose();
            });

            test("SSAOPass generates 4-channel RGBA (x, y, 0, 1) noise texture", (expect) => {
                const pass = new ADDONS.SSAOPass(new THREE.Scene(), new THREE.PerspectiveCamera(), 32, 32);
                const noise = pass.noiseTexture;
                expect.that(<f64>noise.format).is(<f64>THREE.RGBAFormat);
                expect.that(<f64>noise.type).is(<f64>THREE.FloatType);
                expect.that(<f64>noise.width).is(4);
                expect.that(<f64>noise.height).is(4);
                const data = noise.data as Float32Array;
                expect.that(<f64>data.length).is(4 * 4 * 4);
                let xyValid = true;
                let zZero = true;
                let wOne = true;
                let xyDiffers = false;
                for (let i = 0; i < 16; i++) {
                    const x = <f64>data[i * 4];
                    const y = <f64>data[i * 4 + 1];
                    const z = <f64>data[i * 4 + 2];
                    const w = <f64>data[i * 4 + 3];
                    if (x < -1 || x > 1 || y < -1 || y > 1) xyValid = false;
                    if (z != 0) zZero = false;
                    if (w != 1) wOne = false;
                    if (Math.abs(x - y) > 1e-4) xyDiffers = true;
                }
                expect.that(xyValid).is(true);
                expect.that(zZero).is(true);
                expect.that(wOne).is(true);
                expect.that(xyDiffers).is(true);
                pass.generateSampleKernel(12);
                expect.that(<f64>pass.kernel.length).is(12);
                pass.dispose();
            });
        });

        group("Controls fixes", () => {
            test("TransformControls accounts for parent scale during translation", (expect) => {
                const cam = new THREE.PerspectiveCamera(50, 1, 0.1, 100);
                cam.position.set(0, 0, 5);
                cam.updateMatrixWorld();

                // Reference drag with unscaled parent.
                const scene1 = new THREE.Scene();
                const p1 = new THREE.Group();
                const b1 = new THREE.Mesh(new THREE.BoxGeometry(1, 1, 1));
                p1.add(b1);
                scene1.add(p1);
                const tc1 = new ADDONS.TransformControls(cam);
                tc1.attach(b1);
                scene1.add(tc1.getHelper());
                scene1.updateMatrixWorld();

                let x: f64 = 0.5;
                while (x < 0.75 && tc1.axis != "X") {
                    tc1.pointerMove(ev(x, 0.5));
                    x += 0.01;
                }
                expect.that(tc1.axis).is("X");
                tc1.pointerDown(ev(x, 0.5));
                tc1.pointerMove(ev(x + 0.1, 0.5));
                tc1.pointerUp(ev(x + 0.1, 0.5));
                const worldDeltaUnscaled = b1.position.x;
                expect.that(worldDeltaUnscaled > 0.2).is(true);

                // Same drag with parent scaled 2x on X: local delta must be half,
                // so world position moves by the exact same world delta.
                const scene2 = new THREE.Scene();
                const p2 = new THREE.Group();
                p2.scale.set(2, 3, 0.5);
                const b2 = new THREE.Mesh(new THREE.BoxGeometry(1, 1, 1));
                p2.add(b2);
                scene2.add(p2);
                const tc2 = new ADDONS.TransformControls(cam);
                tc2.attach(b2);
                scene2.add(tc2.getHelper());
                scene2.updateMatrixWorld();

                let x2: f64 = 0.5;
                while (x2 < 0.75 && tc2.axis != "X") {
                    tc2.pointerMove(ev(x2, 0.5));
                    x2 += 0.01;
                }
                expect.that(tc2.axis).is("X");
                tc2.pointerDown(ev(x2, 0.5));
                tc2.pointerMove(ev(x2 + 0.1, 0.5));
                tc2.pointerUp(ev(x2 + 0.1, 0.5));
                expect.that(approx(b2.position.x * 2, worldDeltaUnscaled, 1e-3)).is(true);

                tc1.dispose();
                tc2.dispose();
            });

            test("TransformControls.detach() resets dragging and fires dragging-changed", (expect) => {
                const cam = new THREE.PerspectiveCamera(50, 1, 0.1, 100);
                cam.position.set(0, 0, 5);
                cam.updateMatrixWorld();
                const scene = new THREE.Scene();
                const box = new THREE.Mesh(new THREE.BoxGeometry(1, 1, 1));
                scene.add(box);
                const tc = new ADDONS.TransformControls(cam);
                tc.attach(box);
                scene.add(tc.getHelper());
                scene.updateMatrixWorld();

                const listener = new DragListener();
                tc.addEventListener("dragging-changed", listener);
                let x: f64 = 0.5;
                while (x < 0.75 && tc.axis != "X") {
                    tc.pointerMove(ev(x, 0.5));
                    x += 0.01;
                }
                tc.pointerDown(ev(x, 0.5));
                expect.that(tc.dragging).is(true);
                expect.that(tc.capturing()).is(true);
                tc.detach();
                expect.that(tc.dragging).is(false);
                expect.that(tc.capturing()).is(false);
                expect.that(listener.lastValue).is(false);
                expect.that(<f64>listener.calls).is(2);
                tc.dispose();
            });

            test("FlyControls guards disabled mid-drag capture and 0x0 viewport", (expect) => {
                const obj = new THREE.Object3D();
                const fly = new ADDONS.FlyControls(obj);
                fly.dragToLook = true;
                fly.pointerDown(ev(10, 10));
                expect.that(fly.capturing()).is(true);
                fly.enabled = false;
                expect.that(fly.capturing()).is(false);
                fly.pointerUp(ev(10, 10));
                fly.enabled = true;
                expect.that(fly.capturing()).is(false);
                // Pointer move without viewport size does not introduce NaN.
                fly.pointerDown(ev(10, 10));
                fly.pointerMove(ev(20, 20));
                fly.update(0.1);
                expect.that(isFinite(obj.quaternion.x) && isFinite(obj.quaternion.w)).is(true);
                fly.pointerUp(ev(20, 20));
            });

            test("OrbitControls, FirstPersonControls capturing() and TrackballControls pointer dedup", (expect) => {
                const cam = new THREE.PerspectiveCamera(50, 1, 0.1, 100);
                cam.position.set(0, 0, 5);
                const orbit = new ADDONS.OrbitControls(cam);
                expect.that(orbit.capturing()).is(false);
                orbit.pointerDown(ev(10, 10, 1));
                expect.that(orbit.capturing()).is(true);
                orbit.pointerUp(ev(10, 10, 1));
                expect.that(orbit.capturing()).is(false);

                const fp = new ADDONS.FirstPersonControls(new THREE.Object3D());
                expect.that(fp.capturing()).is(false);
                fp.pointerDown(ev(10, 10, 1));
                expect.that(fp.capturing()).is(true);
                fp.pointerUp(ev(10, 10, 1));
                expect.that(fp.capturing()).is(false);

                const tb = new ADDONS.TrackballControls(cam);
                tb.pointerDown(ev(0.5, 0.5, 7));
                // Duplicate pointerDown with the same id must not duplicate tracking.
                tb.pointerDown(ev(0.6, 0.5, 7));
                expect.that(tb.capturing()).is(true);
                tb.pointerUp(ev(0.6, 0.5, 7));
                expect.that(tb.capturing()).is(false);
            });
        });

        group("Addon objects fixes", () => {
            test("MarchingCubes clamps drawRange.count to vertex capacity", (expect) => {
                const mc = new ADDONS.MarchingCubes(12, new THREE.MeshBasicMaterial(), false, false, 2);
                mc.reset();
                mc.addBall(0.5, 0.5, 0.5, 1.2, 12);
                mc.update();
                expect.that(mc.count > 6).is(true);
                expect.that(<f64>mc.geometry.drawRange.count).is(6);
            });

            test("VertexNormalsHelper clamps mismatched position and normal counts", (expect) => {
                const geo = new THREE.BufferGeometry();
                geo.setAttribute("position", new THREE.BufferAttribute(new Float32Array(12), 3)); // 4 verts
                geo.setAttribute("normal", new THREE.BufferAttribute(new Float32Array(6), 3));    // 2 verts
                const mesh = new THREE.Mesh(geo, new THREE.MeshBasicMaterial());
                const helper = new ADDONS.VertexNormalsHelper(mesh, 1);
                expect.that(<f64>helper.geometry.getAttribute("position")!.count).is(4); // 2 normals * 2 verts
                helper.update();
                helper.dispose();
            });

            test("Lensflare.dispose() completes cleanly", (expect) => {
                const lf = new ADDONS.Lensflare();
                lf.dispose();
                expect.that(lf.isLensflare).is(true);
            });
        });

        group("CSM and CSMFrustum", () => {
            test("CSMFrustum computes corners, clamps maxFar, splits and transforms", (expect) => {
                const cam = new THREE.PerspectiveCamera(60, 1, 1, 200);
                const f = new ADDONS.CSMFrustum();
                f.setFromProjectionMatrix(cam.projectionMatrix, 50);
                // Near plane at z = -1, far clamped to z = -50.
                expect.that(approx(f.near[0].z, -1, 1e-3)).is(true);
                expect.that(approx(f.far[0].z, -50, 1e-3)).is(true);
                expect.that(f.far[0].x > 0 && f.far[0].y > 0).is(true);
                expect.that(f.far[2].x < 0 && f.far[2].y < 0).is(true);

                const slices: Array<ADDONS.CSMFrustum> = [];
                f.split([0.25, 0.6, 1.0], slices);
                expect.that(<f64>slices.length).is(3);
                expect.that(approx(slices[0].near[0].z, f.near[0].z, 1e-3)).is(true);
                expect.that(approx(slices[0].far[0].z, slices[1].near[0].z, 1e-3)).is(true);
                expect.that(approx(slices[1].far[0].z, slices[2].near[0].z, 1e-3)).is(true);
                expect.that(approx(slices[2].far[0].z, f.far[0].z, 1e-3)).is(true);

                const shifted = new ADDONS.CSMFrustum();
                const m = new THREE.Matrix4().makeTranslation(10, 0, 0);
                slices[0].toSpace(m, shifted);
                expect.that(approx(shifted.near[0].x, slices[0].near[0].x + 10, 1e-3)).is(true);

                const ortho = new THREE.OrthographicCamera(-5, 5, 5, -5, 1, 100);
                const of = new ADDONS.CSMFrustum().setFromProjectionMatrix(ortho.projectionMatrix, 40);
                expect.that(approx(of.near[0].x, 5, 1e-3)).is(true);
                expect.that(approx(of.far[0].z, -40, 1e-3)).is(true);
            });

            test("CSM creates cascade lights, splits, updates and disposes", (expect) => {
                const scene = new THREE.Scene();
                const cam = new THREE.PerspectiveCamera(50, 1.5, 0.5, 100);
                cam.position.set(0, 5, 10);
                cam.lookAt(new THREE.Vector3(0, 0, 0));

                const params = new ADDONS.CSMParameters();
                params.camera = cam;
                params.parent = scene;
                params.cascades = 3;
                params.maxFar = 60;
                params.mode = "practical";
                const csm = new ADDONS.CSM(params);

                expect.that(<f64>csm.lights.length).is(3);
                expect.that(<f64>csm.breaks.length).is(3);
                expect.that(<f64>csm.frustums.length).is(3);
                expect.that(csm.breaks[0] > 0 && csm.breaks[0] < csm.breaks[1]).is(true);
                expect.that(csm.breaks[1] < 1 && approx(csm.breaks[2], 1, 1e-6)).is(true);
                expect.that(csm.lights[0].cascadeNear).is(0);
                expect.that(approx(csm.lights[0].cascadeFar, csm.lights[1].cascadeNear, 1e-4)).is(true);
                expect.that(approx(csm.lights[1].cascadeFar, csm.lights[2].cascadeNear, 1e-4)).is(true);
                // Each cascade adds light + light.target to parent.
                expect.that(<f64>scene.children.length).is(6);

                csm.update();
                expect.that(isFinite(csm.lights[0].position.x) && isFinite(csm.lights[0].position.z)).is(true);

                // Uniform and logarithmic modes produce valid splits.
                csm.mode = "uniform";
                csm.updateFrustums();
                expect.that(csm.breaks[0] > 0 && csm.breaks[0] < csm.breaks[1]).is(true);
                csm.mode = "logarithmic";
                csm.updateFrustums();
                expect.that(csm.breaks[0] > 0 && csm.breaks[0] < csm.breaks[1]).is(true);

                csm.dispose();
                expect.that(<f64>scene.children.length).is(0);
            });
        });
    }
}
