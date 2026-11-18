// three.js Sprite: a quad always facing the camera, scale.x by scale.y
// world units (or pixels-like with sizeAttenuation false), turned by
// SpriteMaterial.rotation around `center`.

import { Object3D } from "../core/Object3D";
import { Vector2 } from "../math/Vector2";
import { SpriteMaterial } from "../materials/SpriteMaterial";

export class Sprite extends Object3D {
    readonly isSprite: bool = true;
    material: SpriteMaterial;
    /// The anchor in the quad: (0.5, 0.5) its middle, (0, 0) bottom left.
    center: Vector2 = new Vector2(0.5, 0.5);

    constructor(material: SpriteMaterial = new SpriteMaterial()) {
        super();
        this.type = "Sprite";
        this.material = material;
    }
}
