// Effect passes (M12d, part 1) without a GPU: rive . --test

import { Tests } from "rive/test";
import { Texture } from "../three/textures/Texture";
import { DepthTexture } from "../three/textures/DepthTexture";
import { Vector2 } from "../three/math/Vector2";
import { Color } from "../three/math/Color";
import { Object3D } from "../three/core/Object3D";
import { Scene } from "../three/scenes/Scene";
import { Mesh } from "../three/objects/Mesh";
import { Group } from "../three/objects/Group";
import { Line } from "../three/objects/Line";
import { PerspectiveCamera } from "../three/cameras/PerspectiveCamera";
import { AdditiveBlending, RedFormat, FloatType, HalfFloatType } from "../three/constants";
import { OutlinePass } from "../three/addons/postprocessing/OutlinePass";
import { BokehPass, BokehPassParameters } from "../three/addons/postprocessing/BokehPass";
import { AfterimagePass } from "../three/addons/postprocessing/AfterimagePass";
import { FilmPass } from "../three/addons/postprocessing/FilmPass";
import { GlitchPass } from "../three/addons/postprocessing/GlitchPass";
import { DotScreenPass } from "../three/addons/postprocessing/DotScreenPass";
import { DotScreenShader } from "../three/addons/shaders/DotScreenShader";
import { FilmShader } from "../three/addons/shaders/FilmShader";
import { BokehShader } from "../three/addons/shaders/BokehShader";
import { DigitalGlitch } from "../three/addons/shaders/DigitalGlitch";
import { AfterimageShader } from "../three/addons/shaders/AfterimageShader";

