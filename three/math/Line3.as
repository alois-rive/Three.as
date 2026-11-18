// three.js Line3: a segment from start to end.

import { Vector3 } from "./Vector3";
import { Matrix4 } from "./Matrix4";

export class Line3 {
    start: Vector3;
    end: Vector3;

    constructor(start: Vector3 = new Vector3(), end: Vector3 = new Vector3()) {
        this.start = start;
        this.end = end;
    }

    set(start: Vector3, end: Vector3): Line3 {
        this.start.copy(start);
        this.end.copy(end);
        return this;
    }

    copy(line: Line3): Line3 { return this.set(line.start, line.end); }
    clone(): Line3 { return new Line3(this.start.clone(), this.end.clone()); }

    getCenter(target: Vector3): Vector3 { return target.addVectors(this.start, this.end).multiplyScalar(0.5); }
    delta(target: Vector3): Vector3 { return target.subVectors(this.end, this.start); }
    distanceSq(): f64 { return this.start.distanceToSquared(this.end); }
    distance(): f64 { return this.start.distanceTo(this.end); }

    at(t: f64, target: Vector3): Vector3 { return this.delta(target).multiplyScalar(t).add(this.start); }

    closestPointToPointParameter(point: Vector3, clampToLine: bool): f64 {
        _startP.subVectors(point, this.start);
        _startEnd.subVectors(this.end, this.start);
        const startEnd2 = _startEnd.dot(_startEnd);
        if (startEnd2 == 0) return 0;
        let t = _startEnd.dot(_startP) / startEnd2;
        if (clampToLine) t = Math.max(0, Math.min(1, t));
        return t;
    }

    closestPointToPoint(point: Vector3, clampToLine: bool, target: Vector3): Vector3 {
        const t = this.closestPointToPointParameter(point, clampToLine);
        return this.delta(target).multiplyScalar(t).add(this.start);
    }

    applyMatrix4(matrix: Matrix4): Line3 {
        this.start.applyMatrix4(matrix);
        this.end.applyMatrix4(matrix);
        return this;
    }

    equals(line: Line3): bool { return line.start.equals(this.start) && line.end.equals(this.end); }
}

const _startP: Vector3 = new Vector3();
const _startEnd: Vector3 = new Vector3();
