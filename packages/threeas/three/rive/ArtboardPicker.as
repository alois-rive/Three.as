// ArtboardPicker (Rive-only): finds the interactive ArtboardTexture under a
// ray without raycasting the whole scene. ThreeLayout forwards the pointer
// with one (`layout.picker`).
//
// It keeps a list of candidates: the visible meshes and sprites whose
// material maps an interactive ArtboardTexture, found by a walk of the
// scene (no geometry work) when the list is stale (`invalidate()`;
// ThreeLayout marks it once a frame). A pick then
//
//   1. raycasts the candidates only: no candidate hit, no target;
//   2. takes the nearest candidate hit (a part of a candidate whose
//      material does not map a target hides what is behind it);
//   3. asks whether a visible Mesh or Sprite of `occluders` (the scene by
//      default) lies in front of it: a walk that skips hidden subtrees and
//      stops at the first hit (`ArtboardPicker.occluded`). Points and lines
//      are hit within a threshold and do not hide a target.
//
// With no ArtboardTexture alive at all (`ArtboardTexture.live()`), a pick
// does nothing. In a crowded scene, set `occluders` to a group of the
// meshes that can hide the targets (big ones first).

import { Raycaster, Intersection } from "../core/Raycaster";
import { Object3D } from "../core/Object3D";
import { Mesh } from "../objects/Mesh";
import { Sprite } from "../objects/Sprite";
import { setRaycastAnyHit } from "../objects/raycasting";
import { Material } from "../materials/Material";
import { MaterialUniforms, SLOT_MAP } from "../materials/MaterialUniforms";
import { Texture } from "../textures/Texture";
import { Vector2 } from "../math/Vector2";
import { ArtboardTexture } from "./ArtboardTexture";

export class ArtboardPicker {
    /// What can hide a target: null for the picked scene. Only its visible
    /// meshes and sprites (and their subclasses) occlude.
    occluders: Object3D? = null;
    /// The last pick's target texture (null when nothing was found), its
    /// texture coordinate (the map's offset and repeat applied, as the
    /// shader samples it), the object hit and its distance.
    texture: Texture? = null;
    uv: Vector2 = new Vector2();
    object: Object3D? = null;
    distance: f64 = Infinity;
    /// Objects the last pick raycast (candidates and occluders), and how
    /// often the candidate list was rebuilt: for tests and profiling.
    raycasts: i32 = 0;
    rebuilds: i32 = 0;

    private candidates: Array<Object3D> = [];
    private stale: bool = true;
    private root: Object3D? = null;
    private hits: Array<Intersection> = [];
    private uniforms: MaterialUniforms = new MaterialUniforms();
    // Per rebuild: material id -> whether it maps a target.
    private targetMaterials: Map<i32, bool> = new Map<i32, bool>();

    /// Whether `map` takes the pointer: an interactive ArtboardTexture.
    isTarget(map: Texture): bool {
        return map instanceof ArtboardTexture && (map as ArtboardTexture).interactive;
    }

    /// Whether a target can exist at all; false skips the pick (no
    /// ArtboardTexture alive).
    mayHaveTargets(): bool { return ArtboardTexture.live() > 0; }

    /// Marks the candidate list stale: the next pick walks the scene again.
    /// Call it after adding, removing, showing or re-texturing objects
    /// outside ThreeLayout's frame (ThreeLayout calls it every advance).
    invalidate(): void { this.stale = true; }

    /// The objects that can show a target, as of the last rebuild.
    get candidateCount(): i32 { return this.candidates.length; }

    /// Finds the target under `raycaster`'s ray in `scene` (world matrices
    /// current). True when found: `texture`, `uv`, `object` and `distance`
    /// say where.
    pick(scene: Object3D, raycaster: Raycaster): bool {
        this.texture = null;
        this.object = null;
        this.distance = Infinity;
        this.raycasts = 0;
        if (!this.mayHaveTargets()) return false;
        if (this.stale || this.root !== scene) this.rebuild(scene);
        const candidates = this.candidates;
        if (candidates.length == 0) return false;

        const hits = this.hits;
        hits.length = 0;
        for (let i = 0; i < candidates.length; i++) {
            const c = candidates[i];
            if (!c.layers.test(raycaster.layers) || !isVisible(c)) continue;
            this.raycasts++;
            c.raycast(raycaster, hits);
        }
        if (hits.length == 0) return false;
        let nearest = hits[0];
        for (let i = 1; i < hits.length; i++) if (hits[i].distance < nearest.distance) nearest = hits[i];
        hits.length = 0;
        const uv = nearest.uv;
        const material = materialOf(nearest);
        if (uv == null || material == null) return false;
        const map = this.mapOf(material);
        if (map == null || !this.isTarget(map)) return false;

        // Anything in front? Candidates were tested above (none is nearer).
        const occluders = this.occluders != null ? this.occluders! : scene;
        const far = raycaster.far;
        raycaster.far = Math.min(far, nearest.distance * (1 - 1e-6));
        const blocked = isVisible(occluders) && this.occludes(occluders, raycaster);
        raycaster.far = far;
        if (blocked) return false;

        const t = map!;
        this.texture = t;
        this.object = nearest.object;
        this.distance = nearest.distance;
        if (t.matrixAutoUpdate) t.updateMatrix();
        this.uv.copy(uv).applyMatrix3(t.matrix);
        return true;
    }

