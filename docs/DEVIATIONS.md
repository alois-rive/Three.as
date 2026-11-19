# Deviations from three.js

ThreeAS keeps three.js's names, signatures and behaviour wherever
AnimaScript and Rive allow. This page lists every place it does not, so that
code, examples and fixes taken from three.js sources can be ported without
guessing. **When porting from three.js, read this first.** If you add a
deviation, add it here in the same change.

Status: Milestones 14 and 15 done (see [../PLAN.md](../PLAN.md); performance notes in
[PERFORMANCE.md](PERFORMANCE.md)). Features not yet ported
are listed under [Not yet supported](#not-yet-supported); they are missing,
not different.

## Porting checklist

1. Import the namespace: `import * as THREE from "lib:threeas/three/Three";`
   (the `threeas` Rive library, not `"three"`; a relative path such as
   `"../three/Three"` with a copy of `three/`, or inside the engine).
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
import * as THREE from "lib:threeas/three/Three";
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
| `WebGLRendererParameters` | `GPURendererParameters`: `antialias` (4x MSAA), `alpha` (transparent clear), `logarithmicDepthBuffer` only (no `reverseDepthBuffer`, see [Render target features](#render-target-features)) |
| `outputColorSpace` | read-only, always sRGB |
| `toneMapping`, `toneMappingExposure` | as three.js (Linear, Reinhard, Cineon, ACESFilmic, AgX, Neutral); no CustomToneMapping |
| output | premultiplied alpha, composited with `srcOver` |
| custom vertex layouts | fixed slots: 0 position, 1 normal (location 1) and tangent (location 12) interleaved, 2 uv, 3 colour, 4 instance matrix (mat4), 5 instance colour (rgb), 6 uv1 (location 11), 7 skin index and weight interleaved (skinned only) |
| `info.render.calls/triangles/lines/points`, `info.memory`, `info.autoReset` / `reset()` | same, plus `info.render.culled` (objects frustum culled); `info.memory` counts `geometries` and `textures` (no `info.programs`) |
| (none) | `renderer.parallelCulling` (Rive-only, default true): views with 2048 or more frustum-culled candidates test them in a Rive parallel call (`three/renderers/gpu/Culling`), with the same result as on the main lane |
| (none) | `info.timings` (Rive-only, off by default): CPU seconds per render stage (`matrices`, `collect`, `prepare`, `write`, `passes`, `draw`) summed over `renders`; `summary()` averages them, `reset()` clears |
| uniforms uploaded per program | each draw keeps one 1536-byte block in a shared uniform buffer across frames (bound at a dynamic offset), rewritten and uploaded only when its world matrix, light list or material changed; a material's share of the block is built once a view however many draws use it |

### Shader programs: the uber-shader and baked variants

three.js compiles a program per material configuration (`#define`s from
`getProgramCacheKey`). ThreeAS draws every built-in material with **one
uber-shader** (`three/shaders/three.wgsl`) whose features are uniform
branches, so there is no compile per material and no `onBeforeCompile` /
`customProgramCacheKey` (`material.version` / `needsUpdate` cost nothing).
The **optional "optimized" mode** bakes three.js-style variants ahead of
time: `tools/bake_shaders.sh` records the program keys a project draws
(`--arg threeShaderKeys=1`) and generates `three/shaders/baked/*.wgsl`,
three.wgsl with the fragment features as constants (shading model, maps,
extra maps, flags, cut-out or not, flat shading, environments, fog type,
hemisphere light, linear output, the light count and types in list order)
and only the draw's two entry points, plus the registry
`three/renderers/gpu/BakedShaders.as`. At runtime a draw whose key is baked
from the current three.wgsl (`THREE_WGSL_HASH`) uses its variant; any other
draw, the transmission pass, shadow passes and ShaderMaterials use the
uber-shader. Unbaked keys are logged once (silence with
`--define=THREE_RELEASE`); `renderer.useBakedShaders = false` or
`--arg threeUberShader=1` ignores the bake. Baked and uber renders match
except for a few high-contrast or grazing-angle pixels (compiling without
`discard` and with folded constants changes derivatives and rounding: up to
about 1% of a scene's pixels, mostly by a few levels). Each variant adds
about 0.5 MB to the .riv (five backends) and a pipeline compile on first
use. The default repository state bakes nothing.

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
- **`userData` is a `Dynamic` table** (`rive/dynamic`, AnimaScript's
  untyped value) on objects, geometries, materials and textures:
  `object.userData.set("hp", Dynamic.fromNumber(3))`,
  `Dynamic.asNumber(object.userData.get("hp"))`. It holds what JSON holds;
  `copy` / `clone` deep-copy it (geometries share it), and toJSON writes it.
- `uuid` (objects, geometries, materials, textures, sources, skeletons,
  clips, shapes) is made by `MathUtils.generateUUID()` on first read, not
  in the constructor; `id` is unique too.
- Loaders that set typed data return subclasses with typed fields as well
  (`STLGeometry.groupNames`, `SVGShapePath.userData`).

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
  alpha, envMap); further ones are ignored with a log line. Morphed meshes
  and skeletons over 256 bones lend slots to their vertex textures (see
  [Skinning and morph targets](#skinning-and-morph-targets)). **Extra map k
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
  `node.asPath()`. The reverse, `rivePathFromShapePath(shapePath, scale,
  flipY = false)`, makes a Rive path of a ShapePath (SVGLoader paths: SVG's
  y already points down, as Rive's): lines and Béziers as they are,
  ellipse arcs as cubics, a contour per sub-path, closed with `autoClose`;
  set its `fillRule` from the SVG style.
- `NURBSCurve` and `NURBSUtils` are addons in `three/addons/curves/`
  (`NURBSSurface`, `NURBSVolume` and `toJSON` / `fromJSON` are not ported).
  `NURBSCurve(degree, knots, controlPoints, startKnot = 0, endKnot = -1)`:
  -1 (or 0) for `endKnot` is three.js's undefined, the last knot.

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
  `generateMipmaps`, `type`, `count`, `depthTexture`). Its texture holds
  the renderer's output: sRGB, premultiplied, top row first (`colorSpace =
  SRGBColorSpace`, `premultiplyAlpha = true`, `flipY = true`), so sampling
  it gives the same colours as three.js. `rt.image` is a Rive `Image` for
  2D drawing. Multiple render targets, depth textures and copies: see
  [Render target features](#render-target-features).

## Render target features

- **Multiple render targets**: `{ count: n }` (1 to 4) gives `rt.textures`
  (`rt.texture` is `textures[0]`), as three.js. ShaderMaterials write them
  with `@location(n)` outputs (every location: a pipeline cannot leave one
  unwritten); built-in materials write the first only. The extra textures
  have the first one's format and hold what the shader wrote
  (`NoColorSpace`, not premultiplied). `samples` is ignored (no MSAA) with
  `count` > 1 or a depth texture.
- **`DepthTexture(width, height, type, format)`**, set as
  `options.depthTexture` or `rt.depthTexture`: it is the pass's depth
  attachment itself (24-bit depth plus stencil, whatever `type` says),
  sized with the target and kept after the render. ShaderMaterials declare
  it `texture_depth_2d` and read it with `textureLoad` or `textureSample`
  (window depth, 0 near, 1 far); built-in materials ignore it (a log line).
  Its rows are top first (`flipY` true; three.js: false), as every render
  target texture here: sample at `(u, 1 - v)` from a fullscreen quad.
- **`readRenderTargetPixels` / `readRenderTargetPixelsAsync` are not
  ported**: Rive's GPU API has no readback (no buffer mapping or texture to
  buffer copy), so pixels cannot come back to a script. Keep the data on
  the GPU (render targets, copies) or compute it on the CPU.
- **`copyFramebufferToTexture(texture, position, level)`** copies from the
  current render target, or the canvas, at `position` (pixels from the
  bottom left) into a `FramebufferTexture` (its size); the texture takes
  the source's colour space and premultiplied alpha.
  **`copyTextureToTexture(src, dst, srcRegion, dstPosition, level)`**: a
  `Box2` region and a `Vector2` position (texels, from the bottom in uv
  terms; three.js's Box3 / 3D and array textures are not supported), rows
  flipped where `flipY` differs. Render target textures are written in
  place; any other destination (an image, a DataTexture, a canvas, a
  FramebufferTexture) samples a GPU copy of itself from then on, until its
  own content changes (a new `version`). Level 0 only; depth textures
  cannot be copied. Both are passes: call them from `draw()`.
- **`logarithmicDepthBuffer`** (a GPURendererParameters option) as
  three.js for built-in materials: depth `log2(1 + w) / log2(1 + far)`
  written from the fragment shader (orthographic cameras keep the window
  depth). ShaderMaterials do not get it: write `@builtin(frag_depth)`
  yourself (the frame block's `viewport.w` holds `1 / log2(far + 1)`), or
  they will not sort against the rest. MeshDepthMaterial still draws the
  linear window depth.
- **`reverseDepthBuffer` is not ported**: colour passes use a
  depth24plus-stencil8 attachment (fixed point on some backends, and the
  stencil must stay), where a reversed depth range gains little;
  `logarithmicDepthBuffer` covers scenes of huge depth ranges.

## Views: viewports, scissors, several renders a frame

- `setViewport`, `setScissor` (both `(x, y, width, height)` or a
  `Vector4`, in points from the bottom left), `setScissorTest`,
  `getViewport`, `getScissor`, `getCurrentViewport` (pixels), and a render
  target's `viewport`, `scissor`, `scissorTest` (pixels) work as three.js;
  `setSize` resets the viewport. With the scissor test on, `autoClear` and
  `clear()` clear only inside the scissor (a fullscreen draw, since a pass's
  load op clears the whole target). `clear(color, depth, stencil)`,
  `clearColor()`, `clearDepth()`, `clearStencil()`, `autoClearColor`,
  `autoClearDepth` and `autoClearStencil` are three.js's. Viewports are
  clamped to the target (WebGPU rejects one that overflows it).
- Several renders into one target in a frame (split screens, insets,
  overlays with `autoClear = false`) keep the earlier ones' colour and depth
  (stencil does not survive, see above). With `antialias`, the MSAA samples
  and depth are stored at the end of a pass only once a render of that
  target was partial (a viewport or scissor), loaded (`autoClear` off) or
  followed `clear()`: an overlay after a full render, without `clear()`,
  starts from an undefined MSAA buffer in its first frame only.
- **`ArrayCamera`**: each sub-camera's `viewport` (a `Vector4`, drawing-buffer
  pixels from the bottom left, as three.js) gets a full render of its own:
  culled by that sub-camera, the first one clearing (three.js culls with
  the array camera and draws the lists once per sub-camera). Shadow maps
  render once. **`StereoCamera`** as three.js (`update(camera)`, then render
  `cameraL` / `cameraR` into the halves).
- `setViewOffset` / `clearViewOffset` (and `view`) on PerspectiveCamera and
  OrthographicCamera as three.js (they live on the Camera base class).
- **`renderer.compile(scene, camera, targetScene)`** builds every
  pipeline, bind group, upload and mip chain the render would need (culling
  off) without drawing, and returns the materials as an `Array<Material>`
  (three.js: a Set). Call it from `draw()`, as `render`; `targetScene`'s
  lights are not merged in, and there is no `compileAsync`.

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
  an (animated) Rive node; `RiveRig` does more (see
  [Rive-driven animation](#rive-driven-animation-rive-only)).
- ThreeLayout's `overlay` (an `ArtboardOverlayRenderer`) is placed and
  advanced after `animate` and the controls, drawn after the canvas is
  presented, and gets pointer events first; its `bindings` (a
  `SceneBindings`) sync after `animate`, and are made by ThreeLayout itself
  when the bound view model has a `threeBindings` string.

## Animation

- `KeyframeTrack(name, times, values, interpolation)` takes `Array<f64>`
  and stores `Float32Array`s. Interpolations: Discrete, Linear (slerp for
  quaternions), Smooth, plus `InterpolateGLTFCubicSpline` (three.js keeps
  that inside its GLTFLoader). `StringKeyframeTrack` is not ported
  (`AnimationClip.parse` skips string tracks). Tracks and clips have
  three.js's `clone`, `trim`, `optimize` and `validate` (validate's
  reason is in `track.validationError` instead of a console error);
  `track.getKeyStride()` is the values a key takes (3 x the value size for
  glTF cubic splines). `AnimationClip.CreateFromMorphTargetSequence` and
  `CreateClipsFromMorphTargetSequences` take morph attributes
  (`Array<BufferAttribute>`); `findByName` takes an array of clips only.
- **Additive blending** as three.js: an action's `blendMode` (the clip's,
  or `clipAction(clip, root, blendMode)`) of `AdditiveAnimationBlendMode`
  adds its weighted values on top of the normal blend (quaternions
  multiplied). A property no action drives this frame keeps its value
  (three.js writes the original value back while an action is still
  bound).
- **AnimationUtils** is a class of static methods (`THREE.AnimationUtils.
  subclip(...)`; three.js exports a namespace object): `subclip`,
  `makeClipAdditive`, `getKeyframeOrder`, `sortedArray`, `flattenJSON`
  (keys as a `Dynamic` array), `convertArray` (to a Float32Array) and
  `isTypedArray`; the array helpers take `Array<f64>`. The functions are
  also module exports of `three/animation/AnimationUtils`.
- **AnimationObjectGroup** is an Object3D subclass so it can be a mixer's
  root (three.js types the root as either): never add it to a scene. Its
  `add`, `remove` and `uncache` take one object each and do not parent
  it; `stats.objects.total / inUse` and `stats.bindingsPerObject` as
  three.js. Tracks bind on each object (`PropertyBindingComposite`,
  three.js's `PropertyBinding.Composite`, made by `PropertyBinding.
  create`); the value's kind comes from the first object, so add objects
  before the first `clipAction`.
- `PropertyBinding` resolves `node.position|quaternion|scale|rotation|
  visible`, one component of them (`node.position[x]`, x/y/z/w or 0-3),
  `node.morphTargetInfluences[i|name]`, `node.material.color|opacity|
  emissive|emissiveIntensity|roughness|metalness` (`material[i]` for an
  entry of `mesh.materials`; colours also by `[r|g|b]`) and lights'
  `node.intensity|color`; nodes by name under the root (names cannot hold
  dots: `PropertyBinding.sanitizeNodeName`). No uuid paths, no arbitrary
  properties (there is no reflection). `isBoolean` / `isColor` /
  `isQuaternion` tell how a value blends. The static
  `PropertyBinding.findNode(root, nodeName)` is three.js's (the root, a
  skeleton bone, or a descendant by name or uuid); `parseTrackName` splits
  "node.bones[Arm].position" with `objectIndex` "Arm".
- `mixer.clipAction(clip)` takes an `AnimationClip` (not a clip name).
  Mixer events (`finished`, `loop`) are not dispatched: poll
  `action.isRunning()`, `action.enabled`, `action.paused`. Cross-fades
  ignore `warp`; `halt` and `warp` are not ported.

## Skinning and morph targets

- `Skeleton.calculateInverses()` (and `new Skeleton(bones)` without
  inverses) updates each bone's world matrix first; three.js inverts
  `matrixWorld` as it is. Pass the inverses to set them from matrices you
  wrote into `matrixWorld` yourself (FBXLoader does).
- GPU skinning: up to 256 bones from a uniform block, **bigger skeletons
  from a bone texture** (three.js's `boneTexture`, here rgba16float: each
  bone's three affine rows as half floats plus their half-float
  remainders, about 22 bits; three.js uses Float32). `Skeleton(bones:
  Array<Bone>, boneInverses)`; `skeleton.boneTexture` is not exposed.
- **Morph targets blend on the GPU** from a morph target texture, any
  number of targets, as three.js's WebGL2 path: the geometry's deltas
  (relative to the base, whatever `morphTargetsRelative` says) for
  positions and normals, as rgba16float texels (half floats: three.js
  stores Float32), rebuilt when a morph attribute's `version` changes.
  **Above 65536 texels the half-float conversion runs in a Rive job**
  (`three/renderers/gpu/MorphTexels`), started when the mesh is first
  collected and joined before the view's first pass, so it overlaps the
  rest of the frame and several geometries convert at once; a join that
  would pass the script call's budget leaves the texture zero (the mesh
  unmorphed) until a later frame. Every morphed or big-skinned mesh's
  MorphU block (the weighted targets) is packed into one shared uniform
  buffer per view at 256-byte offsets (group 1 binding 7 is a dynamic
  binding), taking the bytes it uses instead of 16 KB a mesh. A big
  skeleton's bone texture converts and uploads only the bones that moved.
  Only targets with a non-zero weight cost anything, at most 2044 of them
  at once (the rest are skipped). Morph colours are not read. A texture
  bigger than the device allows (`maxTextureSize2D` squared texels) falls
  back to blending on the CPU, with a log line.
- **InstancedMesh morphs**: `setMorphAt(index, mesh)` / `getMorphAt`,
  `morphTexture` (a FloatType RedFormat DataTexture, a row per instance:
  base influence, then the weights; uploaded as half floats) as three.js;
  set `morphTexture.needsUpdate = true` after changing it.
- **The vertex textures borrow extra map slots**: the morph texture takes
  extra slot 4, the bone texture slot 3 and an instanced morphTexture
  slot 2 (group 1 bindings 6, 5, 4; the web allows 16 textures a stage
  and the shader already declares 16). A morphed or big-skinned mesh's
  material keeps the other extra slots for its extra maps (see
  [Materials](#materials)); maps that do not fit are ignored with a log
  line. ShaderMaterials do not morph or skin.
- A SkinnedMesh is frustum culled only after `computeBoundingSphere()` (its
  posed bounds); otherwise it is always drawn.

## Loaders

- **`load(name)` is synchronous and reads Rive assets by name**: `new
  GLTFLoader(context).load("robot")` returns a `GLTF` (or null) from the
  BlobAsset `robot`, with no callbacks (three.js's `load(url, onLoad,
  onProgress, onError)`). Embedded images decode asynchronously; their
  textures fill in a few frames later. Import loaders from
  `three/addons/loaders/...`. Loaders take the Rive `Context` first:
  `new GLTFLoader(context, manager)`.
- **Urls load with `loadAsync`**, which returns a Rive `Promise`:
  `FileLoader`, `TextureLoader` and `GLTFLoader` fetch https: urls through
  `rive/net` `fetch` where the host allows the network (`rive . --allow-net`
  in the CLI; a host without it rejects with "disabled"), and fall back to
  the blob asset of that name. A `.gltf`'s external buffers and images load
  from beside it (or `resourcePath`); with `load(name)` they are blob assets
  named after the files without extension (`scene.bin` -> `scene`).
  `FileLoader.loadAsync` resolves with bytes, `loadTextAsync` with text
  (three.js picks by `responseType`).
- `LoadingManager` reports through a `LoadingManagerListener` (override
  `onStart`, `onProgress`, `onLoad`, `onError`) instead of callbacks;
  `setURLModifier` is `addURLRewrite(prefix, replacement)`. Progress is
  counted per file, as three.js.
- GLTFLoader reads `.glb`, and `.gltf` JSON whose buffers and images are
  base64 `data:` URIs (external files are not read: there are no URLs).
  Extensions read: KHR_lights_punctual, KHR_materials_unlit,
  emissive_strength, clearcoat, sheen, ior, specular, transmission, volume,
  iridescence, anisotropy, dispersion (with their textures),
  KHR_texture_transform, KHR_mesh_quantization, EXT_texture_webp,
  EXT_mesh_gpu_instancing (with `_COLOR_0`), EXT_meshopt_compression and
  KHR_draco_mesh_compression (`setDRACOLoader`); sparse accessors too. Not
  read: KTX2 / Basis textures
  (KHR_texture_basisu), KHR_materials_variants, TEXCOORD_2 and up (the
  renderer has two uv sets). A file that *requires* another extension
  fails (`loader.error`), as three.js throws. `gltf.parser`,
  `gltf.userData` and `extras` are not exposed.
- **The meshopt decoder is AnimaScript**, not WebAssembly:
  `three/addons/libs/meshopt_decoder` exports `MeshoptDecoder` for
  `setMeshoptDecoder`, as three.js's module. It reads the attribute codec
  version 0 (meshoptimizer's default for EXT_meshopt_compression), the
  triangle and index codecs and the three filters.
- **The Draco decoder is AnimaScript** (`three/addons/libs/draco`, Google's
  Draco 1.5.7 C++ decoder ported, Apache 2.0), not draco_decoder.js /
  .wasm in Web Workers. `three/addons/libs/draco/draco_decoder` exports the
  decoder's JavaScript API under its names (`Decoder` with
  `GetEncodedGeometryType`, `DecodeArrayToMesh`, `DecodeArrayToPointCloud`,
  `GetAttributeId`, `GetAttributeByUniqueId`, `GetTrianglesUInt32Array`,
  `GetAttributeFloatForAllPoints`, `GetAttributeDataArrayForAllPoints`;
  `Mesh`, `PointCloud`, `PointAttribute`, `Status`, the `POSITION` ... and
  `DT_*` constants), with no `destroy` (memory is managed) and metadata as
  `pointCloud.metadata` (a `GeometryMetadata` with `getEntryString`,
  `getEntryInt` ...) instead of a `MetadataQuerier`;
  `GetAttributeDataArrayForAllPoints` returns the values (a Float64Array,
  null when they do not fit the type) instead of filling a heap pointer.
  It reads bitstreams up to 2.2 (meshes) and 2.3 (point clouds), tested
  from 1.1 (Draco 0.9) on:
  sequential and Edgebreaker (standard, valence, predictive) connectivity,
  every attribute decoder, prediction scheme and transform, metadata, and
  sequential and kd-tree point clouds. Not read: kd-tree point clouds
  older than 2.3 (Draco 1.3), whose coders were not ported.
- **DRACOLoader** (`three/addons/loaders/DRACOLoader`, r170): `load(name)`
  decodes the BlobAsset at once and returns the BufferGeometry (or null,
  with `loader.error`), `loadAsync(url)` / `parseAsync(bytes)` return a
  `Promise<BufferGeometry>` and decode in a Rive job (`decodeDraco`, in
  place of the worker), `parse(buffer)` returns the geometry (three.js's
  `parse(buffer, onLoad, onError)`). `decodeDracoFile(buffer, attributeIDs,
  attributeTypes, vertexColorSpace)` returns the geometry instead of calling
  back; `attributeIDs` is a `Map<string, i32>` of unique ids (glTF's case;
  null reads attributes by type, `defaultAttributeIDs`), `attributeTypes` a
  `Map<string, string>` of typed array names. `decodeGeometry(buffer,
  taskConfig)` returns the job's promise; `DRACOTaskConfig` holds the task
  config as arrays (a Map does not cross to a job), with
  `attributeNormalized` for glTF's accessors. `setDecoderPath`,
  `setDecoderConfig`, `setWorkerLimit`, `preload` and `dispose` are kept
  and do nothing. **Attributes are Float32Arrays** (ThreeAS's
  BufferAttribute): an integer type converts, and where three.js keeps
  normalized integers (colours, normalized glTF accessors) they are scaled
  to [0, 1] (signed: [-1, 1]) and `normalized` stays false. A .drc's
  colours read as Float32Array (the default) are Draco's values (in [0, 1]
  only when the file flags them normalized), as three.js; read 8-bit ones as
  `Uint8Array` (`defaultAttributeTypes`) for [0, 1].
- **`loadAsync(name)` / `parseAsync(bytes)` return a Rive `Promise<GLTF>`**
  and decode in a Rive job (`decodeGLTF`: the container, meshopt views,
  Draco primitives and every accessor, handed back as one Float32Array and
  the Draco geometries); the scene is built on
  the main lane when the job is done. Images decode asynchronously either
  way. Await it in an `async` method, or use the promise's `andThen`. The
  scene's objects are still created in one main-lane call, and vertex data
  is uploaded from the decoded arrays (not from Blobs).
- `GLTFLoader`'s context is optional: without one, `parse` still builds
  the scene (no images; warnings in `loader.warnings`, the failure in
  `loader.error`).
- With anisotropy and neither tangents nor uvs, the tangent frame is any
  frame around the normal (three.js's derivative frame degenerates).
- **FBXLoader** (`three/addons/loaders/FBXLoader`, binary 6400+ and ASCII
  7000+, as three.js r170): `new FBXLoader(context).load(name)` returns
  the Group (or null, with `loader.error`; three.js throws) from the
  BlobAsset `name`; `parse(bytes, path)` too. `loadAsync(url)` /
  `parseAsync(bytes)` return a `Promise<Group>` and inflate a binary file's
  zlib arrays in a Rive job (`inflateFBX`, most of a binary parse); the
  scene is still built in one main-lane call, so files of several MB can
  pass a host's per-call budget. Clips are `object.animations`, as
  three.js. Warnings (three.js's console.warn) are in `loader.warnings`.
  `object.userData.unitScaleFactor` is `loader.unitScaleFactor`, and
  `userData.originalName` is `loader.originalNames.get(object.id)`;
  `transformData` and the FBX `ID` are not exposed.
- FBX textures: embedded Video content (PNG, JPEG) decodes into a
  DataTexture that fills in once decoded; a texture file is the image or
  blob asset named after it without folders or extension (`resourcePath`,
  else the `load` path, prefixes it), or, for a url load, fetched beside
  the file. Embedded BMP, TIFF and TGA are not decoded (Rive's decoder),
  and TGA, TIFF, EXR, DDS, HDR and KTX2 files give an empty placeholder
  texture, as three.js without a loader handler (LoadingManager has no
  `addHandler` here). Image-asset textures get `NoColorSpace`, as
  three.js's loaded textures (colour maps are then set to sRGB).
- FBX differences from three.js: IDs are exact 64-bit integers (three.js
  rounds them to doubles); a camera without AspectWidth/AspectHeight gets
  aspect 1 (three.js uses the window); a rotation curve node missing an
  axis gives no track, with a warning (three.js emits a one-value track
  that cannot play); the ASCII parser reads `Vector` properties as numbers
  (three.js keeps them strings, so a texture's Scaling / Translation read
  wrong there). The parsed tree is typed (`FBXTree`, `FBXNode`, `FBXValue`,
  `FBXProperty`) and walks objects in three.js's for-in order.
- OBJLoader ignores `mtllib` (.mtl files): materials are MeshPhongMaterials
  named after `usemtl`.
- **SVGLoader** (`three/addons/loaders/SVGLoader`, r170): `load(name)`
  reads a BlobAsset, `loadAsync(url)` fetches, `parse(text)` returns an
  `SVGResult` (`paths`, `xml`: the root element). **`paths` are
  `SVGShapePath`s**, ShapePaths with a typed `userData` (three.js sets an
  untyped one): `userData.node` (the XMLNode) and `userData.style`, an
  `SVGStyle` with three.js's fields (`fill`, `fillOpacity`, `fillRule`,
  `opacity`, `stroke`, `strokeOpacity`, `strokeWidth`, `strokeLineJoin`,
  `strokeLineCap`, `strokeMiterLimit`, `visibility`, plus `display` and
  getStrokeStyle's `strokeColor`). Fields three.js leaves undefined are ""
  (`fillRule`, `stroke`, `visibility`) or 1 (`opacity`): test
  `style.stroke != "" && style.stroke != "none"`. `createShapes`,
  `getStrokeStyle`, `pointsToStroke` and `pointsToStrokeWithBuffers` are
  static as three.js; the buffers are `Array<f64>?` (null: count only),
  grown as written, and the count is three.js's (3 per vertex).
- SVG parsing goes through **`three/addons/libs/dom_parser`** (AnimaScript
  has no DOM): `new DOMParser().parseFromString(text)` gives an XMLDocument
  of XMLNodes with the DOM calls loaders use (`nodeName`, `childNodes`,
  `getAttribute` returning null when missing, `getAttributeNS`,
  `textContent`, `getElementById`, `getElementsByTagName`,
  `viewportElement`), `node.style` (a CSSStyleDeclaration of the style
  attribute) and `node.sheet` (a <style> element's CSSStyleSheet). It reads
  comments, CDATA, processing instructions, the XML declaration, a DOCTYPE
  and its internal `<!ENTITY>`s; it recovers from malformed markup
  (`document.errors`) where a browser would give a `<parsererror>`.
- SVGLoader differences, all on input three.js mishandles or ignores:
  CSS element selectors (`rect { ... }`) apply, below class and id
  selectors (three.js reads only class and id rules); `<use>` takes SVG 2's
  `href` as well as `xlink:href` (and skips a reference to its own
  ancestor); `display` is kept in the style (filter on
  `style.display == "none"` as on `visibility`); polygon and polyline
  points are read as a number list (three.js's pattern drops pairs written
  "x, y"); commas between transforms are allowed; `use` with only one of
  `x` / `y` treats the other as 0 (three.js gets NaN); a malformed number
  list stops at the error instead of throwing, and an arc or `Z` with no
  current point starts one. `em` and `%` lengths read as plain numbers, as
  three.js's `parseFloatWithUnits`. **Rive-only `loader.applyViewBox`**
  (off by default, as three.js ignores viewBox) maps each `<svg>`'s
  viewBox onto its width and height with `preserveAspectRatio`.

## JSON: toJSON and ObjectLoader

- **`toJSON()` returns a `Dynamic`** (a `rive/dynamic` table of three.js's
  JSON shape, format 4.6), where three.js returns a plain object.
  AnimaScript has a JSON parser but no writer, so **`THREE.JSON.stringify(
  value, space = 0)`** writes the text (and `THREE.JSON.parse(text)` reads
  it, `JSON.lastError` saying why it failed): `THREE.JSON.stringify(
  scene.toJSON())` is three.js's `JSON.stringify(scene.toJSON())`. A table
  with string keys is written as an object, any other as an array (an empty
  one as `[]`; three.js leaves empty objects out). Non-finite numbers are
  written `null`, as JavaScript.
- `toJSON(meta)` takes a `JSONMeta` (the libraries three.js's `meta` object
  holds: geometries, materials, textures, images, shapes, skeletons,
  animations, nodes, keyed by uuid). Subclasses add their members through
  internal hooks (`toJSONObject`, `toJSONProperties`, `toJSONParameters`,
  `imageToJSON`) instead of overriding toJSON, so the shared resources are
  in `meta` before the root collects them. `BufferGeometry.toJSON(meta)`
  takes an optional meta (shape geometries put their shapes in it).
  `AnimationClip.toJSON(clip)` / `KeyframeTrack.toJSON(track)` are static as
  three.js; clips also have `toJSON()`; `AnimationClip.parse(json)` reads one.
- Written as three.js r170 writes them: Object3D (and Mesh, InstancedMesh,
  SkinnedMesh + Skeleton, Bone, Group, LOD, Line/LineLoop/LineSegments,
  Points, Sprite, Scene with background, environment and fog, cameras,
  every light with its shadow and target), materials (every property the
  class has; colours as hex, maps as texture uuids; ShaderMaterial adds
  `shader` and its entry points, the WGSL asset, beside `uniforms` and
  `lights`), textures, curves and shapes, clips. Differences:
  - The local matrix is brought up to date before it is written (three.js
    writes it as last updated).
  - Built-in geometries write their parameters (Box, Sphere, Plane,
    Cylinder, Cone, Torus, TorusKnot, Circle, Ring, Capsule, Lathe,
    Polyhedron and its presets, Shape, Extrude); `CapsuleGeometry` writes
    both r170's `length` and r174's `height` (and reads either). Every other
    geometry (Tube, Edges, Wireframe, Text, a transformed clone ...) is
    written as data with type "BufferGeometry", so three.js reads it too.
    Attributes are always "Float32Array" (they are f32 here), interleaved
    ones de-interleaved; an index is "Uint16Array" when it fits.
  - **Images**: Rive images cannot be read back, so a texture's image is
    what its `source` (three.js's `Source`, here the record of where the
    image came from) knows: `source.url` (a data: url, an https: url or the
    Rive image asset name, set by TextureLoader, CubeTextureLoader and
    ObjectLoader) or, for a DataTexture without one, its texels as
    `{ data, width, height, type }`. A texture from a canvas, an artboard
    or a render target has no image in the JSON. Image-backed textures
    write `premultiplyAlpha: false` (the file is straight alpha to
    three.js); here the flag means "the source is premultiplied", so
    ObjectLoader sets it for images Rive decodes.
  - Not written: BatchedMesh's batches (it loads as an Object3D), camera
    `view` offsets (setViewOffset is ported, not written), `blendSrc` & co. and the other material
    members this port does not have, `clippingPlanes` (as three.js).
- **`ObjectLoader(context, manager)`**: `load(name)` reads the BlobAsset
  `name` at once; `parse(json)` takes the text (a string) or a parsed
  `Dynamic` (a generic method); `loadAsync(url)` fetches an https: url
  (where the host allows the network; its relative images from beside it
  or `resourcePath`) or reads the blob asset, and `parseAsync(json)` /
  `loadAsync` resolve once every image has decoded. `parse` returns null on
  failure, with `loader.error`; problems met on the way (unknown types,
  missing references) are in `loader.warnings`. No callbacks.
  `parseShapes`, `parseGeometries`, `parseMaterials`, `parseAnimations`,
  `parseImages`, `parseTextures`, `parseObject`, `parseSkeletons`,
  `bindSkeletons`, `bindLightTargets` keep their names and return `Map`s
  by uuid (parseImages: `ObjectLoaderImage` records instead of Sources).
- Images in a document: base64 **data: urls** decode through
  `context.decodeImage` (the texture is a DataTexture filled a frame or so
  later); other urls name a **Rive image asset** (the url as is, then its
  file name without folders or extension: "textures/wood.png" -> "wood");
  https: urls load with `loadAsync` only; `{ data }` images become
  DataTextures. Cube textures read six image asset names. Without a
  Context nothing decodes (a warning, an empty texture).
- Geometries rebuild from their parameters by type (with pre-r125
  `*BufferGeometry` names), through `X.fromJSON(data)` (and
  `ShapeGeometry.fromJSON(data, shapes)`, `ExtrudeGeometry.fromJSON(data,
  shapes)`, with `extrudePath`); TubeGeometry, TextGeometry and other
  addon types are not rebuilt from parameters (data with any type is read
  as a BufferGeometry). `BufferGeometryLoader` reads integer arrays as
  floats, normalized ones scaled to [0, 1] / [-1, 1] (then `normalized` is
  false), and interleaved buffers (`arrayBuffers` words) de-interleaved.
  `MaterialLoader` makes every material class the project has (an unknown
  type is a MeshBasicMaterial, with a warning); a ShaderMaterial needs
  its WGSL `shader` in the file (GLSL `vertexShader` / `fragmentShader`
  cannot run here: a warning). Both loaders also take a string or a
  Dynamic, and load / loadAsync as ObjectLoader.
- Object types the loader does not know (helpers, BatchedMesh) load as
  Object3D with a warning, as three.js's default. A directional or spot
  light whose target is not in the document gets a new Object3D, as
  three.js. Meshes get `updateMorphTargets()`.
- `THREE.JSON.stringify` writes an empty table as `[]`; `emptyObject()`
  (`three/core/JSON`) makes a table written `{}` (it holds one key set to
  null, which the writer skips), for JSON whose empty objects matter.

## Exporters

- **GLTFExporter** (`three/addons/exporters/GLTFExporter`, r170) has no
  callbacks: **`parse(input, options)` returns a `GLTFExporterResult`**
  at once (three.js's `parse(input, onDone, onError, options)`): `glb`
  (the .glb bytes, an ArrayBuffer) with `binary`, else `json` (the .gltf
  text, its buffer and images as base64 data: URIs); `gltf` is the
  document as a Dynamic either way (three.js hands .gltf callers the JSON
  object). `parseAsync` returns a Rive `Promise`, already settled. What
  three.js throws or warns about (an image it cannot read, a morph target
  name not found, CUBICSPLINE morph tracks to merge, ShaderMaterials) is
  in `result.warnings`, the item left out.
- `input` is an `Object3D` or an `Array<Object3D>` (a generic method);
  `options` a `GLTFExporterOptions` (`{ binary: true, animations: [clip]
  }` works), not changed by the call.
- **Plugins are objects**: `register(plugin)` / `unregister(plugin)` take
  a `GLTFExporterPlugin` subclass overriding the hooks it needs
  (`beforeParse`, `writeNode`, `writeMesh`, `writeMaterial` for three.js's
  `writeMaterialAsync`, `writeTexture`, `afterParse`), with `writer` set
  to the parse's `GLTFWriter` (three.js registers `writer => plugin`
  factories). The built-in extensions are plugins in
  `exporter.pluginCallbacks`, in three.js's order. The writer is
  synchronous: `processTexture`, `processMaterial`, `processMesh`,
  `processNode` (three.js's `...Async`); `processAccessor(attribute,
  geometry, start, count)` takes a float attribute and returns -1 for
  three.js's null, indices go through `processIndexAccessor`;
  `extensionsUsed` / `extensionsRequired` are `Map<string, bool>`.
  `GLTFExporter.Utils` has `insertKeyframe` and `mergeMorphTargetTracks`
  (`toFloat32BufferAttribute` is not needed: attributes are f32).
- **Images are PNGs encoded by the exporter** (stored deflate blocks: not
  compressed, so large) from the pixels a texture holds: a DataTexture in
  RGBA8 (premultiplied ones are divided by alpha), which is what
  GLTFLoader's textures are once their images have decoded. JPEG is never
  written (`userData.mimeType` is ignored). A texture with no pixels whose
  `source.url` is a base64 data: url is written from that url, in its own
  format. Rive images, canvases, artboards, render targets and compressed
  textures cannot be read back and are left out, with a warning (three.js
  draws images into a canvas, and decompresses through
  `setTextureUtils`, not ported). `maxTextureSize` scales larger images
  down (nearest; three.js crops DataTextures). Separate metalness and
  roughness maps are merged into one texture when both are RGBA8
  DataTextures (nearest scaling), else the one there is written alone.
- Attributes are f32 here, so accessors are FLOAT, except JOINTS_0
  (UNSIGNED_SHORT) and indices (UNSIGNED_SHORT when every index fits,
  else UNSIGNED_INT); KHR_mesh_quantization is never written. Node
  matrices are written with f32 precision as short decimals. Morph tracks
  may name targets by index (`morphTargetInfluences[1]`, as GLTFLoader
  here names them) as well as by name. `_COLOR_0` of
  EXT_mesh_gpu_instancing holds the `count` drawn instances' colours (as
  the other instance attributes; three.js writes the whole attribute). A
  .glb without binary data has no BIN chunk (three.js writes an empty
  one).

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
- `Uniform.clone()` is UniformsUtils.clone per uniform.
- The other passes (M12) are three.js r170's, with its constructors,
  fields, defaults and `OUTPUT` values, and their shaders are
  ShaderDefinitions, one file per three.js shader file in
  `three/addons/shaders/` (SMAAShader, SSAOShader, SAOShader,
  DepthLimitedBlurShader, GTAOShader, PoissonDenoiseShader, BokehShader,
  AfterimageShader, FilmShader, DigitalGlitch, DotScreenShader,
  HalftoneShader; LUTPass's, OutlinePass's and RenderPixelatedPass's stay in
  their pass files, as three.js). What changes everywhere:
  - **`defines` are uniforms or WGSL constants** (Rive pipelines take no
    overridable constants); boolean and integer uniforms are numbers (0 or
    1: FilmShader `grayscale`, DigitalGlitch `byp`, HalftoneShader
    `greyscale` / `disable`); `PERSPECTIVE_CAMERA` is a `perspective`
    uniform. three.js's uniform arrays are `Uniform<Float32Array>` (WGSL
    `array<vec4<f32>, N>`).
  - Depth is always a `DepthTexture` read with `textureLoad`, never
    RGBA-packed (DepthLimitedBlur supports `DEPTH_PACKING` 0 only; GTAO and
    the Poisson denoise read depth from x only, no `DEPTH_SWIZZLING`).
  - A shader's textures share one sampler (the first texture's): textures
    that need another filter or wrapping are read with `textureLoad` and
    wrapped by hand (noise textures, SMAA's search texture, the glitch
    heightmap). SSAODepthShader and GTAODepthShader have an unused
    `tDiffuse` so their sampler pairs with a colour texture.
  - New HalfFloat targets start undefined (WebGL zero-fills them), so
    passes that keep history clear it first (AfterimagePass, SMAA's stages).
  - `OutputPass` clamps alpha to 1 before un-premultiplying: additive passes
    that sum alpha (a bloom mix, the bloom blend) no longer brighten the
    result (three.js ignores alpha there).
- **SMAAPass(width, height)**: three.js's SMAA 1x stages in its GL texture
  coordinates; `SMAA_THRESHOLD` and the search and area constants are WGSL
  constants. The area and search textures are three.js's texels, stored in
  `SMAATextures.as` as zlib-compressed bytes (RG8 and R8 DataTextures,
  `flipY` false) and inflated when the pass is made (decoding three.js's
  PNGs takes longer than a script call's budget). `round` rounds halves away
  from zero, as GLSL on GPUs.
- **SSAARenderPass(scene, camera, clearColor, clearAlpha)**: `clearColor`
  is a hex number; `sampleLevel` (0 to 5, default 4: 16 renders a frame),
  `unbiased`, jitter by `camera.setViewOffset` (an earlier view offset is
  restored), additive accumulation into HalfFloat targets; `stencilBuffer`
  is ignored. Each sample is a full render, shadow maps included.
  **TAARenderPass** as three.js (`accumulate`, `accumulateIndex`,
  2^`sampleLevel` of 32 samples a frame); as the last pass its accumulating
  path renders to the screen, and `setSize` restarts accumulation.
- **SSAOPass, SAOPass, GTAOPass**: as three.js, a MeshNormalMaterial
  prepass into a HalfFloatType target with a DepthTexture (points and lines
  hidden for SSAO and GTAO), and the occlusion multiplied onto the read
  buffer (put a RenderPass first; three.js's CustomBlending DstColor copies
  are MultiplyBlending). The camera's projection, near and far are re-read
  every render. SSAO's `kernelSize` is at most 32, DepthLimitedBlur's
  `kernelRadius` 64 (`saoBlurRadius` is clamped), Poisson denoise `samples`
  32; `generatePdSamplePointInitializer` returns the sample floats (the
  `poissonDisk` uniform) instead of GLSL. SimplexNoise is not ported: the
  rotation and denoise noise textures are uniform random values (random
  noise either way). `SAOPass.params` is a typed `SAOPassParams`;
  `updateGtaoMaterial(GTAOParameters)` and
  `updatePdMaterial(PoissonDenoiseParameters)` take typed objects where NaN
  (or -1 for `samples`) means "leave as is"; GTAO's constructor
  `parameters` is a `GTAOPassParameters`. `GTAOPass.setGBuffer(depth,
  normals)` takes a DepthTexture and optional packed view normals (an
  attachment of a multiple render target works); without normals they are
  rebuilt from depth.
- **OutlinePass(resolution, scene, camera, selectedObjects)**: three.js's
  stages and parameters (`visibleEdgeColor`, `hiddenEdgeColor`,
  `edgeStrength`, `edgeThickness`, `edgeGlow`, `pulsePeriod`,
  `usePatternTexture` / `patternTexture`, `downSampleRatio`). The other
  objects' depth is a DepthTexture read at the mask's own pixel
  (`textureMatrix` unused); selected meshes are drawn instanced but not
  skinned or morphed; the pulse follows the accumulated `deltaTime`; the
  overlay's additive blend is done in the shader.
- **BokehPass(scene, camera, params)**: a `BokehPassParameters` (focus 1,
  aperture 0.025, maxblur 1); depth from a MeshDepthMaterial render whose
  DepthTexture the shader reads. **AfterimagePass(damp)**,
  **FilmPass(intensity, grayscale)**, **DotScreenPass(center, angle,
  scale)** (a null center is (0.5, 0.5)) and **GlitchPass(dt_size)**
  (counts frames, as three.js; its heightmap is a float DataTexture) as
  three.js. DotScreen thresholds colour, so tone mapping whitens it: put it
  after the OutputPass.
- **HalftonePass(width, height, params)** takes a `HalftonePassParameters`.
  **LUTPass(params)** takes a `LUTPassParameters` (`lut`, a Data3DTexture
  sampled as a `texture_3d`, and `intensity`); without the `texture3D`
  feature, or while `lut` is null, it copies its input (three.js samples a
  null LUT as black). **LUTCubeLoader / LUT3dlLoader**: `load(name)` reads
  a BlobAsset, `loadAsync(url)` fetches, `parse(text)`, `setType`; they
  return a `LUTCubeResult` (`title` "" where three.js has null, `size`,
  `domainMin`, `domainMax`, `texture3D`) or a `LUT3dlResult`, or null with
  `loader.error` on a malformed file (three.js throws).
- **RenderPixelatedPass(pixelSize, scene, camera, options)** as three.js;
  an explicit 0 in `RenderPixelatedPassOptions` stays 0 (three.js's `||`
  turns it into the default). **TexturePass(map, opacity)** decodes what the
  texture holds (sRGB, premultiplied, flipY) before drawing over the
  composer's linear buffer (three.js lets the texture format decode sRGB).
  **ClearPass(clearColor, clearAlpha)** takes a hex colour.
- **MaskPass / ClearMaskPass are emulated without stencil** (stencil does
  not survive Rive passes): MaskPass renders its scene in white into its own
  `maskTarget` (`inverse` and `clear` as three.js), and while a mask is
  active EffectComposer restores, outside the mask, what each pass changed,
  with a shader that discards inside it: a swapping pass gets the read
  buffer drawn back into its write buffer (three.js's NOTEQUAL copy), a
  non-swapping pass (RenderPass, TexturePass, ClearPass) has its buffer
  backed up first and restored. Passes rendering to the screen are not
  masked (end with a copy, as the Effects example does); the mask is
  binary; each masked pass costs one or two fullscreen draws.
  `EffectComposer.maskActiveAfter(pass, active)` is three.js's `instanceof
  MaskPass / ClearMaskPass` step.
- **Selective bloom** works as three.js's example (a second composer with
  `renderToScreen = false`, the other objects' materials swapped to black,
  a mix ShaderPass): see the gallery's `examples/effects/effects.as` and
  `examples/effects/bloom_mix.wgsl`.

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

### 2D overlays (CSS2DRenderer / CSS3DRenderer)

three.js's CSS renderers place DOM elements over the canvas; here Rive
artboards are drawn over it by the script's 2D renderer, in
`three/rive/ArtboardOverlay`:

| three.js | ThreeAS |
|---|---|
| `CSS2DRenderer` / `CSS3DRenderer` | one `ArtboardOverlayRenderer` for both: `setSize`, `getSize`, `render(scene, camera)` places, `draw(renderer)` paints (from the script's `draw`, after `present`), `advance(seconds)`, `pointerDown/Move/Up/Exit(event)`; or set it as ThreeLayout's `overlay` |
| `CSS2DObject(element)`, `center` | `Artboard2DObject(artboard)` (instanced unless `instance = false`), `center` the same; `screenScale` sizes it |
| `CSS3DObject(element)` | `Artboard3DObject(artboard)`: one artboard unit per world unit in the object's XY plane |
| `CSS3DSprite(element)` | `Artboard3DSprite(artboard)`, `rotation2D` for the screen-plane rotation |
| `element.style.zIndex` by distance | `sortObjects` (near on top), `objects` lists them far to near |
| `renderer.domElement` | none: the artboards draw into the layout |

- **Rive's renderer draws affine 2D transforms only**, so an
  Artboard3DObject seen in perspective is drawn with the affine map through
  three of its projected corners (exact for orthographic cameras, close
  for small or distant objects); one with a corner behind the camera is
  hidden. CSS3D's perspective is exact.
- **Occlusion (not in three.js)**: `occlude` on an object fades it to
  `occludedOpacity` while a visible mesh lies between the camera and its
  position (a raycast against `renderer.occluders`, the scene by default,
  stopping `occlusionBias` short of the object, ending at the first hit
  and skipping hidden subtrees; set `occluders` to a smaller group of big
  meshes for crowded scenes). Rive scripts cannot read
  the depth buffer back; for per-pixel depth, draw the artboard as an
  ArtboardTexture on a Sprite instead.
- Pointer events go to the topmost interactive object whose artboard bounds
  contain the point, in its artboard's coordinates; a press an artboard
  took keeps its moves and release. `opacity`, `interactive` and
  `autoAdvance` (off when something else advances a shared instance) are
  per object. Objects are placed from the last `render` (ThreeLayout
  renders them in `advance`, so headless pointer tests hit them).

### Data binding (SceneBindings)

`three/rive/SceneBindings` binds scene properties to Rive view model
properties, so a state machine, a timeline (through a bind written back
with `direction="true"`), a listener, the host or the editor drives the
scene, and the scene can write Rive UI:

- `new SceneBindings(root, viewModel)`; `bind(property, path, direction =
  BindBoth, scale = 1, offset = 0)` with a PropertyBinding path
  ("Lamp.intensity", "Cube.position[y]", "Car.material.color",
  "Lamp.visible", "Face.morphTargetInfluences[smile]" ...) or
  "@action.field" for an action named with `addAction(name, action)`
  (fields `weight`, `time`, `timeScale`, `paused`, `enabled`, `running`,
  and the triggers `play`, `stop`); `bindAction(property, action, field)`,
  `bindTarget(property, SceneBindingTarget)` for anything else (subclass
  it: no closures), `unbind`, `setViewModel`, `errors` (what did not
  resolve).
- Directions: `BindToScene` (the view model drives), `BindToViewModel`
  (the scene writes), `BindBoth` (whichever changed since the last
  `update()` wins; the view model on the first). Numbers map as `scene =
  viewModel x scale + offset`; colours convert sRGB to linear; booleans
  are 0 / 1; a trigger fires the target (plays an action, toggles a
  boolean). The view model property's own kind picks the conversion (a
  number or boolean for one value, a colour for a colour path).
- **A spec string**: `parse("lamp -> Lamp.intensity * 0.03; height <-
  Crate.position[y]; tint <-> Car.material.color")` (`->` to the scene,
  `<-` to the view model, `<->` or `=` both; lines or `;`; `#` comments).
  `SceneBindings.fromViewModel(root, vm)` reads the view model's
  `threeBindings` string (`BINDINGS_PROPERTY`) at the first update and
  again when it changes, an action is added or `refresh()` is called:
  edit the string in the Rive editor to rewire the scene without code.
- Polling, not listeners: `update()` compares values each frame (ThreeLayout
  calls it after `animate`). View model properties cannot be enumerated
  from a script, so bindings name them.

### Rive-driven animation

`three/rive/RiveRig` retargets a Rive artboard's bones and nodes onto
three.js objects:

- `new RiveRig(artboard)` (an artboard input, instanced), `unitsPerPixel`
  (0.01), `axis` (Rive's clockwise rotation about -Z in a y-up XY plane);
  `map(name, object, mode)`, `mapSkeleton(skeleton, prefix)` (bones by
  name), `mappingOf(object)`; per mapping `position` / `rotation` /
  `scale` switches and `captureRest()`.
- `RiveRig.RELATIVE` (default) applies the node's change from its pose
  when mapped onto the object's own rest pose (a 3D skeleton modelled in
  another pose follows the 2D rig's motion); `RiveRig.ABSOLUTE` copies
  the local transform as `copyNodeTransform`.
- `advance(seconds)` advances the artboard (its state machine, or a
  timeline started with `play(name)`, looping with `loop`) and poses the
  objects; `apply()` poses them as the artboard stands.
- `bake(name, fps)` samples a timeline into a three.js `AnimationClip`
  (position, quaternion and scale tracks named after the mapped objects),
  to blend, cross-fade or play on copies with the mixer.
- **Limits of Rive's scripting API**: nodes and bones are found only by
  name (`artboard.node(name)`; exported names) and cannot be listed or
  typed (bone or node); a bone's length, a mesh's vertices and skin
  weights, and a timeline's keyframes cannot be read (`bake` samples by
  setting the time); a timeline played by hand is overridden by a default
  state machine keying the same properties (give the rig artboard an empty
  state machine, as RiveDrivenRig does); a script cannot reach the
  artboard it is attached to, so the rig is an artboard input. Rive's
  meshes and skins therefore cannot become three.js geometry: only the
  bones' motion transfers.

### Other

- `ArtboardTexture(artboard, width = 0, height = 0)`: a live artboard as a
  texture. Call `texture.advance(seconds)` from the script's `advance`; it
  redraws only after a change. `texture.artboard` is the instance.
- `Color.alphaOf(argb)` and `color.getRiveColor(alpha)` convert to Rive
  colours; `setHex` accepts a Rive `Color` (alpha ignored), so `Color` script
  inputs plug straight in.

## Not yet supported

Missing so far, planned in [../PLAN.md](../PLAN.md):
no milestone is open. Left from M14: publishing (`--publish=web`, the
library to the Rive community) and a measured comparison with three.js in a
browser (the method is in [PERFORMANCE.md](PERFORMANCE.md)).
