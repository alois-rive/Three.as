// Texture transforms and channels: rive . --test

import { Tests } from "rive/test";
import { Texture } from "../three/textures/Texture";
import { Event, EventListener } from "../three/core/EventDispatcher";
import { Vector2 } from "../three/math/Vector2";
import { Vector3 } from "../three/math/Vector3";
import { CubeTexture } from "../three/textures/CubeTexture";
import { CubeCamera } from "../three/cameras/CubeCamera";
import { WebGLCubeRenderTarget } from "../three/renderers/WebGLCubeRenderTarget";
import {
    CubeReflectionMapping, HalfFloatType, RGB_S3TC_DXT1_Format, RGBA_ASTC_4x4_Format, RGBA_ASTC_6x5_Format,
    SRGBColorSpace, RGBAFormat,
} from "../three/constants";
import { KTX2Loader } from "../three/addons/loaders/KTX2Loader";
import { CompressedTexture, CompressedMipmap } from "../three/textures/CompressedTexture";
import { decodeCompressedJob } from "../three/textures/decoders/TextureDecoders";
import { unzlibSync } from "../three/addons/libs/fflate";

/// tools/make_ktx2_samples.py's 64 x 64 checker: yellow cells, and blue
/// ones with a gradient.
function checkerTexel(x: i32, y: i32, c: i32): i32 {
    if (((x * 4 / 64) + (y * 4 / 64)) % 2 == 1) return c == 0 ? 240 : c == 1 ? 200 : 60;
    const t = <f64>(x + y) / 128;
    return c == 0 ? <i32>(40 + 60 * t) : c == 1 ? <i32>(90 + 80 * t) : <i32>(200 - 60 * t);
}

/// How many bytes of `a` differ from `b[offset..]` by more than `tolerance`.
function differences(a: Uint8Array, b: Uint8Array, offset: i32, tolerance: i32): i32 {
    let n = 0;
    for (let i = 0; i < a.length; i++) if (Math.abs(<i32>a[i] - <i32>b[offset + i]) > tolerance) n++;
    return n;
}

function apply(t: Texture, u: f64, v: f64): Vector2 {
    const p = new Vector3(u, v, 1).applyMatrix3(t.matrix);
    return new Vector2(p.x, p.y);
}

class CountTextureDisposes extends EventListener {
    count: i32 = 0;
    override handleEvent(event: Event): void { this.count++; }
}

