// three.js Shape: a closed Path with holes.

import { Path } from "./Path";
import { Vector2 } from "../../math/Vector2";

export class ShapePoints {
    shape: Array<Vector2>;
    holes: Array<Array<Vector2>>;

    constructor(shape: Array<Vector2>, holes: Array<Array<Vector2>>) {
        this.shape = shape;
        this.holes = holes;
    }
}

export class Shape extends Path {
    holes: Array<Path> = [];

    constructor(points: Array<Vector2> = []) {
        super(points);
        this.type = "Shape";
    }

    getPointsHoles(divisions: i32): Array<Array<Vector2>> {
        const out: Array<Array<Vector2>> = [];
        for (let i = 0; i < this.holes.length; i++) out.push(this.holes[i].getPoints(divisions));
        return out;
    }

    extractPoints(divisions: i32): ShapePoints {
        return new ShapePoints(this.getPoints(divisions), this.getPointsHoles(divisions));
    }
}
