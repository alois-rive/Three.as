// Views and render target features that run without a GPU (M12):
// rive . --test

import { Tests } from "rive/test";
import { PerspectiveCamera } from "../three/cameras/PerspectiveCamera";
import { OrthographicCamera } from "../three/cameras/OrthographicCamera";
import { ArrayCamera } from "../three/cameras/ArrayCamera";
import { StereoCamera } from "../three/cameras/StereoCamera";
import { Vector3 } from "../three/math/Vector3";
import { Vector4 } from "../three/math/Vector4";
import { RenderTarget } from "../three/renderers/RenderTarget";
import { RendererInfo } from "../three/renderers/GPURenderer";
import { RenderTargetOptions } from "../three/renderers/RenderTarget";
import { DepthTexture } from "../three/textures/DepthTexture";
import { FramebufferTexture } from "../three/textures/FramebufferTexture";
import {
    HalfFloatType, NoColorSpace, UnsignedIntType, UnsignedInt248Type, DepthFormat, DepthStencilFormat, NearestFilter,
} from "../three/constants";

function near(a: f64, b: f64): bool { return Math.abs(a - b) < 1e-4; }

export class ViewsTests extends Tests {
    override run(): void {
        group("setViewOffset", () => {
            test("a quarter of a perspective view", (expect) => {
                const full = new PerspectiveCamera(60, 2, 1, 10);
                const part = new PerspectiveCamera(60, 2, 1, 10);
                part.setViewOffset(200, 100, 100, 0, 100, 50);
                // The top right quarter's centre is the full view's (0.5, 0.5).
                const p = new Vector3(0.5, 0.5, 0.5).applyMatrix4(full.projectionMatrixInverse);
                const q = p.clone().applyMatrix4(part.projectionMatrix);
                expect.that(near(q.x, 0)).is(true);
                expect.that(near(q.y, 0)).is(true);
                expect.that(near(part.aspect, 2)).is(true);
                part.clearViewOffset();
                expect.that(near(part.projectionMatrix.elements[0], full.projectionMatrix.elements[0])).is(true);
                expect.that(near(part.projectionMatrix.elements[8], 0)).is(true);
            });
            test("orthographic", (expect) => {
                const cam = new OrthographicCamera(-2, 2, 1, -1, 0.1, 10);
                cam.setViewOffset(400, 200, 0, 0, 200, 100);
                // The top left half: x in [-2, 0], y in [0, 1].
                const p = new Vector3(-1, 0.5, -1).applyMatrix4(cam.projectionMatrix);
                expect.that(near(p.x, 0)).is(true);
                expect.that(near(p.y, 0)).is(true);
                const copy = cam.clone() as OrthographicCamera;
                expect.that(copy.view != null && copy.view!.width == 200).is(true);
            });
        });
        group("ArrayCamera", () => {
            test("holds sub-cameras with viewports", (expect) => {
                const a = new PerspectiveCamera();
                a.viewport = new Vector4(0, 0, 100, 50);
                const b = new PerspectiveCamera();
                b.viewport = new Vector4(100, 0, 100, 50);
                const array = new ArrayCamera([a, b]);
                expect.that(array.isArrayCamera).is(true);
                expect.that(<f64>array.cameras.length).is(2);
                expect.that(array.cameras[1].viewport!.x).is(100);
                const c = a.clone() as PerspectiveCamera;
                expect.that(c.viewport!.z).is(100);
            });
        });
        group("StereoCamera", () => {
            test("off-axis eyes either side", (expect) => {
                const camera = new PerspectiveCamera(50, 1, 0.1, 100);
                camera.position.set(0, 0, 5);
                camera.updateMatrixWorld();
                const stereo = new StereoCamera();
                stereo.eyeSep = 0.2;
                stereo.update(camera);
                const l = new Vector3().setFromMatrixPosition(stereo.cameraL.matrixWorld);
                const r = new Vector3().setFromMatrixPosition(stereo.cameraR.matrixWorld);
                expect.that(near(l.x, -0.1)).is(true);
                expect.that(near(r.x, 0.1)).is(true);
                expect.that(near(l.z, 5)).is(true);
                // Off axis: the frustums shift towards each other.
                expect.that(stereo.cameraL.projectionMatrix.elements[8] > 0).is(true);
                expect.that(stereo.cameraR.projectionMatrix.elements[8] < 0).is(true);
                expect.that(stereo.cameraL.layers.isEnabled(1)).is(true);
                expect.that(stereo.cameraR.layers.isEnabled(2)).is(true);
            });
        });
        group("RenderTarget viewport", () => {
            test("whole target, reset by setSize", (expect) => {
                const rt = new RenderTarget(64, 32);
                expect.that(rt.viewport.z).is(64);
                expect.that(rt.scissor.w).is(32);
                rt.viewport.set(0, 0, 10, 10);
                rt.setSize(128, 16);
                expect.that(rt.viewport.z).is(128);
                expect.that(rt.viewport.w).is(16);
                expect.that(rt.scissorTest).is(false);
            });
        });
        group("Multiple render targets", () => {
            test("count, textures and clone", (expect) => {
                const o = new RenderTargetOptions();
                o.type = HalfFloatType;
                o.count = 3;
                const rt = new RenderTarget(32, 16, o);
                expect.that(<f64>rt.count).is(3);
                expect.that(rt.textures[0] === rt.texture).is(true);
                expect.that(rt.textures[1].colorSpace).is(NoColorSpace);
                expect.that(rt.textures[2].premultiplyAlpha).is(false);
                rt.setSize(64, 8);
                expect.that(<f64>rt.textures[2].width).is(64);
                const c = rt.clone();
                expect.that(<f64>c.count).is(3);
                expect.that(c.textures[1] !== rt.textures[1]).is(true);
                o.count = 9;
                expect.that(<f64>new RenderTarget(4, 4, o).count).is(4);
            });
        });
        group("DepthTexture", () => {
            test("defaults and render target clone", (expect) => {
                const d = new DepthTexture(16, 8);
                expect.that(d.isDepthTexture).is(true);
                expect.that(<f64>d.width).is(16);
                expect.that(<f64>d.type).is(<f64>UnsignedIntType);
                expect.that(<f64>d.format).is(<f64>DepthFormat);
                expect.that(<f64>d.minFilter).is(<f64>NearestFilter);
                expect.that(d.generateMipmaps).is(false);
                expect.that(<f64>new DepthTexture(1, 1, -1, DepthStencilFormat).type).is(<f64>UnsignedInt248Type);
                const o = new RenderTargetOptions();
                o.depthTexture = d;
                const rt = new RenderTarget(16, 8, o);
                expect.that(rt.depthTexture === d).is(true);
                const c = rt.clone();
                expect.that(c.depthTexture != null && c.depthTexture !== d).is(true);
            });
        });
        group("FramebufferTexture", () => {
            test("size and filters", (expect) => {
                const t = new FramebufferTexture(64, 32);
                expect.that(t.isFramebufferTexture).is(true);
                expect.that(<f64>t.width).is(64);
                expect.that(<f64>t.height).is(32);
                expect.that(<f64>t.magFilter).is(<f64>NearestFilter);
                expect.that(t.generateMipmaps).is(false);
            });
        });
        group("RendererInfo", () => {
            test("reset clears the render counters", (expect) => {
                const info = new RendererInfo();
                info.render.calls = 5;
                info.render.triangles = 12;
                info.render.frame = 3;
                info.reset();
                expect.that(<f64>info.render.calls).is(0);
                expect.that(<f64>info.render.triangles).is(0);
                expect.that(<f64>info.render.frame).is(3);
                expect.that(info.autoReset).is(true);
                expect.that(<f64>info.memory.geometries).is(0);
            });
        });
    }
}