    /// Whether the ray of `raycaster` hits a visible Mesh or Sprite of
    /// `root`'s subtree between its near and far: hidden subtrees are
    /// skipped, layers tested, and the walk stops at the first hit (no
    /// list, no sort). Points and lines do not count.
    static occluded(root: Object3D, raycaster: Raycaster): bool {
        if (!isVisible(root)) return false;
        setRaycastAnyHit(true);
        const hit = anyHit(root, raycaster, _hits, null);
        setRaycastAnyHit(false);
        _hits.length = 0;
        return hit;
    }

    private occludes(root: Object3D, raycaster: Raycaster): bool {
        setRaycastAnyHit(true);
        const hit = anyHit(root, raycaster, this.hits, this);
        setRaycastAnyHit(false);
        this.hits.length = 0;
        return hit;
    }

    /// Whether `o` is one of the candidates (as of the last rebuild).
    isCandidate(o: Object3D): bool {
        const c = this.candidates;
        for (let i = 0; i < c.length; i++) if (c[i] === o) return true;
        return false;
    }

    private rebuild(scene: Object3D): void {
        this.stale = false;
        this.root = scene;
        this.rebuilds++;
        this.candidates.length = 0;
        this.targetMaterials.clear();
        this.collect(scene);
    }

    private collect(o: Object3D): void {
        if (!o.visible) return;
        if (o instanceof Mesh) {
            const mesh = o as Mesh;
            let found = false;
            if (mesh.materials.length > 0) {
                for (let i = 0; i < mesh.materials.length && !found; i++) found = this.mapsTarget(mesh.materials[i]);
            } else {
                found = this.mapsTarget(mesh.material);
            }
            if (found) this.candidates.push(o);
        } else if (o instanceof Sprite) {
            if (this.mapsTarget((o as Sprite).material)) this.candidates.push(o);
        }
        const children = o.children;
        for (let i = 0; i < children.length; i++) this.collect(children[i]);
    }

    private mapsTarget(material: Material): bool {
        const known = this.targetMaterials;
        if (known.has(material.id)) return known.get(material.id);
        const map = this.mapOf(material);
        const yes = map != null && this.isTarget(map);
        known.set(material.id, yes);
        return yes;
    }

    private mapOf(material: Material): Texture? {
        material.fillUniforms(this.uniforms);
        const map = this.uniforms.textures[SLOT_MAP];
        this.uniforms.reset();   // drop the references
        return map;
    }
}

const _hits: Array<Intersection> = [];

function anyHit(o: Object3D, raycaster: Raycaster, hits: Array<Intersection>, picker: ArtboardPicker?): bool {
    if ((o instanceof Mesh || o instanceof Sprite) && o.layers.test(raycaster.layers)
            && (picker == null || !picker.isCandidate(o))) {
        if (picker != null) picker.raycasts++;
        hits.length = 0;
        o.raycast(raycaster, hits);
        if (hits.length > 0) return true;
    }
    const children = o.children;
    for (let i = 0; i < children.length; i++) {
        const c = children[i];
        if (c.visible && anyHit(c, raycaster, hits, picker)) return true;
    }
    return false;
}

function isVisible(o: Object3D): bool {
    let p: Object3D? = o;
    while (p != null) {
        if (!p.visible) return false;
        p = p.parent;
    }
    return true;
}

function materialOf(hit: Intersection): Material? {
    const o = hit.object;
    if (o instanceof Mesh) {
        const mesh = o as Mesh;
        const face = hit.face;
        if (mesh.materials.length > 0 && face != null && face.materialIndex < mesh.materials.length) {
            return mesh.materials[face.materialIndex];
        }
        return mesh.material;
    }
    if (o instanceof Sprite) return (o as Sprite).material;
    return null;
}
