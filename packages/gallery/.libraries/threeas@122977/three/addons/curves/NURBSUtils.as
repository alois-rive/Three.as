// three.js's NURBSUtils addon: B-spline and NURBS evaluation (The NURBS
// Book's algorithms), for NURBSCurve and the FBXLoader's NurbsCurve
// geometry. Control points are Vector4s (x, y, z, w = weight).

import { Vector3 } from "../../math/Vector3";
import { Vector4 } from "../../math/Vector4";

/// The knot span of `u` for degree `p` and knot vector `U`.
export function findSpan(p: i32, u: f64, U: Array<f64>): i32 {
    const n = U.length - p - 1;
    if (u >= U[n]) return n - 1;
    if (u <= U[p]) return p;
    let low = p;
    let high = n;
    let mid = (low + high) >> 1;
    while (u < U[mid] || u >= U[mid + 1]) {
        if (u < U[mid]) high = mid;
        else low = mid;
        mid = (low + high) >> 1;
    }
    return mid;
}

/// The p + 1 non-zero basis functions at `u` in `span` (A2.2).
export function calcBasisFunctions(span: i32, u: f64, p: i32, U: Array<f64>): Array<f64> {
    const N = new Array<f64>(p + 1);
    const left = new Array<f64>(p + 1);
    const right = new Array<f64>(p + 1);
    N[0] = 1.0;
    for (let j = 1; j <= p; ++j) {
        left[j] = u - U[span + 1 - j];
        right[j] = U[span + j] - u;
        let saved = 0.0;
        for (let r = 0; r < j; ++r) {
            const rv = right[r + 1];
            const lv = left[j - r];
            const temp = N[r] / (rv + lv);
            N[r] = saved + rv * temp;
            saved = lv * temp;
        }
        N[j] = saved;
    }
    return N;
}

/// The homogeneous point (wx, wy, wz, w) of the B-spline at `u` (A3.1).
export function calcBSplinePoint(p: i32, U: Array<f64>, P: Array<Vector4>, u: f64): Vector4 {
    const span = findSpan(p, u, U);
    const N = calcBasisFunctions(span, u, p, U);
    const C = new Vector4(0, 0, 0, 0);
    for (let j = 0; j <= p; ++j) {
        const point = P[span - p + j];
        const Nj = N[j];
        const wNj = point.w * Nj;
        C.x += point.x * wNj;
        C.y += point.y * wNj;
        C.z += point.z * wNj;
        C.w += point.w * Nj;
    }
    return C;
}

function zeros(n: i32): Array<f64> {
    const a = new Array<f64>(n);
    for (let i = 0; i < n; i++) a[i] = 0;
    return a;
}

/// The basis functions and their first `n` derivatives: [n + 1][p + 1] (A2.3).
export function calcBasisFunctionDerivatives(span: i32, u: f64, p: i32, n: i32, U: Array<f64>): Array<Array<f64>> {
    const ders: Array<Array<f64>> = [];
    for (let i = 0; i <= n; ++i) ders.push(zeros(p + 1));
    const ndu: Array<Array<f64>> = [];
    for (let i = 0; i <= p; ++i) ndu.push(zeros(p + 1));
    ndu[0][0] = 1.0;
    const left = zeros(p + 1);
    const right = zeros(p + 1);
    for (let j = 1; j <= p; ++j) {
        left[j] = u - U[span + 1 - j];
        right[j] = U[span + j] - u;
        let saved = 0.0;
        for (let r = 0; r < j; ++r) {
            const rv = right[r + 1];
            const lv = left[j - r];
            ndu[j][r] = rv + lv;
            const temp = ndu[r][j - 1] / ndu[j][r];
            ndu[r][j] = saved + rv * temp;
            saved = lv * temp;
        }
        ndu[j][j] = saved;
    }
    for (let j = 0; j <= p; ++j) ders[0][j] = ndu[j][p];
    for (let r = 0; r <= p; ++r) {
        let s1 = 0;
        let s2 = 1;
        const a: Array<Array<f64>> = [];
        for (let i = 0; i <= p; ++i) a.push(zeros(p + 1));
        a[0][0] = 1.0;
        for (let k = 1; k <= n; ++k) {
            let d = 0.0;
            const rk = r - k;
            const pk = p - k;
            if (r >= k) {
                a[s2][0] = a[s1][0] / ndu[pk + 1][rk];
                d = a[s2][0] * ndu[rk][pk];
            }
            const j1 = rk >= -1 ? 1 : -rk;
            const j2 = r - 1 <= pk ? k - 1 : p - r;
            for (let j = j1; j <= j2; ++j) {
                a[s2][j] = (a[s1][j] - a[s1][j - 1]) / ndu[pk + 1][rk + j];
                d += a[s2][j] * ndu[rk + j][pk];
            }
            if (r <= pk) {
                a[s2][k] = -a[s1][k - 1] / ndu[pk + 1][r];
                d += a[s2][k] * ndu[r][pk];
            }
            ders[k][r] = d;
            const j = s1;
            s1 = s2;
            s2 = j;
        }
    }
    let r = p;
    for (let k = 1; k <= n; ++k) {
        for (let j = 0; j <= p; ++j) ders[k][j] *= <f64>r;
        r *= p - k;
    }
    return ders;
}

