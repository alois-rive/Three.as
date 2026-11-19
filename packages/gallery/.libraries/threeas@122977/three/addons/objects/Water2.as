// three.js examples/jsm/objects/Water2.js (r170): water from a Reflector and
// a Refractor sharing its geometry, two normal maps scrolled along a flow
// direction or a flow map, and a Fresnel mix of the two (Alex Vlachos,
// "Water Flow in Portal 2"). Import it under another name when Water.js's
// Water is imported too:
//
//     import { Water as Water2, Water2Options } from "lib:threeas/three/addons/objects/Water2";
//     const water = new Water2(new PlaneGeometry(20, 20), {
//         color: 0xffffff, scale: 4, flowDirection: new Vector2(1, 1),
//         normalMap0: n0, normalMap1: n1, textureWidth: 1024, textureHeight: 1024,
//     });
//     // each frame (three.js's Clock reads the wall clock):
//     water.tick(seconds);
//
// Differences from three.js (see docs/DEVIATIONS.md): typed Water2Options
// (`color` a hex number); without normalMap0 / normalMap1 the maps are
// flat (three.js loads textures/water/Water_*_M_Normal.jpg by URL); the
// flow advances by `tick(seconds)`; USE_FLOWMAP picks the shader's
// fragment entry point, and `flowDirection` and `tFlowMap` are both
// uniforms; the shader's textures start with the normal maps (their
// repeating sampler is the one it has); onBeforeRender is called before
// the render's pass.

import { Mesh } from "../../objects/Mesh";
import { Object3D } from "../../core/Object3D";
import { BufferGeometry, GeometryGroup } from "../../core/BufferGeometry";
import { Camera } from "../../cameras/Camera";
import { Clock } from "../../core/Clock";
import { Material } from "../../materials/Material";
import { ShaderMaterial, UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Color } from "../../math/Color";
import { Matrix4 } from "../../math/Matrix4";
import { Vector2 } from "../../math/Vector2";
import { Vector4 } from "../../math/Vector4";
import { Texture } from "../../textures/Texture";
import { DataTexture } from "../../textures/DataTexture";
import { GPURenderer } from "../../renderers/GPURenderer";
import { ShaderDefinition, emptyTexture } from "../shaders/PostShaders";
import { Reflector } from "./Reflector";
import { Refractor } from "./Refractor";
import { RepeatWrapping } from "../../constants";

/// Water2's options (three.js's options object).
export class Water2Options {
    color: u32 = 0xFFFFFF;
    textureWidth: i32 = 512;
    textureHeight: i32 = 512;
    clipBias: f64 = 0;
    /// The flow without a flow map.
    flowDirection: Vector2 = new Vector2(1, 0);
    /// How fast the normal maps move (uv per second).
    flowSpeed: f64 = 0.03;
    reflectivity: f64 = 0.02;
    /// Repeats of the normal maps over the geometry's uv.
    scale: f64 = 1;
    /// The shader (null: Water.WaterShader).
    shader: ShaderDefinition? = null;
    /// The flow per texel (rg, 0.5 still), or null for flowDirection.
    flowMap: Texture? = null;
    /// The two normal maps (null: flat).
    normalMap0: Texture? = null;
    normalMap1: Texture? = null;
}

class WaterShaderDefinition extends ShaderDefinition {
    constructor() { super("WaterShader", "three/shaders/objects/water2"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("color", new Uniform<Color>(new Color(0xFFFFFF)));
        m.set("reflectivity", new Uniform<f64>(0));
        m.set("textureMatrix", new Uniform<Matrix4>(new Matrix4()));
        m.set("config", new Uniform<Vector4>(new Vector4()));
        m.set("flowDirection", new Uniform<Vector2>(new Vector2(1, 0)));
        m.set("tNormalMap0", new Uniform<Texture>(emptyTexture()));
        m.set("tNormalMap1", new Uniform<Texture>(emptyTexture()));
        m.set("tReflectionMap", new Uniform<Texture>(emptyTexture()));
        m.set("tRefractionMap", new Uniform<Texture>(emptyTexture()));
        m.set("tFlowMap", new Uniform<Texture>(emptyTexture()));
        return m;
    }
}

/// A flat normal map (one texel).
function flatNormals(): Texture {
    const data = new Uint8Array(4);
    data[0] = 128; data[1] = 128; data[2] = 255; data[3] = 255;
    const t = new DataTexture(data, 1, 1);
    t.needsUpdate = true;
    return t;
}

export class Water extends Mesh {
    readonly isWater: bool = true;
    /// The flow's time source (tick it with the seconds of each advance).
    readonly clock: Clock = new Clock();
    private reflector: Reflector;
    private refractor: Refractor;
    private textureMatrix: Matrix4 = new Matrix4();
    private flowSpeed: f64;
    private cycle: f64 = 0.15; // a cycle of a flow map phase
    private halfCycle: f64 = 0.075;

