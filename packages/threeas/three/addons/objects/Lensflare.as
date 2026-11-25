// three.js examples/jsm/objects/Lensflare.js (r170): lens flares for a
// light. Add a Lensflare to a light (or any object) and LensflareElements
// to it; each render, after the pass, it copies the 16 x 16 pixels at the
// flare's screen position (copyFramebufferToTexture), draws a magenta quad
// there at the flare's depth (depth tested), copies the result as the
// occlusion map, puts the pixels back, then draws each element along the
// line through the screen centre, faded by how much magenta survived. No
// pixels are read back: the occlusion stays on the GPU.
//
//     const lensflare = new Lensflare();
//     lensflare.addElement(new LensflareElement(texture0, 700, 0, light.color));
//     lensflare.addElement(new LensflareElement(texture3, 60, 0.6));
//     light.add(lensflare);
//
// Differences from three.js (see docs/DEVIATIONS.md): the work happens in
// onAfterRender, after the render's pass (three.js: onBeforeRender at its
// own draw, last thanks to renderOrder Infinity), drawing through
// renderBufferDirect (one pass per draw); LensflareElement's colour is a
// Color (three.js's default argument is white); the shaders are WGSL in
// three/shaders/objects/lensflare*.wgsl.

import { Mesh } from "../../objects/Mesh";
import { Object3D } from "../../core/Object3D";
import { BufferGeometry, GeometryGroup } from "../../core/BufferGeometry";
import { InterleavedBuffer, InterleavedBufferAttribute } from "../../core/InterleavedBuffer";
import { Camera } from "../../cameras/Camera";
import { Material } from "../../materials/Material";
import { MeshBasicMaterial } from "../../materials/MeshBasicMaterial";
import { RawShaderMaterial, UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Box2 } from "../../math/Box2";
import { Color } from "../../math/Color";
import { Vector2 } from "../../math/Vector2";
import { Vector3 } from "../../math/Vector3";
import { Vector4 } from "../../math/Vector4";
import { Texture } from "../../textures/Texture";
import { FramebufferTexture } from "../../textures/FramebufferTexture";
import { GPURenderer } from "../../renderers/GPURenderer";
import { ShaderDefinition, emptyTexture } from "../shaders/PostShaders";
import { AdditiveBlending, UnsignedByteType } from "../../constants";

/// One flare: a texture drawn `size` pixels tall at `distance` along the
/// line from the light (0) through the screen centre (1 is mirrored).
export class LensflareElement {
    texture: Texture;
    size: f64;
    distance: f64;
    color: Color;

    constructor(texture: Texture, size: f64 = 1, distance: f64 = 0, color: Color? = null) {
        this.texture = texture;
        this.size = size;
        this.distance = distance;
        this.color = color != null ? color! : new Color(0xffffff);
    }

    static Shader: ShaderDefinition = new LensflareElementShaderDefinition();
}

class LensflareElementShaderDefinition extends ShaderDefinition {
    constructor() { super("LensflareElementShader", "three/shaders/objects/lensflare"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("map", new Uniform<Texture>(emptyTexture()));
        m.set("occlusionMap", new Uniform<Texture>(emptyTexture()));
        m.set("color", new Uniform<Color>(new Color(0xffffff)));
        m.set("scale", new Uniform<Vector2>(new Vector2()));
        m.set("screenPosition", new Uniform<Vector3>(new Vector3()));
        return m;
    }
}

function makeGeometry(): BufferGeometry {
    const geometry = new BufferGeometry();
    const float32Array = new Float32Array(20);
    const values: StaticArray<f32> = [
        -1, -1, 0, 0, 0,
        1, -1, 0, 1, 0,
        1, 1, 0, 1, 1,
        -1, 1, 0, 0, 1,
    ];
    for (let i = 0; i < 20; i++) float32Array[i] = values[i];
    const interleavedBuffer = new InterleavedBuffer(float32Array, 5);
    geometry.setIndex([0, 1, 2, 0, 2, 3]);
    geometry.setAttribute("position", new InterleavedBufferAttribute(interleavedBuffer, 3, 0, false));
    geometry.setAttribute("uv", new InterleavedBufferAttribute(interleavedBuffer, 2, 3, false));
    return geometry;
}

export class Lensflare extends Mesh {
    readonly isLensflare: bool = true;

