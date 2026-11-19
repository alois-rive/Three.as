// Baked shader variants (Rive-only, PLAN.md M18): tools/threeas_bake.sh
// specializes three/shaders/three.wgsl for the program keys a project
// draws (GPURenderer.programKey) and writes each into the project as
// threeas_baked/v_<h>.wgsl, <h> the FNV-1a hash of THREE_WGSL_HASH, "|" and
// the key. GPURenderer finds a key's variant by that name alone: no
// registry, and a variant baked from another three.wgsl is never found.
// tests/shader_variants_test.as and `tools/threeas_bake.sh --self-test`
// check the same hash vectors.

import { THREE_WGSL_HASH } from "./ShaderSourceHash";

/// The folder (and asset name prefix) of a project's baked variants.
export const BAKED_SHADER_PREFIX: string = "threeas_baked/v_";

const HEX_DIGITS: string = "0123456789abcdef";

/// The 64-bit FNV-1a hash of `s`, as 16 lowercase hex digits. Hashes the low
/// byte of each UTF-16 unit: the bytes of an ASCII string (program keys are).
export function fnv1a64(s: string): string {
    let h: u64 = 0xcbf29ce484222325;
    for (let i = 0; i < s.length; i++) {
        h ^= <u64>(s.charCodeAt(i) & 0xff);
        h *= 0x100000001b3;
    }
    let out = "";
    for (let k = 15; k >= 0; k--) out += HEX_DIGITS.charAt(<i32>((h >> <u64>(k * 4)) & 0xf));
    return out;
}

/// The shader asset name of `key`'s variant baked from the three.wgsl whose
/// hash is `sourceHash` (THREE_WGSL_HASH, the one this engine runs, by
/// default).
export function bakedShaderName(key: string, sourceHash: string = THREE_WGSL_HASH): string {
    return BAKED_SHADER_PREFIX + fnv1a64(sourceHash + "|" + key);
}
