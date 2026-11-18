// three.js Mesh: a geometry drawn with a material, or with one material per
// geometry group.

import { Object3D } from "../core/Object3D";
import { BufferGeometry } from "../core/BufferGeometry";
import { Material } from "../materials/Material";
import { MeshBasicMaterial } from "../materials/MeshBasicMaterial";
import { Raycaster, Intersection } from "../core/Raycaster";
import { raycastMesh } from "./raycasting";
import { Vector3 } from "../math/Vector3";

export class Mesh extends Object3D {
    readonly isMesh: bool = true;
    geometry: BufferGeometry;
    /// The material of the whole geometry, when `materials` is empty.
    material: Material;
    /// One material per geometry group, indexed by the group's
    /// materialIndex: three.js's `material` array (a field cannot be
    /// "Material or array" here). Groups without a material are not drawn.
    materials: Array<Material> = [];
    /// Morph target weights, one per geometry.morphAttributes entry.
    morphTargetInfluences: Array<f64> = [];
    /// Morph target names to indices.
    morphTargetDictionary: Map<string, i32> = new Map<string, i32>();

    constructor(geometry: BufferGeometry = new BufferGeometry(), material: Material = new MeshBasicMaterial()) {
        super();
        this.type = "Mesh";
        this.geometry = geometry;
        this.material = material;
    }

    /// Sizes morphTargetInfluences and fills morphTargetDictionary from the
    /// geometry's morph attributes.
    updateMorphTargets(): void {
        const geometry = this.geometry;
        const keys = geometry.morphAttributes.keys();
        if (keys.length == 0) return;
        const targets = geometry.morphAttributes.get(keys[0]);
        this.morphTargetInfluences = [];
        this.morphTargetDictionary.clear();
        for (let i = 0; i < targets.length; i++) {
            this.morphTargetInfluences.push(0);
            const name = targets[i].name.length > 0 ? targets[i].name : i.toString();
            this.morphTargetDictionary.set(name, i);
        }
    }

    /// The vertex's position after morph targets (mesh space), as three.js.
    getVertexPosition(index: i32, target: Vector3): Vector3 {
        const geometry = this.geometry;
        const position = geometry.getAttribute("position");
        if (position == null) return target.set(0, 0, 0);
        target.set(position.getX(index), position.getY(index), position.getZ(index));
        const influences = this.morphTargetInfluences;
        if (influences.length > 0 && geometry.morphAttributes.has("position")) {
            const morph = geometry.morphAttributes.get("position");
            _morph.set(0, 0, 0);
            for (let i = 0; i < influences.length && i < morph.length; i++) {
                const w = influences[i];
                if (w == 0) continue;
                const m = morph[i];
                _temp.set(m.getX(index), m.getY(index), m.getZ(index));
                if (!geometry.morphTargetsRelative) _temp.sub(target);
                _morph.addScaledVector(_temp, w);
            }
            target.add(_morph);
        }
        return target;
    }

    override raycast(raycaster: Raycaster, intersects: Array<Intersection>): bool {
        raycastMesh(this, raycaster, intersects, this.matrixWorld, -1);
        return true;
    }

    override copy(source: Object3D, recursive: bool = true): Object3D {
        super.copy(source, recursive);
        if (source instanceof Mesh) {
            const s = source as Mesh;
            this.geometry = s.geometry;
            this.material = s.material;
            this.materials = s.materials.slice();
            this.morphTargetInfluences = s.morphTargetInfluences.slice();
            const keys = s.morphTargetDictionary.keys();
            for (let i = 0; i < keys.length; i++) this.morphTargetDictionary.set(keys[i], s.morphTargetDictionary.get(keys[i]));
        }
        return this;
    }

    override clone(recursive: bool = true): Object3D {
        return new Mesh(this.geometry, this.material).copy(this, recursive);
    }
}

const _morph: Vector3 = new Vector3();
const _temp: Vector3 = new Vector3();
