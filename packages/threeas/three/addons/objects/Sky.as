// three.js examples/jsm/objects/Sky.js (r170): an analytic daylight sky,
// the Preetham model ("A Practical Analytic Model for Daylight"), first
// implemented by Simon Wallner, improved by Martin Upitis, brought to
// three.js by zz85. A unit box drawn from inside at the far plane: scale it
// past the scene (`sky.scale.setScalar(10000)`) and set the uniforms.
//
//     const sky = new Sky();
//     sky.scale.setScalar(10000);
//     scene.add(sky);
//     sky.shaderMaterial.uniform<Vector3>("sunPosition").value.setFromSphericalCoords(1, phi, theta);
//
// For environment lighting, as three.js's ocean example, render it into a
// PMREM: `scene.environment = pmrem.fromScene(skyScene).texture` (here
// fromScene renders at the start of the renderer's next render, so keep
// the sky in `skyScene` until then; give that scene a Sky of its own).
//
// Differences from three.js (see docs/DEVIATIONS.md): the material is a
// ShaderMaterial over three/shaders/objects/sky.wgsl, reached as
// `sky.shaderMaterial` (or `material as ShaderMaterial`); Sky.SkyShader is
// a ShaderDefinition.

import { Mesh } from "../../objects/Mesh";
import { BoxGeometry } from "../../geometries/BoxGeometry";
import { ShaderMaterial, UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Vector3 } from "../../math/Vector3";
import { ShaderDefinition } from "../shaders/PostShaders";
import { BackSide } from "../../constants";

class SkyShaderDefinition extends ShaderDefinition {
    constructor() { super("SkyShader", "three/shaders/objects/sky"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("turbidity", new Uniform<f64>(2));
        m.set("rayleigh", new Uniform<f64>(1));
        m.set("mieCoefficient", new Uniform<f64>(0.005));
        m.set("mieDirectionalG", new Uniform<f64>(0.8));
        m.set("sunPosition", new Uniform<Vector3>(new Vector3()));
        m.set("up", new Uniform<Vector3>(new Vector3(0, 1, 0)));
        return m;
    }
}

export class Sky extends Mesh {
    readonly isSky: bool = true;

    static SkyShader: ShaderDefinition = new SkyShaderDefinition();

    constructor() {
        const shader = Sky.SkyShader;
        const material = new ShaderMaterial({
            shader: shader.shader, vertexEntryPoint: shader.vertexEntryPoint,
            fragmentEntryPoint: shader.fragmentEntryPoint, side: BackSide, depthWrite: false,
        });
        material.name = shader.name;
        material.uniforms = shader.uniforms();
        super(new BoxGeometry(1, 1, 1), material);
    }

    /// The material, typed (three.js's `sky.material`).
    get shaderMaterial(): ShaderMaterial { return this.material as ShaderMaterial; }

    /// Disposes the box geometry and sky shader material.
    dispose(): void {
        this.geometry.dispose();
        this.material.dispose();
    }
}
