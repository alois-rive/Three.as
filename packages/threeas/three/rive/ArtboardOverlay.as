// Rive artboards over a 3D scene: three.js's CSS2DRenderer / CSS3DRenderer
// (examples/jsm/renderers) with Rive artboards for HTML elements. Labels,
// tooltips, HUD markers and panels follow objects in the scene, drawn by
// the script's 2D renderer over the GPU canvas, and take pointer events.
//
//     const overlay = new ArtboardOverlayRenderer();      // CSS2DRenderer
//     this.overlay = overlay;                              // ThreeLayout drives it
//     const label = new Artboard2DObject(labelArtboard);  // CSS2DObject
//     label.position.set(0, 1.2, 0);
//     mesh.add(label);
//
// - Artboard2DObject: the artboard stays screen-aligned at its projected
//   position, `center` the point of it there (three.js's CSS2DObject.center).
// - Artboard3DObject: the artboard lies in the object's XY plane, an
//   artboard unit a world unit (CSS3DObject's pixel). Rive's renderer draws
//   2D affine transforms, so a perspective view is approximated by the
//   affine map through three corners (exact for orthographic cameras and
//   small or distant objects).
// - Artboard3DSprite: an Artboard3DObject facing the camera (CSS3DSprite).
//
// Occlusion (Rive-only): with `occlude`, an object fades to
// `occludedOpacity` when a mesh or sprite lies between the camera and its
// position (a raycast against `renderer.occluders`, the scene by default;
// points and lines do not occlude). For
// per-pixel depth, draw the artboard as an ArtboardTexture on a Sprite
// instead.

import { Renderer } from "rive/renderer";
import { Artboard } from "rive/artboard";
import { Mat2D } from "rive/mat2d";
import { Vector } from "rive/vector";
import { PointerEvent } from "rive/events";
import { Object3D } from "../core/Object3D";
import { Camera } from "../cameras/Camera";
import { Raycaster } from "../core/Raycaster";
import { Vector2 } from "../math/Vector2";
import { Vector3 } from "../math/Vector3";
import { ArtboardPicker } from "./ArtboardPicker";

/// Base of the overlay objects: an Object3D carrying an artboard instance.
export class ArtboardObject extends Object3D {
    readonly isArtboardObject: bool = true;
    /// The artboard instance drawn (its state machine runs on `advance`).
    readonly artboard: Artboard;
    /// The point of the artboard placed at the object's position, as
    /// fractions of its bounds (three.js's CSS2DObject.center).
    center: Vector2 = new Vector2(0.5, 0.5);
    /// Multiplies the opacity the artboard draws with.
    opacity: f64 = 1;
    /// Fade when a mesh hides the object's position (see the renderer).
    occlude: bool = false;
    /// The opacity factor while occluded (0 hides it).
    occludedOpacity: f64 = 0;
    /// Forward pointer events to the artboard.
    interactive: bool = true;
    /// Let the renderer advance the artboard (off when something else
    /// advances it, such as a RiveRig sharing the instance).
    autoAdvance: bool = true;

    // Set by the renderer's last render.
    /// The transform from artboard to layout coordinates.
    transform2D: Mat2D = Mat2D();
    /// Whether the last render placed it on screen (in front of the camera).
    onScreen: bool = false;
    /// Whether the last render found it occluded.
    occluded: bool = false;
    /// Its distance to the camera at the last render.
    cameraDistance: f64 = 0;
    /// Whether the last advance reported a change (it redraws either way).
    changed: bool = true;
    /// Whether dispose() ran: the overlay renderer skips it.
    disposed: bool = false;
    // Whether it made the instance (and releases it on dispose).
    private ownsArtboard: bool;

    /// Instances `artboard` (pass `instance = false` to use it as it is).
    constructor(artboard: Artboard, instance: bool = true) {
        super();
        this.artboard = instance ? artboard.instance() : artboard;
        this.ownsArtboard = instance;
        this.artboard.advance(0);
    }

    /// Advances the artboard and its state machine.
    advance(seconds: f64): bool {
        if (this.disposed) return false;
        this.changed = this.artboard.advance(seconds);
        return this.changed;
    }

    /// Releases the artboard instance it made (not one passed with
    /// `instance = false`); the overlay renderer no longer draws, advances
    /// or forwards events to it. Rive-only: a CSS object's element is the
    /// page's to remove. Remove it from the scene as well.
    dispose(): void {
        if (this.disposed) return;
        this.disposed = true;
        this.onScreen = false;
        if (this.ownsArtboard) this.artboard.release();
    }

