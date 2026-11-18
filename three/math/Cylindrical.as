// three.js Cylindrical: radius from the Y axis, theta around it from +Z,
// and height y.

import { Vector3 } from "./Vector3";

export class Cylindrical {
    radius: f64;
    theta: f64;
    y: f64;

    constructor(radius: f64 = 1, theta: f64 = 0, y: f64 = 0) {
        this.radius = radius;
        this.theta = theta;
        this.y = y;
    }

    set(radius: f64, theta: f64, y: f64): Cylindrical {
        this.radius = radius;
        this.theta = theta;
        this.y = y;
        return this;
    }

    copy(other: Cylindrical): Cylindrical { return this.set(other.radius, other.theta, other.y); }
    clone(): Cylindrical { return new Cylindrical(this.radius, this.theta, this.y); }

    setFromVector3(v: Vector3): Cylindrical { return this.setFromCartesianCoords(v.x, v.y, v.z); }

    setFromCartesianCoords(x: f64, y: f64, z: f64): Cylindrical {
        this.radius = Math.sqrt(x * x + z * z);
        this.theta = Math.atan2(x, z);
        this.y = y;
        return this;
    }
}
