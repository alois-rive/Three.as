// three.js Interpolations: Catmull-Rom and Bézier, per component.

export function CatmullRom(t: f64, p0: f64, p1: f64, p2: f64, p3: f64): f64 {
    const v0 = (p2 - p0) * 0.5;
    const v1 = (p3 - p1) * 0.5;
    const t2 = t * t;
    const t3 = t * t2;
    return (2 * p1 - 2 * p2 + v0 + v1) * t3 + (-3 * p1 + 3 * p2 - 2 * v0 - v1) * t2 + v0 * t + p1;
}

export function QuadraticBezier(t: f64, p0: f64, p1: f64, p2: f64): f64 {
    const k = 1 - t;
    return k * k * p0 + 2 * k * t * p1 + t * t * p2;
}

export function CubicBezier(t: f64, p0: f64, p1: f64, p2: f64, p3: f64): f64 {
    const k = 1 - t;
    return k * k * k * p0 + 3 * k * k * t * p1 + 3 * k * t * t * p2 + t * t * t * p3;
}
