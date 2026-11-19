// three.js examples/jsm/lights/LightProbeGenerator.js. three.js reads a
// cube map's pixels back on the CPU; Rive images cannot be read back, so
// the probe comes from data already on the CPU: an equirectangular
// DataTexture (e.g. from RGBELoader or EXRLoader), `fromEquirectangular`.
// `fromCubeTexture` / `fromCubeRenderTarget` are not ported.

import { LightProbe } from "../../lights/LightProbe";
import { SphericalHarmonics3 } from "../../math/SphericalHarmonics3";
import { DataTexture } from "../../textures/DataTexture";
import { fromHalf } from "../../textures/DataUpload";
import { Vector3 } from "../../math/Vector3";
import { Color } from "../../math/Color";
import { FloatType, HalfFloatType, SRGBColorSpace } from "../../constants";

export class LightProbeGenerator {
    /// Projects an RGBA equirectangular DataTexture (byte, half or float;
    /// rows top first when flipY) onto spherical harmonics, weighting each
    /// texel by its solid angle.
    static fromEquirectangular(texture: DataTexture, step: i32 = 1): LightProbe {
        const sh = new SphericalHarmonics3();
        const w = <i32>texture.width, h = <i32>texture.height;
        const basis: Array<f64> = [0, 0, 0, 0, 0, 0, 0, 0, 0];
        const dir = new Vector3();
        const c = new Color();
        const srgb = texture.colorSpace == SRGBColorSpace;
        let total: f64 = 0;
        const s = max<i32>(1, step);
        for (let y = 0; y < h; y += s) {
            const v = (<f64>y + 0.5) / <f64>h;
            const lat = texture.flipY ? (0.5 - v) * Math.PI : (v - 0.5) * Math.PI;
            const cosLat = Math.cos(lat);
            const weight = cosLat;   // solid angle of a texel row, up to a constant
            for (let x = 0; x < w; x += s) {
                const lon = ((<f64>x + 0.5) / <f64>w - 0.5) * Math.PI * 2;
                dir.set(cosLat * Math.cos(lon), Math.sin(lat), cosLat * Math.sin(lon));
                LightProbeGenerator.texel(texture, x, y, c);
                if (srgb) c.convertSRGBToLinear();
                SphericalHarmonics3.getBasisAt(dir, basis);
                for (let j = 0; j < 9; j++) {
                    sh.coefficients[j].x += basis[j] * c.r * weight;
                    sh.coefficients[j].y += basis[j] * c.g * weight;
                    sh.coefficients[j].z += basis[j] * c.b * weight;
                }
                total += weight;
            }
        }
        if (total > 0) sh.scale(4 * Math.PI / total);
        return new LightProbe(sh);
    }

    private static texel(t: DataTexture, x: i32, y: i32, out: Color): void {
        const i = (y * <i32>t.width + x) * 4;
        if (t.type == FloatType) {
            const f = t.data as Float32Array;
            out.setRGB(<f64>f[i], <f64>f[i + 1], <f64>f[i + 2]);
        } else if (t.type == HalfFloatType) {
            const h = t.data as Uint16Array;
            out.setRGB(<f64>fromHalf(h[i]), <f64>fromHalf(h[i + 1]), <f64>fromHalf(h[i + 2]));
        } else {
            const b = t.data as Uint8Array;
            out.setRGB(<f64>b[i] / 255, <f64>b[i + 1] / 255, <f64>b[i + 2] / 255);
        }
    }
}
