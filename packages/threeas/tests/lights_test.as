// Light probes and area lights: rive . --test

import { Tests } from "rive/test";
import { Vector3 } from "../three/math/Vector3";
import { DataTexture } from "../three/textures/DataTexture";
import { LightProbeGenerator } from "../three/addons/lights/LightProbeGenerator";
import { RectAreaLight } from "../three/lights/RectAreaLight";
import { LTC_TABLE, LTC_SIZE } from "../three/lights/RectAreaLightTables";
import { FloatType, RGBAFormat } from "../three/constants";

export class LightsTests extends Tests {
    override run(): void {
        group("LightProbeGenerator", () => {
            test("uniform white radiance gives PI irradiance everywhere", (expect) => {
                const w = 32, h = 16;
                const data = new Float32Array(w * h * 4);
                data.fill(1);
                const t = new DataTexture(data, w, h, RGBAFormat, FloatType);
                const probe = LightProbeGenerator.fromEquirectangular(t);
                const e = new Vector3();
                const dirs: StaticArray<f64> = [0, 1, 0, 1, 0, 0, 0, -1, 0, 0.6, 0, 0.8];
                for (let i = 0; i < 4; i++) {
                    probe.sh.getIrradianceAt(new Vector3(dirs[i * 3], dirs[i * 3 + 1], dirs[i * 3 + 2]), e);
                    expect.that(Math.abs(e.x - Math.PI) < 0.05).is(true);
                }
            });
            test("a bright sky lights upward normals more", (expect) => {
                const w = 32, h = 16;
                const data = new Float32Array(w * h * 4);
                for (let y = 0; y < h; y++) {
                    for (let x = 0; x < w; x++) {
                        const v: f32 = y < h / 2 ? 4 : 0.5;   // top rows bright (flipY: top first)
                        const o = (y * w + x) * 4;
                        data[o] = v; data[o + 1] = v; data[o + 2] = v; data[o + 3] = 1;
                    }
                }
                const t = new DataTexture(data, w, h, RGBAFormat, FloatType);
                t.flipY = true;
                const probe = LightProbeGenerator.fromEquirectangular(t);
                const up = probe.sh.getIrradianceAt(new Vector3(0, 1, 0), new Vector3());
                const down = probe.sh.getIrradianceAt(new Vector3(0, -1, 0), new Vector3());
                expect.that(up.x > down.x * 2).is(true);
            });
        });
        group("RectAreaLight", () => {
            test("power and the LTC tables", (expect) => {
                const l = new RectAreaLight(0xffffff, 2, 3, 4);
                expect.that(Math.abs(l.power - 2 * 12 * Math.PI) < 1e-9).is(true);
                expect.that(LTC_TABLE.length).is(LTC_SIZE * LTC_SIZE * 4);
                // Roughness 0, normal incidence: LTC_MAT_1 is the identity (1, 0, 0, 1).
                expect.that(<f64>(LTC_TABLE[0] & 0xffff)).is(<f64>0x3c00);
            });
        });
    }
}
