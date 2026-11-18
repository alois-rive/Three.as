// three.js ConeGeometry: a cylinder with a zero top radius.

import { CylinderGeometry } from "./CylinderGeometry";

export class ConeGeometry extends CylinderGeometry {
    constructor(radius: f64 = 1, height: f64 = 1, radialSegments: i32 = 32, heightSegments: i32 = 1,
                openEnded: bool = false, thetaStart: f64 = 0, thetaLength: f64 = Math.PI * 2) {
        super(0, radius, height, radialSegments, heightSegments, openEnded, thetaStart, thetaLength);
        this.type = "ConeGeometry";
    }
}
