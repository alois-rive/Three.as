// ThreeLayout: a Rive Layout that is a three.js app. It makes the renderer,
// keeps the camera's aspect and the pixel ratio in step with the layout,
// renders and presents every frame, drives `controls`, and forwards
// pointer events to interactive ArtboardTextures under the pointer. With
// `overlay` set it also places, draws and advances the scene's artboard
// overlays (Artboard2DObject ...), which get the pointer first; with
// `bindings` set it syncs them with the view model every frame (and makes
// them itself when the bound view model has a `threeBindings` string).
//
//     export class Demo extends ThreeLayout {
//         cube: Mesh = new Mesh(new BoxGeometry(), new MeshNormalMaterial());
//         override setup(context: Context): bool {
//             this.scene.add(this.cube);
//             this.camera.position.z = 3;
//             this.controls = new OrbitControls(this.camera, this.renderer);
//             return true;
//         }
//         override animate(seconds: f64): void {
//             this.cube.rotation.y += seconds;
//         }
//     }
//
// Override setup/animate/onResize (and onPointer* to react to the pointer)
// rather than init/advance/resize/draw.
//
// Pointer events stay cheap in big scenes: world matrices are updated at
// the first pointer event after each advance (not at every event), and
// forwarding raycasts only the meshes and sprites that map an interactive
// ArtboardTexture, then tests the scene in front of the nearest hit for
// an occluder (see ArtboardPicker; nothing at all without an
// ArtboardTexture). Moves at the same ray within a frame reuse the last
// answer. A subclass that moves objects or changes materials in a pointer
// hook (or anywhere outside advance) calls `invalidatePointer()` so the
// next event sees the change.

import { Layout, Context } from "rive/host";
import { Renderer } from "rive/renderer";
import { PointerEvent, ScrollEvent, KeyboardEvent } from "rive/events";
import { GPURenderer } from "../renderers/GPURenderer";
import { Scene } from "../scenes/Scene";
import { Camera } from "../cameras/Camera";
import { PerspectiveCamera } from "../cameras/PerspectiveCamera";
import { Raycaster } from "../core/Raycaster";
import { Vector2 } from "../math/Vector2";
import { Vector3 } from "../math/Vector3";
import { Controls } from "../extras/Controls";
import { ArtboardTexture } from "./ArtboardTexture";
import { ArtboardPicker } from "./ArtboardPicker";
import { ArtboardOverlayRenderer } from "./ArtboardOverlay";
import { SceneBindings, BINDINGS_PROPERTY } from "./SceneBindings";

export abstract class ThreeLayout extends Layout {
    context: Context? = null;
    renderer: GPURenderer? = null;
    scene: Scene = new Scene();
    /// A PerspectiveCamera's aspect follows the layout.
    camera: Camera = new PerspectiveCamera(50, 1, 0.1, 2000);
    /// Driven by the pointer and updated every frame when set.
    controls: Controls? = null;
    /// Controls that get the pointer before `controls` (TransformControls,
    /// DragControls): while one is capturing, `controls` does not see it.
    tools: Array<Controls> = [];
    /// The last pointer position, normalized device coordinates (x right,
    /// y up, -1 to 1), as three.js examples keep it.
    pointer: Vector2 = new Vector2();
    raycaster: Raycaster = new Raycaster();
    /// The layout size in points.
    width: f64 = 0;
    height: f64 = 0;
    antialias: bool = true;
    /// Raycast pointer events into interactive ArtboardTextures.
    forwardToArtboards: bool = true;
    /// Finds the ArtboardTexture under the pointer; set `picker.occluders`
    /// to a group of the meshes that can hide them in a crowded scene.
    picker: ArtboardPicker = new ArtboardPicker();
    /// Artboards drawn over the scene (CSS2DRenderer / CSS3DRenderer's
    /// counterpart): placed after each render, drawn over the canvas,
    /// advanced each frame, first to get the pointer.
    overlay: ArtboardOverlayRenderer? = null;
    /// Scene properties synced with view model properties each frame (after
    /// `animate`, before the controls).
    bindings: SceneBindings? = null;
    // A press an overlay took: its moves and release go to the overlay.
    private overlayPressed: bool = false;

    private hovered: ArtboardTexture? = null;
    private captured: ArtboardTexture? = null;
    private hitUv: Vector2 = new Vector2();
    private hoveredUv: Vector2 = new Vector2();
    private capturedUv: Vector2 = new Vector2();
    // Frames advanced; world matrices changed since the last pointer update.
    private frame: i32 = 0;
    private matricesStale: bool = true;
    // The last pick: its frame (-1: none), ray and answer.
    private pickFrame: i32 = -1;
    private pickOrigin: Vector3 = new Vector3();
    private pickDirection: Vector3 = new Vector3();
    private pickTarget: ArtboardTexture? = null;
    // Presses that began inside the layout and have not ended.
    private pressed: i32 = 0;
    /// Seconds since the previous frame (the last advance).
    delta: f64 = 0;

