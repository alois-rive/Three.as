// ThreeLayout: a Rive Layout that is a three.js app. It makes the renderer,
// keeps the camera's aspect and the pixel ratio in step with the layout,
// renders and presents every frame, drives `controls`, and forwards
// pointer events to interactive ArtboardTextures under the pointer.
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

import { Layout, Context } from "rive/host";
import { Renderer } from "rive/renderer";
import { PointerEvent, ScrollEvent } from "rive/events";
import { GPURenderer } from "../renderers/GPURenderer";
import { Scene } from "../scenes/Scene";
import { Camera } from "../cameras/Camera";
import { PerspectiveCamera } from "../cameras/PerspectiveCamera";
import { Raycaster, Intersection } from "../core/Raycaster";
import { Object3D } from "../core/Object3D";
import { Mesh } from "../objects/Mesh";
import { Sprite } from "../objects/Sprite";
import { Material } from "../materials/Material";
import { MaterialUniforms, SLOT_MAP } from "../materials/MaterialUniforms";
import { Vector2 } from "../math/Vector2";
import { OrbitControls } from "../addons/controls/OrbitControls";
import { ArtboardTexture } from "./ArtboardTexture";

export abstract class ThreeLayout extends Layout {
    context: Context? = null;
    renderer: GPURenderer? = null;
    scene: Scene = new Scene();
    /// A PerspectiveCamera's aspect follows the layout.
    camera: Camera = new PerspectiveCamera(50, 1, 0.1, 2000);
    /// Driven by the pointer and updated every frame when set.
    controls: OrbitControls? = null;
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

    private hovered: ArtboardTexture? = null;
    private captured: ArtboardTexture? = null;
    private uniforms: MaterialUniforms = new MaterialUniforms();
    private hitUv: Vector2 = new Vector2();
    /// Seconds since the previous frame (the last advance).
    delta: f64 = 0;

    override init(context: Context): bool {
        this.context = context;
        this.renderer = new GPURenderer(context, { antialias: this.antialias });
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
        const camera = this.camera;
        if (camera instanceof PerspectiveCamera && height > 0) {
            (camera as PerspectiveCamera).aspect = width / height;
            camera.updateProjectionMatrix();
        }
        this.onResize(width, height);
    }

    override advance(seconds: f64): bool {
        this.delta = seconds;
        this.animate(seconds);
        const c = this.controls;
        if (c != null) c.update(seconds);
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
    }

    // ------------------------------------------------------------ pointer

    /// Hooks for subclasses, after the pointer and raycaster are set.
    onPointerDown(event: PointerEvent): void {}
    onPointerMove(event: PointerEvent): void {}
    onPointerUp(event: PointerEvent): void {}

    override pointerDown(event: PointerEvent): void {
        this.setPointer(event);
        const t = this.artboardUnderPointer();
        if (t != null && t.pointerDown(this.hitUv, event.id)) {
            this.captured = t;
            event.hit();
        } else {
            const c = this.controls;
            if (c != null) c.pointerDown(event);
        }
        this.onPointerDown(event);
    }

    override pointerMove(event: PointerEvent): void {
        this.setPointer(event);
        const t = this.artboardUnderPointer();
        const hovered = this.hovered;
        if (hovered != null && hovered !== t) hovered.pointerExit(this.hitUv, event.id);
        this.hovered = t;
        const captured = this.captured;
        if (t != null) t.pointerMove(this.hitUv, event.id);
        else if (captured != null) captured.pointerMove(this.hitUv, event.id);
        if (captured == null) {
            const c = this.controls;
            if (c != null) c.pointerMove(event);
        } else {
            event.hit();
        }
        this.onPointerMove(event);
    }

    override pointerUp(event: PointerEvent): void {
        this.setPointer(event);
        const t = this.artboardUnderPointer();
        const captured = this.captured;
        if (captured != null) {
            captured.pointerUp(this.hitUv, event.id);
            this.captured = null;
            event.hit();
        } else if (t != null) {
            t.pointerUp(this.hitUv, event.id);
        }
        const c = this.controls;
        if (c != null) c.pointerUp(event);
        this.onPointerUp(event);
    }

    override pointerExit(event: PointerEvent): void {
        const hovered = this.hovered;
        if (hovered != null) hovered.pointerExit(this.hitUv, event.id);
        this.hovered = null;
        const c = this.controls;
        if (c != null) c.pointerExit(event);
    }

    override pointerScroll(event: ScrollEvent): void {
        const c = this.controls;
        if (c != null) c.pointerScroll(event);
    }

    /// Sets `pointer` (NDC) and aims the raycaster through it. World
    /// matrices are refreshed first: pointer events can arrive before the
    /// next render has updated them.
    setPointer(event: PointerEvent): void {
        const w = this.width > 0 ? this.width : 1, h = this.height > 0 ? this.height : 1;
        this.pointer.set(<f64>event.position.x / w * 2 - 1, -(<f64>event.position.y / h * 2 - 1));
        this.scene.updateMatrixWorld();
        this.raycaster.setFromCamera(this.pointer, this.camera);
    }

    /// The nearest interactive ArtboardTexture hit by the raycaster (its hit
    /// uv in hitUv), or null.
    private artboardUnderPointer(): ArtboardTexture? {
        if (!this.forwardToArtboards) return null;
        const hits = this.raycaster.intersectObject(this.scene, true);
        for (let i = 0; i < hits.length; i++) {
            const hit = hits[i];
            if (!visible(hit.object)) continue;
            const uv = hit.uv;
            const material = materialOf(hit);
            if (material == null || uv == null) return null;   // something opaque in front
            material.fillUniforms(this.uniforms);
            const map = this.uniforms.textures[SLOT_MAP];
            if (map != null && map instanceof ArtboardTexture && (map as ArtboardTexture).interactive) {
                const t = map as ArtboardTexture;
                // The map's offset and repeat, as the shader applies them.
                this.hitUv.set(uv.x * t.repeat.x + t.offset.x, uv.y * t.repeat.y + t.offset.y);
                return t;
            }
            return null;
        }
        return null;
    }
}

function visible(o: Object3D): bool {
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