    static WaterShader: ShaderDefinition = new WaterShaderDefinition();

    constructor(geometry: BufferGeometry, options: Water2Options? = null) {
        super(geometry);
        this.type = "Water";
        const o = options != null ? options! : new Water2Options();
        const color = new Color(<f64>o.color);
        const shader = o.shader != null ? o.shader! : Water.WaterShader;
        this.flowSpeed = o.flowSpeed;
        const flowMap = o.flowMap;
        const normalMap0 = o.normalMap0 != null ? o.normalMap0! : flatNormals();
        const normalMap1 = o.normalMap1 != null ? o.normalMap1! : flatNormals();

        // internal components
        this.reflector = new Reflector(geometry, {
            textureWidth: o.textureWidth, textureHeight: o.textureHeight, clipBias: o.clipBias,
        });
        this.refractor = new Refractor(geometry, {
            textureWidth: o.textureWidth, textureHeight: o.textureHeight, clipBias: o.clipBias,
        });
        this.reflector.matrixAutoUpdate = false;
        this.refractor.matrixAutoUpdate = false;

        // material
        const material = new ShaderMaterial({
            shader: shader.shader, vertexEntryPoint: shader.vertexEntryPoint,
            fragmentEntryPoint: flowMap != null ? "fs_flowmap" : shader.fragmentEntryPoint,
            transparent: true, fog: true,
        });
        material.name = shader.name;
        material.uniforms = shader.uniforms();
        if (flowMap != null) material.uniform<Texture>("tFlowMap").value = flowMap!;
        else material.uniform<Vector2>("flowDirection").value = o.flowDirection;

        // maps
        normalMap0.wrapS = normalMap0.wrapT = RepeatWrapping;
        normalMap1.wrapS = normalMap1.wrapT = RepeatWrapping;

        material.uniform<Texture>("tReflectionMap").value = this.reflector.getRenderTarget().texture;
        material.uniform<Texture>("tRefractionMap").value = this.refractor.getRenderTarget().texture;
        material.uniform<Texture>("tNormalMap0").value = normalMap0;
        material.uniform<Texture>("tNormalMap1").value = normalMap1;

        // water
        material.uniform<Color>("color").value = color;
        material.uniform<f64>("reflectivity").value = o.reflectivity;
        material.uniform<Matrix4>("textureMatrix").value = this.textureMatrix;

        // inital values
        const config = material.uniform<Vector4>("config").value;
        config.x = 0; // flowMapOffset0
        config.y = this.halfCycle; // flowMapOffset1
        config.z = this.halfCycle; // halfCycle
        config.w = o.scale; // scale
        this.material = material;
    }

    /// The material, typed (three.js's `water.material`).
    get shaderMaterial(): ShaderMaterial { return this.material as ShaderMaterial; }

    /// Advances the flow's clock (Rive-only: call from advance).
    tick(seconds: f64): void {
        this.clock.tick(seconds);
    }

    private updateTextureMatrix(camera: Camera): void {
        const textureMatrix = this.textureMatrix;
        textureMatrix.set(
            0.5, 0.0, 0.0, 0.5,
            0.0, 0.5, 0.0, 0.5,
            0.0, 0.0, 0.5, 0.5,
            0.0, 0.0, 0.0, 1.0
        );
        textureMatrix.multiply(camera.projectionMatrix);
        textureMatrix.multiply(camera.matrixWorldInverse);
        textureMatrix.multiply(this.matrixWorld);
    }

    private updateFlow(): void {
        const delta = this.clock.getDelta();
        const config = (this.material as ShaderMaterial).uniform<Vector4>("config").value;

        config.x += this.flowSpeed * delta; // flowMapOffset0
        config.y = config.x + this.halfCycle; // flowMapOffset1

        // Important: The distance between offsets should be always the value of "halfCycle".
        // Moreover, both offsets should be in the range of [ 0, cycle ].
        // This approach ensures a smooth water flow and avoids "reset" effects.
        if (config.x >= this.cycle) {
            config.x = 0;
            config.y = this.halfCycle;
        } else if (config.y >= this.cycle) {
            config.y = config.y - this.cycle;
        }
    }

    /// Renders the reflection and the refraction (the renderer calls it
    /// before the pass).
    override onBeforeRender(renderer: GPURenderer, scene: Object3D, camera: Camera, geometry: BufferGeometry?,
                            material: Material?, group: GeometryGroup?): void {
        this.updateTextureMatrix(camera);
        this.updateFlow();

        this.visible = false;

        this.reflector.matrixWorld.copy(this.matrixWorld);
        this.refractor.matrixWorld.copy(this.matrixWorld);

        this.reflector.onBeforeRender(renderer, scene, camera, null, null, null);
        this.refractor.onBeforeRender(renderer, scene, camera, null, null, null);

        this.visible = true;
    }
}
