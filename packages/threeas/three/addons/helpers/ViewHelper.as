// three.js examples/jsm/helpers/ViewHelper.js (r16x): an axis gizmo drawn
// in a 128 x 128 point viewport at the renderer's bottom-right corner, from
// its own orthographic camera. A click on one of its six end sprites turns
// the camera, around `center`, to look along that axis; `update(delta)`
// runs the turn while `animating`.
//
//     helper = new ViewHelper(this.camera, this.renderer);
//     helper.center = controls.target;
//     // in animate(seconds):  if (helper.animating) helper.update(seconds);
//     // in renderFrame():     renderer.clear(); super.renderFrame(); helper.render(renderer);
//     // on a click:           helper.handleClick(event);
//     // (and controls.enabled = !helper.animating, as three.js's editor)
//
// What differs (docs/DEVIATIONS.md): `domElement` is the GPURenderer (its
// size in points places the gizmo; null takes the gizmo's own 128 x 128);
// `handleClick` takes a Rive PointerEvent in layout coordinates; the
// sprites' canvases are Rive 2D canvases drawn by the renderer (Texture's
// `update` hook), the label font a font asset of the Rive file named by
// the CSS font string's family; `render` clears depth through its own
// pass (autoClear on, autoClearColor off, restored after) rather than a
// separate `clearDepth()`.

import { PointerEvent } from "rive/events";
import { Context } from "rive/host";
import { Renderer } from "rive/renderer";
import { Path } from "rive/path";
import { Paint, PaintStyle } from "rive/paint";
import { Text, TextRunStyle, TextAlign, TextOrigin, TextSizing, TextWrap } from "rive/text";
import { Vector } from "rive/vector";
import { Mat2D } from "rive/mat2d";
import { Canvas } from "rive/canvas";
import { Dynamic } from "rive/dynamic";
import { Object3D } from "../../core/Object3D";
import { Camera } from "../../cameras/Camera";
import { OrthographicCamera } from "../../cameras/OrthographicCamera";
import { GPURenderer } from "../../renderers/GPURenderer";
import { Raycaster, Intersection } from "../../core/Raycaster";
import { Mesh } from "../../objects/Mesh";
import { Sprite } from "../../objects/Sprite";
import { MeshBasicMaterial } from "../../materials/MeshBasicMaterial";
import { SpriteMaterial } from "../../materials/SpriteMaterial";
import { BufferGeometry } from "../../core/BufferGeometry";
import { CylinderGeometry } from "../../geometries/CylinderGeometry";
import { Texture } from "../../textures/Texture";
import { Color } from "../../math/Color";
import { Euler } from "../../math/Euler";
import { Quaternion } from "../../math/Quaternion";
import { Vector2 } from "../../math/Vector2";
import { Vector3 } from "../../math/Vector3";
import { Vector4 } from "../../math/Vector4";
import { SRGBColorSpace } from "../../constants";

const COLOR_X: u32 = 0xff4466;
const COLOR_Y: u32 = 0x88ff44;
const COLOR_Z: u32 = 0x4488ff;
/// The gizmo's viewport, in points.
const DIM: f64 = 128;
/// Radians a second.
const TURN_RATE: f64 = 2 * Math.PI;
/// The sprites' canvas size in pixels (three.js's 64 x 64 canvas).
const CANVAS_SIZE: u32 = 64;
/// Circle control-point distance for a quarter arc.
const KAPPA: f32 = 0.5522847498;

const _size = new Vector2();
const _color = new Color();

/// Label options (three.js's `options`).
class LabelOptions {
    labelX: string? = null;
    labelY: string? = null;
    labelZ: string? = null;
    font: string = "24px Arial";
    color: string = "#000000";
    radius: f64 = 14;
}

/// A sprite's map: a disc of the axis colour with an optional label, drawn
/// into a Rive 2D canvas when the renderer updates it (three.js draws an
/// HTML canvas once into a CanvasTexture).
export class ViewHelperTexture extends Texture {
    color: u32;
    label: string? = null;
    options: LabelOptions;
    private canvas: Canvas? = null;
    private drawn: bool = false;

    constructor(color: u32, options: LabelOptions) {
        super();
        this.color = color;
        this.options = options;
        this.colorSpace = SRGBColorSpace;
    }

    /// Draws again at the next update (labels or style changed).
    redraw(): void { this.drawn = false; }

