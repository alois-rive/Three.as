// three.js PropertyBinding (subset): a track name to an object property.
//
//     "Cube.position"                      node "Cube"'s position
//     ".quaternion"                        the mixer's root
//     "Cube.scale" / ".rotation"           scale / Euler rotation (radians)
//     "Cube.position[x]" / ".rotation[y]"  one component (x, y, z, w or 0-3)
//     "Cube.visible"                       visibility (bool tracks)
//     "Face.morphTargetInfluences[2]"      a morph target, by index ...
//     "Face.morphTargetInfluences[smile]"  ... or by name
//     "Cube.material.color" / ".material.opacity" / ".material.emissive"
//     ".material.emissiveIntensity" / ".material.roughness" / ".material.metalness"
//     "Cube.material[1].color"             an entry of mesh.materials
//     "Lamp.intensity" / "Lamp.color"      a light's intensity or colour
//
// Nodes are found by name under the root (getObjectByName). A root that is
// an AnimationObjectGroup binds the path on each of its objects
// (PropertyBindingComposite, three.js's PropertyBinding.Composite):
// `PropertyBinding.create` picks the right one.

import { Object3D } from "../core/Object3D";
import { Mesh } from "../objects/Mesh";
import { SkinnedMesh } from "../objects/SkinnedMesh";
import { Line } from "../objects/Line";
import { Points } from "../objects/Points";
import { Sprite } from "../objects/Sprite";
import { Light } from "../lights/Light";
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
import { AnimationObjectGroup } from "./AnimationObjectGroup";

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
const P_EMISSIVE_INTENSITY: i32 = 10;
const P_ROUGHNESS: i32 = 11;
const P_METALNESS: i32 = 12;
const P_LIGHT_INTENSITY: i32 = 13;
const P_LIGHT_COLOR: i32 = 14;

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
    protected kind: i32 = P_NONE;
    private morphIndex: i32 = -1;
    /// The component of "position[x]" (0-3), or -1 for the whole value.
    private component: i32 = -1;
    private materialIndex: i32 = -1;
    private boundMaterial: Material? = null;
    private boundColor: Color? = null;

    constructor(rootNode: Object3D, path: string) {
        this.rootNode = rootNode;
        this.path = path;
        this.parsedPath = PropertyBinding.parseTrackName(path);
        this.bind();
    }

    /// A binding of `path` under `root`: a PropertyBindingComposite when
    /// `root` is an AnimationObjectGroup (three.js's PropertyBinding.create).
    static create(root: Object3D, path: string): PropertyBinding {
        if (root instanceof AnimationObjectGroup) return new PropertyBindingComposite(root as AnimationObjectGroup, path);
        return new PropertyBinding(root, path);
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
        if (k == P_NONE) return 0;
        if (this.component >= 0) return 1;
        if (k == P_QUATERNION) return 4;
        if (k == P_POSITION || k == P_SCALE || k == P_ROTATION || k == P_COLOR || k == P_EMISSIVE
            || k == P_LIGHT_COLOR) return 3;
        return 1;
    }

    /// Whether the value is a whole quaternion (blended by slerp).
    get isQuaternion(): bool { return this.kind == P_QUATERNION && this.component < 0; }

    /// Whether the value is a boolean (blended by picking, not mixing).
    get isBoolean(): bool { return this.kind == P_VISIBLE; }

    /// Whether the value is a colour (material or light colour).
    get isColor(): bool {
        return this.component < 0 && (this.kind == P_COLOR || this.kind == P_EMISSIVE || this.kind == P_LIGHT_COLOR);
    }

    bind(): void {
        const p = this.parsedPath;
        const root = this.rootNode;
        const node = p.nodeName == "" || p.nodeName == root.name ? root : root.getObjectByName(p.nodeName);
        this.node = node;
        this.kind = P_NONE;
        this.component = -1;
        this.boundMaterial = null;
        this.boundColor = null;
        if (node == null) return;
        const name = p.propertyName;
        if (p.objectName == "material") {
            if (p.objectIndex.length > 0) {
                const idx = parseNonNegativeInt(p.objectIndex);
                if (idx < 0) return;
                this.materialIndex = idx;
            } else {
                this.materialIndex = -1;
            }
            const m = this.material();
            if (m == null) return;
            this.boundMaterial = m;
            if (name == "color") {
                const col = colorOf(m);
                if (col != null) { this.kind = P_COLOR; this.boundColor = col; }
            } else if (name == "opacity") this.kind = P_OPACITY;
            else if (name == "emissive") {
                const col = emissiveOf(m);
                if (col != null) { this.kind = P_EMISSIVE; this.boundColor = col; }
            } else if (name == "emissiveIntensity" && emissiveOf(m) != null) this.kind = P_EMISSIVE_INTENSITY;
            else if (name == "roughness" && m instanceof MeshStandardMaterial) this.kind = P_ROUGHNESS;
            else if (name == "metalness" && m instanceof MeshStandardMaterial) this.kind = P_METALNESS;
            if (this.isColor && p.propertyIndex.length > 0) {
                this.component = componentIndex(p.propertyIndex, true);
                if (this.component < 0 || this.component >= 3) this.kind = P_NONE;
            }
            return;
        }
        if (p.objectName.length > 0) return;
        if (name == "position") this.kind = P_POSITION;
        else if (name == "quaternion") this.kind = P_QUATERNION;
        else if (name == "scale") this.kind = P_SCALE;
        else if (name == "rotation") this.kind = P_ROTATION;
        else if (name == "visible") this.kind = P_VISIBLE;
        else if (name == "intensity" && node instanceof Light) this.kind = P_LIGHT_INTENSITY;
        else if (name == "color" && node instanceof Light) this.kind = P_LIGHT_COLOR;
        else if (name == "morphTargetInfluences" && node instanceof Mesh) {
            const mesh = node as Mesh;
            const idx = p.propertyIndex;
            let index = -1;
            if (mesh.morphTargetDictionary.has(idx)) index = mesh.morphTargetDictionary.get(idx);
            else if (idx.length > 0) index = parseNonNegativeInt(idx);
            if (index >= 0) {
                this.morphIndex = index;
                this.kind = P_MORPH;
            }
            return;
        }
        const k = this.kind;
        if (k == P_POSITION || k == P_QUATERNION || k == P_SCALE || k == P_ROTATION || k == P_LIGHT_COLOR) {
            if (p.propertyIndex.length > 0) {
                this.component = componentIndex(p.propertyIndex, k == P_LIGHT_COLOR);
                const limit = k == P_QUATERNION ? 4 : 3;
                if (this.component < 0 || this.component >= limit) this.kind = P_NONE;
            }
        }
    }

    unbind(): void {
        this.node = null;
        this.boundMaterial = null;
        this.boundColor = null;
        this.kind = P_NONE;
    }

    private material(): Material? {
        const node = this.node;
        if (node == null) return null;
        const i = this.materialIndex;
        if (node instanceof Mesh) {
            const mesh = node as Mesh;
            if (i >= 0) return i < mesh.materials.length ? mesh.materials[i] : (i == 0 ? mesh.material : null);
            return mesh.material;
        }
        if (i > 0) return null;
        if (node instanceof Line) return (node as Line).material;
        if (node instanceof Points) return (node as Points).material;
        if (node instanceof Sprite) return (node as Sprite).material;
        return null;
    }

    getValue(out: Float64Array): void {
        const node = this.node;
        if (node == null) return;
        const k = this.kind;
        const c = this.component;
        if (k == P_POSITION) read3(out, c, node.position.x, node.position.y, node.position.z);
        else if (k == P_QUATERNION) {
            const q = node.quaternion;
            if (c < 0) { out[0] = q.x; out[1] = q.y; out[2] = q.z; out[3] = q.w; }
            else out[0] = c == 0 ? q.x : c == 1 ? q.y : c == 2 ? q.z : q.w;
        } else if (k == P_SCALE) read3(out, c, node.scale.x, node.scale.y, node.scale.z);
        else if (k == P_ROTATION) read3(out, c, node.rotation.x, node.rotation.y, node.rotation.z);
        else if (k == P_VISIBLE) { out[0] = node.visible ? 1 : 0; }
        else if (k == P_MORPH) {
            const infl = (node as Mesh).morphTargetInfluences;
            out[0] = this.morphIndex < infl.length ? infl[this.morphIndex] : 0;
        } else if (k == P_LIGHT_INTENSITY) out[0] = (node as Light).intensity;
        else if (k == P_LIGHT_COLOR) {
            const col = (node as Light).color;
            read3(out, c, col.r, col.g, col.b);
        } else {
            const m = this.material();
            if (m == null) return;
            if (k == P_OPACITY) out[0] = m.opacity;
            else if (k == P_EMISSIVE_INTENSITY) out[0] = emissiveIntensityOf(m);
            else if (k == P_ROUGHNESS) out[0] = (m as MeshStandardMaterial).roughness;
            else if (k == P_METALNESS) out[0] = (m as MeshStandardMaterial).metalness;
            else {
                let col: Color?;
                if (m === this.boundMaterial) {
                    col = this.boundColor;
                } else {
                    col = k == P_COLOR ? colorOf(m) : emissiveOf(m);
                    this.boundMaterial = m;
                    this.boundColor = col;
                }
                if (col != null) read3(out, c, col.r, col.g, col.b);
            }
        }
    }

    setValue(v: Float64Array): void {
        const node = this.node;
        if (node == null) return;
        const k = this.kind;
        const c = this.component;
        if (k == P_POSITION) {
            if (c < 0) node.position.set(v[0], v[1], v[2]);
            else if (c == 0) node.position.x = v[0]; else if (c == 1) node.position.y = v[0]; else node.position.z = v[0];
        } else if (k == P_QUATERNION) {
            const q = node.quaternion;
            if (c < 0) q.set(v[0], v[1], v[2], v[3]);
            else q.set(c == 0 ? v[0] : q.x, c == 1 ? v[0] : q.y, c == 2 ? v[0] : q.z, c == 3 ? v[0] : q.w);
        } else if (k == P_SCALE) {
            if (c < 0) node.scale.set(v[0], v[1], v[2]);
            else if (c == 0) node.scale.x = v[0]; else if (c == 1) node.scale.y = v[0]; else node.scale.z = v[0];
        } else if (k == P_ROTATION) {
            const r = node.rotation;
            if (c < 0) r.set(v[0], v[1], v[2]);
            else r.set(c == 0 ? v[0] : r.x, c == 1 ? v[0] : r.y, c == 2 ? v[0] : r.z);
        } else if (k == P_VISIBLE) node.visible = v[0] >= 0.5;
        else if (k == P_MORPH) {
            const infl = (node as Mesh).morphTargetInfluences;
            while (infl.length <= this.morphIndex) infl.push(0);
            infl[this.morphIndex] = v[0];
        } else if (k == P_LIGHT_INTENSITY) (node as Light).intensity = v[0];
        else if (k == P_LIGHT_COLOR) write3((node as Light).color, c, v);
        else {
            const m = this.material();
            if (m == null) return;
            if (k == P_OPACITY) m.opacity = v[0];
            else if (k == P_EMISSIVE_INTENSITY) setEmissiveIntensity(m, v[0]);
            else if (k == P_ROUGHNESS) (m as MeshStandardMaterial).roughness = v[0];
            else if (k == P_METALNESS) (m as MeshStandardMaterial).metalness = v[0];
            else {
                let col: Color?;
                if (m === this.boundMaterial) {
                    col = this.boundColor;
                } else {
                    col = k == P_COLOR ? colorOf(m) : emissiveOf(m);
                    this.boundMaterial = m;
                    this.boundColor = col;
                }
                if (col != null) write3(col, c, v);
            }
        }
    }
}

