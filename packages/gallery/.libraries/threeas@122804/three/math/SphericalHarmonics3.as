// three.js SphericalHarmonics3: nine Vector3 coefficients (three bands),
// for LightProbe.

import { Vector3 } from "./Vector3";

export class SphericalHarmonics3 {
    readonly isSphericalHarmonics3: bool = true;
    coefficients: Array<Vector3> = [];

    constructor() {
        for (let i = 0; i < 9; i++) this.coefficients.push(new Vector3());
    }

    set(coefficients: Array<Vector3>): SphericalHarmonics3 {
        for (let i = 0; i < 9 && i < coefficients.length; i++) this.coefficients[i].copy(coefficients[i]);
        return this;
    }

    zero(): SphericalHarmonics3 {
        for (let i = 0; i < 9; i++) this.coefficients[i].set(0, 0, 0);
        return this;
    }

    /// The radiance along unit `normal`.
    getAt(normal: Vector3, target: Vector3): Vector3 {
        const x = normal.x, y = normal.y, z = normal.z;
        const c = this.coefficients;
        target.copy(c[0]).multiplyScalar(0.282095);
        target.addScaledVector(c[1], 0.488603 * y);
        target.addScaledVector(c[2], 0.488603 * z);
        target.addScaledVector(c[3], 0.488603 * x);
        target.addScaledVector(c[4], 1.092548 * (x * y));
        target.addScaledVector(c[5], 1.092548 * (y * z));
        target.addScaledVector(c[6], 0.315392 * (3.0 * z * z - 1.0));
        target.addScaledVector(c[7], 1.092548 * (x * z));
        target.addScaledVector(c[8], 0.546274 * (x * x - y * y));
        return target;
    }

    /// The irradiance (radiance convolved with cosine) along `normal`.
    getIrradianceAt(normal: Vector3, target: Vector3): Vector3 {
        const x = normal.x, y = normal.y, z = normal.z;
        const c = this.coefficients;
        target.copy(c[0]).multiplyScalar(0.886227);
        target.addScaledVector(c[1], 2.0 * 0.511664 * y);
        target.addScaledVector(c[2], 2.0 * 0.511664 * z);
        target.addScaledVector(c[3], 2.0 * 0.511664 * x);
        target.addScaledVector(c[4], 2.0 * 0.429043 * x * y);
        target.addScaledVector(c[5], 2.0 * 0.429043 * y * z);
        target.addScaledVector(c[6], 0.743125 * z * z - 0.247708);
        target.addScaledVector(c[7], 2.0 * 0.429043 * x * z);
        target.addScaledVector(c[8], 0.429043 * (x * x - y * y));
        return target;
    }

    add(sh: SphericalHarmonics3): SphericalHarmonics3 {
        for (let i = 0; i < 9; i++) this.coefficients[i].add(sh.coefficients[i]);
        return this;
    }

    addScaledSH(sh: SphericalHarmonics3, s: f64): SphericalHarmonics3 {
        for (let i = 0; i < 9; i++) this.coefficients[i].addScaledVector(sh.coefficients[i], s);
        return this;
    }

    scale(s: f64): SphericalHarmonics3 {
        for (let i = 0; i < 9; i++) this.coefficients[i].multiplyScalar(s);
        return this;
    }

    lerp(sh: SphericalHarmonics3, alpha: f64): SphericalHarmonics3 {
        for (let i = 0; i < 9; i++) this.coefficients[i].lerp(sh.coefficients[i], alpha);
        return this;
    }

    equals(sh: SphericalHarmonics3): bool {
        for (let i = 0; i < 9; i++) if (!this.coefficients[i].equals(sh.coefficients[i])) return false;
        return true;
    }

    copy(sh: SphericalHarmonics3): SphericalHarmonics3 { return this.set(sh.coefficients); }

    clone(): SphericalHarmonics3 { return new SphericalHarmonics3().copy(this); }

    fromArray(array: Array<f64>, offset: i32 = 0): SphericalHarmonics3 {
        for (let i = 0; i < 9; i++) this.coefficients[i].set(array[offset + i * 3], array[offset + i * 3 + 1], array[offset + i * 3 + 2]);
        return this;
    }

    toArray(array: Array<f64> = [], offset: i32 = 0): Array<f64> {
        while (array.length < offset + 27) array.push(0);
        for (let i = 0; i < 9; i++) {
            array[offset + i * 3] = this.coefficients[i].x;
            array[offset + i * 3 + 1] = this.coefficients[i].y;
            array[offset + i * 3 + 2] = this.coefficients[i].z;
        }
        return array;
    }

    /// The nine basis values along unit `normal`.
    static getBasisAt(normal: Vector3, shBasis: Array<f64>): void {
        const x = normal.x, y = normal.y, z = normal.z;
        while (shBasis.length < 9) shBasis.push(0);
        shBasis[0] = 0.282095;
        shBasis[1] = 0.488603 * y;
        shBasis[2] = 0.488603 * z;
        shBasis[3] = 0.488603 * x;
        shBasis[4] = 1.092548 * x * y;
        shBasis[5] = 1.092548 * y * z;
        shBasis[6] = 0.315392 * (3 * z * z - 1);
        shBasis[7] = 1.092548 * x * z;
        shBasis[8] = 0.546274 * (x * x - y * y);
    }
}