    override update(context: Context): void {
        if (this.drawn) return;
        let canvas = this.canvas;
        if (canvas == null) {
            canvas = context.canvas(CANVAS_SIZE, CANVAS_SIZE);
            if (canvas == null) return;
            this.canvas = canvas;
            this.image = canvas.image;
        }
        const r = canvas.beginFrame(0);
        if (r == null) return;
        const o = this.options;
        const c: f32 = <f32>CANVAS_SIZE / 2;
        const radius: f32 = <f32>o.radius;
        const k = radius * KAPPA;
        const path = new Path();
        path.moveTo(Vector.xy(c + radius, c));
        path.cubicTo(Vector.xy(c + radius, c + k), Vector.xy(c + k, c + radius), Vector.xy(c, c + radius));
        path.cubicTo(Vector.xy(c - k, c + radius), Vector.xy(c - radius, c + k), Vector.xy(c - radius, c));
        path.cubicTo(Vector.xy(c - radius, c - k), Vector.xy(c - k, c - radius), Vector.xy(c, c - radius));
        path.cubicTo(Vector.xy(c + k, c - radius), Vector.xy(c + radius, c - k), Vector.xy(c + radius, c));
        path.close();
        const paint = new Paint();
        paint.style = PaintStyle.fill;
        paint.color = 0xFF000000 | this.color;
        r.drawPath(path, paint);
        const label = this.label;
        if (label != null && label.length > 0) drawLabel(context, r, label, o);
        canvas.endFrame();
        path.release();
        paint.release();
        this.drawn = true;
        this.needsUpdate = true;
    }

    /// Frees the canvas too (it is the texture's own).
    override dispose(): void {
        const canvas = this.canvas;
        if (canvas != null) canvas.release();
        this.canvas = null;
        this.image = null;
        this.drawn = false;
        super.dispose();
    }
}

/// `text` centred at x 32 with its baseline at y 41, as three.js's
/// `fillText(text, 32, 41)`, in the CSS font string's size and family (a
/// font asset of the Rive file; nothing is drawn when there is none).
function drawLabel(context: Context, r: Renderer, text: string, o: LabelOptions): void {
    let size: f32 = 24;
    let family = "";
    const words = o.font.trim().split(" ");
    for (let i = 0; i < words.length; i++) {
        const w = words[i];
        if (w.endsWith("px")) {
            size = <f32>parseFloat(w.substring(0, w.length - 2));
            family = words.slice(i + 1).join(" ");
            break;
        }
    }
    const comma = family.indexOf(",");
    if (comma >= 0) family = family.substring(0, comma);
    family = family.replaceAll("'", "").replaceAll("\"", "").trim();
    const font = context.font(family);
    if (font == null) return;
    const paint = new Paint();
    paint.style = PaintStyle.fill;
    paint.color = 0xFF000000 | _color.setStyle(o.color).getHex();
    const style = new TextRunStyle(font);
    style.size = size;
    style.paint = paint;
    const t = new Text();
    t.sizing = TextSizing.autoHeight;
    t.maxWidth = <f32>CANVAS_SIZE;
    t.wrap = TextWrap.noWrap;
    t.align = TextAlign.center;
    t.origin = TextOrigin.baseline;
    t.append(text, style);
    r.save();
    r.transform(Mat2D(1, 0, 0, 1, 0, 41));
    t.draw(r);
    r.restore();
    t.release();
    paint.release();
}

export class ViewHelper extends Object3D {
    readonly isViewHelper: bool = true;
    animating: bool = false;
    center: Vector3 = new Vector3();

    camera: Camera;
    domElement: GPURenderer?;

    private options: LabelOptions = new LabelOptions();
    private interactiveObjects: Array<Object3D> = [];
    private raycaster: Raycaster = new Raycaster();
    private mouse: Vector2 = new Vector2();
    private dummy: Object3D = new Object3D();
    private orthoCamera: OrthographicCamera = new OrthographicCamera(-2, 2, 2, -2, 0, 4);
    private geometry: BufferGeometry;
    private xAxis: Mesh;
    private yAxis: Mesh;
    private zAxis: Mesh;
    private posXAxisHelper: Sprite;
    private posYAxisHelper: Sprite;
    private posZAxisHelper: Sprite;
    private negXAxisHelper: Sprite;
    private negYAxisHelper: Sprite;
    private negZAxisHelper: Sprite;
    private point: Vector3 = new Vector3();
    private targetPosition: Vector3 = new Vector3();
    private targetQuaternion: Quaternion = new Quaternion();
    private q1: Quaternion = new Quaternion();
    private q2: Quaternion = new Quaternion();
    private viewport: Vector4 = new Vector4();
    private radius: f64 = 0;
    private hits: Array<Intersection> = [];

