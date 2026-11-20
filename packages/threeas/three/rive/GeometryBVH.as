// GeometryBVH (Rive-only): a bounding volume hierarchy over a geometry's
// triangles, as three-mesh-bvh's `computeBoundsTree`, so a raycast tests
// the few triangles near the ray instead of all of them. Raycasts use it
// by themselves: the first raycast that reaches the triangles of a
// geometry with at least `GeometryBVH.AUTO_TRIANGLES` triangles starts a
// build in a Rive job (off the main lane, no time budget), and later ones
// use the tree once the job is done; until then they test every triangle
// (occlusion tests, see ArtboardPicker, count the geometry as a hit).
//
//     GeometryBVH.request(geometry);   // start building now (any size)
//     GeometryBVH.build(geometry);     // or build it here, synchronously
//
// A tree follows its geometry's position and index attributes: a new
// attribute, array or `needsUpdate` starts a rebuild. Skinned meshes and
// meshes with morph influences do not use one (their triangles move), nor
// do draw ranges that do not start on a triangle. Hits come out in the
// tree's order, not the index order (Raycaster sorts them anyway).
//
// Trees live in a table by geometry id (three-mesh-bvh keeps one on
// `geometry.boundsTree`; scripts have no weak references): geometry.dispose()
// or GeometryBVH.dispose(geometry) drops one, and past `GeometryBVH.maxTrees`
// the least recently used goes, so geometries dropped without dispose()
// cannot pile up (a raycast of an evicted one builds it again).

import { Job, Jobs } from "rive/jobs";
import { BufferGeometry } from "../core/BufferGeometry";
import { BufferAttribute, Uint32BufferAttribute } from "../core/BufferAttribute";
import { Event, EventListener } from "../core/EventDispatcher";
import { Ray } from "../math/Ray";

// Triangles a leaf holds at most.
const LEAF: i32 = 8;

/// What buildBVH reads: the geometry's positions (stride floats a vertex)
/// and index (empty when not indexed), copied into the job.
export class BVHInput {
    positions: Float32Array = new Float32Array(0);
    stride: i32 = 3;
    index: Uint32Array = new Uint32Array(0);
    indexed: bool = false;
    /// Index (or vertex) count: triangles start at 0, 3, 6 ... below it.
    count: i32 = 0;
}

/// A built tree. Node i: bounds[6i .. 6i + 6] (min xyz, max xyz) and
/// nodes[2i], nodes[2i + 1]: a leaf's first entry in `tris` and its count,
/// or an inner node's right child and 0 (its left child is i + 1).
/// `tris` lists triangle starts (index positions, multiples of 3).
export class BVHData {
    tris: Int32Array = new Int32Array(0);
    nodes: Int32Array = new Int32Array(0);
    bounds: Float32Array = new Float32Array(0);
}

