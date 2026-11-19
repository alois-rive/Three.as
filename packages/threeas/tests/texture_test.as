// Texture transforms and channels: rive . --test

import { Tests } from "rive/test";
import { Texture } from "../three/textures/Texture";
import { Vector2 } from "../three/math/Vector2";
import { Vector3 } from "../three/math/Vector3";
import { CubeTexture } from "../three/textures/CubeTexture";
import { CubeCamera } from "../three/cameras/CubeCamera";
import { WebGLCubeRenderTarget } from "../three/renderers/WebGLCubeRenderTarget";
import { CubeReflectionMapping, HalfFloatType, RGB_S3TC_DXT1_Format, RGBA_ASTC_4x4_Format, SRGBColorSpace } from "../three/constants";
import { KTX2Loader } from "../three/addons/loaders/KTX2Loader";
import { CompressedTexture } from "../three/textures/CompressedTexture";
import { unzlibSync } from "../three/addons/libs/fflate";

function apply(t: Texture, u: f64, v: f64): Vector2 {
    const p = new Vector3(u, v, 1).applyMatrix3(t.matrix);
    return new Vector2(p.x, p.y);
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
