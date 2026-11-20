// Effect passes (M12d: halftone, LUT, pixelated, texture, clear, masks)
// that run without a GPU: rive . --test

import { Tests } from "rive/test";
import { LUTCubeLoader } from "../three/addons/loaders/LUTCubeLoader";
import { LUT3dlLoader } from "../three/addons/loaders/LUT3dlLoader";
import { HalftonePass, HalftonePassParameters } from "../three/addons/postprocessing/HalftonePass";
import { LUTPass, LUTPassParameters } from "../three/addons/postprocessing/LUTPass";
import { RenderPixelatedPass } from "../three/addons/postprocessing/RenderPixelatedPass";
import { TexturePass } from "../three/addons/postprocessing/TexturePass";
import { ClearPass } from "../three/addons/postprocessing/ClearPass";
import { MaskPass, ClearMaskPass } from "../three/addons/postprocessing/MaskPass";
import { EffectComposer } from "../three/addons/postprocessing/EffectComposer";
import { HalftoneShader } from "../three/addons/shaders/HalftoneShader";
import { Scene } from "../three/scenes/Scene";
import { PerspectiveCamera } from "../three/cameras/PerspectiveCamera";
import { Texture } from "../three/textures/Texture";
import { FloatType, LinearFilter, UnsignedByteType } from "../three/constants";

const CUBE = "TITLE \"Tiny\"\n# a comment\nLUT_3D_SIZE 2\nDOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n"
    + "0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n";

// Blue fastest, 10-bit values.
const DL3 = "0 1023\n0 0 0\n0 0 1023\n0 1023 0\n0 1023 1023\n512 0 0\n1023 0 1023\n1023 1023 0\n1023 1023 1023\n";

