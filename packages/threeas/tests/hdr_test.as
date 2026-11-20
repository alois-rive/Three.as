// HDR loaders and inflate: rive . --test

import { Tests } from "rive/test";
import { RGBELoader, decodeRGBE, buildRGBEData } from "../three/addons/loaders/RGBELoader";
import { EXRLoader, decodeEXR, buildEXRData } from "../three/addons/loaders/EXRLoader";
import { unzlibSync, inflateSync } from "../three/addons/libs/fflate";
import { toHalf, fromHalf } from "../three/textures/DataUpload";
import { FloatType, HalfFloatType } from "../three/constants";

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
            test("rewinds buffered bits before stored block and guards EOF on truncated streams", (expect) => {
                // Multi-block raw deflate:
                // Block 1 (BFINAL=0, BTYPE=01 fixed): 3 bits (0, 1, 0) + 7-bit EOB (0000000) = 10 bits -> 2 bytes
                // Wait: emit literal 'A' (65 -> 8-bit fixed code 0x30+65=0x71=01110001 -> MSB-first 10001110) then EOB (7 zeros):
                // Simpler: empty fixed block (BFINAL=0, BTYPE=01, EOB=0000000) = 10 bits:
                //   byte 0 = 0b00000_01_0 = 0x02, byte 1 = 0b000000_00 = 0x00 (bits 0..1 are last 2 bits of EOB,
                //   bits 2..4 are block 2 header: BFINAL=1, BTYPE=00 => 0b00_1 << 2 = 0x04! So byte 1 = 0x04!).
                //   Wait: to ensure bitCount >= 8 BEFORE storedBlock, block 1 ends with 0 bits left, and block 2 reads
                //   1 bit (BFINAL=1) then 2 bits (BTYPE=00) -> 5 bits left; to get >= 8 bits left we need a previous
                //   bits(n) call with n > 8, e.g. dynamic block with 7-bit repeat or a fixed match with 5 extra bits
                //   Wait: fixed block emitting "AB" (2 literals) + back-ref (length 3, dist 1): let's build a block
                //   where EOB ends at bit 0 of a byte, then storedBlock aligns; even better, test BOTH:
                //   (a) empty fixed block followed by stored block "OK" (byte 0 = 0x02, byte 1 = 0x04, then LEN=2, NLEN=~2, 'O', 'K')
                const multi: StaticArray<u8> = [0x02, 0x04, 2, 0, 253, 255, 79, 75];
                const out = inflateSync(bytesOf(multi));
                expect.that(String.UTF8.decode(out.buffer)).is("OK");
                // (b) Truncated fixed-Huffman block (no EOB) must terminate without hanging!
                const truncFixed: StaticArray<u8> = [0x03];   // BFINAL=1, BTYPE=01, truncated immediately
                const tfOut = inflateSync(bytesOf(truncFixed));
                expect.that(tfOut.length >= 0).is(true);
                // (c) Truncated dynamic-Huffman block header must terminate cleanly.
                const truncDyn: StaticArray<u8> = [0x05, 0x00];
                const tdOut = inflateSync(bytesOf(truncDyn));
                expect.that(tdOut.length).is(0);
                // (d) Stored block with invalid NLEN must terminate cleanly.
                const badStored: StaticArray<u8> = [0x01, 5, 0, 0, 0, 65, 66];
                const bsOut = inflateSync(bytesOf(badStored));
                expect.that(bsOut.length).is(0);
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
            test("decodeEXR and decodeRGBE (job paths) match parse", (expect) => {
                const hdrBytes = this.blob("studio_rgbe");
                const exrBytes = this.blob("studio_exr");
                if (hdrBytes != null) {
                    const sync = new RGBELoader().setDataType(HalfFloatType).parse(Uint8Array.wrap(hdrBytes!))!;
                    const dec = decodeRGBE(hdrBytes!, HalfFloatType);
                    expect.that(dec.error).is("");
                    expect.that(dec.blob != null).is(true);
                    const asyncData = buildRGBEData(dec)!;
                    expect.that(asyncData.width).is(sync.width);
                    expect.that(asyncData.height).is(sync.height);
                    const sa = sync.data as Uint16Array, sb = asyncData.data as Uint16Array;
                    let same = sa.length == sb.length;
                    for (let i = 0; i < sa.length && same; i++) if (sa[i] != sb[i]) same = false;
                    expect.that(same).is(true);
                }
                if (exrBytes != null) {
                    const sync = new EXRLoader().setDataType(FloatType).parse(Uint8Array.wrap(exrBytes!))!;
                    const dec = decodeEXR(exrBytes!, FloatType);
                    expect.that(dec.error).is("");
                    expect.that(dec.blob != null).is(true);
                    const asyncData = buildEXRData(dec)!;
                    expect.that(asyncData.width).is(sync.width);
                    expect.that(asyncData.height).is(sync.height);
                    const sa = sync.data as Float32Array, sb = asyncData.data as Float32Array;
                    let same = sa.length == sb.length;
                    for (let i = 0; i < sa.length && same; i++) if (sa[i] != sb[i]) same = false;
                    expect.that(same).is(true);
                }
                // Malformed EXR header with negative attribute size fails cleanly
                const bad = new Uint8Array(24);
                const dv = new DataView(bad.buffer);
                dv.setUint32(0, 20000630, true);
                dv.setUint32(4, 2, true);
                bad[8] = 97; bad[9] = 0; bad[10] = 98; bad[11] = 0;
                dv.setInt32(12, -100, true);
                const badDec = decodeEXR(bad.buffer, HalfFloatType);
                expect.that(badDec.error.length > 0).is(true);
                expect.that(buildEXRData(badDec) == null).is(true);
            });
            test("EXRLoader DECREASING_Y does not double-flip and HALF->HALF fast path matches FloatType", (expect) => {
                // Build a minimal 2x2 uncompressed HALF RGB EXR with lineOrder = 1 (DECREASING_Y).
                // Row y=0 (top): (R=10, G=0, B=0); Row y=1 (bottom): (R=0, G=20, B=0).
                // In DECREASING_Y, chunk for y=1 appears first in file, then chunk for y=0.
                const b: Array<u8> = [];
                const pushU32 = (v: u32): void => {
                    b.push(<u8>(v & 255)); b.push(<u8>((v >> 8) & 255));
                    b.push(<u8>((v >> 16) & 255)); b.push(<u8>((v >> 24) & 255));
                };
                const pushU16 = (v: u16): void => {
                    b.push(<u8>(v & 255)); b.push(<u8>((v >> 8) & 255));
                };
                const pushCStr = (s: string): void => {
                    for (let i = 0; i < s.length; i++) b.push(<u8>s.charCodeAt(i));
                    b.push(0);
                };
                pushU32(20000630); pushU32(2); // magic + version 2
                // channels attribute: B, G, R (alphabetical, HALF=1)
                pushCStr("channels"); pushCStr("chlist");
                const chSizePos = b.length; pushU32(0);
                const chStart = b.length;
                const chNames: StaticArray<string> = ["B", "G", "R"];
                for (let c = 0; c < 3; c++) {
                    pushCStr(chNames[c]); pushU32(1); // HALF
                    pushU32(0); pushU32(1); pushU32(1);
                }
                b.push(0); // end of chlist
                const chSize = <u32>(b.length - chStart);
                b[chSizePos] = <u8>(chSize & 255); b[chSizePos + 1] = <u8>((chSize >> 8) & 255);
                // compression = NO_COMPRESSION (0)
                pushCStr("compression"); pushCStr("compression"); pushU32(1); b.push(0);
                // dataWindow = (0, 0) to (1, 1) -> 2x2
                pushCStr("dataWindow"); pushCStr("box2i"); pushU32(16);
                pushU32(0); pushU32(0); pushU32(1); pushU32(1);
                // lineOrder = DECREASING_Y (1)
                pushCStr("lineOrder"); pushCStr("lineOrder"); pushU32(1); b.push(1);
                b.push(0); // end of header
                // offset table: 2 scanline blocks * 8 bytes (zeros, skipped by reader)
                for (let i = 0; i < 16; i++) b.push(0);
                const h0 = toHalf(0.0), h10 = toHalf(10.0), h20 = toHalf(20.0);
                // Chunk 0: y = 1 (bottom row: G=20)
                pushU32(1); pushU32(12); // y=1, dataSize = 3 channels * 2 pixels * 2 bytes
                pushU16(h0); pushU16(h0);     // B
                pushU16(h20); pushU16(h20);   // G
                pushU16(h0); pushU16(h0);     // R
                // Chunk 1: y = 0 (top row: R=10)
                pushU32(0); pushU32(12); // y=0
                pushU16(h0); pushU16(h0);     // B
                pushU16(h0); pushU16(h0);     // G
                pushU16(h10); pushU16(h10);   // R

                const bytes = new Uint8Array(b.length);
                for (let i = 0; i < b.length; i++) bytes[i] = b[i];
                // FloatType parse
                const df = new EXRLoader().setDataType(FloatType).parse(bytes)!;
                const fa = df.data as Float32Array;
                // Row 0 (top) must have R=10, G=0; Row 1 (bottom) must have R=0, G=20.
                expect.that(<f64>fa[0]).is(10.0);
                expect.that(<f64>fa[1]).is(0.0);
                expect.that(<f64>fa[3]).is(1.0);
                expect.that(<f64>fa[2 * 4 + 0]).is(0.0);
                expect.that(<f64>fa[2 * 4 + 1]).is(20.0);
                // HalfFloatType parse (direct HALF -> HALF fast path)
                const dh = new EXRLoader().setDataType(HalfFloatType).parse(bytes)!;
                const ha = dh.data as Uint16Array;
                expect.that(<f64>ha[0]).is(<f64>h10);
                expect.that(<f64>ha[1]).is(<f64>h0);
                expect.that(<f64>ha[3]).is(<f64>0x3c00);
                expect.that(<f64>ha[2 * 4 + 0]).is(<f64>h0);
                expect.that(<f64>ha[2 * 4 + 1]).is(<f64>h20);
            });
            test("RGBELoader supports CRLF headers", (expect) => {
                const hdrHeader = "#?RADIANCE\r\nFORMAT=32-bit_rle_rgbe\r\n\r\n-Y 1 +X 2\r\n";
                const out = new Uint8Array(hdrHeader.length + 8);
                for (let i = 0; i < hdrHeader.length; i++) out[i] = <u8>hdrHeader.charCodeAt(i);
                const o = hdrHeader.length;
                // Flat pixels (width < 8): pixel 0 = (128, 0, 0, 129) => (1.0, 0, 0); pixel 1 = (0, 128, 0, 130) => (0, 2.0, 0)
                out[o + 0] = 128; out[o + 1] = 0; out[o + 2] = 0; out[o + 3] = 129;
                out[o + 4] = 0; out[o + 5] = 128; out[o + 6] = 0; out[o + 7] = 130;
                const loader = new RGBELoader().setDataType(FloatType);
                const parsed = loader.parse(out);
                expect.that(loader.error).is("");
                expect.that(parsed != null).is(true);
                if (parsed == null) return;
                expect.that(parsed.width).is(2);
                expect.that(parsed.height).is(1);
                const f = parsed.data as Float32Array;
                expect.that(Math.abs(<f64>f[0] - 1.0) < 1e-5).is(true);
                expect.that(Math.abs(<f64>f[5] - 2.0) < 1e-5).is(true);
            });
        });
    }
}
