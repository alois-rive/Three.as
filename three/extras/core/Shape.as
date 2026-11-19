// three.js Shape: a closed Path with holes.

import { Path } from "./Path";
import { Curve } from "./Curve";
import { Vector2 } from "../../math/Vector2";
import { MathUtils } from "../../math/MathUtils";
import { Dynamic } from "rive/dynamic";
import { jstr, jarr, jhas } from "../../core/JSON";

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
    private _uuid: string = "";

    constructor(points: Array<Vector2> = []) {
        super(points);
        this.type = "Shape";
    }

    /// A random uuid, made on first use (shape geometries refer to their
    /// shapes by it in JSON).
    get uuid(): string {
        if (this._uuid.length == 0) this._uuid = MathUtils.generateUUID();
        return this._uuid;
    }
    set uuid(value: string) { this._uuid = value; }

    getPointsHoles(divisions: i32): Array<Array<Vector2>> {
        const out: Array<Array<Vector2>> = [];
        for (let i = 0; i < this.holes.length; i++) out.push(this.holes[i].getPoints(divisions));
        return out;
    }

    extractPoints(divisions: i32): ShapePoints {
        return new ShapePoints(this.getPoints(divisions), this.getPointsHoles(divisions));
    }

    override toJSON(): Dynamic {
        const data = super.toJSON();
        data.set("uuid", Dynamic.fromString(this.uuid));
        const holes = Dynamic.newTable();
        for (let i = 0; i < this.holes.length; i++) holes.push(this.holes[i].toJSON());
        data.set("holes", holes);
        return data;
    }

    override fromJSON(json: Dynamic?): Curve<Vector2> {
        super.fromJSON(json);
        if (jhas(json, "uuid")) this.uuid = jstr(json, "uuid", "");
        this.holes = [];
        const items = jarr(json, "holes");
        for (let i = 0; i < items.length; i++) {
            const hole = new Path();
            hole.fromJSON(items[i]);
            this.holes.push(hole);
        }
        return this;
    }
}