export class PostProcessingEffects2Tests extends Tests {
    override run(): void {
        group("LUTCubeLoader", () => {
            test("parses size, title, domain and texels", (expect) => {
                const r = new LUTCubeLoader().parse(CUBE)!;
                expect.that(<f64>r.size).is(2);
                expect.that(r.title).is("Tiny");
                expect.that(r.domainMax.x).is(1);
                const t = r.texture3D;
                expect.that(<f64>t.width).is(2);
                expect.that(<f64>t.depth).is(2);
                expect.that(<f64>t.magFilter).is(<f64>LinearFilter);
                expect.that(t.generateMipmaps).is(false);
                const d = t.data as Uint8Array;
                expect.that(<f64>d.length).is(32);
                // Texel 1 is (1, 0, 0), texel 2 (0, 1, 0); alpha 255.
                expect.that(<f64>d[4]).is(255);
                expect.that(<f64>d[5]).is(0);
                expect.that(<f64>d[9]).is(255);
                expect.that(<f64>d[31]).is(255);
            });
            test("float type and errors", (expect) => {
                const loader = new LUTCubeLoader().setType(FloatType);
                const r = loader.parse(CUBE)!;
                expect.that((r.texture3D.data as Float32Array)[28]).is(1);
                expect.that(<f64>r.texture3D.type).is(<f64>FloatType);
                expect.that(loader.parse("0 0 0\n") == null).is(true);
                expect.that(loader.error).is("LUTCubeLoader: Missing LUT_3D_SIZE information");
                expect.that(loader.parse("LUT_3D_SIZE 2\nDOMAIN_MIN 1 1 1\nDOMAIN_MAX 0 0 0\n") == null).is(true);
            });
        });
        group("LUT3dlLoader", () => {
            test("reorders blue-fastest data and scales by bit depth", (expect) => {
                const r = new LUT3dlLoader().parse(DL3)!;
                expect.that(<f64>r.size).is(2);
                const d = r.texture3D.data as Uint8Array;
                // File entry 1 (b = 1023) lands at texel (r 0, g 0, b 1) = index 4: 1023 / 1023 * 255 = 255.
                expect.that(<f64>d[4 * 4 + 2]).is(255);
                // File entry 4 (r = 512) lands at texel index 1: floor(512 / 1023 * 255) = 127.
                expect.that(<f64>d[1 * 4]).is(127);
                expect.that(<f64>d[3]).is(255);
                expect.that(<f64>r.texture3D.type).is(<f64>UnsignedByteType);
                // FloatType: max 10-bit value (1023) normalizes to exact 1.0.
                const rf = new LUT3dlLoader().setType(FloatType).parse(DL3)!;
                const df = rf.texture3D.data as Float32Array;
                expect.that(<f64>df[4 * 4 + 2]).is(1.0);
            });
            test("grid errors", (expect) => {
                const loader = new LUT3dlLoader();
                expect.that(loader.parse("0 1 3\n0 0 0\n") == null).is(true);
                expect.that(loader.error).is("LUT3dlLoader: Inconsistent grid size");
                expect.that(loader.parse("") == null).is(true);
            });
        });
        group("Effect passes", () => {
            test("HalftonePass takes its params", (expect) => {
                const p = new HalftonePassParameters();
                p.shape = 3;
                p.radius = 7;
                p.greyscale = true;
                const pass = new HalftonePass(200, 100, p);
                expect.that(pass.uniform("shape").value).is(3);
                expect.that(pass.uniform("radius").value).is(7);
                expect.that(pass.uniform("greyscale").value).is(1);
                expect.that(pass.uniform("width").value).is(200);
                pass.setSize(64, 32);
                expect.that(pass.uniform("height").value).is(32);
                const d = new HalftonePass(1, 1);
                expect.that(d.uniform("radius").value).is(4);
                expect.that(<f64>HalftoneShader.createMaterial().uniforms.size).is(13);
            });
            test("LUTPass lut and intensity", (expect) => {
                const lut = new LUTCubeLoader().parse(CUBE)!.texture3D;
                const o = new LUTPassParameters();
                o.lut = lut;
                o.intensity = 0.5;
                const pass = new LUTPass(o);
                expect.that(pass.lut === lut).is(true);
                expect.that(pass.intensity).is(0.5);
                expect.that(pass.uniform<f64>("lutSize").value).is(2);
                expect.that(new LUTPass().intensity).is(1);
                expect.that(new LUTPass().lut == null).is(true);
            });
            test("RenderPixelatedPass sizes its targets", (expect) => {
                const pass = new RenderPixelatedPass(4, new Scene(), new PerspectiveCamera());
                expect.that(pass.normalEdgeStrength).is(0.3);
                expect.that(pass.depthEdgeStrength).is(0.4);
                pass.setSize(101, 50);
                expect.that(pass.renderResolution.x).is(25);
                expect.that(<f64>pass.beautyRenderTarget.width).is(25);
                expect.that(<f64>pass.normalRenderTarget.height).is(12);
                expect.that(pass.beautyRenderTarget.depthTexture != null).is(true);
                pass.setPixelSize(2);
                expect.that(<f64>pass.beautyRenderTarget.width).is(50);
            });
            test("TexturePass, ClearPass, MaskPass do not swap", (expect) => {
                const t = new TexturePass(new Texture(), 0.5);
                expect.that(t.needsSwap).is(false);
                expect.that(t.opacity).is(0.5);
                const c = new ClearPass();
                expect.that(c.needsSwap).is(false);
                expect.that(c.clearAlpha).is(0);
                const m = new MaskPass(new Scene(), new PerspectiveCamera());
                expect.that(m.needsSwap).is(false);
                expect.that(m.clear).is(true);
                expect.that(m.inverse).is(false);
                m.setSize(64, 32);
                expect.that(<f64>m.maskTarget.width).is(64);
                expect.that(new ClearMaskPass().needsSwap).is(false);
            });
            test("masks toggle the composer's state", (expect) => {
                const mask = new MaskPass(new Scene(), new PerspectiveCamera());
                const clear = new ClearMaskPass();
                const other = new TexturePass();
                expect.that(EffectComposer.maskActiveAfter(mask, false)).is(true);
                expect.that(EffectComposer.maskActiveAfter(other, true)).is(true);
                expect.that(EffectComposer.maskActiveAfter(other, false)).is(false);
                expect.that(EffectComposer.maskActiveAfter(clear, true)).is(false);
            });
        });
    }
}
