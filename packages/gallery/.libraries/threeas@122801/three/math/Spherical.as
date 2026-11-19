// three.js Spherical: radius, phi (polar angle from +Y) and theta
// (azimuth around +Y from +Z).

import { Vector3 } from "./Vector3";

export class Spherical {
    radius: f64;
    phi: f64;
    theta: f64;

    constructor(radius: f64 = 1, phi: f64 = 0, theta: f64 = 0) {
        this.radius = radius;
        this.phi = phi;
        this.theta = theta;
    }

    set(radius: f64, phi: f64, theta: f64): Spherical {
        this.radius = radius;
        this.phi = phi;
        this.theta = theta;
        return this;
    }

    copy(other: Spherical): Spherical { return this.set(other.radius, other.phi, other.theta); }
    clone(): Spherical { return new Spherical(this.radius, this.phi, this.theta); }

    /// Keeps phi away from the poles.
    makeSafe(): Spherical {
        const EPS = 0.000001;
        this.phi = Math.max(EPS, Math.min(Math.PI - EPS, this.phi));
        return this;
    }

    setFromVector3(v: Vector3): Spherical { return this.setFromCartesianCoords(v.x, v.y, v.z); }

    setFromCartesianCoords(x: f64, y: f64, z: f64): Spherical {
        this.radius = Math.sqrt(x * x + y * y + z * z);
        if (this.radius == 0) {
            this.theta = 0;
            this.phi = 0;
        } else {
            this.theta = Math.atan2(x, z);
            this.phi = Math.acos(Math.max(-1, Math.min(1, y / this.radius)));
        }
        return this;
    }
}