/// three.js's PropertyBinding.Composite: one path bound on every object of
/// an AnimationObjectGroup. getValue reads the first object, setValue
/// writes them all. The value's kind comes from the first object that
/// binds, so add the objects before the first `clipAction`.
export class PropertyBindingComposite extends PropertyBinding {
    readonly group: AnimationObjectGroup;
    private bindings: Map<i32, PropertyBinding> = new Map<i32, PropertyBinding>();
    private activeBindings: Array<PropertyBinding> = [];
    private syncedVersion: i32 = -1;
    private size: i32 = 0;
    private quaternion: bool = false;
    private boolean: bool = false;
    private color: bool = false;

    constructor(group: AnimationObjectGroup, path: string) {
        super(group, path);
        this.group = group;
        this.sync();
    }

    override get isBound(): bool { return this.size > 0; }
    override get valueSize(): i32 { return this.size; }
    override get isQuaternion(): bool { return this.quaternion; }
    override get isBoolean(): bool { return this.boolean; }
    override get isColor(): bool { return this.color; }

    /// Number of per-object bindings currently held in the cache.
    get cachedBindingCount(): i32 { return this.bindings.size; }

    private bindingOf(object: Object3D): PropertyBinding {
        if (this.bindings.has(object.id)) return this.bindings.get(object.id);
        const b = new PropertyBinding(object, this.path);
        this.bindings.set(object.id, b);
        return b;
    }