export class PostProcessingEffectsTests extends Tests {
    override run(): void {
        group("Effect shaders", () => {
            test("assets, entry points and uniform order", (expect) => {
                expect.that(DotScreenShader.createMaterial().shader).is("three/shaders/post/dot_screen");
                expect.that(FilmShader.createMaterial().shader).is("three/shaders/post/film");
                expect.that(AfterimageShader.createMaterial().uniforms.keys()[0]).is("damp");
                const b = BokehShader.createMaterial();
                expect.that(b.uniforms.keys()[1]).is("tDepth");
                expect.that(<f64>b.uniforms.size).is(9);
                expect.that(<f64>DigitalGlitch.createMaterial().uniforms.size).is(11);
            });
        });
        group("DotScreenPass", () => {
            test("defaults and parameters", (expect) => {
                const p = new DotScreenPass();
                expect.that(p.uniform<f64>("angle").value).is(1.57);
                expect.that(p.uniform<Vector2>("center").value.x).is(0.5);
                const q = new DotScreenPass(new Vector2(3, 4), 0.5, 0.8);
                expect.that(q.uniform<Vector2>("center").value.y).is(4);
                expect.that(q.uniform<f64>("scale").value).is(0.8);
                expect.that(q.needsSwap).is(true);
            });
        });
        group("FilmPass", () => {
            test("intensity and grayscale", (expect) => {
                const p = new FilmPass();
                expect.that(p.uniform<f64>("intensity").value).is(0.5);
                expect.that(p.uniform<f64>("grayscale").value).is(0);
                expect.that(new FilmPass(0.35, true).uniform<f64>("grayscale").value).is(1);
            });
        });
        group("AfterimagePass", () => {
            test("damp and history targets", (expect) => {
                const p = new AfterimagePass();
                expect.that(p.uniform<f64>("damp").value).is(0.96);
                expect.that(new AfterimagePass(0.8).uniform<f64>("damp").value).is(0.8);
                p.setSize(64, 32);
                expect.that(<f64>p.textureOld.width).is(64);
                expect.that(<f64>p.textureComp.height).is(32);
                expect.that(<f64>p.textureOld.type).is(<f64>HalfFloatType);
            });
        });
        group("GlitchPass", () => {
            test("heightmap", (expect) => {
                const p = new GlitchPass(16);
                const h = p.heightMap;
                expect.that(<f64>h.width).is(16);
                expect.that(<f64>h.format).is(<f64>RedFormat);
                expect.that(<f64>h.type).is(<f64>FloatType);
                const data = h.data as Float32Array;
                expect.that(<f64>data.length).is(256);
                let inRange = true;
                for (let i = 0; i < data.length; i++) if (data[i] < 0 || data[i] > 1) inRange = false;
                expect.that(inRange).is(true);
                expect.that(p.uniform<Texture>("tDisp").value === h).is(true);
                expect.that(p.randX >= 120 && p.randX <= 240).is(true);
                expect.that(p.goWild).is(false);
                expect.that(<f64>new GlitchPass().heightMap.width).is(64);
            });
        });
        group("BokehPass", () => {
            test("parameters and depth target", (expect) => {
                const scene = new Scene();
                const camera = new PerspectiveCamera(50, 2, 0.5, 80);
                const params = new BokehPassParameters();
                expect.that(params.maxblur).is(1);
                params.focus = 6;
                params.aperture = 0.005;
                params.maxblur = 0.01;
                const p = new BokehPass(scene, camera, params);
                expect.that(p.uniform<f64>("focus").value).is(6);
                expect.that(p.uniform<f64>("aspect").value).is(2);
                expect.that(p.uniform<f64>("nearClip").value).is(0.5);
                expect.that(p.uniform<f64>("farClip").value).is(80);
                expect.that(p.renderTargetDepth.depthTexture != null).is(true);
                expect.that(p.uniform<Texture>("tDepth").value instanceof DepthTexture).is(true);
                p.setSize(300, 100);
                expect.that(p.uniform<f64>("aspect").value).is(3);
                expect.that(<f64>p.renderTargetDepth.width).is(300);
                expect.that(new BokehPass(scene, camera).uniform<f64>("aperture").value).is(0.025);
            });
        });
        group("OutlinePass", () => {
            test("defaults, sizes and the selection", (expect) => {
                const scene = new Scene();
                const camera = new PerspectiveCamera();
                const group = new Group();
                const a = new Mesh();
                const b = new Mesh();
                group.add(a);
                group.add(b);
                const other = new Mesh();
                const line = new Line();
                scene.add(group);
                scene.add(other);
                scene.add(line);
                const sel: Array<Object3D> = [group];
                const p = new OutlinePass(new Vector2(200, 100), scene, camera, sel);
                expect.that(p.edgeStrength).is(3);
                expect.that(p.edgeThickness).is(1);
                expect.that(p.downSampleRatio).is(2);
                expect.that(p.needsSwap).is(false);
                expect.that(p.hiddenEdgeColor.equals(new Color(0.1, 0.04, 0.02))).is(true);
                expect.that(<f64>p.renderTargetMaskDownSampleBuffer.width).is(100);
                expect.that(<f64>p.renderTargetEdgeBuffer2.height).is(25);
                expect.that(<f64>p.overlayMaterial.blending).is(<f64>AdditiveBlending);
                p.setSize(400, 300);
                expect.that(<f64>p.renderTargetBlurBuffer1.width).is(200);
                expect.that(<f64>p.renderTargetBlurBuffer2.height).is(75);

                // Hiding and restoring, as the passes' stages do.
                other.visible = false;
                p.updateSelectionCache();
                p.changeVisibilityOfSelectedObjects(false);
                expect.that(a.visible || b.visible).is(false);
                p.changeVisibilityOfSelectedObjects(true);
                expect.that(a.visible && b.visible).is(true);
                p.changeVisibilityOfNonSelectedObjects(false);
                expect.that(line.visible).is(false);
                expect.that(a.visible).is(true);
                p.changeVisibilityOfNonSelectedObjects(true);
                expect.that(line.visible).is(true);
                expect.that(other.visible).is(false);
            });
        });
    }
}
