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
| custom vertex layouts | fixed slots: 0 position, 1 normal (location 1) and tangent (location 12) interleaved, 2 uv, 3 colour, 4 instance matrix (mat4), 5 instance colour (rgb), 6 uv1 (location 11), 7 skin index and weight interleaved (skinned only) |
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
- `Object3D.copy(source, recursive)` / `clone(recursive)` work for every
  object class (geometries and materials shared, as three.js);
  `copyTransform` copies just the transform and flags. `clone()` returns
  `Object3D`: cast it (`mesh.clone() as Mesh`). `BufferGeometry.copy`,
  `clone` and `toNonIndexed` as three.js.
- **Events take listener objects** (no closures): subclass
  `EventListener` with `handleEvent(event)`. Objects dispatch "added",
  "removed", "childadded", "childremoved"; materials, geometries and
  textures "dispose"; controls "change", "start", "end".
- `InterleavedBuffer` / `InterleavedBufferAttribute`: the attribute keeps
  its own dense copy (the renderer uploads attributes separately); its
  setters write both, and `buffer.needsUpdate = true` after writing
  `buffer.array` directly refreshes them.
- `BufferGeometryUtils` (mergeGeometries, mergeAttributes, mergeVertices,
  interleaveAttributes, deinterleaveGeometry; computeMikkTSpaceTangents is
  computeTangents), `SceneUtils` (createMultiMaterialObject,
  createMeshesFromInstancedMesh, createMeshesFromMultiMaterialMesh) and
  `SkeletonUtils` (clone, getBoneByName, a simplified retarget copying
  local rotations by bone name) are addons imported by path as namespaces.
- The polyhedron presets (`IcosahedronGeometry`, `OctahedronGeometry`,
  `TetrahedronGeometry`, `DodecahedronGeometry`) live in
  `geometries/PolyhedronGeometry.as` rather than a file each; through the
  `THREE` namespace nothing changes.

## Materials

- Normal maps: tangent space (with the "tangent" attribute when the
  geometry has one, e.g. from `computeTangents()`, else a frame from screen
  derivatives) or `ObjectSpaceNormalMap`. `bumpMap`, `displacementMap`
  (vertex stage, in shadow passes too), `lightMap`, `specularMap`, and the
  physical maps (clearcoat, clearcoat roughness and normal, sheen colour and
  roughness, specular intensity and colour) work as three.js.
- **At most five distinct "extra" maps per material** (light, bump,
  displacement, specular, and the physical maps; maps sharing a texture
  count once, as glTF packs them), beyond the eight base slots (map,
  normal, roughness/specular/gradient/matcap, metalness, ao, emissive,
  alpha, envMap); further ones are ignored with a log line. **Extra map k
  shares base slot k's sampler** (map, normal, roughness, metalness, ao): the renderer prefers a slot whose base map is absent or has
  the same wrapping and filters, else the extra map is sampled with the
  base map's sampler. (Rive allows 8 bindings a group and the web 16
  textures a stage; one sampler per texture keeps the shader translatable
  to GLSL.)
- Basic, Lambert and Phong `envMap` with `combine` (Multiply, Mix, Add),
  `reflectivity` and `refractionRatio` (Cube/EquirectangularRefraction
  mapping refracts) as three.js's envmap_fragment; they do not read
  `scene.environment`, as three.js.
- `MeshToonMaterial.gradientMap` is always read nearest (as three.js
  recommends setting it); without one the two tones step sharply.
- `MeshDepthMaterial` supports `BasicDepthPacking` only.
- `MeshPhysicalMaterial` supports clearcoat, sheen, ior, specularIntensity
  and specularColor with their maps, transmission, thickness,
  attenuationColor/Distance, dispersion, iridescence (thin film, IOR and
  thickness range) and anisotropy (strength, rotation, map) with three.js's
  maths. **Transmission** renders the opaque, non-transmissive draws and
  the background into a linear HDR target the size of the pass, mipmapped,
  once per render when a transmissive material is drawn (three.js's
  transmission pass); ShaderMaterials are left out of it, transmissive
  objects do not see each other, and there is no
  `transmissionResolutionScale`. Sampling is bilinear between mips (three.js
  filters bicubically).