    private sync(): void {
        const g = this.group;
        if (this.syncedVersion == g.version) return;
        this.syncedVersion = g.version;
        this.prune();
        const active = this.activeBindings;
        active.length = 0;
        const objects = g.activeObjects;
        for (let i = 0; i < objects.length; i++) {
            const b = this.bindingOf(objects[i]);
            if (b.isBound) active.push(b);
        }
        if (this.size == 0 && active.length > 0) {
            const first = active[0];
            this.size = first.valueSize;
            this.quaternion = first.isQuaternion;
            this.boolean = first.isBoolean;
            this.color = first.isColor;
            if (this.size > 0 && g.paths.indexOf(this.path) < 0) g.paths.push(this.path);
        }
    }

    override getValue(out: Float64Array): void {
        this.sync();
        if (this.activeBindings.length > 0) this.activeBindings[0].getValue(out);
    }

    override setValue(v: Float64Array): void {
        this.sync();
        const active = this.activeBindings;
        for (let i = 0; i < active.length; i++) active[i].setValue(v);
    }

    override unbind(): void {
        this.bindings.clear();
        this.activeBindings.length = 0;
        this.syncedVersion = -1;
        const i = this.group.paths.indexOf(this.path);
        if (i >= 0) this.group.paths.splice(i, 1);
        super.unbind();
    }

