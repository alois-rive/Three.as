// Rive nodes driving 3D objects: animate a node in a Rive artboard (with a
// timeline or a state machine) and copy its transform onto an Object3D.

import { NodeData } from "rive/artboard";
import { Object3D } from "../core/Object3D";

/// Copies `node`'s local 2D transform onto `object` in its XY plane: x right
/// and y up (Rive's y flipped), times `unitsPerPixel`; rotation about Z
/// (Rive's clockwise rotation negated); scaleX and scaleY. Z and the other
/// rotations are left alone.
export function copyNodeTransform(object: Object3D, node: NodeData, unitsPerPixel: f64 = 0.01,
                                  originX: f64 = 0, originY: f64 = 0): void {
    object.position.x = (node.x - originX) * unitsPerPixel;
    object.position.y = -(node.y - originY) * unitsPerPixel;
    object.rotation.z = -node.rotation;
    object.scale.x = node.scaleX;
    object.scale.y = node.scaleY;
}