    override init(context: Context): bool {
        this.context = context;
        this.renderer = new GPURenderer(context, { antialias: this.antialias });
        // A bound view model with a `threeBindings` spec binds itself (at
        // the first update, so setup can build the scene and add actions).
        const dc = context.dataContext();
        const vm = dc != null ? dc.viewModel() : null;
        if (vm != null && vm.getString(BINDINGS_PROPERTY) != null) {
            this.bindings = SceneBindings.fromViewModel(this.scene, vm);
        }
        return this.setup(context);
    }

    /// Builds the scene (the renderer exists already).
    setup(context: Context): bool { return true; }

    /// Called every frame with the seconds since the last one.
    animate(seconds: f64): void {}

    /// Called after the layout changed size (the camera aspect is updated).
    onResize(width: f64, height: f64): void {}

    override resize(width: f64, height: f64, scale: f64): void {
        this.width = width;
        this.height = height;
        const r = this.renderer;
        if (r != null) {
            r.setPixelRatio(scale);
            r.setSize(width, height);
        }
        const overlay = this.overlay;
        if (overlay != null) overlay.setSize(width, height);
        const camera = this.camera;
        if (camera instanceof PerspectiveCamera && height > 0) {
            (camera as PerspectiveCamera).aspect = width / height;
            camera.updateProjectionMatrix();
        }
        this.onResize(width, height);
    }

    override advance(seconds: f64): bool {
        this.delta = seconds;
        this.invalidatePointer();
        this.frame++;
        this.animate(seconds);
        const b = this.bindings;
        if (b != null) b.update();
        const c = this.controls;
        if (c != null) c.update(seconds);
        for (let i = 0; i < this.tools.length; i++) this.tools[i].update(seconds);
        // Overlays are placed here (pointer events between frames hit
        // where they were drawn) and drawn after the render.
        const overlay = this.overlay;
        if (overlay != null) {
            if (overlay.width != this.width || overlay.height != this.height) overlay.setSize(this.width, this.height);
            overlay.advance(seconds);
            overlay.render(this.scene, this.camera);
        }
        return true;
    }

    /// Renders the frame; override to render through an EffectComposer
    /// (`this.composer.render(this.delta)`) or into render targets first.
    renderFrame(): void {
        const r = this.renderer;
        if (r != null) r.render(this.scene, this.camera);
    }

    override draw(renderer: Renderer): void {
        const r = this.renderer;
        if (r == null) return;
        this.renderFrame();
        r.present(renderer);
        const overlay = this.overlay;
        if (overlay != null) overlay.draw(renderer);
    }

    // ------------------------------------------------------------ pointer

    /// Hooks for subclasses, after the pointer and raycaster are set.
    onPointerDown(event: PointerEvent): void {}
    onPointerMove(event: PointerEvent): void {}
    onPointerUp(event: PointerEvent): void {}

    /// Whether `x, y` (layout coordinates) is inside the layout. Rive hands
    /// a script every pointer event of its artboard, so presses and scrolls
    /// elsewhere (other UI around the layout) are left alone.
    contains(x: f64, y: f64): bool {
        return x >= 0 && y >= 0 && x <= this.width && y <= this.height;
    }

    override pointerDown(event: PointerEvent): void {
        if (!this.contains(<f64>event.position.x, <f64>event.position.y)) return;
        this.pressed++;
        this.setPointer(event);
        const overlay = this.overlay;
        if (overlay != null && overlay.pointerDown(event)) {
            this.overlayPressed = true;
            event.hit();
            this.onPointerDown(event);
            return;
        }
        const t = this.artboardUnderPointer(true);
        if (t != null && t.pointerDown(this.hitUv, event.id)) {
            this.captured = t;
            this.capturedUv.copy(this.hitUv);
            event.hit();
        } else {
            let claimed = false;
            for (let i = 0; i < this.tools.length; i++) {
                this.tools[i].pointerDown(event);
                if (this.tools[i].capturing()) claimed = true;
            }
            const c = this.controls;
            if (c != null && !claimed) c.pointerDown(event);
            if (claimed) this.invalidatePointer();
        }
        this.onPointerDown(event);
    }

    override pointerMove(event: PointerEvent): void {
        // Outside the layout, only drags that started inside it continue.
        if (this.pressed == 0 && !this.contains(<f64>event.position.x, <f64>event.position.y)) {
            this.pointerExit(event);
            return;
        }
        this.setPointer(event);
        const overlay = this.overlay;
        if (overlay != null) {
            const took = overlay.pointerMove(event);
            if (this.overlayPressed || took) {
                event.hit();
                this.onPointerMove(event);
                return;
            }
        }
        const t = this.artboardUnderPointer(false);
        const captured = this.captured;
        if (captured != null) {
            if (t === captured) this.capturedUv.copy(this.hitUv);
            captured.pointerMove(this.capturedUv, event.id);
            const hovered = this.hovered;
            if (hovered != null && hovered !== t && hovered !== captured) {
                hovered.pointerExit(this.hoveredUv, event.id);
            }
            this.hovered = t;
            if (t != null) this.hoveredUv.copy(this.hitUv);
            event.hit();
        } else {
            const hovered = this.hovered;
            if (hovered != null && hovered !== t) hovered.pointerExit(this.hoveredUv, event.id);
            this.hovered = t;
            if (t != null) {
                this.hoveredUv.copy(this.hitUv);
                t.pointerMove(this.hitUv, event.id);
            }
            let claimed = false;
            for (let i = 0; i < this.tools.length; i++) {
                this.tools[i].pointerMove(event);
                if (this.tools[i].capturing()) claimed = true;
            }
            const c = this.controls;
            if (c != null && !claimed) c.pointerMove(event);
            // A tool dragging an object moves it.
            if (claimed) this.invalidatePointer();
        }
        this.onPointerMove(event);
    }

