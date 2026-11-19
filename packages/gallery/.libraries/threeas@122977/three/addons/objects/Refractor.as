// three.js examples/jsm/objects/Refractor.js (r170): planar refraction.
// Each render, before the pass, onBeforeRender renders the scene behind
// the refractor's plane (its local XY plane, facing +Z) from the camera,
// clipped by an oblique near plane on it, into a HalfFloatType render
// target that the RefractorShader projects through `textureMatrix`: a
// distortion-free window, tinted, for shaders (Water2) to bend.
//
//     const pane = new Refractor(new PlaneGeometry(2, 2), { color: 0x999999 });
//     scene.add(pane);
//
// Differences from three.js (see docs/DEVIATIONS.md): the options are a
// typed RefractorOptions (`color` a hex number, `shader` a
// ShaderDefinition over a WGSL asset); onBeforeRender is a method the
// renderer calls before the render's pass; the oblique clipping writes
// WebGPU's [0, 1] depth; `updateMatrices` is the camera and matrix half of
// onBeforeRender (Rive-only, for tests).

import { Mesh } from "../../objects/Mesh";
import { Object3D } from "../../core/Object3D";
import { BufferGeometry, GeometryGroup } from "../../core/BufferGeometry";
import { Camera } from "../../cameras/Camera";
import { PerspectiveCamera } from "../../cameras/PerspectiveCamera";
import { Material } from "../../materials/Material";
import { ShaderMaterial, UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Color } from "../../math/Color";
import { Matrix4 } from "../../math/Matrix4";
import { Plane } from "../../math/Plane";
import { Quaternion } from "../../math/Quaternion";
import { Vector3 } from "../../math/Vector3";
import { Vector4 } from "../../math/Vector4";
import { Texture } from "../../textures/Texture";
import { RenderTarget } from "../../renderers/RenderTarget";
import { GPURenderer } from "../../renderers/GPURenderer";
import { ShaderDefinition, emptyTexture } from "../shaders/PostShaders";
import { obliqueClip, cameraFar } from "./Reflector";
import { HalfFloatType } from "../../constants";
import { Dynamic } from "rive/dynamic";

/// Refractor's options (three.js's options object).
export class RefractorOptions {
    /// The tint (hex), blended with the refraction (overlay).
    color: u32 = 0x7F7F7F;
    /// The render target's size in pixels (0: 512).
    textureWidth: i32 = 512;
    textureHeight: i32 = 512;
    clipBias: f64 = 0;
    /// The shader (null: Refractor.RefractorShader). Its uniforms must hold
    /// `color`, `tDiffuse` and `textureMatrix`.
    shader: ShaderDefinition? = null;
    /// MSAA samples of the render target (4; 0 or 1 for none).
    multisample: i32 = 4;
}

class RefractorShaderDefinition extends ShaderDefinition {
    constructor() { super("RefractorShader", "three/shaders/objects/refractor"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("color", new Uniform<Color>(new Color(0x7F7F7F)));
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        m.set("textureMatrix", new Uniform<Matrix4>(new Matrix4()));
        return m;
    }
}

export class Refractor extends Mesh {
    readonly isRefractor: bool = true;
    /// The camera the refraction renders from (the viewer's, clipped).
    camera: PerspectiveCamera = new PerspectiveCamera();
    /// Maps the refractor's local positions to the refraction's texture
    /// coordinates (the shader's `textureMatrix`).
    readonly textureMatrix: Matrix4 = new Matrix4();
    clipBias: f64;
    private renderTarget: RenderTarget;
    private refractorPlane: Plane = new Plane();

    private refractorWorldPosition: Vector3 = new Vector3();
    private cameraWorldPosition: Vector3 = new Vector3();
    private rotationMatrix: Matrix4 = new Matrix4();
    private view: Vector3 = new Vector3();
    private normal: Vector3 = new Vector3();
    private position2: Vector3 = new Vector3();
    private quaternion2: Quaternion = new Quaternion();
    private scale2: Vector3 = new Vector3();
    private clipPlane: Plane = new Plane();
    private clipVector: Vector4 = new Vector4();

    static RefractorShader: ShaderDefinition = new RefractorShaderDefinition();

    constructor(geometry: BufferGeometry, options: RefractorOptions? = null) {
        super(geometry);
        this.type = "Refractor";
        const o = options != null ? options! : new RefractorOptions();
        const color = new Color(<f64>o.color);
        const textureWidth = o.textureWidth > 0 ? o.textureWidth : 512;
        const textureHeight = o.textureHeight > 0 ? o.textureHeight : 512;
        this.clipBias = o.clipBias;
        const shader = o.shader != null ? o.shader! : Refractor.RefractorShader;

        const virtualCamera = this.camera;
        virtualCamera.matrixAutoUpdate = false;
        virtualCamera.userData.set("refractor", Dynamic.fromBool(true));

        // render target
        this.renderTarget = new RenderTarget(<u32>textureWidth, <u32>textureHeight,
            { samples: o.multisample, type: HalfFloatType });

        // material
        const material = new ShaderMaterial({
            shader: shader.shader, vertexEntryPoint: shader.vertexEntryPoint,
            fragmentEntryPoint: shader.fragmentEntryPoint,
            transparent: true, // ensures, refractors are drawn from farthest to closest
        });
        material.name = shader.name;
        material.uniforms = shader.uniforms();
        material.uniform<Color>("color").value = color;
        material.uniform<Texture>("tDiffuse").value = this.renderTarget.texture;
        material.uniform<Matrix4>("textureMatrix").value = this.textureMatrix;
        this.material = material;
    }

