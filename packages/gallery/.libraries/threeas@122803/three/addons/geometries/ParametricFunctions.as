// three.js examples/jsm/geometries/ParametricFunctions.js: surfaces for
// ParametricGeometry. `plane(width, height)` returns a closure in three.js
// and is not ported.

import { Vector3 } from "../../math/Vector3";

export function klein(v: f64, u: f64, target: Vector3): void {
    u *= Math.PI;
    v *= 2 * Math.PI;
    u = u * 2;
    let x: f64, z: f64;
    if (u < Math.PI) {
        x = 3 * Math.cos(u) * (1 + Math.sin(u)) + (2 * (1 - Math.cos(u) / 2)) * Math.cos(u) * Math.cos(v);
        z = -8 * Math.sin(u) - 2 * (1 - Math.cos(u) / 2) * Math.sin(u) * Math.cos(v);
    } else {
        x = 3 * Math.cos(u) * (1 + Math.sin(u)) + (2 * (1 - Math.cos(u) / 2)) * Math.cos(v + Math.PI);
        z = -8 * Math.sin(u);
    }
    const y = -2 * (1 - Math.cos(u) / 2) * Math.sin(v);
    target.set(x, y, z);
}

export function mobius(u: f64, t: f64, target: Vector3): void {
    u = u - 0.5;
    const v = 2 * Math.PI * t;
    const a: f64 = 2;
    target.set(Math.cos(v) * (a + u * Math.cos(v / 2)), Math.sin(v) * (a + u * Math.cos(v / 2)), u * Math.sin(v / 2));
}

export function mobius3d(u: f64, t: f64, target: Vector3): void {
    u *= Math.PI;
    t *= 2 * Math.PI;
    u = u * 2;
    const phi = u / 2;
    const major: f64 = 2.25, a: f64 = 0.125, b: f64 = 0.65;
    let x = a * Math.cos(t) * Math.cos(phi) - b * Math.sin(t) * Math.sin(phi);
    const z = a * Math.cos(t) * Math.sin(phi) + b * Math.sin(t) * Math.cos(phi);
    const y = (major + x) * Math.sin(u);
    x = (major + x) * Math.cos(u);
    target.set(x, y, z);
}
