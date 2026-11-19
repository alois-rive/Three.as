// three.js ConeGeometry: a cylinder with a zero top radius.

import { CylinderGeometry } from "./CylinderGeometry";
import { Dynamic } from "rive/dynamic";
import { JSONMeta, setNumber, setBool, jnum, jint, jbool } from "../core/JSON";

export class ConeGeometry extends CylinderGeometry {
    constructor(radius: f64 = 1, height: f64 = 1, radialSegments: i32 = 32, heightSegments: i32 = 1,
                openEnded: bool = false, thetaStart: f64 = 0, thetaLength: f64 = Math.PI * 2) {
        super(0, radius, height, radialSegments, heightSegments, openEnded, thetaStart, thetaLength);
        this.type = "ConeGeometry";
    }

    /// three.js's cone parameters: `radius`, not the cylinder's two radii.
    override toJSONParameters(data: Dynamic, meta: JSONMeta?): bool {
        const p = this.parameters;
        setNumber(data, "radius", p.radiusBottom);
        setNumber(data, "height", p.height);
        setNumber(data, "radialSegments", <f64>p.radialSegments);
        setNumber(data, "heightSegments", <f64>p.heightSegments);
        setBool(data, "openEnded", p.openEnded);
        setNumber(data, "thetaStart", p.thetaStart);
        setNumber(data, "thetaLength", p.thetaLength);
        return true;
    }

    static fromJSON(data: Dynamic?): ConeGeometry {
        return new ConeGeometry(jnum(data, "radius", 1), jnum(data, "height", 1), jint(data, "radialSegments", 32),
            jint(data, "heightSegments", 1), jbool(data, "openEnded", false), jnum(data, "thetaStart", 0),
            jnum(data, "thetaLength", Math.PI * 2));
    }
}