    private visibleFrom(camera: Camera): bool {
        this.refractorWorldPosition.setFromMatrixPosition(this.matrixWorld);
        this.cameraWorldPosition.setFromMatrixPosition(camera.matrixWorld);
        this.view.subVectors(this.refractorWorldPosition, this.cameraWorldPosition);
        this.rotationMatrix.extractRotation(this.matrixWorld);
        this.normal.set(0, 0, 1);
        this.normal.applyMatrix4(this.rotationMatrix);
        return this.view.dot(this.normal) < 0;
    }

    private updateRefractorPlane(): void {
        this.matrixWorld.decompose(this.position2, this.quaternion2, this.scale2);
        const normal = this.normal;
        normal.set(0, 0, 1).applyQuaternion(this.quaternion2).normalize();
        // flip the normal because we want to cull everything above the plane
        normal.negate();
        this.refractorPlane.setFromNormalAndCoplanarPoint(normal, this.position2);
    }

    private updateVirtualCamera(camera: Camera): void {
        const virtualCamera = this.camera;
        virtualCamera.matrixWorld.copy(camera.matrixWorld);
        virtualCamera.matrixWorldInverse.copy(virtualCamera.matrixWorld).invert();
        virtualCamera.projectionMatrix.copy(camera.projectionMatrix);
        virtualCamera.far = cameraFar(camera); // used in WebGLBackground

        // The following code creates an oblique view frustum for clipping.
        // see: Lengyel, Eric. "Oblique View Frustum Depth Projection and Clipping".
        // Journal of Game Development, Vol. 1, No. 2 (2005), Charles River Media, pp. 5-16
        const clipPlane = this.clipPlane;
        clipPlane.copy(this.refractorPlane);
        clipPlane.applyMatrix4(virtualCamera.matrixWorldInverse);
        this.clipVector.set(clipPlane.normal.x, clipPlane.normal.y, clipPlane.normal.z, clipPlane.constant);
        obliqueClip(virtualCamera.projectionMatrix, this.clipVector, this.clipBias);
    }

    // This will update the texture matrix that is used for projective texture mapping in the shader.
    // see: http://developer.download.nvidia.com/assets/gamedev/docs/projective_texture_mapping.pdf
    private updateTextureMatrix(camera: Camera): void {
        // this matrix does range mapping to [ 0, 1 ]
        const textureMatrix = this.textureMatrix;
        textureMatrix.set(
            0.5, 0.0, 0.0, 0.5,
            0.0, 0.5, 0.0, 0.5,
            0.0, 0.0, 0.5, 0.5,
            0.0, 0.0, 0.0, 1.0
        );
        // we use "Object Linear Texgen", so we need to multiply the texture matrix T
        // (matrix above) with the projection and view matrix of the virtual camera
        // and the model matrix of the refractor
        textureMatrix.multiply(camera.projectionMatrix);
        textureMatrix.multiply(camera.matrixWorldInverse);
        textureMatrix.multiply(this.matrixWorld);
    }

    /// The plane, texture matrix and clipped camera for `camera`: the first
    /// half of onBeforeRender (Rive-only). False when there is nothing to
    /// render (a refractor's own camera, or seen from behind).
    updateMatrices(camera: Camera): bool {
        // ensure refractors are rendered only once per frame
        if (Dynamic.truthy(camera.userData.get("refractor"))) return false;
        // avoid rendering when the refractor is viewed from behind
        if (!this.visibleFrom(camera)) return false;
        this.updateRefractorPlane();
        this.updateTextureMatrix(camera);
        this.updateVirtualCamera(camera);
        return true;
    }

    private renderRefraction(renderer: GPURenderer, scene: Object3D): void {
        this.visible = false;
        const currentRenderTarget = renderer.getRenderTarget();
        const currentShadowAutoUpdate = renderer.shadowMap.autoUpdate;
        renderer.shadowMap.autoUpdate = false; // avoid re-computing shadows
        renderer.setRenderTarget(this.renderTarget);
        if (renderer.autoClear == false) renderer.clear();
        renderer.render(scene, this.camera);
        renderer.shadowMap.autoUpdate = currentShadowAutoUpdate;
        renderer.setRenderTarget(currentRenderTarget);
        this.visible = true;
    }

    /// Renders the refraction (the renderer calls it before the pass).
    override onBeforeRender(renderer: GPURenderer, scene: Object3D, camera: Camera, geometry: BufferGeometry?,
                            material: Material?, group: GeometryGroup?): void {
        if (!this.updateMatrices(camera)) return;
        this.renderRefraction(renderer, scene);
    }

    getRenderTarget(): RenderTarget {
        return this.renderTarget;
    }

    dispose(): void {
        this.renderTarget.dispose();
        this.material.dispose();
    }
}