    private positionScreen: Vector3 = new Vector3();
    private positionView: Vector3 = new Vector3();
    // textures
    private tempMap: FramebufferTexture = new FramebufferTexture(16, 16);
    private occlusionMap: FramebufferTexture = new FramebufferTexture(16, 16);
    private currentType: i32 = UnsignedByteType;
    // materials
    private material1a: RawShaderMaterial;
    private material1b: RawShaderMaterial;
    private elementMaterials: Array<RawShaderMaterial> = [];
    // the following object is used for occlusionMap generation
    private mesh1: Mesh;
    private mesh2: Mesh;
    private elements: Array<LensflareElement> = [];

    private scale2: Vector2 = new Vector2();
    private screenPositionPixels: Vector2 = new Vector2();
    private validArea: Box2 = new Box2();
    private viewport: Vector4 = new Vector4();

    static Geometry: BufferGeometry = makeGeometry();

    constructor() {
        super(Lensflare.Geometry, new MeshBasicMaterial({ opacity: 0, transparent: true }));
        this.type = "Lensflare";
        this.frustumCulled = false;
        this.renderOrder = 0x3fffffff; // three.js: Infinity

        const geometry = Lensflare.Geometry;

        const material1a = new RawShaderMaterial({
            shader: "three/shaders/objects/lensflare_occlusion",
            depthTest: true, depthWrite: false, transparent: false,
        });
        material1a.uniforms.set("scale", new Uniform<Vector2>(new Vector2()));
        material1a.uniforms.set("screenPosition", new Uniform<Vector3>(new Vector3()));
        this.material1a = material1a;

        const material1b = new RawShaderMaterial({
            shader: "three/shaders/objects/lensflare_copy",
            depthTest: false, depthWrite: false, transparent: false,
        });
        material1b.uniforms.set("map", new Uniform<Texture>(this.tempMap));
        material1b.uniforms.set("scale", new Uniform<Vector2>(new Vector2()));
        material1b.uniforms.set("screenPosition", new Uniform<Vector3>(new Vector3()));
        this.material1b = material1b;

        this.mesh1 = new Mesh(geometry, material1a);
        this.mesh1.frustumCulled = false;

        this.mesh2 = new Mesh(geometry, material1a);
        this.mesh2.frustumCulled = false;
    }

    private makeElementMaterial(element: LensflareElement): RawShaderMaterial {
        const shader = LensflareElement.Shader;
        const m = new RawShaderMaterial({
            shader: shader.shader, vertexEntryPoint: shader.vertexEntryPoint,
            fragmentEntryPoint: shader.fragmentEntryPoint,
            blending: AdditiveBlending, transparent: true, depthWrite: false,
        });
        m.name = shader.name;
        m.uniforms = shader.uniforms();
        m.uniform<Texture>("occlusionMap").value = this.occlusionMap;
        m.uniform<Texture>("map").value = element.texture;
        return m;
    }

    addElement(element: LensflareElement): void {
        this.elements.push(element);
        this.elementMaterials.push(this.makeElementMaterial(element));
    }

