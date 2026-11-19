// three.js Sprite: a quad always facing the camera, scale.x by scale.y
// world units (or pixels-like with sizeAttenuation false), turned by
// SpriteMaterial.rotation around `center`.

import { Object3D } from "../core/Object3D";
import { Vector2 } from "../math/Vector2";
import { SpriteMaterial } from "../materials/SpriteMaterial";
import { Raycaster, Intersection } from "../core/Raycaster";
import { raycastSprite } from "./raycasting";
import { Dynamic } from "rive/dynamic";
import { JSONMeta } from "../core/JSON";
import { materialToLibrary } from "./serialize";

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

    /// The material, as three.js (the quad and `center` are not written).
    override toJSONObject(object: Dynamic, meta: JSONMeta): void {
        super.toJSONObject(object, meta);
        object.set("material", Dynamic.fromString(materialToLibrary(this.material, meta)));
    }

    /// Needs raycaster.camera (setFromCamera sets it).
    override raycast(raycaster: Raycaster, intersects: Array<Intersection>): bool {
        raycastSprite(this, raycaster, intersects);
        return true;
    }

    override copy(source: Object3D, recursive: bool = true): Object3D {
        super.copy(source, recursive);
        if (source instanceof Sprite) {
            const s = source as Sprite;
            this.material = s.material;
            this.center.copy(s.center);
        }
        return this;
    }

    override clone(recursive: bool = true): Object3D {
        return new Sprite(this.material).copy(this, recursive);
    }
}
