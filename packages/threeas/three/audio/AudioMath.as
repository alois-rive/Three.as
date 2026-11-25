// The math of Web Audio's PannerNode, BiquadFilterNode and AnalyserNode,
// which three.js's audio classes sit on, as pure functions (tested in
// tests/audio_test.as):
//
// - distance models (https://webaudio.github.io/web-audio-api/#distance-models),
// - sound cones (#Spatialization-sound-cones),
// - azimuth and elevation in the listener's frame and equal-power panning
//   (#Spatialization-equal-power-panning),
// - biquad coefficients (#filters-characteristics),
// - the analyser's FFT, Blackman window and dB scaling (#AnalyserNode).
//
// Plus the two cues ThreeAS adds to equal-power panning for its "HRTF"
// panning model (Web Audio convolves with measured HRTFs instead): an
// interaural time difference (Woodworth's spherical head) and a head-shadow
// low-pass on the far ear.

/// Web Audio's distance gain: "linear", "inverse" (the default) or
/// "exponential".
export function distanceGain(model: string, distance: f64, refDistance: f64, maxDistance: f64, rolloffFactor: f64): f64 {
    if (model == "linear") {
        const f = Math.min(Math.max(rolloffFactor, 0), 1);
        const lo = Math.min(refDistance, maxDistance), hi = Math.max(refDistance, maxDistance);
        const d = Math.min(Math.max(distance, lo), hi);
        if (maxDistance == refDistance) return 1 - f;
        return 1 - f * (d - refDistance) / (maxDistance - refDistance);
    }
    if (model == "exponential") {
        if (refDistance <= 0) return 0;
        const d = Math.max(distance, refDistance);
        return Math.pow(d / refDistance, -rolloffFactor);
    }
    // inverse
    const d = Math.max(distance, refDistance);
    const den = refDistance + rolloffFactor * (d - refDistance);
    return den > 0 ? refDistance / den : 0;
}

/// Web Audio's cone gain for a source at `(sx, sy, sz)` facing
/// `(ox, oy, oz)` heard from `(lx, ly, lz)`; angles in degrees.
export function coneGain(sx: f64, sy: f64, sz: f64, ox: f64, oy: f64, oz: f64, lx: f64, ly: f64, lz: f64,
                         coneInnerAngle: f64, coneOuterAngle: f64, coneOuterGain: f64): f64 {
    const ol = Math.sqrt(ox * ox + oy * oy + oz * oz);
    if (ol == 0 || (coneInnerAngle == 360 && coneOuterAngle == 360)) return 1;
    let dx = lx - sx, dy = ly - sy, dz = lz - sz;
    const dl = Math.sqrt(dx * dx + dy * dy + dz * dz);
    if (dl == 0) return 1;
    const dot = (dx * ox + dy * oy + dz * oz) / (dl * ol);
    const angle = Math.abs(180 * Math.acos(Math.min(Math.max(dot, -1), 1)) / Math.PI);
    const inner = Math.abs(coneInnerAngle) / 2, outer = Math.abs(coneOuterAngle) / 2;
    if (angle <= inner) return 1;
    if (angle >= outer) return coneOuterGain;
    const x = (angle - inner) / (outer - inner);
    return (1 - x) + coneOuterGain * x;
}