    /// The artboard point under layout point (x, y), or null when the
    /// transform cannot be inverted.
    artboardPoint(x: f64, y: f64): Vector2? {
        const m = this.transform2D;
        const det = <f64>m.xx * <f64>m.yy - <f64>m.xy * <f64>m.yx;
        if (Math.abs(det) < 1e-12) return null;
        const dx = x - <f64>m.tx, dy = y - <f64>m.ty;
        return new Vector2((<f64>m.yy * dx - <f64>m.yx * dy) / det, (-<f64>m.xy * dx + <f64>m.xx * dy) / det);
    }

    /// Whether layout point (x, y) falls inside the artboard's bounds.
    contains(x: f64, y: f64): bool {
        if (this.disposed) return false;
        const p = this.artboardPoint(x, y);
        if (p == null) return false;
        const b = this.artboard.bounds();
        return p.x >= <f64>b.v0.x && p.x <= <f64>b.v1.x && p.y >= <f64>b.v0.y && p.y <= <f64>b.v1.y;
    }
}

/// three.js's CSS2DObject: a screen-aligned artboard at a 3D position.
export class Artboard2DObject extends ArtboardObject {
    readonly isArtboard2DObject: bool = true;
    /// Layout points per artboard unit.
    screenScale: f64 = 1;

    constructor(artboard: Artboard, instance: bool = true) {
        super(artboard, instance);
        this.type = "Artboard2DObject";
    }
}

/// three.js's CSS3DObject: an artboard in the object's XY plane, one
/// artboard unit per world unit (scale the object to size it).
export class Artboard3DObject extends ArtboardObject {
    readonly isArtboard3DObject: bool = true;

    constructor(artboard: Artboard, instance: bool = true) {
        super(artboard, instance);
        this.type = "Artboard3DObject";
    }
}

/// three.js's CSS3DSprite: an Artboard3DObject that faces the camera.
export class Artboard3DSprite extends Artboard3DObject {
    readonly isArtboard3DSprite: bool = true;
    /// Rotation in the screen plane, radians.
    rotation2D: f64 = 0;

    constructor(artboard: Artboard, instance: bool = true) {
        super(artboard, instance);
        this.type = "Artboard3DSprite";
    }
}

/// three.js's CSS2DRenderer and CSS3DRenderer in one: places every
/// visible ArtboardObject of a scene (`render`), draws them over the
/// canvas (`draw`, from the script's draw after `present`), advances them
/// and forwards pointer events. ThreeLayout calls all of it when its
/// `overlay` is set.
export class ArtboardOverlayRenderer {
    /// The layout size in points (setSize).
    width: f64 = 0;
    height: f64 = 0;
    /// Draw nearer objects on top (three.js sets zIndex by distance).
    sortObjects: bool = true;
    /// What occludes objects with `occlude` (null: the rendered scene; a
    /// smaller group of big meshes is cheaper per label).
    occluders: Object3D? = null;
    /// How far in front of an object a hit must be to occlude it (world
    /// units), so the surface an object sits on does not hide it.
    occlusionBias: f64 = 0.05;
    /// The objects placed by the last render, far to near.
    readonly objects: Array<ArtboardObject> = [];

    private captured: ArtboardObject? = null;
    private hovered: ArtboardObject? = null;
    private raycaster: Raycaster = new Raycaster();

    setSize(width: f64, height: f64): void {
        this.width = width;
        this.height = height;
    }

    getSize(target: Vector2): Vector2 {
        return target.set(this.width, this.height);
    }

    /// Places the scene's visible overlay objects for `camera` (world
    /// matrices must be current: call it after the GPU render, or after
    /// `scene.updateMatrixWorld()`).
    render(scene: Object3D, camera: Camera): void {
        const list = this.objects;
        list.length = 0;
        if (scene.matrixWorldAutoUpdate) scene.updateMatrixWorld();
        if (camera.parent == null && camera.matrixWorldAutoUpdate) camera.updateMatrixWorld();
        collect(scene, camera, list);
        _cameraPos.setFromMatrixPosition(camera.matrixWorld);
        const occluders = this.occluders != null ? this.occluders! : scene;
        for (let i = 0; i < list.length; i++) {
            const o = list[i];
            _pos.setFromMatrixPosition(o.matrixWorld);
            o.cameraDistance = _pos.distanceTo(_cameraPos);
            if (o instanceof Artboard3DObject) o.onScreen = this.place3D(o as Artboard3DObject, camera);
            else o.onScreen = this.place2D(o, camera);
            o.occluded = o.onScreen && o.occlude && this.isOccluded(o, occluders);
        }
        // Far to near: nearer ones draw (and take the pointer) on top.
        if (this.sortObjects) list.sort(byDistance);
    }