    override pointerUp(event: PointerEvent): void {
        if (this.pressed == 0) return;
        this.pressed--;
        this.setPointer(event);
        if (this.overlayPressed) {
            this.overlayPressed = false;
            const overlay = this.overlay;
            if (overlay != null) overlay.pointerUp(event);
            event.hit();
            this.onPointerUp(event);
            return;
        }
        const t = this.artboardUnderPointer(true);
        const captured = this.captured;
        if (captured != null) {
            if (t === captured) this.capturedUv.copy(this.hitUv);
            captured.pointerUp(this.capturedUv, event.id);
            if (t !== captured) {
                captured.pointerExit(this.capturedUv, event.id);
                if (this.hovered === captured) this.hovered = null;
            }
            this.captured = null;
            event.hit();
        } else if (t != null) {
            this.hoveredUv.copy(this.hitUv);
            t.pointerUp(this.hitUv, event.id);
        }
        for (let i = 0; i < this.tools.length; i++) this.tools[i].pointerUp(event);
        const c = this.controls;
        if (c != null) c.pointerUp(event);
        this.onPointerUp(event);
    }

    override pointerExit(event: PointerEvent): void {
        this.pressed = 0;
        this.overlayPressed = false;
        const overlay = this.overlay;
        if (overlay != null) overlay.pointerExit(event);
        const hovered = this.hovered;
        if (hovered != null) hovered.pointerExit(this.hoveredUv, event.id);
        this.hovered = null;
        const captured = this.captured;
        if (captured != null) {
            if (captured !== hovered) captured.pointerExit(this.capturedUv, event.id);
            this.captured = null;
        }
        for (let i = 0; i < this.tools.length; i++) this.tools[i].pointerExit(event);
        const c = this.controls;
        if (c != null) c.pointerExit(event);
    }

    override keyboardEvent(event: KeyboardEvent): bool {
        let handled = false;
        for (let i = 0; i < this.tools.length; i++) if (this.tools[i].keyboardEvent(event)) handled = true;
        const c = this.controls;
        if (c != null && c.keyboardEvent(event)) handled = true;
        return handled;
    }

    override pointerScroll(event: ScrollEvent): void {
        if (!this.contains(<f64>event.position.x, <f64>event.position.y)) return;
        const c = this.controls;
        if (c != null) c.pointerScroll(event);
    }

    /// Sets `pointer` (NDC) and aims the raycaster through it. World
    /// matrices are refreshed at the first event after an advance (or
    /// after `invalidatePointer()`): pointer events can arrive before the
    /// next render has updated them. The camera's are refreshed every time
    /// (controls move it between events).
    setPointer(event: PointerEvent): void {
        const w = this.width > 0 ? this.width : 1, h = this.height > 0 ? this.height : 1;
        this.pointer.set(<f64>event.position.x / w * 2 - 1, -(<f64>event.position.y / h * 2 - 1));
        if (this.matricesStale) {
            this.matricesStale = false;
            this.scene.updateMatrixWorld();
        }
        this.raycaster.setFromCamera(this.pointer, this.camera);
    }

    /// Makes the next pointer event update world matrices and look for
    /// interactive ArtboardTextures again. Call it after moving objects,
    /// adding or hiding them, or changing their materials outside `advance`
    /// (in a pointer hook, say) when the next event in the same frame must
    /// see it. ThreeLayout calls it every advance and while a tool drags.
    invalidatePointer(): void {
        this.matricesStale = true;
        this.pickFrame = -1;
        this.picker.invalidate();
    }

    /// The nearest interactive ArtboardTexture hit by the raycaster (its hit
    /// uv in hitUv), or null. A move along the ray of the last pick in the
    /// same frame reuses it (`exact` for presses and releases: never).
    private artboardUnderPointer(exact: bool): ArtboardTexture? {
        if (!this.forwardToArtboards) return null;
        const ray = this.raycaster.ray;
        if (!exact && this.pickFrame == this.frame && ray.origin.equals(this.pickOrigin)
                && ray.direction.equals(this.pickDirection)) {
            return this.pickTarget;
        }
        const picker = this.picker;
        let t: ArtboardTexture? = null;
        if (picker.pick(this.scene, this.raycaster)) {
            const map = picker.texture;
            if (map != null && map instanceof ArtboardTexture) {
                t = map as ArtboardTexture;
                this.hitUv.copy(picker.uv);
            }
        }
        this.pickFrame = this.frame;
        this.pickOrigin.copy(ray.origin);
        this.pickDirection.copy(ray.direction);
        this.pickTarget = t;
        return t;
    }
}