/// Azimuth and elevation (degrees) of a source at `(sx, sy, sz)` from a
/// listener at `(lx, ly, lz)` facing `forward` with `up`, as Web Audio
/// computes them: azimuth 0 ahead, +90 to the right, -90 to the left, +-180
/// behind. Written to `out[0]` (azimuth) and `out[1]` (elevation).
export function azimuthElevation(sx: f64, sy: f64, sz: f64, lx: f64, ly: f64, lz: f64,
                                 fx: f64, fy: f64, fz: f64, ux: f64, uy: f64, uz: f64,
                                 out: StaticArray<f64>): void {
    let vx = sx - lx, vy = sy - ly, vz = sz - lz;
    const vl = Math.sqrt(vx * vx + vy * vy + vz * vz);
    if (vl == 0) { out[0] = 0; out[1] = 0; return; }
    vx /= vl; vy /= vl; vz /= vl;
    const fl = Math.sqrt(fx * fx + fy * fy + fz * fz);
    if (fl == 0) { out[0] = 0; out[1] = 0; return; }
    fx /= fl; fy /= fl; fz /= fl;
    // right = forward x up
    let rx = fy * uz - fz * uy, ry = fz * ux - fx * uz, rz = fx * uy - fy * ux;
    const rl = Math.sqrt(rx * rx + ry * ry + rz * rz);
    if (rl == 0) { out[0] = 0; out[1] = 0; return; }
    rx /= rl; ry /= rl; rz /= rl;
    // up' = right x forward (orthogonal to both)
    let qx = ry * fz - rz * fy, qy = rz * fx - rx * fz, qz = rx * fy - ry * fx;
    const ql = Math.sqrt(qx * qx + qy * qy + qz * qz);
    qx /= ql; qy /= ql; qz /= ql;
    const upProjection = vx * qx + vy * qy + vz * qz;
    let px = vx - upProjection * qx, py = vy - upProjection * qy, pz = vz - upProjection * qz;
    const pl = Math.sqrt(px * px + py * py + pz * pz);
    let azimuth: f64 = 0;
    if (pl > 0) {
        px /= pl; py /= pl; pz /= pl;
        azimuth = 180 * Math.acos(Math.min(Math.max(px * rx + py * ry + pz * rz, -1), 1)) / Math.PI;
        const frontBack = px * fx + py * fy + pz * fz;
        if (frontBack < 0) azimuth = 360 - azimuth;
        if (azimuth >= 0 && azimuth <= 270) azimuth = 90 - azimuth;
        else azimuth = 450 - azimuth;
    }
    let elevation = 90 - 180 * Math.acos(Math.min(Math.max(vx * qx + vy * qy + vz * qz, -1), 1)) / Math.PI;
    if (elevation > 90) elevation = 180 - elevation;
    else if (elevation < -90) elevation = -180 - elevation;
    out[0] = azimuth;
    out[1] = elevation;
}

/// Equal-power panning as a 2x2 matrix from the input channels to the
/// output: `out = [LL, LR, RL, RR]` with outL = LL * inL + LR * inR and
/// outR = RL * inL + RR * inR. A mono input is fed to both inputs, so only
/// LL and RR are set for it.
export function equalPowerMatrix(azimuth: f64, inputChannels: i32, out: StaticArray<f64>): void {
    let az = Math.min(Math.max(azimuth, -180), 180);
    if (az < -90) az = -180 - az;
    else if (az > 90) az = 180 - az;
    if (inputChannels == 1) {
        const x = (az + 90) / 180;
        out[0] = Math.cos(x * Math.PI / 2);
        out[1] = 0;
        out[2] = 0;
        out[3] = Math.sin(x * Math.PI / 2);
        return;
    }
    if (az <= 0) {
        const x = (az + 90) / 90;
        out[0] = 1;
        out[1] = Math.cos(x * Math.PI / 2);
        out[2] = 0;
        out[3] = Math.sin(x * Math.PI / 2);
    } else {
        const x = az / 90;
        out[0] = Math.cos(x * Math.PI / 2);
        out[1] = 0;
        out[2] = Math.sin(x * Math.PI / 2);
        out[3] = 1;
    }
}

/// The head's radius in metres and the speed of sound, for the interaural
/// time difference.
export const HEAD_RADIUS: f64 = 0.0875;
export const SPEED_OF_SOUND: f64 = 343;

/// Woodworth's interaural time difference, in seconds, for a source at
/// `azimuth` (degrees): how much later the far ear hears it (0.66 ms at
/// the side).
export function interauralDelay(azimuth: f64): f64 {
    let az = Math.min(Math.max(azimuth, -180), 180);
    if (az < -90) az = -180 - az;
    else if (az > 90) az = 180 - az;
    const theta = Math.abs(az) * Math.PI / 180;
    return HEAD_RADIUS / SPEED_OF_SOUND * (theta + Math.sin(theta));
}

/// The head-shadow low-pass cutoffs (Hz) for the ear facing away from a
/// source at `azimuth` and for both ears with the source behind:
/// 20 kHz ahead, down to `shadowHz` for the far ear at the side, and to
/// `behindHz` for both ears straight behind. Written to out[0] (left) and
/// out[1] (right).
export function headShadowCutoffs(azimuth: f64, out: StaticArray<f64>, shadowHz: f64 = 3000, behindHz: f64 = 9000): void {
    const az = Math.min(Math.max(azimuth, -180), 180) * Math.PI / 180;
    const side = Math.sin(az);                       // +1 right, -1 left
    const behind = Math.max(0, -Math.cos(az));       // 1 straight behind
    const back = Math.pow(behindHz / 20000, behind);
    out[0] = 20000 * back * Math.pow(shadowHz / 20000, Math.max(0, side));
    out[1] = 20000 * back * Math.pow(shadowHz / 20000, Math.max(0, -side));
}