    constructor(camera: Camera, domElement: GPURenderer? = null) {
        super();
        this.type = "ViewHelper";
        this.camera = camera;
        this.domElement = domElement;
        this.orthoCamera.position.set(0, 0, 2);

        const geometry = new CylinderGeometry(0.04, 0.04, 0.8, 5).rotateZ(-Math.PI / 2).translate(0.4, 0, 0);
        this.geometry = geometry;
        this.xAxis = new Mesh(geometry, getAxisMaterial(COLOR_X));
        this.yAxis = new Mesh(geometry, getAxisMaterial(COLOR_Y));
        this.zAxis = new Mesh(geometry, getAxisMaterial(COLOR_Z));
        this.yAxis.rotation.z = Math.PI / 2;
        this.zAxis.rotation.y = -Math.PI / 2;
        this.add(this.xAxis);
        this.add(this.zAxis);
        this.add(this.yAxis);

        const o = this.options;
        this.posXAxisHelper = makeSprite(COLOR_X, o, "posX");
        this.posYAxisHelper = makeSprite(COLOR_Y, o, "posY");
        this.posZAxisHelper = makeSprite(COLOR_Z, o, "posZ");
        this.negXAxisHelper = makeSprite(COLOR_X, o, "negX");
        this.negYAxisHelper = makeSprite(COLOR_Y, o, "negY");
        this.negZAxisHelper = makeSprite(COLOR_Z, o, "negZ");
        this.posXAxisHelper.position.x = 1;
        this.posYAxisHelper.position.y = 1;
        this.posZAxisHelper.position.z = 1;
        this.negXAxisHelper.position.x = -1;
        this.negYAxisHelper.position.y = -1;
        this.negZAxisHelper.position.z = -1;
        const sprites: StaticArray<Sprite> = [this.posXAxisHelper, this.posYAxisHelper, this.posZAxisHelper,
            this.negXAxisHelper, this.negYAxisHelper, this.negZAxisHelper];
        for (let i = 0; i < sprites.length; i++) {
            this.add(sprites[i]);
            this.interactiveObjects.push(sprites[i]);
        }
        this.updateLabels();
    }

    /// Draws the gizmo over what `renderer` drew, in a DIM x DIM viewport
    /// at its bottom-right corner (call it after the scene's render).
    render(renderer: GPURenderer): void {
        const camera = this.camera;
        this.quaternion.copy(camera.quaternion).invert();
        this.updateMatrixWorld();
        // The sprites on the far side of each axis are dimmed.
        const point = this.point.set(0, 0, 1).applyQuaternion(camera.quaternion);
        dim(this.posXAxisHelper, this.negXAxisHelper, point.x);
        dim(this.posYAxisHelper, this.negYAxisHelper, point.y);
        dim(this.posZAxisHelper, this.negZAxisHelper, point.z);

        const x = renderer.getSize(_size).x - DIM;
        const y: f64 = 0;
        const autoClear = renderer.autoClear;
        const autoClearColor = renderer.autoClearColor;
        const autoClearDepth = renderer.autoClearDepth;
        const autoClearStencil = renderer.autoClearStencil;
        renderer.autoClear = true;
        renderer.autoClearColor = false;
        renderer.autoClearDepth = true;
        renderer.autoClearStencil = false;
        const viewport = renderer.getViewport(this.viewport);
        renderer.setViewport<f64>(x, y, DIM, DIM);
        renderer.render(this, this.orthoCamera);
        renderer.setViewport<f64>(viewport.x, viewport.y, viewport.z, viewport.w);
        renderer.autoClear = autoClear;
        renderer.autoClearColor = autoClearColor;
        renderer.autoClearDepth = autoClearDepth;
        renderer.autoClearStencil = autoClearStencil;
    }

    /// Starts turning the camera when `event` (layout coordinates) is on a
    /// sprite; true then. False while a turn is under way.
    handleClick(event: PointerEvent): bool {
        if (this.animating) return false;
        let width = DIM, height = DIM;
        const element = this.domElement;
        if (element != null) {
            element.getSize(_size);
            width = _size.x;
            height = _size.y;
        }
        const offsetX = width - DIM, offsetY = height - DIM;
        this.mouse.x = (<f64>event.position.x - offsetX) / (width - offsetX) * 2 - 1;
        this.mouse.y = -(<f64>event.position.y - offsetY) / (height - offsetY) * 2 + 1;
        // Oriented as the next render will show it (render may not have
        // run since the camera moved).
        this.quaternion.copy(this.camera.quaternion).invert();
        this.updateMatrixWorld();
        this.raycaster.setFromCamera(this.mouse, this.orthoCamera);
        this.hits.length = 0;
        this.raycaster.intersectObjects(this.interactiveObjects, true, this.hits);
        if (this.hits.length > 0) {
            this.prepareAnimationData(this.hits[0].object, this.center);
            this.animating = true;
            return true;
        }
        return false;
    }