/// The B-spline and its first `nd` derivatives at `u`, homogeneous (A3.2).
export function calcBSplineDerivatives(p: i32, U: Array<f64>, P: Array<Vector4>, u: f64, nd: i32): Array<Vector4> {
    const du = nd < p ? nd : p;
    const CK: Array<Vector4> = [];
    const span = findSpan(p, u, U);
    const nders = calcBasisFunctionDerivatives(span, u, p, du, U);
    const Pw: Array<Vector4> = [];
    for (let i = 0; i < P.length; ++i) {
        const point = P[i].clone();
        const w = point.w;
        point.x *= w;
        point.y *= w;
        point.z *= w;
        Pw.push(point);
    }
    for (let k = 0; k <= du; ++k) {
        const point = Pw[span - p].clone().multiplyScalar(nders[k][0]);
        for (let j = 1; j <= p; ++j) point.add(Pw[span - p + j].clone().multiplyScalar(nders[k][j]));
        CK.push(point);
    }
    for (let k = du + 1; k <= nd + 1; ++k) CK.push(new Vector4(0, 0, 0, 0));
    return CK;
}

/// k! / (i! (k - i)!).
export function calcKoverI(k: i32, i: i32): f64 {
    let nom: f64 = 1;
    for (let j = 2; j <= k; ++j) nom *= <f64>j;
    let denom: f64 = 1;
    for (let j = 2; j <= i; ++j) denom *= <f64>j;
    for (let j = 2; j <= k - i; ++j) denom *= <f64>j;
    return nom / denom;
}

/// The derivatives of a rational curve from its homogeneous ones (A4.2).
export function calcRationalCurveDerivatives(Pders: Array<Vector4>): Array<Vector3> {
    const nd = Pders.length;
    const Aders: Array<Vector3> = [];
    const wders: Array<f64> = [];
    for (let i = 0; i < nd; ++i) {
        const point = Pders[i];
        Aders.push(new Vector3(point.x, point.y, point.z));
        wders.push(point.w);
    }
    const CK: Array<Vector3> = [];
    for (let k = 0; k < nd; ++k) {
        const v = Aders[k].clone();
        for (let i = 1; i <= k; ++i) v.sub(CK[k - i].clone().multiplyScalar(calcKoverI(k, i) * wders[i]));
        CK.push(v.divideScalar(wders[0]));
    }
    return CK;
}

/// The NURBS curve and its first `nd` derivatives at `u` (A4.2).
export function calcNURBSDerivatives(p: i32, U: Array<f64>, P: Array<Vector4>, u: f64, nd: i32): Array<Vector3> {
    const Pders = calcBSplineDerivatives(p, U, P, u, nd);
    return calcRationalCurveDerivatives(Pders);
}

/// The point of a rational B-spline surface at (u, v), into `target` (A4.3).
/// `P` is [u index][v index].
export function calcSurfacePoint(p: i32, q: i32, U: Array<f64>, V: Array<f64>, P: Array<Array<Vector4>>,
                                 u: f64, v: f64, target: Vector3): void {
    const uspan = findSpan(p, u, U);
    const vspan = findSpan(q, v, V);
    const Nu = calcBasisFunctions(uspan, u, p, U);
    const Nv = calcBasisFunctions(vspan, v, q, V);
    const temp: Array<Vector4> = [];
    for (let l = 0; l <= q; ++l) {
        const t = new Vector4(0, 0, 0, 0);
        for (let k = 0; k <= p; ++k) {
            const point = P[uspan - p + k][vspan - q + l].clone();
            const w = point.w;
            point.x *= w;
            point.y *= w;
            point.z *= w;
            t.add(point.multiplyScalar(Nu[k]));
        }
        temp.push(t);
    }
    const Sw = new Vector4(0, 0, 0, 0);
    for (let l = 0; l <= q; ++l) Sw.add(temp[l].multiplyScalar(Nv[l]));
    Sw.divideScalar(Sw.w);
    target.set(Sw.x, Sw.y, Sw.z);
}

/// The point of a rational B-spline volume at (u, v, w), into `target`.
/// `P` is [u index][v index][w index].
export function calcVolumePoint(p: i32, q: i32, r: i32, U: Array<f64>, V: Array<f64>, W: Array<f64>,
                                P: Array<Array<Array<Vector4>>>, u: f64, v: f64, w: f64, target: Vector3): void {
    const uspan = findSpan(p, u, U);
    const vspan = findSpan(q, v, V);
    const wspan = findSpan(r, w, W);
    const Nu = calcBasisFunctions(uspan, u, p, U);
    const Nv = calcBasisFunctions(vspan, v, q, V);
    const Nw = calcBasisFunctions(wspan, w, r, W);
    const temp: Array<Array<Vector4>> = [];
    for (let m = 0; m <= r; ++m) {
        const row: Array<Vector4> = [];
        for (let l = 0; l <= q; ++l) {
            const t = new Vector4(0, 0, 0, 0);
            for (let k = 0; k <= p; ++k) {
                const point = P[uspan - p + k][vspan - q + l][wspan - r + m].clone();
                const pw = point.w;
                point.x *= pw;
                point.y *= pw;
                point.z *= pw;
                t.add(point.multiplyScalar(Nu[k]));
            }
            row.push(t);
        }
        temp.push(row);
    }
    const Sw = new Vector4(0, 0, 0, 0);
    for (let m = 0; m <= r; ++m) {
        for (let l = 0; l <= q; ++l) Sw.add(temp[m][l].multiplyScalar(Nw[m]).multiplyScalar(Nv[l]));
    }
    Sw.divideScalar(Sw.w);
    target.set(Sw.x, Sw.y, Sw.z);
}