/// The one-pole low-pass coefficient `a` (y += a * (x - y)) for a cutoff,
/// 1 (no filtering) at or above Nyquist or for a cutoff of 0.
export function onePoleCoefficient(cutoff: f64, sampleRate: f64): f64 {
    if (cutoff <= 0 || cutoff >= sampleRate / 2) return 1;
    return 1 - Math.exp(-2 * Math.PI * cutoff / sampleRate);
}

/// BiquadFilterNode's types.
export const BIQUAD_TYPES: Array<string> = ["lowpass", "highpass", "bandpass", "lowshelf", "highshelf", "peaking", "notch", "allpass"];

function writeBiquadConstant(out: StaticArray<f64>, offset: i32, gain: f64): void {
    out[offset] = gain;
    out[offset + 1] = 0;
    out[offset + 2] = 0;
    out[offset + 3] = 0;
    out[offset + 4] = 0;
}

/// Web Audio's biquad coefficients, normalized by a0, into `out` at
/// `offset`: b0, b1, b2, a1, a2 (y[n] = b0 x[n] + b1 x[n-1] + b2 x[n-2]
/// - a1 y[n-1] - a2 y[n-2]).
export function biquadCoefficients(type: string, frequency: f64, Q: f64, gain: f64, detune: f64, sampleRate: f64,
                                   out: StaticArray<f64>, offset: i32 = 0): void {
    if (!isFinite(sampleRate) || sampleRate <= 0 || isNaN(frequency) || isNaN(detune)) {
        writeBiquadConstant(out, offset, 1);
        return;
    }
    const nyquist = sampleRate / 2;
    let f0: f64 = 0;
    if (frequency <= 0) {
        f0 = 0;
    } else if (frequency >= nyquist && detune >= 0) {
        f0 = nyquist;
    } else {
        const clampedDetune = Math.min(Math.max(detune, -120000), 120000);
        f0 = Math.min(Math.max(frequency * Math.pow(2, clampedDetune / 1200), 0), nyquist);
    }
    const g = isNaN(gain) ? 0 : Math.min(Math.max(gain, -200), 200);
    const A = Math.pow(10, g / 40);
    const w0 = 2 * Math.PI * f0 / sampleRate;

    // Exact W3C Web Audio boundary behavior at DC (f0 <= 0) and Nyquist (f0 >= nyquist),
    // avoiding alpha == 0 which produces a double pole on the unit circle.
    if (f0 <= 0 || w0 <= 1e-7) {
        if (type == "lowpass" || type == "bandpass") writeBiquadConstant(out, offset, 0);
        else if (type == "highshelf") writeBiquadConstant(out, offset, A * A);
        else writeBiquadConstant(out, offset, 1);
        return;
    }
    if (f0 >= nyquist || Math.PI - w0 <= 1e-7) {
        if (type == "highpass" || type == "bandpass") writeBiquadConstant(out, offset, 0);
        else if (type == "lowshelf") writeBiquadConstant(out, offset, A * A);
        else writeBiquadConstant(out, offset, 1);
        return;
    }

    const cw = Math.cos(w0), sw = Math.sin(w0);
    // For lowpass/highpass, Q is in dB per W3C Web Audio spec; clamp so 10^(Q/20) and alpha stay finite and bounded.
    const qDb = isNaN(Q) ? 0 : Math.min(Math.max(Q, -100), 100);
    const alphaQdB = Math.min(Math.max(sw / (2 * Math.pow(10, qDb / 20)), 1e-6), 1e6);
    // For Q-based filters (bandpass, notch, allpass, peaking), Q must be strictly positive.
    const qPos = isNaN(Q) ? 1 : Math.min(Math.max(Q, 1e-4), 1e4);
    const alphaQ = Math.min(Math.max(sw / (2 * qPos), 1e-6), 1e6);
    // S = 1 shelf slope: sqrt((A + 1/A) * (1/S - 1) + 2) == sqrt(2).
    const alphaS = sw * Math.SQRT1_2;

    let b0: f64 = 1, b1: f64 = 0, b2: f64 = 0, a0: f64 = 1, a1: f64 = 0, a2: f64 = 0;
    if (type == "lowpass") {
        b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2;
        a0 = 1 + alphaQdB; a1 = -2 * cw; a2 = 1 - alphaQdB;
    } else if (type == "highpass") {
        b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2;
        a0 = 1 + alphaQdB; a1 = -2 * cw; a2 = 1 - alphaQdB;
    } else if (type == "bandpass") {
        b0 = alphaQ; b1 = 0; b2 = -alphaQ;
        a0 = 1 + alphaQ; a1 = -2 * cw; a2 = 1 - alphaQ;
    } else if (type == "notch") {
        b0 = 1; b1 = -2 * cw; b2 = 1;
        a0 = 1 + alphaQ; a1 = -2 * cw; a2 = 1 - alphaQ;
    } else if (type == "allpass") {
        b0 = 1 - alphaQ; b1 = -2 * cw; b2 = 1 + alphaQ;
        a0 = 1 + alphaQ; a1 = -2 * cw; a2 = 1 - alphaQ;
    } else if (type == "peaking") {
        const alphaNum = alphaQ * A;
        const alphaDen = Math.min(Math.max(alphaQ / A, 1e-6), 1e6);
        b0 = 1 + alphaNum; b1 = -2 * cw; b2 = 1 - alphaNum;
        a0 = 1 + alphaDen; a1 = -2 * cw; a2 = 1 - alphaDen;
    } else if (type == "lowshelf") {
        const s = 2 * Math.sqrt(A) * alphaS;
        b0 = A * ((A + 1) - (A - 1) * cw + s);
        b1 = 2 * A * ((A - 1) - (A + 1) * cw);
        b2 = A * ((A + 1) - (A - 1) * cw - s);
        a0 = (A + 1) + (A - 1) * cw + s;
        a1 = -2 * ((A - 1) + (A + 1) * cw);
        a2 = (A + 1) + (A - 1) * cw - s;
    } else if (type == "highshelf") {
        const s = 2 * Math.sqrt(A) * alphaS;
        b0 = A * ((A + 1) + (A - 1) * cw + s);
        b1 = -2 * A * ((A - 1) + (A + 1) * cw);
        b2 = A * ((A + 1) + (A - 1) * cw - s);
        a0 = (A + 1) - (A - 1) * cw + s;
        a1 = 2 * ((A - 1) - (A + 1) * cw);
        a2 = (A + 1) - (A - 1) * cw - s;
    }
    if (!(a0 > 0) || !isFinite(a0)) {
        writeBiquadConstant(out, offset, 1);
        return;
    }
    const nb0 = b0 / a0, nb1 = b1 / a0, nb2 = b2 / a0, na1 = a1 / a0, na2 = a2 / a0;
    if (!isFinite(nb0) || !isFinite(nb1) || !isFinite(nb2) || !isFinite(na1) || !isFinite(na2) ||
        Math.abs(na2) >= 1 || 1 + na1 + na2 <= 0 || 1 - na1 + na2 <= 0) {
        writeBiquadConstant(out, offset, 1);
        return;
    }
    out[offset] = nb0;
    out[offset + 1] = nb1;
    out[offset + 2] = nb2;
    out[offset + 3] = na1;
    out[offset + 4] = na2;
}