export class TextureTests extends Tests {
    override run(): void {
        group("Texture.matrix", () => {
            test("identity by default", (expect) => {
                const t = new Texture();
                t.updateMatrix();
                const p = apply(t, 0.25, 0.75);
                expect.that(Math.abs(p.x - (0.25)) < 1e-9).is(true);
                expect.that(Math.abs(p.y - (0.75)) < 1e-9).is(true);
            });
            test("offset and repeat, as uv * repeat + offset", (expect) => {
                const t = new Texture();
                t.offset.set(0.5, 0.25);
                t.repeat.set(2, 4);
                t.updateMatrix();
                const p = apply(t, 1, 1);
                expect.that(Math.abs(p.x - (2.5)) < 1e-9).is(true);
                expect.that(Math.abs(p.y - (4.25)) < 1e-9).is(true);
            });
            test("rotation about the center", (expect) => {
                const t = new Texture();
                t.center.set(0.5, 0.5);
                t.rotation = Math.PI / 2;
                t.updateMatrix();
                // The center stays; (1, 0.5) turns to (0.5, 0) (three.js rotates uvs clockwise).
                const c = apply(t, 0.5, 0.5);
                expect.that(Math.abs(c.x - (0.5)) < 1e-9).is(true);
                expect.that(Math.abs(c.y - (0.5)) < 1e-9).is(true);
                const p = apply(t, 1, 0.5);
                expect.that(Math.abs(p.x - (0.5)) < 1e-9).is(true);
                expect.that(Math.abs(p.y - (0)) < 1e-9).is(true);
            });
            test("channel defaults to the first uv set", (expect) => {
                expect.that(<f64>new Texture().channel).is(0);
            });
        });
        group("CubeTexture", () => {
            test("six faces, cube mapping, not sampled until ready", (expect) => {
                const t = new CubeTexture();
                expect.that(<f64>t.faces.length).is(6);
                expect.that(<f64>t.mapping).is(<f64>CubeReflectionMapping);
                expect.that(t.ready).is(false);
                expect.that(t.flipX).is(true);
                // dispose() disposes all 6 owned face textures.
                const l = new CountTextureDisposes();
                for (let i = 0; i < 6; i++) t.faces[i].addEventListener("dispose", l);
                t.dispose();
                expect.that(l.count).is(6);
            });
            test("a cube render target's faces are its targets' textures", (expect) => {
                const rt = new WebGLCubeRenderTarget(32);
                expect.that(<f64>rt.faces.length).is(6);
                expect.that(rt.texture.faces[3] === rt.faces[3].texture).is(true);
                expect.that(<f64>rt.faces[0].type).is(<f64>HalfFloatType);
                expect.that(rt.texture.flipX).is(false);
            });
            test("CubeCamera faces look along +x -x +y -y +z -z", (expect) => {
                const cc = new CubeCamera(0.1, 10, new WebGLCubeRenderTarget(8));
                cc.updateMatrixWorld();
                const want: StaticArray<f64> = [1, 0, 0, -1, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 1, 0, 0, -1];
                for (let i = 0; i < 6; i++) {
                    const d = cc.cameras[i].getWorldDirection(new Vector3());
                    expect.that(Math.abs(d.x - want[i * 3]) + Math.abs(d.y - want[i * 3 + 1])
                        + Math.abs(d.z - want[i * 3 + 2]) < 1e-9).is(true);
                }
            });
            test("CubeCamera faces share its layers", (expect) => {
                const cc = new CubeCamera(0.1, 10, new WebGLCubeRenderTarget(8));
                cc.layers.set(1);
                for (let i = 0; i < 6; i++) {
                    expect.that(cc.cameras[i].layers.mask).is(2);
                    expect.that(cc.cameras[i].layers === cc.layers).is(true);
                }
            });
        });
        group("KTX2Loader", () => {
            test("BC1 with its mip chain", (expect) => {
                const bytes = this.blob("checker_bc1.ktx2");
                if (bytes == null) return;
                const loader = new KTX2Loader();
                const t = loader.parse(unzlibSync(Uint8Array.wrap(bytes!)));
                expect.that(loader.error).is("");
                expect.that(t instanceof CompressedTexture).is(true);
                if (t == null) return;
                const c = t as CompressedTexture;
                expect.that(<f64>c.format).is(<f64>RGB_S3TC_DXT1_Format);
                expect.that(c.colorSpace).is(SRGBColorSpace);
                expect.that(<f64>c.mipmaps.length).is(5);
                expect.that(<f64>c.mipmaps[0].data.length).is(16 * 16 * 8);
                expect.that(<f64>c.mipmaps[4].width).is(4);
            });
            test("BC1 through the CPU fallback: the generator's texels", (expect) => {
                const bytes = this.blob("checker_bc1.ktx2");
                const expected = this.blob("ktx2_expected");
                if (bytes == null || expected == null) return;
                // A device without BC: the texture decodes on the CPU.
                const loader = new KTX2Loader();
                loader.workerConfig.dxtSupported = false;
                const t = loader.parse(unzlibSync(Uint8Array.wrap(bytes!))) as CompressedTexture;
                expect.that(t.cpuDecode).is(true);
                expect.that(<f64>t.format).is(<f64>RGB_S3TC_DXT1_Format);
                expect.that(t.colorSpace).is(SRGBColorSpace);
                const levels = t.decompress();
                expect.that(levels.length).is(5);
                expect.that(<f64>levels[4].width).is(4);
                expect.that(levels[4].data.length).is(4 * 4 * 4);
                // Level 0 is the palette entries tools/make_ktx2_samples.py
                // picked, texel for texel.
                const want = unzlibSync(Uint8Array.wrap(expected!));
                expect.that(levels[0].data.length).is(64 * 64 * 4);
                expect.that(differences(levels[0].data, want, 0, 0)).is(0);
                // A yellow cell: (240, 200, 60) in 5-6-5 (30, 50, 7), widened
                // back by bit replication.
                const o = (8 * 64 + 24) * 4;
                const d = levels[0].data;
                expect.that(d[o].toString() + "," + d[o + 1].toString() + "," + d[o + 2].toString()).is("247,203,57");
                // With the device's support (the default), the blocks go to the GPU.
                const gpu = new KTX2Loader().parse(unzlibSync(Uint8Array.wrap(bytes!))) as CompressedTexture;
                expect.that(gpu.cpuDecode).is(false);
            });
            test("ASTC void extents through the CPU fallback", (expect) => {
                const bytes = this.blob("checker_astc.ktx2");
                if (bytes == null) return;
                const loader = new KTX2Loader();
                loader.workerConfig.astcSupported = false;
                const t = loader.parse(unzlibSync(Uint8Array.wrap(bytes!))) as CompressedTexture;
                expect.that(t.cpuDecode).is(true);
                const levels = t.decompress();
                expect.that(levels.length).is(1);
                // Each 4x4 block is the average of its texels (the generator
                // stores avg * 257; the sRGB decode keeps the top 8 bits: avg).
                let bad = 0;
                for (let by = 0; by < 16; by++) {
                    for (let bx = 0; bx < 16; bx++) {
                        for (let c = 0; c < 3; c++) {
                            let sum = 0;
                            for (let j = 0; j < 16; j++) sum += checkerTexel(bx * 4 + (j & 3), by * 4 + (j >> 2), c);
                            const got = <i32>levels[0].data[((by * 4 + 1) * 64 + bx * 4 + 2) * 4 + c];
                            if (got != sum / 16) bad++;
                        }
                    }
                }
                expect.that(bad).is(0);
            });
            test("ASTC 6x5 blocks and their mip chain through the CPU fallback", (expect) => {
                const bytes = this.blob("checker_astc6x5.ktx2");
                const expected = this.blob("ktx2_expected");
                if (bytes == null || expected == null) return;
                // No Rive GPU format for 6x5: the CPU decodes it whatever the
                // device has.
                const t = new KTX2Loader().parse(unzlibSync(Uint8Array.wrap(bytes!))) as CompressedTexture;
                expect.that(<f64>t.format).is(<f64>RGBA_ASTC_6x5_Format);
                expect.that(t.cpuDecode).is(true);
                expect.that(t.colorSpace).is(SRGBColorSpace);
                expect.that(t.mipmaps.length).is(7);
                const levels = t.decompress();
                let sizes = "";
                for (let l = 0; l < levels.length; l++) {
                    sizes += levels[l].width.toString() + "x" + levels[l].height.toString() + ":"
                        + (levels[l].data.length / 4).toString() + " ";
                }
                expect.that(sizes).is("64x64:4096 32x32:1024 16x16:256 8x8:64 4x4:16 2x2:4 1x1:1 ");
                // Level 0 is what tools/astc_encode.py computed for its blocks.
                const want = unzlibSync(Uint8Array.wrap(expected!));
                expect.that(differences(levels[0].data, want, 64 * 64 * 4, 0)).is(0);
                // The job decodes the same chain.
                const n = t.mipmaps.length;
                let total = 0;
                for (let l = 0; l < n; l++) total += t.mipmaps[l].data.length;
                const all = new Uint8Array(total);
                const offsets = new Int32Array(n), widths = new Int32Array(n), heights = new Int32Array(n);
                let o = 0;
                for (let l = 0; l < n; l++) {
                    offsets[l] = o;
                    widths[l] = <i32>t.mipmaps[l].width;
                    heights[l] = <i32>t.mipmaps[l].height;
                    all.set(t.mipmaps[l].data, o);
                    o += t.mipmaps[l].data.length;
                }
                const job = decodeCompressedJob(t.format, true, all.buffer, offsets, widths, heights);
                expect.that(job.error).is("");
                expect.that(job.levels.length).is(7);
                expect.that(differences(levels[0].data, job.levels[0], 0, 0)).is(0);
                let decodedBytes = 0;
                for (let l = 0; l < job.levels.length; l++) decodedBytes += job.levels[l].length;
                expect.that(decodedBytes).is((4096 + 1024 + 256 + 64 + 16 + 4 + 1) * 4);
            });
            test("RGBAFormat mipmaps pass through", (expect) => {
                const t = new CompressedTexture([new CompressedMipmap(new Uint8Array(16), 2, 2)], 2, 2, RGBAFormat);
                expect.that(t.decompress().length).is(1);
                expect.that(t.decompress()[0].data.length).is(16);
            });
            test("ASTC header", (expect) => {
                const bytes = this.blob("checker_astc.ktx2");
                if (bytes == null) return;
                const h = new KTX2Loader().parseHeader(unzlibSync(Uint8Array.wrap(bytes!)));
                expect.that(h != null).is(true);
                if (h == null) return;
                expect.that(<f64>h.format).is(<f64>RGBA_ASTC_4x4_Format);
                expect.that(<f64>h.width).is(64);
                expect.that(h.srgb).is(true);
            });
        });
    }
}