    /// Draws the placed objects with the script's 2D renderer, in layout
    /// coordinates (call it after the GPU canvas is presented).
    draw(renderer: Renderer): void {
        const list = this.objects;
        for (let i = 0; i < list.length; i++) {
            const o = list[i];
            if (!o.onScreen) continue;
            const opacity = o.opacity * (o.occluded ? o.occludedOpacity : 1);
            if (opacity <= 0) continue;
            renderer.save();
            renderer.transform(o.transform2D);
            if (opacity < 1) renderer.modulateOpacity(opacity);
            o.artboard.draw(renderer);
            renderer.restore();
        }
    }

    /// Advances every placed object's artboard. Returns true while one of
    /// them keeps changing.
    advance(seconds: f64): bool {
        let changed = false;
        for (let i = 0; i < this.objects.length; i++) {
            const o = this.objects[i];
            if (o.autoAdvance && o.advance(seconds)) changed = true;
        }
        return changed;
    }

    // ------------------------------------------------------------ pointer

    /// The topmost interactive, visible object under layout point (x, y).
    objectAt(x: f64, y: f64): ArtboardObject? {
        const list = this.objects;
        for (let i = list.length - 1; i >= 0; i--) {
            const o = list[i];
            if (!o.interactive || !o.onScreen || (o.occluded && o.occludedOpacity <= 0) || o.opacity <= 0) continue;
            if (o.contains(x, y)) return o;
        }
        return null;
    }

    /// Forwards a press to the object under it; true when an artboard took
    /// it (something hit-testable in it was hit). That object then gets the
    /// moves and the release.
    pointerDown(event: PointerEvent): bool {
        const o = this.objectAt(<f64>event.position.x, <f64>event.position.y);
        if (o == null) return false;
        if (forward(o, event, 0) != 0) {
            this.captured = o;
            return true;
        }
        return false;
    }

    pointerMove(event: PointerEvent): bool {
        const captured = this.captured;
        const o = captured != null ? captured : this.objectAt(<f64>event.position.x, <f64>event.position.y);
        const hovered = this.hovered;
        if (hovered != null && hovered !== o) forward(hovered, event, 3);
        this.hovered = o;
        if (o == null) return false;
        return forward(o, event, 1) != 0 || captured != null;
    }

    pointerUp(event: PointerEvent): bool {
        const captured = this.captured;
        this.captured = null;
        const o = captured != null ? captured : this.objectAt(<f64>event.position.x, <f64>event.position.y);
        if (o == null) return false;
        return forward(o, event, 2) != 0 || captured != null;
    }

    pointerExit(event: PointerEvent): void {
        const hovered = this.hovered;
        if (hovered != null) forward(hovered, event, 3);
        this.hovered = null;
        this.captured = null;
    }

    // ---------------------------------------------------------- placement

    private toScreen(world: Vector3, camera: Camera, out: Vector3): bool {
        out.copy(world).project(camera);
        if (!(out.z >= 0 && out.z <= 1)) return false;
        out.x = (out.x * 0.5 + 0.5) * this.width;
        out.y = (-out.y * 0.5 + 0.5) * this.height;
        return true;
    }

    private place2D(o: ArtboardObject, camera: Camera): bool {
        _pos.setFromMatrixPosition(o.matrixWorld);
        if (!this.toScreen(_pos, camera, _s0)) return false;
        const b = o.artboard.bounds();
        const ax = <f64>b.v0.x + o.center.x * <f64>(b.v1.x - b.v0.x);
        const ay = <f64>b.v0.y + o.center.y * <f64>(b.v1.y - b.v0.y);
        const s = o instanceof Artboard2DObject ? (o as Artboard2DObject).screenScale : 1;
        o.transform2D = Mat2D(<f32>s, 0, 0, <f32>s, <f32>(_s0.x - ax * s), <f32>(_s0.y - ay * s));
        return true;
    }