- `flatShading` is on the `Material` base (ignored by unlit materials).
- Fog is mixed in linear space after tone mapping and before the sRGB
  encode, so a fully fogged surface matches a background of the fog colour.
- **Environment maps** light MeshStandard/Physical materials only
  (Lambert/Phong/Basic ignore `envMap`; no `reflectivity`/`combine`), with
  three.js's IBL maths. The renderer prefilters every environment
  (`scene.environment`, `envMap`, a blurred background) into a PMREM on its
  own, as three.js does for `scene.environment`: **an equirectangular mip
  chain** (128 to 1024 wide, down to 16 x 8) where level k is GGX-convolved
  at roughness k / (levels - 1), sampled at `roughness x (levels - 1)`;
  three.js uses a cube-UV atlas and a non-linear roughness-to-mip mapping,
  so very rough reflections differ slightly. Irradiance reads the
  roughness-1 level, as three.js. A material's `envMap` overrides
  `scene.environment` for that material (`envMapIntensity` scales it;
  `envMapRotation` is not read). The clearcoat reflects the environment too.
- `PMREMGenerator`: `fromEquirectangular` and `fromCubemap` return their
  texture prepared (the renderer prefilters it); `fromScene(scene, sigma,
  near, far)` renders the scene into a 256 cube map at the start of the
  renderer's next `render` (scripts render only from `draw()`), and
  ignores `sigma`. `RoomEnvironment` is in `three/addons/environments/`.
- **Cube textures are converted to equirectangular maps** on the GPU (an
  rgba16float texture 4 x 2 faces wide, redone when a face or `version`
  changes) and sampled as those, for `background`, `environment` and
  `envMap`. Image cube maps follow three.js's orientation (mirrored in x,
  `flipEnvMap`). `CubeRefractionMapping` reflects instead.
  `PMREMGenerator.fromEquirectangular(t).texture` is a shim returning `t`
  prepared; `fromScene`, `fromCubemap` and RoomEnvironment are not ported.
- **ShaderMaterial / RawShaderMaterial take a WGSL shader asset**, not GLSL
  strings: `{ shader: "shaders/wave" }` (its project path without `.wgsl`).
  Nothing is injected: the shader declares the bindings it uses by a fixed
  contract (frame block at group 0, object block at group 1, the material's
  uniforms at group 2; see `three/materials/ShaderMaterial.as`) and outputs
  sRGB, premultiplied colour. `uniforms` is a `Map<string, UniformBase>` of
  `Uniform<T>` (f64, Vector2/3/4, Color, Matrix4, Texture), packed in
  insertion order: `material.uniform<f64>("time").value += dt`.
- **ShaderChunk is a file to copy from**, not an include: WGSL has no
  `#include` and Rive shaders cannot import, so
  `three/shaders/lib/three_chunks.wgsl` (generated from three.wgsl by
  `tools/make_shader_chunks.py`) holds the renderer's frame and object
  blocks, bindings and helpers (`three_direct_light`, `three_ambient`,
  `three_output` for tone mapping, fog and sRGB, `shadow_factor`,
  `tone_map`). With `lights: true` a ShaderMaterial is bound with every
  frame binding (lights, environment, shadow maps, transmission); keep them
  declared and used (`three_keep_frame_bindings`). `fog` defaults to false
  as three.js and is honoured by `three_output`. **`defines` and
  `extensions` are not supported** (Rive pipelines take no overridable
  constants); `wireframe` and custom points/lines neither.

## ShadowMaterial, MeshDistanceMaterial, alpha hashing

- `ShadowMaterial({ color, opacity })` is transparent except where the
  mesh (with `receiveShadow`) is in shadow, as three.js.
- `MeshDistanceMaterial` draws the normalised distance to
  `referencePosition` as grey (three.js packs it to RGBA for its point
  light shadows, which this renderer does not need).
- `alphaHash` as three.js (hashed threshold on the object-space position).
  **`alphaToCoverage` renders as `alphaHash`**: Rive pipelines have no
  alpha to coverage.

## Clipping, stencil and depth state

