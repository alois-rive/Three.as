// A geometry's morph target texture (three.wgsl's morph()): every target's
// deltas from the base, positions then (with normals) normals, as
// rgba16float texels, target-major. GPURenderer builds small ones inline
// and big ones in a Rive job (`morphTexels` is a @job), so the half-float
// conversion stays off the main lane.

/// What morphTexels reads, copied once into flat arrays (a job's arguments
/// cross lanes as copies; typed arrays cross as one block each).
export class MorphTexelInput {
    /// The base positions (xyz a vertex) and normals (empty without).
    base: Float32Array = new Float32Array(0);
    baseNormal: Float32Array = new Float32Array(0);
    /// Every position target's array, one after the other, then every
    /// normal target's.
    data: Float32Array = new Float32Array(0);
    /// Per target: position offset into `data`, item size, count, then the
    /// same for its normal target (count 0 without).
    layout: Int32Array = new Int32Array(0);
    targets: i32 = 0;
    vertices: i32 = 0;
    /// Texels a vertex takes: 1, or 2 with normals.
    stride: i32 = 1;
    width: i32 = 1;
    height: i32 = 1;
    /// morphTargetsRelative: the targets hold deltas already.
    relative: bool = false;
}

/// The texels (width x height x 4 half floats).
@job export function morphTexels(input: MorphTexelInput): Uint16Array {
    const data = new Uint16Array(input.width * input.height * 4);
    const src = input.data;
    const layout = input.layout;
    const vertices = input.vertices;
    const stride = input.stride;
    const perTarget = vertices * stride;
    const relative = input.relative;
    const base = input.base;
    const baseNormal = input.baseNormal;
    const hasBaseNormal = baseNormal.length > 0;
    for (let t = 0; t < input.targets; t++) {
        const l = t * 6;
        const po = layout[l], ps = layout[l + 1], pn = min<i32>(layout[l + 2], vertices);
        for (let v = 0; v < pn; v++) {
            const o = (t * perTarget + v * stride) * 4;
            for (let k = 0; k < 3; k++) {
                let delta: f32 = src[po + v * ps + k];
                if (!relative) delta -= base[v * 3 + k];
                if (delta != 0) data[o + k] = fastHalf(delta);
            }
        }
        const no = layout[l + 3], ns = layout[l + 4], nn = min<i32>(layout[l + 5], vertices);
        for (let v = 0; v < nn; v++) {
            const o = (t * perTarget + v * stride) * 4 + 4;
            for (let k = 0; k < 3; k++) {
                let delta: f32 = src[no + v * ns + k];
                if (!relative && hasBaseNormal) delta -= baseNormal[v * 3 + k];
                if (delta != 0) data[o + k] = fastHalf(delta);
            }
        }
    }
    return data;
}

// f32 to f16 by table (van der Zijp's "Fast Half Float Conversions"):
// truncates the mantissa (no rounding), flushes tiny values to zero, keeps
// infinities. For vertex data built per frame or per geometry.
const _halfBase = new StaticArray<u16>(512);
const _halfShift = new StaticArray<u8>(512);
let _halfReady = false;

function initHalfTables(): void {
    for (let i = 0; i < 256; i++) {
        const e = i - 127;
        let base: u32 = 0, shift: u32 = 24;
        if (e < -24) { base = 0; shift = 24; }
        else if (e < -14) { base = <u32>(0x0400 >> (-e - 14)); shift = <u32>(-e - 1); }
        else if (e <= 15) { base = <u32>((e + 15) << 10); shift = 13; }
        else if (e < 128) { base = 0x7C00; shift = 24; }
        else { base = 0x7C00; shift = 13; }
        _halfBase[i] = <u16>base; _halfBase[i | 0x100] = <u16>(base | 0x8000);
        _halfShift[i] = <u8>shift; _halfShift[i | 0x100] = <u8>shift;
    }
    _halfReady = true;
}

export function fastHalf(value: f32): u16 {
    if (!_halfReady) initHalfTables();
    const f = reinterpret<u32>(value);
    const e = (f >> 23) & 0x1ff;
    return <u16>(<u32>_halfBase[e] + ((f & 0x007fffff) >> <u32>_halfShift[e]));
}