    private place3D(o: Artboard3DObject, camera: Camera): bool {
        const b = o.artboard.bounds();
        const x0 = <f64>b.v0.x, y0 = <f64>b.v0.y, x1 = <f64>b.v1.x, y1 = <f64>b.v1.y;
        const bw = x1 - x0, bh = y1 - y0;
        if (bw <= 0 || bh <= 0) return false;
        const ax = x0 + o.center.x * bw, ay = y0 + o.center.y * bh;
        if (o instanceof Artboard3DSprite) {
            // Facing the camera: one world unit along the camera's right
            // axis at the sprite's depth sets the scale.
            _pos.setFromMatrixPosition(o.matrixWorld);
            if (!this.toScreen(_pos, camera, _s0)) return false;
            o.getWorldScale(_scale);
            _right.setFromMatrixColumn(camera.matrixWorld, 0).normalize().multiplyScalar(_scale.x);
            _p.copy(_pos).add(_right);
            _p.project(camera);
            const sx = (_p.x * 0.5 + 0.5) * this.width, sy = (-_p.y * 0.5 + 0.5) * this.height;
            const s = Math.sqrt((sx - _s0.x) * (sx - _s0.x) + (sy - _s0.y) * (sy - _s0.y));
            const r = (o as Artboard3DSprite).rotation2D;
            const c = Math.cos(r) * s, si = Math.sin(r) * s;
            o.transform2D = Mat2D(<f32>c, <f32>si, <f32>-si, <f32>c,
                <f32>(_s0.x - (c * ax - si * ay)), <f32>(_s0.y - (si * ax + c * ay)));
            return true;
        }
        // Three corners (artboard y down = the object's -y), projected.
        _p.set(x0 - ax, -(y0 - ay), 0).applyMatrix4(o.matrixWorld);
        if (!this.toScreen(_p, camera, _s0)) return false;
        _p.set(x1 - ax, -(y0 - ay), 0).applyMatrix4(o.matrixWorld);
        if (!this.toScreen(_p, camera, _s1)) return false;
        _p.set(x0 - ax, -(y1 - ay), 0).applyMatrix4(o.matrixWorld);
        if (!this.toScreen(_p, camera, _s2)) return false;
        const xx = (_s1.x - _s0.x) / bw, xy = (_s1.y - _s0.y) / bw;
        const yx = (_s2.x - _s0.x) / bh, yy = (_s2.y - _s0.y) / bh;
        o.transform2D = Mat2D(<f32>xx, <f32>xy, <f32>yx, <f32>yy,
            <f32>(_s0.x - xx * x0 - yx * y0), <f32>(_s0.y - xy * x0 - yy * y0));
        return true;
    }

    private isOccluded(o: ArtboardObject, occluders: Object3D): bool {
        _pos.setFromMatrixPosition(o.matrixWorld);
        _dir.copy(_pos).sub(_cameraPos);
        const distance = _dir.length();
        if (distance <= 0) return false;
        _dir.divideScalar(distance);
        const r = this.raycaster;
        r.set(_cameraPos, _dir);
        r.far = Math.max(0, distance - this.occlusionBias);
        // A visible mesh or sprite in front, the walk ending at its first
        // hit (each mesh's at its first triangle).
        return ArtboardPicker.occluded(occluders, r);
    }
}

function forward(o: ArtboardObject, event: PointerEvent, kind: i32): f64 {
    if (o.disposed) return 0;
    const p = o.artboardPoint(<f64>event.position.x, <f64>event.position.y);
    if (p == null) return 0;
    const v = Vector.xy(<f32>p.x, <f32>p.y);
    const types: StaticArray<string> = ["down", "move", "up", "exit"];
    const e = new PointerEvent(event.id, v, v, types[kind]);
    if (kind == 0) return o.artboard.pointerDown(e);
    if (kind == 1) return o.artboard.pointerMove(e);
    if (kind == 2) return o.artboard.pointerUp(e);
    return o.artboard.pointerExit(e);
}

// Visible overlay objects in the camera's layers, depth first (no
// closures for traverseVisible).
function collect(o: Object3D, camera: Camera, out: Array<ArtboardObject>): void {
    if (!o.visible) return;
    if (o instanceof ArtboardObject && o.layers.test(camera.layers) && !(o as ArtboardObject).disposed) {
        out.push(o as ArtboardObject);
    }
    const children = o.children;
    for (let i = 0; i < children.length; i++) collect(children[i], camera, out);
}

function byDistance(a: ArtboardObject, b: ArtboardObject): i32 {
    return a.cameraDistance > b.cameraDistance ? -1 : a.cameraDistance < b.cameraDistance ? 1 : 0;
}

const _pos = new Vector3();
const _cameraPos = new Vector3();
const _dir = new Vector3();
const _p = new Vector3();
const _right = new Vector3();
const _scale = new Vector3();
const _s0 = new Vector3();
const _s1 = new Vector3();
const _s2 = new Vector3();