    /// Drops the bindings of objects the group has uncached.
    prune(): void {
        if (this.bindings.size == 0) return;
        const g = this.group;
        _keepIds.clear();
        for (let i = 0; i < g.activeObjects.length; i++) _keepIds.add(g.activeObjects[i].id);
        for (let i = 0; i < g.cachedObjects.length; i++) _keepIds.add(g.cachedObjects[i].id);
        const keys = this.bindings.keys();
        for (let i = 0; i < keys.length; i++) {
            const id = keys[i];
            if (!_keepIds.has(id)) this.bindings.delete(id);
        }
        _keepIds.clear();
    }
}

const _keepIds: Set<i32> = new Set<i32>();

function parseNonNegativeInt(s: string): i32 {
    if (s.length == 0) return -1;
    let v: i64 = 0;
    for (let i = 0; i < s.length; i++) {
        const c = s.charCodeAt(i);
        if (c < 48 || c > 57) return -1;
        v = v * 10 + <i64>(c - 48);
        if (v > 2147483647) return -1;
    }
    return <i32>v;
}

/// "x"/"y"/"z"/"w" (or "r"/"g"/"b" for colours), or a digit; -1 otherwise.
function componentIndex(index: string, color: bool): i32 {
    if (index.length == 0) return -1;
    if (index == "x" || (color && index == "r")) return 0;
    if (index == "y" || (color && index == "g")) return 1;
    if (index == "z" || (color && index == "b")) return 2;
    if (index == "w") return 3;
    const c = index.charCodeAt(0);
    if (index.length == 1 && c >= 48 && c <= 51) return c - 48;
    return -1;
}

function read3(out: Float64Array, c: i32, x: f64, y: f64, z: f64): void {
    if (c < 0) { out[0] = x; out[1] = y; out[2] = z; }
    else out[0] = c == 0 ? x : c == 1 ? y : z;
}

function write3(color: Color, c: i32, v: Float64Array): void {
    if (c < 0) color.setRGB(v[0], v[1], v[2]);
    else if (c == 0) color.r = v[0]; else if (c == 1) color.g = v[0]; else color.b = v[0];
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

function emissiveIntensityOf(m: Material): f64 {
    if (m instanceof MeshStandardMaterial) return (m as MeshStandardMaterial).emissiveIntensity;
    if (m instanceof MeshLambertMaterial) return (m as MeshLambertMaterial).emissiveIntensity;
    if (m instanceof MeshPhongMaterial) return (m as MeshPhongMaterial).emissiveIntensity;
    if (m instanceof MeshToonMaterial) return (m as MeshToonMaterial).emissiveIntensity;
    return 0;
}

function setEmissiveIntensity(m: Material, v: f64): void {
    if (m instanceof MeshStandardMaterial) (m as MeshStandardMaterial).emissiveIntensity = v;
    else if (m instanceof MeshLambertMaterial) (m as MeshLambertMaterial).emissiveIntensity = v;
    else if (m instanceof MeshPhongMaterial) (m as MeshPhongMaterial).emissiveIntensity = v;
    else if (m instanceof MeshToonMaterial) (m as MeshToonMaterial).emissiveIntensity = v;
}
