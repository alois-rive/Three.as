// three.js examples/jsm/shaders/GTAOShader.js: GTAOShader, GTAODepthShader,
// GTAOBlendShader (ShaderDefinitions over three/shaders/post/gtao*.wgsl) and
// generateMagicSquareNoise. The defines are uniforms: SAMPLES `samples`,
// PERSPECTIVE_CAMERA `perspective`, NORMAL_VECTOR_TYPE `normalVectorType`,
// SCREEN_SPACE_RADIUS `screenSpaceRadius`, SCENE_CLIP_BOX `sceneClipBox`
// (1 or 0). Depth always comes from a DepthTexture (DEPTH_SWIZZLING "x").

import { UniformBase, Uniform } from "../../materials/ShaderMaterial";
import { Texture } from "../../textures/Texture";
import { DataTexture } from "../../textures/DataTexture";
import { Vector2 } from "../../math/Vector2";
import { Vector3 } from "../../math/Vector3";
import { Matrix4 } from "../../math/Matrix4";
import { RepeatWrapping } from "../../constants";
import { ShaderDefinition, emptyTexture } from "./PostShaders";

class GTAOShaderDefinition extends ShaderDefinition {
    constructor() { super("GTAOShader", "three/shaders/post/gtao"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("cameraProjectionMatrix", new Uniform<Matrix4>(new Matrix4()));
        m.set("cameraProjectionMatrixInverse", new Uniform<Matrix4>(new Matrix4()));
        m.set("cameraWorldMatrix", new Uniform<Matrix4>(new Matrix4()));
        m.set("sceneBoxMin", new Uniform<Vector3>(new Vector3(-1, -1, -1)));
        m.set("radius", new Uniform<f64>(0.25));
        m.set("sceneBoxMax", new Uniform<Vector3>(new Vector3(1, 1, 1)));
        m.set("distanceExponent", new Uniform<f64>(1));
        m.set("resolution", new Uniform<Vector2>(new Vector2()));
        m.set("cameraNear", new Uniform<f64>(0.1));
        m.set("cameraFar", new Uniform<f64>(2000));
        m.set("thickness", new Uniform<f64>(1));
        m.set("distanceFallOff", new Uniform<f64>(1));
        m.set("scale", new Uniform<f64>(1));
        m.set("samples", new Uniform<f64>(16));
        m.set("perspective", new Uniform<f64>(1));
        m.set("normalVectorType", new Uniform<f64>(1));
        m.set("screenSpaceRadius", new Uniform<f64>(0));
        m.set("sceneClipBox", new Uniform<f64>(0));
        m.set("tNormal", new Uniform<Texture>(emptyTexture()));
        m.set("tDepth", new Uniform<Texture>(emptyTexture()));
        m.set("tNoise", new Uniform<Texture>(emptyTexture()));
        return m;
    }
}

class GTAODepthShaderDefinition extends ShaderDefinition {
    constructor() { super("GTAODepthShader", "three/shaders/post/gtao_depth"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("cameraNear", new Uniform<f64>(0.1));
        m.set("cameraFar", new Uniform<f64>(2000));
        m.set("perspective", new Uniform<f64>(1));
        // Pairs with the group's sampler (not in three.js).
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        m.set("tDepth", new Uniform<Texture>(emptyTexture()));
        return m;
    }
}

class GTAOBlendShaderDefinition extends ShaderDefinition {
    constructor() { super("GTAOBlendShader", "three/shaders/post/gtao_blend"); }
    override uniforms(): Map<string, UniformBase> {
        const m = new Map<string, UniformBase>();
        m.set("intensity", new Uniform<f64>(1));
        m.set("tDiffuse", new Uniform<Texture>(emptyTexture()));
        return m;
    }
}

export const GTAOShader: ShaderDefinition = new GTAOShaderDefinition();
export const GTAODepthShader: ShaderDefinition = new GTAODepthShaderDefinition();
export const GTAOBlendShader: ShaderDefinition = new GTAOBlendShaderDefinition();

/// three.js's generateMagicSquare: an odd order magic square (1 to
/// size x size), rows first.
export function generateMagicSquare(size: i32): Array<i32> {
    const noiseSize = size % 2 == 0 ? size + 1 : size;
    const noiseSquareSize = noiseSize * noiseSize;
    const magicSquare = new Array<i32>(noiseSquareSize);
    for (let k = 0; k < noiseSquareSize; k++) magicSquare[k] = 0;
    let i = noiseSize / 2;
    let j = noiseSize - 1;
    for (let num = 1; num <= noiseSquareSize;) {
        if (i == -1 && j == noiseSize) {
            j = noiseSize - 2;
            i = 0;
        } else {
            if (j == noiseSize) j = 0;
            if (i < 0) i = noiseSize - 1;
        }
        if (magicSquare[i * noiseSize + j] != 0) {
            j -= 2;
            i++;
            continue;
        } else {
            magicSquare[i * noiseSize + j] = num++;
        }
        j++;
        i--;
    }
    return magicSquare;
}

/// three.js's generateMagicSquareNoise: rotation vectors at magic square
/// angles in an RGBA8 DataTexture (size rounded up to odd), repeating.
export function generateMagicSquareNoise(size: i32 = 5): DataTexture {
    const noiseSize = size % 2 == 0 ? size + 1 : size;
    const magicSquare = generateMagicSquare(noiseSize);
    const noiseSquareSize = magicSquare.length;
    const data = new Uint8Array(noiseSquareSize * 4);
    const v = new Vector3();
    for (let inx = 0; inx < noiseSquareSize; ++inx) {
        const iAng = magicSquare[inx];
        const angle = (2 * Math.PI * <f64>iAng) / <f64>noiseSquareSize;
        v.set(Math.cos(angle), Math.sin(angle), 0).normalize();
        data[inx * 4] = <u8>((v.x * 0.5 + 0.5) * 255);
        data[inx * 4 + 1] = <u8>((v.y * 0.5 + 0.5) * 255);
        data[inx * 4 + 2] = 127;
        data[inx * 4 + 3] = 255;
    }
    const noiseTexture = new DataTexture(data, <u32>noiseSize, <u32>noiseSize);
    noiseTexture.wrapS = RepeatWrapping;
    noiseTexture.wrapT = RepeatWrapping;
    noiseTexture.needsUpdate = true;
    return noiseTexture;
}