    /// The flare's occlusion test and elements, over what the render drew
    /// (the renderer calls it after the pass).
    override onAfterRender(renderer: GPURenderer, scene: Object3D, camera: Camera, geometry: BufferGeometry?,
                           material: Material?, group: GeometryGroup?): void {
        const viewport = this.viewport;
        renderer.getCurrentViewport(viewport);

        const renderTarget = renderer.getRenderTarget();
        const type = renderTarget != null ? renderTarget.type : UnsignedByteType;

        if (this.currentType != type) {
            // The copies take the target's format: new textures.
            this.tempMap.dispose();
            this.occlusionMap.dispose();
            this.tempMap = new FramebufferTexture(16, 16);
            this.occlusionMap = new FramebufferTexture(16, 16);
            this.material1b.uniform<Texture>("map").value = this.tempMap;
            for (let i = 0; i < this.elementMaterials.length; i++) {
                this.elementMaterials[i].uniform<Texture>("occlusionMap").value = this.occlusionMap;
            }
            this.currentType = type;
        }

        const invAspect = viewport.w / viewport.z;
        const halfViewportWidth = viewport.z / 2.0;
        const halfViewportHeight = viewport.w / 2.0;

        let size = 16 / viewport.w;
        const scale = this.scale2;
        scale.set(size * invAspect, size);

        const validArea = this.validArea;
        validArea.min.set(viewport.x, viewport.y);
        validArea.max.set(viewport.x + (viewport.z - 16), viewport.y + (viewport.w - 16));

        // calculate position in screen space
        const positionView = this.positionView;
        const positionScreen = this.positionScreen;
        positionView.setFromMatrixPosition(this.matrixWorld);
        positionView.applyMatrix4(camera.matrixWorldInverse);

        if (positionView.z > 0) return; // lensflare is behind the camera

        positionScreen.copy(positionView).applyMatrix4(camera.projectionMatrix);

        // horizontal and vertical coordinate of the lower left corner of the pixels to copy
        const screenPositionPixels = this.screenPositionPixels;
        screenPositionPixels.x = viewport.x + (positionScreen.x * halfViewportWidth) + halfViewportWidth - 8;
        screenPositionPixels.y = viewport.y + (positionScreen.y * halfViewportHeight) + halfViewportHeight - 8;

        // screen cull
        if (!validArea.containsPoint(screenPositionPixels)) return;

        // copy whole pixels (three.js's copy truncates the position)
        screenPositionPixels.x = Math.floor(screenPositionPixels.x);
        screenPositionPixels.y = Math.floor(screenPositionPixels.y);

        // save current RGB to temp texture
        renderer.copyFramebufferToTexture(this.tempMap, screenPositionPixels);

        // render pink quad
        this.material1a.uniform<Vector2>("scale").value.copy(scale);
        this.material1a.uniform<Vector3>("screenPosition").value.copy(positionScreen);
        renderer.renderBufferDirect(camera, null, Lensflare.Geometry, this.material1a, this.mesh1, null);

        // copy result to occlusionMap
        renderer.copyFramebufferToTexture(this.occlusionMap, screenPositionPixels);

        // restore graphics
        this.material1b.uniform<Vector2>("scale").value.copy(scale);
        this.material1b.uniform<Vector3>("screenPosition").value.copy(positionScreen);
        renderer.renderBufferDirect(camera, null, Lensflare.Geometry, this.material1b, this.mesh1, null);

        // render elements (each element owns its material so group 2 stays cached)
        const vecX = -positionScreen.x * 2;
        const vecY = -positionScreen.y * 2;
        for (let i = 0, l = this.elements.length; i < l; i++) {
            const element = this.elements[i];
            const m = this.elementMaterials[i];
            m.uniform<Color>("color").value.copy(element.color);
            m.uniform<Texture>("map").value = element.texture;
            const sp = m.uniform<Vector3>("screenPosition").value;
            sp.x = positionScreen.x + vecX * element.distance;
            sp.y = positionScreen.y + vecY * element.distance;
            size = element.size / viewport.w;
            m.uniform<Vector2>("scale").value.set(size * invAspect, size);
            renderer.renderBufferDirect(camera, null, Lensflare.Geometry, m, this.mesh2, null);
        }
    }

    dispose(): void {
        this.material.dispose();
        this.material1a.dispose();
        this.material1b.dispose();
        for (let i = 0; i < this.elementMaterials.length; i++) this.elementMaterials[i].dispose();
        this.elementMaterials.length = 0;
        this.tempMap.dispose();
        this.occlusionMap.dispose();
        for (let i = 0, l = this.elements.length; i < l; i++) this.elements[i].texture.dispose();
        this.elements.length = 0;
    }
}