- `renderer.clippingPlanes` (global, always a union),
  `renderer.localClippingEnabled`, `material.clippingPlanes`,
  `clipIntersection` and `clipShadows` as three.js; **at most 8 planes per
  draw** (global first). Planes are world space, as three.js's API.
  ShaderMaterials are not clipped.
- Stencil: `stencilWrite` (turns the test and writes on), `stencilFunc`,
  `stencilRef`, `stencilFuncMask`, `stencilWriteMask`, `stencilFail`,
  `stencilZFail`, `stencilZPass`, with three.js's constants. Colour passes
  use a `depth24plusStencil8` target (24-bit depth, was 32-bit float).
  **Stencil starts at 0 in every pass and does not survive across
  passes**, and there is no `renderer.clearStencil()` or `onAfterRender`
  mid-pass: order stencil draws with `renderOrder` within one render.
- `depthFunc` (NeverDepth ... NotEqualDepth) and `polygonOffset` /
  `polygonOffsetFactor` / `polygonOffsetUnits` work (polygonOffset as the
  pipeline's depth bias). At most 511 distinct depth/stencil/offset
  combinations per renderer.

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
  kept and ignored, as three.js on almost every platform). Wide lines are
  the addons, as three.js: `Line2` / `LineSegments2` with `LineGeometry` /
  `LineSegmentsGeometry` and `LineMaterial` (`linewidth` in pixels, round
  caps, dashes, vertex colours; `setPositions` / `setColors` take plain
  number arrays). `worldUnits` and raycasting wide lines are not ported;
  `resolution` is not needed (the renderer knows its viewport). Every line
  (Line, LineLoop, LineSegments, `wireframe`) is drawn as a line list from
  a generated index buffer.
- **Points are instanced quads** (WebGPU has no point size): square,
  `size` pixels times the pixel ratio, attenuated by depth as three.js.
  A Points geometry's index is ignored.
- `LineDashedMaterial` reads "lineDistance" through the uv slot, so a line
  with both "uv" and "lineDistance" dashes along u instead.

## BatchedMesh

- **One instanced draw per geometry** instead of three.js's multi-draw:
  the visible instances are packed by geometry into an instance buffer
  (re-packed when instances change) and each geometry draws its slice.
  Draws are not sorted per instance (`sortObjects` and `setCustomSort` are
  kept and ignored) and instances are not culled one by one
  (`perObjectFrustumCulled` is ignored): the whole batch is culled by its
  bounding sphere, which is recomputed after instances change (three.js
  leaves it to `computeBoundingSphere`).
- Geometries must share the first geometry's attributes and be all
  indexed or all not; `addGeometry` returns -1 otherwise (three.js
  throws). Shared attributes are stored as Float32. Morph targets are not
  batched. `setInstanceCount` / `setGeometrySize` (growing the buffers)
  are not ported: size the batch up front.
- Hits from raycasting carry `batchId` (the instance), as three.js.

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
  mapping), the wheel dollies. `keys`, `listenToKeyEvents` and
  `zoomToCursor` are not ported. Controls extend `Controls` (three.js r16x's
  base) and dispatch "change", "start" and "end". ThreeLayout's
  `controls` is a `Controls`. Rive hands a script every pointer event of
  its artboard: ThreeLayout ignores presses and scrolls outside its own
  bounds (drags that started inside continue).
- More controls (addons): TrackballControls, FlyControls,
  FirstPersonControls, DragControls and TransformControls. Pointer events
  have no buttons: a press rotates (Trackball), moves forward (Fly,
  FirstPerson; Fly's `dragToLook` looks instead). Keys come through
  `keyboardEvent` with GLFW key codes (`KEY_W`... in `extras/Controls`);
  the ScriptedLayout needs a `FocusData` child to receive them.
  ThreeLayout's **`tools`** get the pointer before `controls`, which skip
  it while a tool is `capturing()` (three.js examples disable OrbitControls
  on "dragging-changed" instead; that works too). TransformControls is a
  compact port: translate/rotate/scale handles, plane handles, uniform
  scale, snapping, world/local space and its events, with a simpler gizmo
  (no view-aligned "E"/"XYZE" rotation rings). Events carry `object` /
  `value` fields. ArcballControls and PointerLockControls are not ported. Import controls from
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
  shadows are off with a log line): at most **24 layers**, one per
  directional or spot light and six per point light; the layer size is the
  largest `mapSize` (256 to 2048), halved until all layers fit 64 MB.
  Lights beyond 24 layers cast no shadow.