/// Builds the tree: spatial-median splits on the longest axis of the
/// triangles' centroids, leaves of up to 8 triangles.
@job export function buildBVH(input: BVHInput): BVHData {
    const n = input.count / 3;
    const p = input.positions;
    const stride = input.stride;
    const index = input.index;
    const indexed = input.indexed;
    // Per triangle: its bounds and centroid.
    const tb = new Float32Array(n * 6);
    const tc = new Float32Array(n * 3);
    const tris = new Int32Array(n);
    for (let t = 0; t < n; t++) {
        const j = t * 3;
        const a = (indexed ? <i32>index[j] : j) * stride;
        const b = (indexed ? <i32>index[j + 1] : j + 1) * stride;
        const c = (indexed ? <i32>index[j + 2] : j + 2) * stride;
        for (let k = 0; k < 3; k++) {
            const va = p[a + k], vb = p[b + k], vc = p[c + k];
            const lo = min<f32>(va, min<f32>(vb, vc)), hi = max<f32>(va, max<f32>(vb, vc));
            tb[t * 6 + k] = lo;
            tb[t * 6 + 3 + k] = hi;
            tc[t * 3 + k] = (lo + hi) * <f32>0.5;
        }
        tris[t] = t;
    }
    let capacity = max<i32>(1, n / 2);
    let nodes = new Int32Array(capacity * 2);
    let bounds = new Float32Array(capacity * 6);
    let count = 0;
    // A stack of (node, start, end); a node's right child is made when
    // its left subtree is done, so the tree is laid out depth first.
    const stack = new Array<i32>();
    stack.push(-1); stack.push(0); stack.push(n);
    while (stack.length > 0) {
        const end = stack.pop();
        const start = stack.pop();
        const parent = stack.pop();
        if (count == capacity) {
            capacity *= 2;
            const grownNodes = new Int32Array(capacity * 2);
            grownNodes.set(nodes);
            nodes = grownNodes;
            const grownBounds = new Float32Array(capacity * 6);
            grownBounds.set(bounds);
            bounds = grownBounds;
        }
        const node = count++;
        if (parent >= 0) nodes[parent * 2] = node;   // the parent's right child
        let x0: f64 = Infinity, y0: f64 = Infinity, z0: f64 = Infinity;
        let x1: f64 = -Infinity, y1: f64 = -Infinity, z1: f64 = -Infinity;
        let cx0: f64 = Infinity, cy0: f64 = Infinity, cz0: f64 = Infinity;
        let cx1: f64 = -Infinity, cy1: f64 = -Infinity, cz1: f64 = -Infinity;
        for (let i = start; i < end; i++) {
            const t = tris[i];
            const o = t * 6;
            x0 = Math.min(x0, tb[o]); y0 = Math.min(y0, tb[o + 1]); z0 = Math.min(z0, tb[o + 2]);
            x1 = Math.max(x1, tb[o + 3]); y1 = Math.max(y1, tb[o + 4]); z1 = Math.max(z1, tb[o + 5]);
            const q = t * 3;
            cx0 = Math.min(cx0, tc[q]); cy0 = Math.min(cy0, tc[q + 1]); cz0 = Math.min(cz0, tc[q + 2]);
            cx1 = Math.max(cx1, tc[q]); cy1 = Math.max(cy1, tc[q + 1]); cz1 = Math.max(cz1, tc[q + 2]);
        }
        const bo = node * 6;
        bounds[bo] = <f32>x0; bounds[bo + 1] = <f32>y0; bounds[bo + 2] = <f32>z0;
        bounds[bo + 3] = <f32>x1; bounds[bo + 4] = <f32>y1; bounds[bo + 5] = <f32>z1;
        const size = end - start;
        const ex = cx1 - cx0, ey = cy1 - cy0, ez = cz1 - cz0;
        let axis = 0;
        let extent = ex;
        if (ey > extent) { axis = 1; extent = ey; }
        if (ez > extent) { axis = 2; extent = ez; }
        if (size <= LEAF || extent <= 0) {
            nodes[node * 2] = start;
            nodes[node * 2 + 1] = size;
            continue;
        }
        const split = (axis == 0 ? cx0 : axis == 1 ? cy0 : cz0) + extent * 0.5;
        // Partition: centroids below the split first.
        let i = start, j = end - 1;
        while (i <= j) {
            if (<f64>tc[tris[i] * 3 + axis] < split) i++;
            else {
                const s = tris[i];
                tris[i] = tris[j];
                tris[j] = s;
                j--;
            }
        }
        let mid = i;
        if (mid == start || mid == end) mid = start + size / 2;
        nodes[node * 2 + 1] = 0;
        // Right after left: push the right half first.
        stack.push(node); stack.push(mid); stack.push(end);
        stack.push(-1); stack.push(start); stack.push(mid);
    }
    const out = new BVHData();
    const order = new Int32Array(n);
    for (let i = 0; i < n; i++) order[i] = tris[i] * 3;
    out.tris = order;
    out.nodes = nodes.slice(0, count * 2);
    out.bounds = bounds.slice(0, count * 6);
    return out;
}

const _trees: Map<i32, GeometryBVH> = new Map<i32, GeometryBVH>();
// The same trees, for eviction.
const _treeList: Array<GeometryBVH> = [];
// Bumped by every lookup: a tree's lastUsed orders evictions.
let _clock: i32 = 0;
let _stack: Int32Array = new Int32Array(128);

class Disposer extends EventListener {
    tree: GeometryBVH;
    constructor(tree: GeometryBVH) {
        super();
        this.tree = tree;
    }
    override handleEvent(event: Event): void {
        forget(this.tree);
    }
}

