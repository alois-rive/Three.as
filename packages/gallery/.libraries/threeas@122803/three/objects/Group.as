// three.js Group: an empty transform that groups its children.

import { Object3D } from "../core/Object3D";

export class Group extends Object3D {
    readonly isGroup: bool = true;

    constructor() {
        super();
        this.type = "Group";
    }

    override copy(source: Object3D, recursive: bool = true): Object3D {
        super.copy(source, recursive);
        return this;
    }

    override clone(recursive: bool = true): Object3D {
        return new Group().copy(this, recursive);
    }
}
