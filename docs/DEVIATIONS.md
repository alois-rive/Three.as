# Deviations from three.js

ThreeAS keeps three.js's names, signatures and behaviour wherever
AnimaScript and Rive allow. This page lists every place it does not, so that
code, examples and fixes taken from three.js sources can be ported without
guessing. **When porting from three.js, read this first.** If you add a
deviation, add it here in the same change.

Status: Milestone 2 in progress (see [../PLAN.md](../PLAN.md)). Features not yet ported
are listed under [Not yet supported](#not-yet-supported); they are missing,
not different.

## Porting checklist

1. Import the namespace: `import * as THREE from "../three/Three";` (a
   relative path, not `"three"`).
2. Replace `new THREE.WebGLRenderer(params)` with
   `new THREE.GPURenderer(context, params)` in the script's `init`.
3. Replace the window: no `domElement` to append. `resize(width, height,
   scale)` calls `setPixelRatio(scale)`, `setSize(width, height)` and
   updates the camera's `aspect`.
4. Replace `requestAnimationFrame` / `setAnimationLoop` with `advance(seconds)`,
   and per-frame increments (`rotation.x += 0.01`) with per-second ones
   (`rotation.x += 0.6 * seconds`).
5. In `draw(renderer)`: `this.renderer.render(scene, camera)`, then
   `this.renderer.present(renderer)`.
6. Add types; turn parameter objects' colours into hex numbers; replace
   closures passed to `traverse` (see below).
7. Check light intensities if the source predates three.js r155 (see
   [Lighting](#lighting)).

```as
import * as THREE from "../three/Three";
import { Layout, Context } from "rive/host";
import { Renderer } from "rive/renderer";

export class Demo extends Layout {
    scene: THREE.Scene = new THREE.Scene();
    camera: THREE.PerspectiveCamera = new THREE.PerspectiveCamera(75, 1, 0.1, 1000);
    renderer: THREE.GPURenderer? = null;

    override init(context: Context): bool {
        this.renderer = new THREE.GPURenderer(context, { antialias: true });
        return true;
    }
    override resize(width: f64, height: f64, scale: f64): void {
        this.renderer!.setPixelRatio(scale);
        this.renderer!.setSize(width, height);
        this.camera.aspect = width / height;
        this.camera.updateProjectionMatrix();
    }
    override draw(renderer: Renderer): void {
        this.renderer!.render(this.scene, this.camera);
        this.renderer!.present(renderer);
    }
}
```

## Renderer

| three.js | ThreeAS |
|---|---|
| `WebGLRenderer` / `WebGPURenderer` | `GPURenderer(context, parameters?)`; it needs the script's Rive `Context` |
| `renderer.domElement` (an HTML canvas) | `renderer.domElement` is the Rive `GPUCanvas` (null before the first render) |
| `render()` anywhere | `render()` only inside the script's `draw()`; then `present(renderer)` composites the canvas into the artboard |
| `setSize(w, h, updateStyle)` | `setSize(w, h)` in points; there is no style |
| `setAnimationLoop(fn)` | the script's `advance(seconds)` (or ThreeLayout's `animate`) |
| `WebGLRendererParameters` | `GPURendererParameters`: `antialias` (4x MSAA), `alpha` (transparent clear) only |
| `outputColorSpace` | read-only, always sRGB |
| `toneMapping`, `toneMappingExposure` | as three.js (Linear, Reinhard, Cineon, ACESFilmic, AgX, Neutral); no CustomToneMapping |
| output | premultiplied alpha, composited with `srcOver` |
| custom vertex layouts | fixed slots: 0 position, 1 normal, 2 uv, 3 colour, 4 instance matrix (mat4), 5 instance colour (rgb), 6-7 skin index/weight |
| `info.render.calls/triangles/lines/points` | same, plus `info.render.culled` (objects frustum culled); `info.memory` is missing |

## Language (AnimaScript is typed and compiled)

- **No union types or overloads.** Where three.js takes "a number or a
  vector", ThreeAS uses a generic method that keeps the call shape:
  `lookAt(x, y, z)` and `lookAt(vector)` both work, as do
  `color.set(0xff0000)`, `color.set("#ff0000")` and `color.set(otherColor)`,
  and `renderer.setClearColor(...)` with the same three forms. Fields and
  constructors cannot be generic, so they take one type:
  - **Parameter objects are typed classes** (`MeshStandardMaterialParameters`
    ...), filled from an object literal. `{ color: 0xff8800, roughness: 0.4 }`
    works; `{ color: "orange" }` or `{ color: new Color() }` does not compile.
    A key that is not a field does not compile either. Set other forms
    afterwards: `material.color.set("orange")`.
  - **Light and Color constructors take a hex number.** `new Color(0xff0000)`
    or linear components `new Color(1, 0, 0)`; for a CSS string use
    `Color.fromStyle("#f00")` or `new Color().set("#f00")`.
  - Where three.js types a field as a union of classes, ThreeAS adds a
    small base class: `scene.background` is a `ColorOrTexture?` (assign a
    `Color` or a `Texture`, read back with `instanceof`), `scene.fog` a
    `FogBase?` (`Fog` or `FogExp2`).
  - **A mesh's material array is `mesh.materials`** (one per geometry
    group, by `materialIndex`); `mesh.material` stays a single material.
    `new Mesh(geometry, [a, b])` becomes
    `const m = new Mesh(geometry); m.materials = [a, b];`.
- **`Object3D.add` / `remove` take one object** (three.js is variadic): call
  them once per object.
- **No closures.** A function passed to `traverse`, `traverseVisible` or
  `traverseAncestors` cannot capture locals or `this`. Use a module-level
  function and module-level state, or loop over `children` yourself.
- **No `undefined`.** Lookups that return `undefined` in three.js return
  `null` (`getObjectByName`, `getAttribute`). Narrow through a local or use
  `!` where it cannot be null.
- **Numbers have sizes.** Public coordinates, angles and factors are `f64`;
  counts, indices and enum constants (`THREE.DoubleSide`,
  `THREE.RepeatWrapping`) are `i32`; colours are `u32`. Cast with `<f64>x`.
- **Integer division truncates**, unlike JavaScript: `i / segments` with two
  `i32`s is 0 for `i < segments`. Where three.js divides counters, cast an
  operand: `<f64>i / <f64>segments`. The reverse trap: a cast applies its
  type to the expression inside, so `<f64>(i / 4)` is a *float* division
  (1.25 for 5); to truncate, divide first into an `i32` local.
- **Down-casting** uses `instanceof` and `as`: `if (o instanceof THREE.Mesh)
  { const mesh = o as THREE.Mesh; }`. The `isMesh`-style flags exist too.
- **Arrays are invariant**: an `Array<Mesh>` is not an `Array<Object3D>`.
  Declare `Array<Object3D>` for what you pass to `intersectObjects` and cast
  elements back (`arr[i] as Mesh`).
- **No `userData`** (no untyped objects). Subclass, or keep a `Map` keyed by
  `object.id`.
- `uuid` and `MathUtils.generateUUID` are missing; `id` is unique.

## Math

- **`Matrix4` is backed by Rive's `Mat4`** (`matrix.mat4`, shared storage):
  `elements` is a `StaticArray<f32>` (three.js uses f64 numbers), column-major
  as in three.js. `set()` still takes row-major arguments. Pass `matrix.mat4`
  to any Rive API; `Matrix4.fromMat4(m)` copies one in.
- **Projection matrices map depth to [0, 1]** (WebGPU), as three.js with
  `WebGPUCoordinateSystem`. `Vector3.project` returns `z` in [0, 1], not
  [-1, 1]. `makePerspective` / `makeOrthographic` take no
  `coordinateSystem` argument.
- `Matrix3.elements` is a `StaticArray<f64>`.
- `MathUtils` is a class of static functions; `DEG2RAD` and `RAD2DEG` are
  also module constants.
- `toArray` / `fromArray` take `Array<f64>`.
- Where three.js returns `null` for "no result" from a method returning a
  number, ThreeAS returns a sentinel: **`Ray.distanceToPlane` returns -1**
  when the ray never reaches the plane. Methods returning objects still
  return `null` (`Ray.intersectBox`, `Plane.intersectLine` ...).
- `Triangle.getInterpolation<V>(...)` returns the target set to zero for a
  degenerate triangle (three.js returns `null`).
- Rive interop: `Vector2.setFromVector(v)` / `toVector()` convert to and from
  Rive's `Vector`.

## Core

- `geometry.attributes` is a `Map<string, BufferAttribute>`:
  `geometry.attributes.position` becomes `geometry.getAttribute("position")`.
- `BufferAttribute(array: Float32Array, itemSize, normalized)` holds f32 data
  only. `Float32BufferAttribute(array: Array<f64>, itemSize)` converts a
  plain array, as three.js.
- Indices: `setIndex(Array<i32>)` (three.js also accepts an attribute: use
  `setIndexAttribute(Uint32BufferAttribute)`). `geometry.index` is a
  `Uint32BufferAttribute`; `Uint16BufferAttribute` has the same storage. The
  renderer uploads 16-bit indices when they fit.
- `Object3D.copy` / `clone()` are not ported yet; `copyTransform(source)`
  copies name, transform and flags (not children).
- The polyhedron presets (`IcosahedronGeometry`, `OctahedronGeometry`,
  `TetrahedronGeometry`, `DodecahedronGeometry`) live in
  `geometries/PolyhedronGeometry.as` rather than a file each; through the
  `THREE` namespace nothing changes.

## Materials

- **All the maps of a material share one sampler and one UV transform**,
  taken from the first map present (`map` first). three.js gives each map
  its own (`offset`, `repeat`, `wrapS`/`wrapT`, filters, `channel`). Use
  the same settings on every map of a material.
- Normal maps are tangent space, with the tangent frame built from screen
  derivatives (three.js's path without a `tangent` attribute);
  `normalMapType` and `bumpMap` are not supported.
- `MeshToonMaterial.gradientMap` is always read nearest (as three.js
  recommends setting it); without one the two tones step sharply.
- `MeshDepthMaterial` supports `BasicDepthPacking` only.
- `MeshPhysicalMaterial` supports clearcoat, sheen, ior, specularIntensity
  and specularColor; transmission, thickness, iridescence, anisotropy,
  dispersion and the physical maps are not ported.
- `flatShading` is on the `Material` base (ignored by unlit materials).
- Fog is mixed in linear space after tone mapping and before the sRGB
  encode, so a fully fogged surface matches a background of the fog colour.
- **Environment maps** light MeshStandard/Physical materials only
  (Lambert/Phong/Basic ignore `envMap`; no `reflectivity`/`combine`), with
  three.js's IBL maths, but **reflections read the equirectangular map's own
  mip chain by roughness, not a GGX-prefiltered PMREM**: rough reflections
  are box-blurred. One environment per render: `scene.environment`, else the
  first material `envMap` drawn. Equirectangular textures only (no cube
  textures yet); clearcoat ignores the environment.
  `PMREMGenerator.fromEquirectangular(t).texture` is a shim returning `t`
  prepared; `fromScene`, `fromCubemap` and RoomEnvironment are not ported.
- **ShaderMaterial / RawShaderMaterial take a WGSL shader asset**, not GLSL
  strings: `{ shader: "shaders/wave" }` (its project path without `.wgsl`).
  Nothing is injected: the shader declares the bindings it uses by a fixed
  contract (frame block at group 0, object block at group 1, the material's
  uniforms at group 2; see `three/materials/ShaderMaterial.as`) and outputs
  sRGB, premultiplied colour. `uniforms` is a `Map<string, UniformBase>` of
  `Uniform<T>` (f64, Vector2/3/4, Color, Matrix4, Texture), packed in
  insertion order: `material.uniform<f64>("time").value += dt`. `defines`,
  `extensions`, `lights`, `fog`, `wireframe` and custom points/lines are not
  supported for shader materials.

## Curves and shapes

- **`Curve` is generic: `Curve<Vector2>` or `Curve<Vector3>`** (three.js's
  untyped vectors). `CurvePath<V>` likewise; `Path`, `Shape` and the 2D
  curves are `Vector2`, the `*Curve3` classes and `CatmullRomCurve3`
  `Vector3`. On the base class `getPoint(t, target)` needs its target;
  concrete curves default it as three.js.
- `curve.computeFrenetFrames(segments, closed)` is the function
  `computeFrenetFrames(curve, segments, closed)`, returning a
  `FrenetFrames` (`tangents`, `normals`, `binormals`).
- `closePath()` is on `Path` (2D) only.
- **`ShapeGeometry` and `ExtrudeGeometry` take an array of shapes**
  (`new ExtrudeGeometry([shape], options)`). Extrude options are an
  `ExtrudeGeometryOptions` object set field by field (its `bevelSize`
  defaults to NaN, meaning `bevelThickness - 0.1` as three.js);
  `UVGenerator` is not supported (always the world UV generator).
- `THREE.Path` is three.js's path; Rive's is `Path` from `rive/path`.
  `shapesFromRivePath(path, scale, isCCW)` and `shapePathFromRivePath`
  (Rive-only) convert a Rive path (y flipped). A node's path is empty until
  its artboard instance has advanced once: call `instance.advance(0)` before
  `node.asPath()`.

## Lines, points and sprites

- **Lines are one pixel wide** (`linewidth`, `linecap`, `linejoin` are
  kept and ignored, as three.js on almost every platform). Every line
  (Line, LineLoop, LineSegments, `wireframe`) is drawn as a line list from
  a generated index buffer.
- **Points are instanced quads** (WebGPU has no point size): square,
  `size` pixels times the pixel ratio, attenuated by depth as three.js.
  A Points geometry's index is ignored.
- `LineDashedMaterial` reads "lineDistance" through the uv slot, so a line
  with both "uv" and "lineDistance" dashes along u instead.

## Interaction, controls and time

- **Raycaster**: as three.js (`setFromCamera`, `intersectObject(s)`,
  `params.Line.threshold`, `params.Points.threshold`, layers, hits sorted by
  distance). `Intersection` is a class: fields three.js leaves undefined are
  `null` (`uv`, `normal`, `face`, `barycoord`) or `-1` (`faceIndex`,
  `index`, `instanceId`, `distanceToRay`). Objects' `raycast()` returns a
  bool (false stops the descent into children). As in three.js, world
  matrices must be current: call `scene.updateMatrixWorld()` before
  raycasting outside a render (ThreeLayout does it for pointer events).
- **Controls take Rive events, not DOM listeners.** `new OrbitControls(
  camera, renderer)`: the second argument is the GPURenderer (for the
  viewport size), three.js's `domElement`. Forward the script's pointer hooks
  to `controls.pointerDown/Move/Up/Exit/Scroll(event)` (ThreeLayout does).
  Rive pointer events have no mouse button, so one pointer rotates
  (MapControls: pans), two pointers dolly and pan (three.js's touch
  mapping), the wheel dollies. `keys`, `listenToKeyEvents`, `zoomToCursor`
  and change events are not ported. Import controls from
  `three/addons/controls/OrbitControls` (or `three/addons/Addons`).
- **Time comes from `advance(seconds)`.** `Clock` has `tick(seconds)` to
  feed it (call it each advance); `Timer.update(seconds)` takes the frame's
  seconds instead of a timestamp. `renderer.setAnimationLoop` does not
  exist.
- **Render targets**: `RenderTarget(width, height, options)` (alias
  `WebGLRenderTarget`), `renderer.setRenderTarget(rt)`. Size in pixels;
  `options` is a `RenderTargetOptions` (`depthBuffer`, `samples`,
  `generateMipmaps`). Its texture holds the renderer's output: sRGB,
  premultiplied, top row first (`colorSpace = SRGBColorSpace`,
  `premultiplyAlpha = true`, `flipY = true`), so sampling it gives the same
  colours as three.js. `rt.image` is a Rive `Image` for 2D drawing.
  `readRenderTargetPixels`, depth textures and multiple render targets are
  not ported.

## Rive app structure (Rive-only)

- `ThreeLayout`: a Layout subclass that owns `renderer`, `scene`, `camera`
  (a PerspectiveCamera whose aspect follows the layout), optional
  `controls`, `pointer` (NDC) and `raycaster`. Override `setup(context)`,
  `animate(seconds)`, `onResize`, `onPointerDown/Move/Up`, not
  `init/advance/resize`. It forwards pointer events into interactive
  `ArtboardTexture`s under the pointer (by raycast UV) before the controls.
- `ArtboardTexture.pointerDown/Move/Up/Exit(uv, id)` forward events by
  texture coordinate; `artboardPoint(uv)` converts.
- `copyNodeTransform(object, node, unitsPerPixel)` drives an Object3D from
  an (animated) Rive node.

## Animation

- `KeyframeTrack(name, times, values, interpolation)` takes `Array<f64>`
  and stores `Float32Array`s. Interpolations: Discrete, Linear (slerp for
  quaternions), Smooth, plus `InterpolateGLTFCubicSpline` (three.js keeps
  that inside its GLTFLoader). `StringKeyframeTrack` is not ported.
- `PropertyBinding` resolves `node.position|quaternion|scale|rotation|
  visible`, `node.morphTargetInfluences[i|name]` and `node.material.color|
  opacity|emissive`; nodes by name under the root (names cannot hold
  dots: `PropertyBinding.sanitizeNodeName`). No uuid paths, no arbitrary
  properties.
- `mixer.clipAction(clip)` takes an `AnimationClip` (not a clip name).
  Mixer events (`finished`, `loop`) are not dispatched: poll
  `action.isRunning()`, `action.enabled`, `action.paused`. Cross-fades
  ignore `warp`; `halt` and `warp` are not ported.

## Skinning and morph targets

- GPU skinning, up to **256 bones** per skeleton (more: drawn unskinned,
  with a log line). `Skeleton(bones: Array<Bone>, boneInverses)`.
- **Morph targets are blended on the CPU** (whenever the influences change),
  then uploaded; fine for faces and props, costly for big meshes animating
  every frame.
- A SkinnedMesh is frustum culled only after `computeBoundingSphere()` (its
  posed bounds); otherwise it is always drawn.

## Loaders

- **Loaders are synchronous and read Rive assets by name**: `new
  GLTFLoader(context).load("robot")` returns a `GLTF` (or null) from the
  BlobAsset `robot`; no URLs, no callbacks, no `LoadingManager`. Embedded
  images decode asynchronously; their textures fill in a few frames later.
  Import loaders from `three/addons/loaders/...`.
- GLTFLoader reads binary `.glb` only, without Draco, meshopt, KTX2 or
  sparse accessors; extensions read: KHR_lights_punctual,
  KHR_materials_unlit, emissive_strength, clearcoat, sheen, ior, specular,
  KHR_texture_transform. `gltf.parser`, `gltf.userData` and `extras` are not
  exposed.
- OBJLoader ignores `mtllib` (.mtl files): materials are MeshPhongMaterials
  named after `usemtl`. ObjectLoader (three.js JSON) is not ported.

## Shadows

- `renderer.shadowMap.enabled/type/autoUpdate/needsUpdate`, `castShadow` /
  `receiveShadow`, `light.shadow.mapSize/bias/normalBias/radius/intensity/
  camera` as three.js, for directional, spot and point lights.
- Shadow maps share one depth **array texture** (needs texture arrays; else
  shadows are off with a log line): at most **12 layers**, one per
  directional or spot light and six per point light; the layer size is the
  largest `mapSize` (256 to 2048). Lights beyond 12 layers cast no shadow.
- `VSMShadowMap` renders as `PCFSoftShadowMap` (PCF 5x5); `shadow.radius`
  scales the PCF step.
- Casters always render their back faces (`shadowSide` is not read) and
  ignore `alphaTest`/`alphaMap` (no cut-out shadows) and
  `customDepthMaterial`. Point light faces are rendered at 98 degrees so
  filtering stays inside a face.
- Directional shadow cameras are not fitted automatically, as in three.js:
  set `shadow.camera.left/right/top/bottom/near/far` and call
  `updateProjectionMatrix()`.

## Lighting

- Intensities are three.js's physically based ones (r155+, no legacy
  lights): diffuse is `irradiance * albedo / PI`. Sources written for
  `useLegacyLights = true` need their intensities multiplied by PI.
- At most **8** directional, point and spot lights reach the shader (the
  rest are ignored, with one log line). Ambient lights are summed, without
  limit. Hemisphere lights are summed too, all along the first one's
  direction.
- Without an environment map, metals reflect only direct lights and look
  dark, as in three.js.

## Textures

- **`Texture.image` is a Rive `Image`**: an image asset, a canvas's image, or
  any image a script holds. The renderer samples `image.view()`.
- **`TextureLoader(context).load(name)`** loads the `ImageAsset` named `name`
  (no extension) from the Rive file. There are no URLs and no callbacks: the
  texture is returned at once and samples once the image has decoded.
- **Textures from Rive images, canvases and artboards default to
  `SRGBColorSpace`** (three.js leaves loaded textures at `NoColorSpace`;
  you usually set sRGB yourself there).
- **`premultiplyAlpha` means the source is premultiplied** (true for Rive
  images, canvases and artboards), and the shader unpremultiplies. In
  three.js it asks the upload to premultiply.
- `flipY` is honoured in the shader (true: v = 0 is the image's bottom row).
- `DataTexture(data: Uint8Array, width, height)` takes RGBA8 only.
- `CanvasTexture(canvas)` takes a Rive 2D `Canvas` (`context.canvas(w, h)`),
  not an HTML canvas.
- UV transform: `offset` and `repeat` work; `rotation` and `center` are
  ignored for now.
- Mipmaps: a texture with `generateMipmaps` and a mipmap `minFilter` (the
  default) is copied into a mipmapped texture, redone when its source
  changes (a Rive image that decoded, `needsUpdate`, an ArtboardTexture
  redraw). `anisotropy` works up to 16 where the device supports it.
- Background textures: UV-mapped ones fill the view (stretched);
  `EquirectangularReflectionMapping` ones surround it, with
  `backgroundRotation` and `backgroundBlurriness` (a mip level).

## Render targets and post-processing

- `RenderTarget(w, h, { type })`: `UnsignedByteType` (the default) is a Rive
  canvas holding sRGB, premultiplied colour, tone mapped; its `image` draws
  with `Renderer.drawImage`. `HalfFloatType` / `FloatType` targets are an
  rgba16float texture (FloatType too) holding **linear, not tone-mapped**
  colour, as three.js's renderer writes into float targets; they have no
  `image`. Materials skip tone mapping and sRGB encoding into them.
- `EffectComposer`, `RenderPass`, `ShaderPass`, `OutputPass`, `FXAAPass`
  and `UnrealBloomPass` are in `three/addons/postprocessing/` (not
  `Three.as`). The composer's buffers are HalfFloatType; put an
  `OutputPass` last (FXAA after it). The composer follows the renderer's
  size on its own. ThreeLayout renders through `renderFrame()`: override it
  with `composer.render(this.delta)`.
- Shaders are `ShaderDefinition`s (`CopyShader`, `OutputShader`,
  `FXAAShader`, `LuminosityHighPassShader`) over WGSL in
  `three/shaders/post/`, instead of `{ uniforms, vertexShader,
  fragmentShader }` objects: `new ShaderPass(FXAAShader)`, or
  `ShaderPass.fromMaterial(material)` for a ShaderMaterial. A custom pass
  shader follows the ShaderMaterial contract and places the quad itself
  (copy `three/shaders/post/copy.wgsl`). `pass.uniform<T>(name).value`
  replaces `pass.uniforms.name.value`.
- `UnrealBloomPass` has no `bloomTintColors`; one shader holds its three
  stages, so every stage material carries all its uniforms.
- Not ported: MaskPass/ClearMaskPass, SMAA, SSAO, BokehPass, the other
  shader passes; `Uniform.clone()` is UniformsUtils.clone per uniform.

## Rive-only additions

- `ArtboardTexture(artboard, width = 0, height = 0)`: a live artboard as a
  texture. Call `texture.advance(seconds)` from the script's `advance`; it
  redraws only after a change. `texture.artboard` is the instance.
- `Color.alphaOf(argb)` and `color.getRiveColor(alpha)` convert to Rive
  colours; `setHex` accepts a Rive `Color` (alpha ignored), so `Color` script
  inputs plug straight in.

## Not yet supported

Missing so far, planned in [../PLAN.md](../PLAN.md): BatchedMesh,
RectAreaLight (not planned: it needs three.js's LTC tables),
cube textures, ObjectLoader, more post-processing passes (SMAA, SSAO, bokeh), `EventDispatcher` events (`dispose` events are internal).