// Drops `tree` from the table, its dispose listener from its geometry, and
// its data.
function forget(tree: GeometryBVH): void {
    const id = tree.geometryId;
    if (_trees.has(id) && _trees.get(id) === tree) _trees.delete(id);
    const i = _treeList.indexOf(tree);
    if (i >= 0) _treeList.splice(i, 1);
    const geometry = tree.geometry;
    const disposer = tree.disposer;
    if (geometry != null && disposer != null) geometry.removeEventListener("dispose", disposer);
    tree.geometry = null;
    tree.disposer = null;
    tree.release();
}

// Makes room for one more tree: the least recently used ones go.
function evict(): void {
    while (_treeList.length > 0 && _treeList.length >= GeometryBVH.maxTrees) {
        let oldest = 0;
        for (let i = 1; i < _treeList.length; i++) {
            if (_treeList[i].lastUsed < _treeList[oldest].lastUsed) oldest = i;
        }
        forget(_treeList[oldest]);
    }
}

export class GeometryBVH {
    /// Geometries with at least this many triangles get a tree on their
    /// first raycast.
    static readonly AUTO_TRIANGLES: i32 = 4096;
    /// Trees kept at most (the least recently used goes first).
    static maxTrees: i32 = 64;

    /// How many trees are kept (built or building).
    static count(): i32 { return _treeList.length; }

    /// The tree, once built (null while its job runs).
    data: BVHData? = null;
    private job: Job<BVHData>? = null;
    private position: BufferAttribute? = null;
    private positionArray: Float32Array? = null;
    private positionVersion: i32 = -1;
    private index: Uint32BufferAttribute? = null;
    private indexVersion: i32 = -1;
    // Candidates of the last query (triangle starts).
    private found: Int32Array = new Int32Array(256);
    // The geometry it was built for, while in the table, and its dispose
    // listener.
    geometryId: i32 = -1;
    geometry: BufferGeometry? = null;
    disposer: Disposer? = null;
    lastUsed: i32 = 0;

    /// Starts building `geometry`'s tree in a job, unless one is built or
    /// building for its current attributes.
    static request(geometry: BufferGeometry): void {
        GeometryBVH.of(geometry, true, false);
    }

    /// Builds `geometry`'s tree now, on this lane (mind the call's budget:
    /// about 0.1 s a million triangles compiled, 2 s interpreted).
    static build(geometry: BufferGeometry): GeometryBVH? {
        return GeometryBVH.of(geometry, true, true);
    }

    /// `geometry`'s tree if it is built and current, else null.
    static get(geometry: BufferGeometry): GeometryBVH? {
        return GeometryBVH.of(geometry, false, false);
    }

    /// Whether a job is building `geometry`'s tree.
    static pending(geometry: BufferGeometry): bool {
        if (!_trees.has(geometry.id)) return false;
        const tree = _trees.get(geometry.id);
        return tree.job != null && tree.current(geometry) && !tree.poll();
    }

    /// Drops `geometry`'s tree (geometry.dispose() does too); the next
    /// raycast of a big geometry starts another.
    static dispose(geometry: BufferGeometry): void {
        if (_trees.has(geometry.id)) forget(_trees.get(geometry.id));
    }

    /// For raycasts (`count`: the index or vertex count): the tree of a
    /// geometry big enough (or requested), its build started at the first
    /// call; null while it builds and for small geometries.
    static forRaycast(geometry: BufferGeometry, count: i32): GeometryBVH? {
        if (count / 3 < GeometryBVH.AUTO_TRIANGLES && !_trees.has(geometry.id)) return null;
        return GeometryBVH.of(geometry, true, false);
    }

    private static of(geometry: BufferGeometry, start: bool, now: bool): GeometryBVH? {
        const position = geometry.getAttribute("position");
        if (position == null || position.itemSize < 3) return null;
        let tree: GeometryBVH;
        if (_trees.has(geometry.id)) {
            tree = _trees.get(geometry.id);
        } else {
            if (!start) return null;
            evict();
            tree = new GeometryBVH();
            tree.geometryId = geometry.id;
            tree.geometry = geometry;
            const disposer = new Disposer(tree);
            tree.disposer = disposer;
            _trees.set(geometry.id, tree);
            _treeList.push(tree);
            geometry.addEventListener("dispose", disposer);
        }
        tree.lastUsed = ++_clock;
        // (A build here replaces a job still running.)
        if (!tree.current(geometry) || (now && !tree.poll())) {
            if (!start) return null;
            tree.release();
            tree.position = position;
            tree.positionArray = position.array;
            tree.positionVersion = position.version;
            const index = geometry.index;
            tree.index = index;
            tree.indexVersion = index != null ? index.version : -1;
            const input = new BVHInput();
            input.positions = position.array;
            input.stride = position.itemSize;
            if (index != null) {
                input.index = index.array;
                input.indexed = true;
            }
            input.count = index != null ? index.count : position.count;
            if (now) tree.data = buildBVH(input);
            else tree.job = Jobs.run(buildBVH, input);
        }
        return tree.poll() ? tree : null;
    }

