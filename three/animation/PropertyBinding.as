// three.js PropertyBinding (subset): a track name to an object property.
//
//     "Cube.position"                      node "Cube"'s position
//     ".quaternion"                        the mixer's root
//     "Cube.scale" / ".rotation"           scale / Euler rotation (radians)
//     "Cube.visible"                       visibility (bool tracks)
//     "Face.morphTargetInfluences[2]"      a morph target, by index ...
//     "Face.morphTargetInfluences[smile]"  ... or by name
//     "Cube.material.color" / ".material.opacity" / ".material.emissive"
//
// Nodes are found by name under the root (getObjectByName).

import { Object3D } from "../core/Object3D";
import { Mesh } from "../objects/Mesh";
import { SkinnedMesh } from "../objects/SkinnedMesh";
import { Material } from "../materials/Material";
import { MeshBasicMaterial } from "../materials/MeshBasicMaterial";
import { MeshLambertMaterial } from "../materials/MeshLambertMaterial";
import { MeshPhongMaterial } from "../materials/MeshPhongMaterial";
import { MeshStandardMaterial } from "../materials/MeshStandardMaterial";
import { MeshToonMaterial } from "../materials/MeshToonMaterial";
import { MeshMatcapMaterial } from "../materials/MeshMatcapMaterial";
import { LineBasicMaterial } from "../materials/LineBasicMaterial";
import { PointsMaterial } from "../materials/PointsMaterial";
import { SpriteMaterial } from "../materials/SpriteMaterial";
import { Color } from "../math/Color";

function searchNodeSubtree(children: Array<Object3D>, nodeName: string): Object3D? {
    for (let i = 0; i < children.length; i++) {
        const child = children[i];
        if (child.name == nodeName || child.uuid == nodeName) return child;
        const result = searchNodeSubtree(child.children, nodeName);
        if (result != null) return result;
    }
    return null;
}

const P_NONE: i32 = 0;
const P_POSITION: i32 = 1;
const P_QUATERNION: i32 = 2;
const P_SCALE: i32 = 3;
const P_ROTATION: i32 = 4;
const P_VISIBLE: i32 = 5;
const P_MORPH: i32 = 6;
const P_COLOR: i32 = 7;
const P_OPACITY: i32 = 8;
const P_EMISSIVE: i32 = 9;

export class ParsedTrackName {
    nodeName: string = "";
    objectName: string = "";
    /// The index of "node.object[index].property" ("bones[Arm].position").
    objectIndex: string = "";
    propertyName: string = "";
    propertyIndex: string = "";
}

export class PropertyBinding {
    rootNode: Object3D;
    path: string;
    parsedPath: ParsedTrackName;
    node: Object3D? = null;
    private kind: i32 = P_NONE;
    private morphIndex: i32 = -1;

    constructor(rootNode: Object3D, path: string) {
        this.rootNode = rootNode;
        this.path = path;
        this.parsedPath = PropertyBinding.parseTrackName(path);
        this.bind();
    }

    /// Splits "node.object.property[index]".
    static parseTrackName(trackName: string): ParsedTrackName {
        const r = new ParsedTrackName();
        const parts = trackName.split(".");
        r.nodeName = parts.length > 0 ? parts[0] : "";
        let prop = parts.length > 1 ? parts[parts.length - 1] : "";
        if (parts.length > 2) {
            let object = parts[1];
            const at = object.indexOf("[");
            if (at >= 0 && object.endsWith("]")) {
                r.objectIndex = object.substring(at + 1, object.length - 1);
                object = object.substring(0, at);
            }
            r.objectName = object;
        }
        const open = prop.indexOf("[");
        if (open >= 0 && prop.endsWith("]")) {
            r.propertyIndex = prop.substring(open + 1, prop.length - 1);
            prop = prop.substring(0, open);
        }
        r.propertyName = prop;
        return r;
    }

    /// The node a track's `nodeName` names under `root`, as three.js: the
    /// root itself for "" (or its name or uuid), else a bone of the root's
    /// skeleton (a SkinnedMesh root), else the first descendant, depth
    /// first, with that name or uuid; null when there is none.
    static findNode(root: Object3D, nodeName: string): Object3D? {
        if (nodeName == "" || nodeName == "." || nodeName == root.name || nodeName == root.uuid) return root;
        if (root instanceof SkinnedMesh) {
            const skeleton = (root as SkinnedMesh).skeleton;
            if (skeleton != null) {
                const bone = skeleton.getBoneByName(nodeName);
                if (bone != null) return bone;
            }
        }
        return searchNodeSubtree(root.children, nodeName);
    }

    /// three.js's name sanitizing: no spaces, dots, colons, slashes or brackets.
    static sanitizeNodeName(name: string): string {
        let out = "";
        for (let i = 0; i < name.length; i++) {
            const c = name.charAt(i);
            if (c == " ") out += "_";
            else if (c == "." || c == ":" || c == "/" || c == "[" || c == "]") continue;
            else out += c;
        }
        return out;
    }

    /// Whether the path resolved to a property.
    get isBound(): bool { return this.kind != P_NONE; }

    /// Values per key the property takes.
    get valueSize(): i32 {
        const k = this.kind;
        if (k == P_QUATERNION) return 4;
        if (k == P_POSITION || k == P_SCALE || k == P_ROTATION || k == P_COLOR || k == P_EMISSIVE) return 3;
        return k == P_NONE ? 0 : 1;
    }

