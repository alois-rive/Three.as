// 32-bit float textures and render targets (texture.internalFormat
// "RGBA32F"), as GPUComputationRenderer uses them: formats, the
// options and the uploads. rive . --test

import { Tests } from "rive/test";
import { TextureFormat } from "rive/gpu_enums";
import { RenderTarget, RenderTargetOptions } from "../three/renderers/RenderTarget";
import { gpuFormat, isFloat32, uploadBytes } from "../three/textures/DataUpload";
import {
    FloatType, HalfFloatType, LinearFilter, NearestFilter, RGBAFormat, RGBFormat, RepeatWrapping,
} from "../three/constants";

export class FloatTargetTests extends Tests {
    override run(): void {
        group("32-bit float textures", () => {
            test("RenderTarget: RGBA32F FloatType targets are rgba32float where supported", (expect) => {
                const o = new RenderTargetOptions();
                o.type = FloatType;
                o.internalFormat = "RGBA32F";
                o.minFilter = NearestFilter;
                o.magFilter = NearestFilter;
                o.wrapS = RepeatWrapping;
                const rt = new RenderTarget(4, 4, o);
                expect.that(<f64>rt.hdrFormat(true)).is(<f64>TextureFormat.rgba32float);
                expect.that(<f64>rt.hdrFormat(false)).is(<f64>TextureFormat.rgba16float);
                expect.that(<f64>rt.texture.type).is(<f64>FloatType);
                const c = rt.clone();
                expect.that(c.texture.internalFormat!).is("RGBA32F");
                expect.that(<f64>c.texture.wrapS).is(<f64>RepeatWrapping);
                expect.that(<f64>c.texture.minFilter).is(<f64>NearestFilter);
                // Without it, FloatType stays rgba16float, as before.
                const plain = new RenderTarget(4, 4, { type: FloatType });
                expect.that(<f64>plain.hdrFormat(true)).is(<f64>TextureFormat.rgba16float);
                expect.that(<f64>plain.texture.minFilter).is(<f64>LinearFilter);
            });
            test("DataTexture uploads: 32-bit floats kept, RGB widened", (expect) => {
                expect.that(isFloat32(FloatType, "RGBA32F")).is(true);
                expect.that(isFloat32(HalfFloatType, "RGBA32F")).is(false);
                expect.that(isFloat32(FloatType, null)).is(false);
                const data = new Float32Array(8);
                for (let i = 0; i < 8; i++) data[i] = <f32>(123.456789 * <f64>(i + 1));
                const bytes = uploadBytes(data, RGBAFormat, FloatType, 2, true);
                const back = Float32Array.wrap(bytes);
                expect.that(back.length).is(8);
                for (let i = 0; i < 8; i++) expect.that(back[i]).is(data[i]);
                // Half floats otherwise (2 bytes a channel).
                expect.that(uploadBytes(data, RGBAFormat, FloatType, 2).byteLength).is(16);
                const rgb = new Float32Array(6);
                rgb[0] = 1.5; rgb[3] = -2.25;
                const wide = Float32Array.wrap(uploadBytes(rgb, RGBFormat, FloatType, 2, true));
                expect.that(wide.length).is(8);
                expect.that(wide[0]).is(<f32>1.5);
                expect.that(wide[3]).is(<f32>1);
                expect.that(wide[4]).is(<f32>-2.25);
                expect.that(<f64>gpuFormat(RGBAFormat, FloatType)).is(<f64>TextureFormat.rgba16float);
            });
        });
    }
}