    private current(geometry: BufferGeometry): bool {
        const position = geometry.getAttribute("position");
        const index = geometry.index;
        return position != null && position === this.position && position.array === this.positionArray
            && position.version == this.positionVersion && index === this.index
            && (index == null || index.version == this.indexVersion);
    }

    /// Whether the tree is built, collecting a finished job's result.
    private poll(): bool {
        if (this.data != null) return true;
        const job = this.job;
        if (job == null) return false;
        const settled = job.joinWithin(0);
        if (settled == null) return false;
        this.job = null;
        if (settled.ok) this.data = settled.value;
        job.release();
        return this.data != null;
    }

    release(): void {
        const job = this.job;
        if (job != null) job.release();
        this.job = null;
        this.data = null;
        this.position = null;
        this.positionArray = null;
        this.index = null;
    }

    /// The starts of the triangles in leaves whose box `ray` (in the
    /// geometry's space) crosses, into `candidates()`; returns how many.
    query(ray: Ray): i32 {
        const data = this.data;
        if (data == null || data.tris.length == 0) return 0;
        const nodes = data.nodes, bounds = data.bounds, tris = data.tris;
        const ox = ray.origin.x, oy = ray.origin.y, oz = ray.origin.z;
        const dx = ray.direction.x, dy = ray.direction.y, dz = ray.direction.z;
        const ix = dx != 0 ? 1 / dx : 0, iy = dy != 0 ? 1 / dy : 0, iz = dz != 0 ? 1 / dz : 0;
        let found = this.found;
        let n = 0;
        let top = 0;
        _stack[top++] = 0;
        while (top > 0) {
            const node = _stack[--top];
            const b = node * 6;
            // Slab test; an axis the ray is parallel to only bounds it.
            let enter = -Infinity, exit = Infinity;
            const x0: f64 = bounds[b], x1: f64 = bounds[b + 3];
            if (dx != 0) {
                const t0 = (x0 - ox) * ix, t1 = (x1 - ox) * ix;
                enter = Math.max(enter, Math.min(t0, t1));
                exit = Math.min(exit, Math.max(t0, t1));
            } else if (ox < x0 || ox > x1) continue;
            const y0: f64 = bounds[b + 1], y1: f64 = bounds[b + 4];
            if (dy != 0) {
                const t0 = (y0 - oy) * iy, t1 = (y1 - oy) * iy;
                enter = Math.max(enter, Math.min(t0, t1));
                exit = Math.min(exit, Math.max(t0, t1));
            } else if (oy < y0 || oy > y1) continue;
            const z0: f64 = bounds[b + 2], z1: f64 = bounds[b + 5];
            if (dz != 0) {
                const t0 = (z0 - oz) * iz, t1 = (z1 - oz) * iz;
                enter = Math.max(enter, Math.min(t0, t1));
                exit = Math.min(exit, Math.max(t0, t1));
            } else if (oz < z0 || oz > z1) continue;
            if (enter > exit || exit < 0) continue;
            const count = nodes[node * 2 + 1];
            if (count > 0) {
                const first = nodes[node * 2];
                if (n + count > found.length) {
                    const grown = new Int32Array(found.length * 2 + count);
                    grown.set(found);
                    found = grown;
                    this.found = found;
                }
                for (let i = 0; i < count; i++) found[n++] = tris[first + i];
            } else {
                if (top + 2 > _stack.length) {
                    const grown = new Int32Array(_stack.length * 2);
                    grown.set(_stack);
                    _stack = grown;
                }
                _stack[top++] = nodes[node * 2];   // right
                _stack[top++] = node + 1;          // left
            }
        }
        return n;
    }

    /// The triangle starts the last query found.
    candidates(): Int32Array { return this.found; }
}
