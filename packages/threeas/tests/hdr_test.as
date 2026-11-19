// HDR loaders and inflate: rive . --test

import { Tests } from "rive/test";
import { RGBELoader } from "../three/addons/loaders/RGBELoader";
import { EXRLoader } from "../three/addons/loaders/EXRLoader";
import { unzlibSync } from "../three/addons/libs/fflate";
import { toHalf, fromHalf } from "../three/textures/DataUpload";
import { FloatType } from "../three/constants";

const DYNAMIC: StaticArray<u8> = [120,218,237,210,215,59,21,0,28,198,113,13,52,105,162,197,105,210,50,154,52,105,162,73,19,45,116,138,163,168,115,164,65,147,38,154,52,105,162,73,19,45,52,105,162,73,147,38,154,52,233,170,231,233,252,46,190,127,66,23,110,223,139,239,205,251,209,209,55,104,220,188,117,7,27,219,254,67,70,140,157,228,173,154,187,96,233,170,200,168,93,251,15,159,56,155,145,121,247,225,179,215,37,165,191,171,213,170,223,68,97,110,217,189,207,64,103,151,137,83,103,204,158,23,18,186,110,211,246,61,9,137,103,46,92,185,121,47,191,224,253,231,31,58,218,76,23,59,251,161,35,199,73,102,125,116,204,129,35,39,37,243,161,172,188,122,237,6,146,25,230,234,54,109,166,191,100,14,38,37,95,188,122,75,50,53,12,141,90,180,233,40,153,233,126,234,133,203,86,75,230,82,86,246,163,231,111,36,211,210,194,170,71,223,65,146,89,28,22,190,121,199,94,201,60,41,44,250,242,179,138,100,122,57,56,142,26,63,89,50,91,99,227,142,158,58,39,153,111,21,186,117,26,54,149,204,24,119,79,159,128,32,201,28,79,73,187,118,251,190,100,234,25,155,182,237,212,85,50,179,52,139,150,175,217,32,153,27,57,143,95,188,253,40,153,246,214,61,251,13,30,46,153,149,17,91,118,238,59,36,153,87,197,95,127,85,173,41,153,1,78,163,39,76,81,74,102,119,252,177,211,231,47,75,230,143,94,221,70,205,90,73,198,195,203,119,206,252,37,146,73,77,191,126,231,193,83,201,152,152,181,235,220,173,183,100,2,131,87,172,221,184,77,50,185,121,47,223,125,250,46,25,237,153,146,209,158,41,25,237,153,146,209,158,41,25,237,153,146,161,9,15,154,72,165,9,19,154,8,164,137,92,154,176,161,137,72,154,40,161,9,103,154,72,160,9,125,154,240,166,137,12,154,80,208,68,8,77,228,211,132,29,77,68,211,68,25,77,184,210,68,18,77,24,210,132,31,77,100,209,132,5,77,132,209,68,33,77,56,208,68,44,77,84,208,132,59,77,164,208,132,49,77,104,104,34,135,38,172,105,34,130,38,138,105,194,137,38,226,105,66,143,38,188,104,34,157,38,204,104,34,152,38,242,104,194,150,38,162,104,162,148,38,92,104,34,145,38,12,104,66,69,19,153,52,97,78,19,161,52,81,64,19,246,52,17,67,19,229,52,225,70,19,201,52,97,68,19,106,154,200,166,9,43,154,8,167,137,34,154,112,164,137,56,154,208,165,9,79,154,72,163,9,211,127,103,6,250,168,149,74,75,149,70,17,224,175,112,245,13,82,42,42,135,202,225,63,28,254,2,68,166,199,122];
const STORED: StaticArray<u8> = [120,1,1,17,0,238,255,115,116,111,114,101,100,32,98,108,111,99,107,32,116,101,115,116,60,42,6,157];

function bytesOf(a: StaticArray<u8>): Uint8Array {
    const out = new Uint8Array(a.length);
    for (let i = 0; i < a.length; i++) out[i] = a[i];
    return out;
}

export class HDRTests extends Tests {
    override run(): void {
        group("fflate", () => {
            test("inflates dynamic Huffman blocks", (expect) => {
                const out = unzlibSync(bytesOf(DYNAMIC));
                expect.that(out.length).is(2180);
                let cs: i64 = 0;
                for (let i = 0; i < out.length; i++) cs = (cs + <i64>(i + 1) * <i64>out[i]) % 1000000007;
                expect.that(cs).is(252882731);
            });
            test("inflates stored blocks", (expect) => {
                const out = unzlibSync(bytesOf(STORED));
                expect.that(String.UTF8.decode(out.buffer)).is("stored block test");
            });
        });
        group("half floats", () => {
            test("round trip", (expect) => {
                expect.that(<f64>fromHalf(toHalf(1.0))).is(1.0);
                expect.that(<f64>fromHalf(toHalf(-2.5))).is(-2.5);
                expect.that(<f64>fromHalf(toHalf(40.0))).is(40.0);
                expect.that(<f64>toHalf(1.0)).is(<f64>0x3c00);
                expect.that(<f64>fromHalf(toHalf(100000.0))).is(Infinity);
                expect.that(Math.abs(<f64>fromHalf(toHalf(0.0001)) - 0.0001) < 1e-6).is(true);
            });
        });
        group("RGBELoader and EXRLoader", () => {
            test("read the same studio", (expect) => {
                const hdrBytes = this.blob("studio_rgbe");
                const exrBytes = this.blob("studio_exr");
                expect.that(hdrBytes != null && exrBytes != null).is(true);
                if (hdrBytes == null || exrBytes == null) return;
                const rl = new RGBELoader().setDataType(FloatType);
                const hdr = rl.parse(Uint8Array.wrap(hdrBytes!));
                expect.that(rl.error).is("");
                const el = new EXRLoader().setDataType(FloatType);
                const exr = el.parse(Uint8Array.wrap(exrBytes!));
                expect.that(el.error).is("");
                if (hdr == null || exr == null) return;
                expect.that(hdr.width).is(256);
                expect.that(hdr.height).is(128);
                expect.that(exr.width).is(256);
                expect.that(exr.compression).is(3);
                const a = hdr.data as Float32Array, b = exr.data as Float32Array;
                // The warm key (40, 30, 18), top rows first.
                const key = (27 * 256 + 225) * 4;
                expect.that(Math.abs(<f64>a[key] - 40) < 0.5).is(true);
                expect.that(Math.abs(<f64>b[key] - 40) < 0.05).is(true);
                expect.that(Math.abs(<f64>b[key + 2] - 18) < 0.05).is(true);
                // Everywhere within RGBE precision of each other.
                let worst: f64 = 0;
                for (let i = 0; i < a.length; i++) {
                    const d = Math.abs(<f64>a[i] - <f64>b[i]) / Math.max(0.05, Math.abs(<f64>b[i]));
                    if (d > worst) worst = d;
                }
                expect.that(worst < 0.02).is(true);
            });
        });
    }
}
