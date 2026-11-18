// three.js Group: an empty transform that groups its children.

import { Object3D } from "../core/Object3D";

export class Group extends Object3D {
    readonly isGroup: bool = true;

    constructor() {
        super();
        this.type = "Group";
    }
}