- `VSMShadowMap` renders as `PCFSoftShadowMap` (PCF 5x5); `shadow.radius`
  scales the PCF step. `SpotLight.map` (projected textures) is not
  supported (the main shader has no texture binding left).
- The **CSM** addon (`three/addons/csm/`) fits one DirectionalLight per
  cascade as three.js; instead of injecting shader code
  (`setupMaterial` does nothing), each cascade light carries its view
  depth range (`cascadeNear` / `cascadeFar`) and lights only fragments in
  it. Cascades switch hard (`fade` is not supported).
- Casters render the side three.js picks (`shadowSide`, else the
  opposite of `side`); casters with `alphaTest`, `alphaHash` or
  `alphaToCoverage` cut their shadows with their `map` alpha and
  `alphaMap`, displacement maps displace them, and
  `object.customDepthMaterial` (else `customDistanceMaterial`; one
  material serves every light) stands in for the material in shadow
  passes. Point light faces are rendered at 98 degrees so
  filtering stays inside a face.
- Directional shadow cameras are not fitted automatically, as in three.js:
  set `shadow.camera.left/right/top/bottom/near/far` and call
  `updateProjectionMatrix()`.

## Lighting

- Intensities are three.js's physically based ones (r155+, no legacy
  lights): diffuse is `irradiance * albedo / PI`. Sources written for
  `useLegacyLights = true` need their intensities multiplied by PI.
- At most **32** directional, point and spot lights per render (the rest
  are ignored, with one log line), and **each draw is lit by at most 31**:
  the lights whose `distance` reaches its bounding sphere (all directional
  lights and lights with `distance` 0 do), the strongest, nearest and
  closest to the camera first. three.js lights every object with every light. Ambient lights are summed, without
  limit. Hemisphere lights are summed too, all along the first one's
  direction.
- Without an environment map, metals reflect only direct lights and look
  dark, as in three.js.