    get isQuaternion(): bool { return this.kind == P_QUATERNION; }

    bind(): void {
        const p = this.parsedPath;
        const root = this.rootNode;
        const node = p.nodeName == "" || p.nodeName == root.name ? root : root.getObjectByName(p.nodeName);
        this.node = node;
        this.kind = P_NONE;
        if (node == null) return;
        const name = p.propertyName;
        if (p.objectName == "material") {
            if (name == "color") this.kind = P_COLOR;
            else if (name == "opacity") this.kind = P_OPACITY;
            else if (name == "emissive") this.kind = P_EMISSIVE;
            return;
        }
        if (name == "position") this.kind = P_POSITION;
        else if (name == "quaternion") this.kind = P_QUATERNION;
        else if (name == "scale") this.kind = P_SCALE;
        else if (name == "rotation") this.kind = P_ROTATION;
        else if (name == "visible") this.kind = P_VISIBLE;
        else if (name == "morphTargetInfluences" && node instanceof Mesh) {
            const mesh = node as Mesh;
            const idx = p.propertyIndex;
            let index = -1;
            if (mesh.morphTargetDictionary.has(idx)) index = mesh.morphTargetDictionary.get(idx);
            else if (idx.length > 0) index = I32.parseInt(idx);
            if (index >= 0) {
                this.morphIndex = index;
                this.kind = P_MORPH;
            }
        }
    }

    unbind(): void {
        this.node = null;
        this.kind = P_NONE;
    }

    getValue(out: Float64Array): void {
        const node = this.node;
        if (node == null) return;
        const k = this.kind;
        if (k == P_POSITION) { out[0] = node.position.x; out[1] = node.position.y; out[2] = node.position.z; }
        else if (k == P_QUATERNION) {
            const q = node.quaternion;
            out[0] = q.x; out[1] = q.y; out[2] = q.z; out[3] = q.w;
        } else if (k == P_SCALE) { out[0] = node.scale.x; out[1] = node.scale.y; out[2] = node.scale.z; }
        else if (k == P_ROTATION) { out[0] = node.rotation.x; out[1] = node.rotation.y; out[2] = node.rotation.z; }
        else if (k == P_VISIBLE) { out[0] = node.visible ? 1 : 0; }
        else if (k == P_MORPH) {
            const infl = (node as Mesh).morphTargetInfluences;
            out[0] = this.morphIndex < infl.length ? infl[this.morphIndex] : 0;
        } else {
            const m = materialOf(node);
            if (m == null) return;
            if (k == P_OPACITY) out[0] = m.opacity;
            else {
                const c = k == P_COLOR ? colorOf(m) : emissiveOf(m);
                if (c != null) { out[0] = c.r; out[1] = c.g; out[2] = c.b; }
            }
        }
    }

    setValue(v: Float64Array): void {
        const node = this.node;
        if (node == null) return;
        const k = this.kind;
        if (k == P_POSITION) node.position.set(v[0], v[1], v[2]);
        else if (k == P_QUATERNION) node.quaternion.set(v[0], v[1], v[2], v[3]);
        else if (k == P_SCALE) node.scale.set(v[0], v[1], v[2]);
        else if (k == P_ROTATION) node.rotation.set(v[0], v[1], v[2]);
        else if (k == P_VISIBLE) node.visible = v[0] >= 0.5;
        else if (k == P_MORPH) {
            const infl = (node as Mesh).morphTargetInfluences;
            while (infl.length <= this.morphIndex) infl.push(0);
            infl[this.morphIndex] = v[0];
        } else {
            const m = materialOf(node);
            if (m == null) return;
            if (k == P_OPACITY) m.opacity = v[0];
            else {
                const c = k == P_COLOR ? colorOf(m) : emissiveOf(m);
                if (c != null) c.setRGB(v[0], v[1], v[2]);
            }
        }
    }
}

function materialOf(node: Object3D): Material? {
    if (node instanceof Mesh) return (node as Mesh).material;
    return null;
}

function colorOf(m: Material): Color? {
    if (m instanceof MeshStandardMaterial) return (m as MeshStandardMaterial).color;
    if (m instanceof MeshBasicMaterial) return (m as MeshBasicMaterial).color;
    if (m instanceof MeshLambertMaterial) return (m as MeshLambertMaterial).color;
    if (m instanceof MeshPhongMaterial) return (m as MeshPhongMaterial).color;
    if (m instanceof MeshToonMaterial) return (m as MeshToonMaterial).color;
    if (m instanceof MeshMatcapMaterial) return (m as MeshMatcapMaterial).color;
    if (m instanceof LineBasicMaterial) return (m as LineBasicMaterial).color;
    if (m instanceof PointsMaterial) return (m as PointsMaterial).color;
    if (m instanceof SpriteMaterial) return (m as SpriteMaterial).color;
    return null;
}

function emissiveOf(m: Material): Color? {
    if (m instanceof MeshStandardMaterial) return (m as MeshStandardMaterial).emissive;
    if (m instanceof MeshLambertMaterial) return (m as MeshLambertMaterial).emissive;
    if (m instanceof MeshPhongMaterial) return (m as MeshPhongMaterial).emissive;
    if (m instanceof MeshToonMaterial) return (m as MeshToonMaterial).emissive;
    return null;
}