/// In-place radix-2 FFT of `re` / `im` (length a power of two).
export function fft(re: Float64Array, im: Float64Array): void {
    const n = re.length;
    for (let i = 1, j = 0; i < n; i++) {
        let bit = n >> 1;
        for (; (j & bit) != 0; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            const tr = re[i]; re[i] = re[j]; re[j] = tr;
            const ti = im[i]; im[i] = im[j]; im[j] = ti;
        }
    }
    for (let len = 2; len <= n; len <<= 1) {
        const angle = -2 * Math.PI / <f64>len;
        const wr = Math.cos(angle), wi = Math.sin(angle);
        const half = len >> 1;
        for (let i = 0; i < n; i += len) {
            let cr: f64 = 1, ci: f64 = 0;
            for (let k = 0; k < half; k++) {
                const a = i + k, b = a + half;
                const xr = re[b] * cr - im[b] * ci;
                const xi = re[b] * ci + im[b] * cr;
                re[b] = re[a] - xr; im[b] = im[a] - xi;
                re[a] += xr; im[a] += xi;
                const ncr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = ncr;
            }
        }
    }
}

/// Web Audio's Blackman window (alpha 0.16) value at `i` of `n`.
export function blackman(i: i32, n: i32): f64 {
    const a0: f64 = 0.42, a1: f64 = 0.5, a2: f64 = 0.08;
    const x = <f64>i / <f64>n;
    return a0 - a1 * Math.cos(2 * Math.PI * x) + a2 * Math.cos(4 * Math.PI * x);
}

/// Linear gain to decibels (-Infinity for 0), as the analyser converts.
export function toDecibels(value: f64): f64 {
    return value > 0 ? 20 * Math.log10(value) : -Infinity;
}

/// A playback rate with `detune` cents applied, as AudioBufferSourceNode
/// combines them.
export function computedPlaybackRate(playbackRate: f64, detune: f64): f64 {
    if (detune == 0) return playbackRate;
    return playbackRate * Math.pow(2, detune / 1200);
}