- **RectAreaLight** works without `RectAreaLightUniformsLib.init()` (kept
  as a no-op): its LTC tables are built into the renderer, **resampled
  from three.js's 64 x 64 to 32 x 32** half floats so both fit one 16 KB
  uniform block (the shader is at the web's 16-texture limit). It lights
  MeshStandard/Physical only and casts no shadow, as three.js. It counts
  toward the 32 lights.
- `LightProbe` (any number, summed) with `SphericalHarmonics3`.
  **`LightProbeGenerator.fromEquirectangular(dataTexture, step)`** replaces
  `fromCubeTexture` / `fromCubeRenderTarget`: Rive images cannot be read
  back, so probes come from CPU data (RGBELoader / EXRLoader / DataTexture
  equirectangular maps).

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
- `DataTexture(data, width, height, format, type)`: `data` is an
  `ArrayBufferView` (cast it to index: `t.data as Uint8Array`): a
  Uint8Array (UnsignedByteType), a Uint16Array of half floats
  (HalfFloatType) or a Float32Array (FloatType). Formats: RGBAFormat,
  RGBFormat (widened to RGBA), RGFormat, RedFormat. **FloatType uploads as
  half floats** (rgba16float; 32-bit float filtering is optional in
  WebGPU). `toHalf` / `fromHalf` convert (three.js's DataUtils).
- `DataArrayTexture` / `Data3DTexture` (same data rules) are for
  ShaderMaterials declaring `texture_2d_array<f32>` / `texture_3d<f32>`;
  built-in materials do not read them; `addLayerUpdate` is not ported.
- `RGBELoader` (alias `HDRLoader`) and `EXRLoader` read BlobAssets (`load(name)`,
  or `parse(bytes)` without a Context), returning a DataTexture with
  `flipY` true (rows top first). EXR: scanline files with NO, RLE, ZIPS or
  ZIP compression only (no PIZ, PXR24, B44, DWA; no tiled, deep or
  multi-part). `libs/fflate` has `inflateSync`, `unzlibSync` and
  `decompressSync` (no compression).
- `CompressedTexture(mipmaps, width, height, format)`: `mipmaps` are
  `CompressedMipmap(data, width, height)`; BC1/BC3/BC7, ETC2 and ASTC
  (4x4, 6x6, 8x8) when the device has the feature (`bc`, `etc2`, `astc`
  in `context.features()`); no CPU fallback. Sizes must be block
  multiples. sRGB variants decode in the shader (`colorSpace`).
- `KTX2Loader(context).detectSupport(renderer).load(name)` reads KTX2
  BlobAssets holding a GPU format directly (the formats above, RGBA8,
  RGBA16F). **No Basis Universal transcoding and no Zstandard**: ship
  files in a format the target devices have (BC for desktop, ASTC/ETC2
  for mobile). `setTranscoderPath` is accepted and ignored.
- Note for test suites: `rive --test` names blobs by file stem, so give
  blob files distinct stems (`studio_rgbe.hdr`, `studio_exr.exr`).
- `CanvasTexture(canvas)` takes a Rive 2D `Canvas` (`context.canvas(w, h)`),
  not an HTML canvas.
- UV transforms as three.js: each map has its own `offset`, `repeat`,
  `rotation`, `center` (`matrix`, `matrixAutoUpdate`, `updateMatrix()`),
  wrapping and filters. `channel` 0 reads "uv", 1 reads "uv1" (2 and 3
  read "uv1" too: two uv sets only); a geometry without "uv1" reads "uv".
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

## Cube maps and CubeCamera

- `CubeTextureLoader(context).load([px, nx, py, ny, pz, nz])` takes six
  image asset names (`setPath` prefixes them).
- `WebGLCubeRenderTarget(size, options)` is six RenderTargets (`faces`),
  HalfFloatType by default; its `texture` is a CubeTexture over them.
  `fromEquirectangularTexture` and `clear` are not ported.
- `CubeCamera.update(renderer, scene)` renders the six faces; hide the
  reflecting object yourself (three.js examples do the same).

## Addon geometries and text

- RoundedBoxGeometry, ParametricGeometry (+ ParametricFunctions klein,
  mobius, mobius3d), ConvexGeometry (on `addons/math/ConvexHull`, an
  incremental hull rather than three.js's quickhull, same results),
  DecalGeometry and TextGeometry are addons. **ParametricGeometry takes a
  top-level function** (no closures: `ParametricFunctions.plane(w, h)`,
  which returns one in three.js, is not ported). TeapotGeometry is not
  ported.
- `FontLoader(context).load(name)` reads a typeface JSON BlobAsset;
  `parse(json)` takes its text. **Rive-only `RiveFont(context.font(name))`**
  makes a Font of any font in the Rive file, shaped by Rive's text engine
  (kerning, ligatures, any script): `new TextGeometry("Hi", { font, size,
  depth })` works with either. TextGeometryParameters has three.js's
  defaults (depth 50, bevel off, bevelThickness 10, bevelSize 8).

## Helpers

- AxesHelper, GridHelper, PolarGridHelper, BoxHelper, Box3Helper,
  PlaneHelper, ArrowHelper, CameraHelper, DirectionalLightHelper,
  PointLightHelper, SpotLightHelper, HemisphereLightHelper and
  SkeletonHelper are in `Three.as`; VertexNormalsHelper is an addon. As
  three.js, call `update()` after what they show changed (BoxHelper,
  CameraHelper, light helpers, VertexNormalsHelper). Helper colour
  arguments are hex numbers; the light helpers take `-1` for "the light's
  colour" (three.js's undefined). Lines are one pixel wide.

## Rive-only additions

- `ArtboardTexture(artboard, width = 0, height = 0)`: a live artboard as a
  texture. Call `texture.advance(seconds)` from the script's `advance`; it
  redraws only after a change. `texture.artboard` is the instance.
- `Color.alphaOf(argb)` and `color.getRiveColor(alpha)` convert to Rive
  colours; `setHex` accepts a Rive `Color` (alpha ignored), so `Color` script
  inputs plug straight in.

## Not yet supported

Missing so far, planned in [../PLAN.md](../PLAN.md):
ObjectLoader, more post-processing passes (SMAA, SSAO, bokeh), 