    /// Labels on the positive sprites (null: none).
    setLabels(labelX: string? = null, labelY: string? = null, labelZ: string? = null): void {
        const o = this.options;
        o.labelX = labelX;
        o.labelY = labelY;
        o.labelZ = labelZ;
        this.updateLabels();
    }

    /// The labels' CSS font ("24px Orbitron": its size and the family of a
    /// font asset of the Rive file), CSS colour and the discs' radius in
    /// canvas pixels (of 64).
    setLabelStyle(font: string = "24px Arial", color: string = "#000000", radius: f64 = 14): void {
        const o = this.options;
        o.font = font;
        o.color = color;
        o.radius = radius;
        this.updateLabels();
    }

    /// Advances the turn by `delta` seconds.
    update(delta: f64): void {
        const step = delta * TURN_RATE;
        const q1 = this.q1, q2 = this.q2;
        // Position: a slerp on the unit sphere, scaled to the radius.
        q1.rotateTowards(q2, step);
        this.camera.position.set(0, 0, 1).applyQuaternion(q1).multiplyScalar(this.radius).add(this.center);
        // Orientation.
        this.camera.quaternion.rotateTowards(this.targetQuaternion, step);
        if (q1.angleTo(q2) == 0) this.animating = false;
    }

    /// Disposes the axes' geometry and materials and the sprites' materials
    /// and textures (with their canvases).
    dispose(): void {
        this.geometry.dispose();
        this.xAxis.material.dispose();
        this.yAxis.material.dispose();
        this.zAxis.material.dispose();
        for (let i = 0; i < this.interactiveObjects.length; i++) {
            const m = (this.interactiveObjects[i] as Sprite).material;
            const map = m.map;
            if (map != null) map.dispose();
            m.dispose();
        }
    }

    private prepareAnimationData(object: Object3D, focusPoint: Vector3): void {
        const type = Dynamic.asString(object.userData.get("type"));
        const tp = this.targetPosition;
        const tq = this.targetQuaternion;
        const halfPi = Math.PI * 0.5;
        if (type == "posX") {
            tp.set(1, 0, 0);
            tq.setFromEuler(new Euler(0, halfPi, 0));
        } else if (type == "posY") {
            tp.set(0, 1, 0);
            tq.setFromEuler(new Euler(-halfPi, 0, 0));
        } else if (type == "posZ") {
            tp.set(0, 0, 1);
            tq.setFromEuler(new Euler());
        } else if (type == "negX") {
            tp.set(-1, 0, 0);
            tq.setFromEuler(new Euler(0, -halfPi, 0));
        } else if (type == "negY") {
            tp.set(0, -1, 0);
            tq.setFromEuler(new Euler(halfPi, 0, 0));
        } else if (type == "negZ") {
            tp.set(0, 0, -1);
            tq.setFromEuler(new Euler(0, Math.PI, 0));
        } else {
            console.warn("ViewHelper: Invalid axis.");
        }
        const camera = this.camera;
        this.radius = camera.position.distanceTo(focusPoint);
        tp.multiplyScalar(this.radius).add(focusPoint);
        const dummy = this.dummy;
        dummy.position.copy(focusPoint);
        dummy.lookAt<Vector3>(camera.position);
        this.q1.copy(dummy.quaternion);
        dummy.lookAt<Vector3>(tp);
        this.q2.copy(dummy.quaternion);
    }

    /// Positive sprites take the labels; all are drawn again.
    private updateLabels(): void {
        const o = this.options;
        mapOf(this.posXAxisHelper).label = o.labelX;
        mapOf(this.posYAxisHelper).label = o.labelY;
        mapOf(this.posZAxisHelper).label = o.labelZ;
        for (let i = 0; i < this.interactiveObjects.length; i++) {
            mapOf(this.interactiveObjects[i] as Sprite).redraw();
        }
    }
}

function getAxisMaterial(color: u32): MeshBasicMaterial {
    return new MeshBasicMaterial({ color: color, toneMapped: false });
}

function makeSprite(color: u32, options: LabelOptions, type: string): Sprite {
    const map = new ViewHelperTexture(color, options);
    const sprite = new Sprite(new SpriteMaterial({ map: map, toneMapped: false }));
    sprite.userData.set("type", Dynamic.fromString(type));
    return sprite;
}

function mapOf(sprite: Sprite): ViewHelperTexture {
    return sprite.material.map as ViewHelperTexture;
}

/// The sprite on the camera's side of an axis at full opacity, the other
/// at half.
function dim(pos: Sprite, neg: Sprite, side: f64): void {
    pos.material.opacity = side >= 0 ? 1 : 0.5;
    neg.material.opacity = side >= 0 ? 0.5 : 1;
}
