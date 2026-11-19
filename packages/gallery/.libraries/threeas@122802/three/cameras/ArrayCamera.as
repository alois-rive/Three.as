// three.js ArrayCamera: renders a scene once per sub-camera, each into its
// `viewport` (a Vector4 in drawing-buffer pixels, from the bottom left).
//
//     const cameras: Array<PerspectiveCamera> = [];
//     const sub = new PerspectiveCamera(40, w / h, 0.1, 10);
//     sub.viewport = new Vector4(0, 0, w, h);
//     cameras.push(sub);
//     const camera = new ArrayCamera(cameras);
//     renderer.render(scene, camera);

import { Object3D } from "../core/Object3D";
import { PerspectiveCamera } from "./PerspectiveCamera";

export class ArrayCamera extends PerspectiveCamera {
    readonly isArrayCamera: bool = true;
    cameras: Array<PerspectiveCamera>;

    constructor(array: Array<PerspectiveCamera> = []) {
        super();
        this.type = "ArrayCamera";
        this.cameras = array;
    }

    override clone(recursive: bool = true): Object3D {
        const c = new ArrayCamera(this.cameras.slice(0));
        c.copy(this, recursive);
        return c;
    }
}
