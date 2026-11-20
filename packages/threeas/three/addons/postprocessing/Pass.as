// three.js examples/jsm/postprocessing/Pass.js: the base pass and the
// fullscreen quad passes draw with.

import { GPURenderer } from "../../renderers/GPURenderer";
import { RenderTarget } from "../../renderers/RenderTarget";
import { ShaderMaterial } from "../../materials/ShaderMaterial";
import { Material } from "../../materials/Material";
import { Mesh } from "../../objects/Mesh";
import { Scene } from "../../scenes/Scene";
import { OrthographicCamera } from "../../cameras/OrthographicCamera";
import { PlaneGeometry } from "../../geometries/PlaneGeometry";

export abstract class Pass {
    readonly isPass: bool = true;
    /// Whether the composer runs it.
    enabled: bool = true;
    /// Whether the composer swaps read and write buffers after it.
    needsSwap: bool = true;
    /// Whether it clears before rendering.
    clear: bool = false;
    /// Set by the composer on the last enabled pass: render to the screen.
    renderToScreen: bool = false;

    setSize(width: f64, height: f64): void {}

    /// Renders from `readBuffer` into `writeBuffer` (or the screen when
    /// `renderToScreen`).
    abstract render(renderer: GPURenderer, writeBuffer: RenderTarget, readBuffer: RenderTarget, deltaTime: f64,
        maskActive: bool): void;

    dispose(): void {}
}

const _camera = new OrthographicCamera(-1, 1, 1, -1, 0, 1);
const _geometry = new PlaneGeometry(2, 2);

/// A fullscreen triangle pair drawn with `material` (three.js's
/// FullScreenQuad). Post shaders (three/shaders/post) place its vertices
/// themselves; the camera is unused.
export class FullScreenQuad {
    private mesh: Mesh;
    private scene: Scene = new Scene();

    constructor(material: Material? = null) {
        this.mesh = new Mesh(_geometry, material != null ? material! : new ShaderMaterial());
        this.mesh.frustumCulled = false;
        this.scene.add(this.mesh);
    }

    get material(): Material { return this.mesh.material; }
    set material(value: Material) { this.mesh.material = value; }

    render(renderer: GPURenderer): void {
        renderer.render(this.scene, _camera);
    }

    /// Disposes the quad's geometry, as three.js (shared by every quad: it
    /// is uploaded again when one draws next) and lets its mesh go (the
    /// renderer's sweep frees its draw state). The material is the
    /// caller's, as three.js.
    dispose(): void {
        this.mesh.geometry.dispose();
        this.scene.remove(this.mesh);
    }
}
