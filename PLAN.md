# ThreeAS plan

ThreeAS ports the three.js API to Rive: scenes are written in AnimaScript,
rendered with Rive's `GPUCanvas` (WebGPU-style passes and WGSL shaders), and
composited into the artboard like any other drawing.

## Principles

1. **Keep three.js signatures.** A three.js snippet should port by adding
   types and swapping `new WebGLRenderer()` for `new GPURenderer(context)`.
   AnimaScript has no unions or overloads, so three.js "number or vector"
   parameters become generic methods (`lookAt<T>(x: T, y, z)`), and
   parameter objects become typed classes filled by object literals
   (`new MeshStandardMaterial({ color: 0xff8800, roughness: 0.4 })`).
2. **Use Rive where Rive already has it.** `Matrix4` is backed by
   `rive/mat4`'s `Mat4` (projection, multiply and invert run there);
   `Texture.image` is a Rive `Image` (`context.image(name)`);
   `CanvasTexture` wraps a Rive 2D `Canvas`; time comes from `advance`;
   input comes from Rive pointer events; `Color.setHex` accepts a Rive
   `Color` (`0xAARRGGBB`, alpha ignored) so script inputs plug straight in.
3. **Rive-only helpers live in `three/rive/`**: things three.js cannot have,
   such as an artboard as a live texture.
4. **Same coordinate system as three.js**: right handed, Y up, cameras look
   down -Z, radians, linear working colour space, sRGB output. The one
   difference: projection matrices map depth to [0, 1] (WebGPU), as three.js
   does with `WebGPUCoordinateSystem`.

## Layout

Two Rive CLI projects (see README.md); the root holds docs/ and tools/.

```
packages/threeas/   the engine, published as the Rive library "threeas"
  three/            the library (no protocol classes; import "three/Three",
                    from another project "lib:threeas/three/Three")
    Three.as        re-exports everything: import * as THREE from "../three/Three"
    constants.as    three.js's constants
    math/ core/ objects/ scenes/ cameras/ lights/ materials/ geometries/
    textures/ loaders/ animation/ extras/ audio/
                    as three.js's src/
    renderers/      GPURenderer, RenderTarget (+ gpu/ internals)
    rive/           Rive-only: ArtboardTexture, ThreeLayout, Rive paths/nodes
    shaders/        WGSL (three.wgsl, mips, post/)
    addons/         three.js's examples/jsm ports, imported by path:
                    controls/, loaders/, postprocessing/, shaders/
  tests/            rive --test suites, fixtures/
packages/gallery/   the gallery page and the example artboards
  gallery/          the landing page (gallery.rml, make_gallery.py)
  examples/<name>/  one example each (<name>.as, <name>.rml, its assets)
tools/              cross-package scripts (publish, bench, screenshots, ...)
docs/               DEVIATIONS.md, screenshots
```

## Milestones

### M1: first scene (done)

Goal: the classic three.js "rotating cube" running in Rive, with a live
Rive artboard as the cube's texture.

- Math: Vector2, Vector3, Vector4, Quaternion, Euler, Matrix3, Matrix4
  (on `Mat4`), Color, MathUtils.
- Core: Object3D (hierarchy, transforms, lookAt, traverse), BufferAttribute,
  BufferGeometry (attributes, index, transforms, computeVertexNormals).
- Scene, Group, Mesh; PerspectiveCamera, OrthographicCamera.
- Geometries: BoxGeometry, PlaneGeometry, SphereGeometry.
- Materials: MeshBasicMaterial, MeshNormalMaterial, MeshLambertMaterial,
  MeshStandardMaterial (metal/roughness GGX, as three.js), with `map`,
  `side`, `transparent`, `opacity`, `depthTest`, `depthWrite`.
- Lights: AmbientLight, DirectionalLight, PointLight (three.js physical
  intensities and distance falloff), up to 8.
- Textures: Texture (from a Rive `Image`), DataTexture (raw RGBA8),
  CanvasTexture (a Rive `Canvas`), TextureLoader (image assets by name).
- `GPURenderer`: `setSize`, `setPixelRatio`, `setClearColor`, `render(scene,
  camera)`, `present(renderer)`, MSAA (`antialias`), depth, opaque then
  sorted transparent draws, sRGB output, premultiplied compositing.
- Rive: `ArtboardTexture` draws an artboard instance into a canvas and feeds
  it to a material; redrawn only after an advance changed it.
- Example `FirstScene`: lit, rotating cube textured with an animated
  artboard, on a procedural checker floor.
- Example `HelloCube`: three.js's "Creating a scene" tutorial, ported.
- Tests: math round trips (compose/decompose, invert, Euler/Quaternion),
  colours, geometry counts.

### M2: breadth of the core API

In steps, each committed with tests and a screenshot check:

- **M2a, bounds and culling (done).** Math: Box3, Sphere, Plane, Ray, Line3,
  Triangle, Frustum, Spherical, Cylindrical. `computeBoundingBox` /
  `computeBoundingSphere`, Layers, frustum culling in the renderer.
- **M2b, geometries (done).** Circle, Ring, Cylinder, Cone, Torus, TorusKnot,
  Capsule, Lathe, Polyhedron/Icosahedron/Octahedron/Tetrahedron/
  Dodecahedron, EdgesGeometry, WireframeGeometry.
- **M2c, shading (done; tone mapping from M5 came along).** Geometry groups with material arrays, vertexColors,
  MeshPhongMaterial, MeshToonMaterial, MeshMatcapMaterial,
  MeshDepthMaterial; `normalMap`, `roughnessMap`, `metalnessMap`, `aoMap`,
  `emissiveMap`, `alphaMap`; SpotLight, HemisphereLight; Fog, FogExp2;
  background texture; mipmap generation and anisotropy.
- **M2d, other primitives (done).** Line, LineSegments, LineLoop, Points, Sprite,
  InstancedMesh, LOD; LineBasicMaterial, LineDashedMaterial,
  PointsMaterial, SpriteMaterial; `wireframe`.
- **M2e, curves and shapes (done).** Curves (2D and 3D, CatmullRomCurve3,
  Béziers, ellipses, splines), CurvePath/Path/Shape/ShapePath, Earcut,
  ShapeGeometry, ExtrudeGeometry (bevels, path extrusion), TubeGeometry,
  and Rive `Path`s as shapes. (MeshPhysicalMaterial came in M2c; cube
  textures moved to M5, uniform chunks with dynamic offsets to M6;
  RectAreaLight dropped: it needs three.js's LTC lookup tables.)

### M3: Rive integration (done)

- `ThreeLayout`: lifecycle, resize, pixel ratio, present, controls and
  pointer forwarding handled; scripts override `setup` and `animate`.
- Raycaster (meshes with groups, instances, lines, points, sprites) on Rive
  pointer events; `ArtboardTexture` takes pointer events at the hit UV, so
  artboard UIs on 3D surfaces are interactive (clicks reach their state
  machines).
- OrbitControls and MapControls on Rive pointer and scroll events (one
  pointer rotates or pans, two pinch and pan, the wheel zooms).
- `RenderTarget` (WebGLRenderTarget): render to a texture, use it as a map,
  or draw its Rive `Image` in 2D.
- `Clock` / `Timer` fed by `advance`; `copyNodeTransform` drives objects
  from animated Rive nodes. Script inputs drive the scene directly (any
  `@input` field read in `animate`).
- Publishing as a Rive library is documented in the README (it needs a
  Rive account: `rive login`, `rive library publish`), not done from here.
- Not ported: TrackballControls, FlyControls, PointerLockControls,
  TransformControls, DragControls.

### M4: assets and animation (done)

- Animation: KeyframeTracks (number, vector, quaternion, colour, boolean;
  discrete, linear, smooth, glTF cubic spline), AnimationClip,
  PropertyBinding, AnimationMixer/AnimationAction (weights, loops, fades,
  cross-fades).
- SkinnedMesh, Skeleton, Bone (GPU skinning, 256 bones); morph targets
  (CPU blended).
- GLTFLoader from a BlobAsset (.glb): hierarchy, meshes, PBR materials and
  extensions, embedded textures, skins, morphs, animations, cameras,
  KHR_lights_punctual. A generated sample (tools/make_sample_glb.py).
- OBJLoader. (ObjectLoader dropped: three.js JSON scenes are rare in Rive
  projects.) meshopt/Draco/KTX2 decoding are left for later.

### M5: lighting quality (done)

- Shadows: directional, spot and point (six faces) shadow maps in a depth
  array texture, Basic/PCF/PCFSoft filtering, bias, normalBias, radius,
  intensity.
- Environment: equirectangular `scene.environment` / `envMap` lighting with
  three.js's IBL maths over the map's mip chain (not a GGX-prefiltered
  PMREM), environmentIntensity/Rotation, PMREMGenerator shim.
- Tone mapping (came in M2c).
- ShaderMaterial / RawShaderMaterial with WGSL shader assets and typed
  uniforms.
- Later: cube textures and cube environment maps, a real PMREM (GGX
  prefiltering pass), alpha-tested shadows.

### M6: post-processing and performance (done)

- (M6a, done) EffectComposer with RenderPass, ShaderPass, UnrealBloomPass,
  OutputPass, FXAAPass over HalfFloat (rgba16float) render targets. Later:
  SMAA, SSAO, bokeh.
- (M6b, done) Per-object blocks in one uniform buffer bound at dynamic
  offsets (one upload per draw list), redundant vertex/index/material binds
  skipped, InstancedMesh matrices uploaded as is (colours in their own
  buffer). The Benchmark artboard (1000 meshes, 10000 moving instances,
  interpreter tier) went from 6.1 ms to 4.2 ms of render script time:
  `rive . --artboard=Benchmark --bench=300`.
- Later: BatchedMesh; skipping unchanged object blocks; geometry uploads
  from `Blob`s (GPUBuffer.fromBlob) in the loaders; comparing against
  three.js in a browser; validating `--gpu-manifest` output with Rive's
  WebGPU validator (not installed here) before `--publish=web`.

### Coming next

Each milestone is split into steps committed one at a time, each with its
tests, an example artboard (or an addition to one), a screenshot check and
docs/DEVIATIONS.md updated. The Rive APIs each one relies on are named, so
a step can start by checking them (`rive docs animascript/api/<module>`).

### M7: textures and environments (done)

Goal: environments and textures as three.js has them, so glTF scenes and
three.js lighting setups look the same.

- **M7a, per-map sampling (done).** Every map its own sampler and UV transform
  (`offset`, `repeat`, `rotation`, `center`, `wrapS/T`, filters) and
  `channel` (uv, uv1, uv2), as three.js's `*MapTransform` uniforms; the
  "one sampler per material" deviation goes away.
- **M7b, cube textures (done).** CubeTexture, CubeTextureLoader (six image
  assets), cube backgrounds and `envMap`s, `CubeReflectionMapping` /
  `CubeRefractionMapping`; WebGLCubeRenderTarget and CubeCamera (six passes
  into a cube texture: `TextureType.cube`).
- **M7c, a real PMREM (done; an equirectangular GGX mip chain rather
  than three.js's cube-UV atlas).** PMREMGenerator ported (cube-UV layout, GGX
  importance-sampled blur passes): `fromEquirectangular`, `fromCubemap`,
  `fromScene`; RoomEnvironment (addon). Rough reflections then match
  three.js; the mip-chain approximation goes away.
- **M7d, HDR and data textures (done).** Float/half-float DataTexture
  (both upload as `rgba16float`), RGBELoader / HDRLoader (Radiance .hdr
  from a BlobAsset) and EXRLoader (NO/RLE/ZIPS/ZIP; PIZ later),
  DataArrayTexture, Data3DTexture. DepthTexture moved to M12b.
- **M7e, compressed textures (done; no Basis transcoding).** CompressedTexture with BC, ETC2 and ASTC
  (Rive's `bc` / `etc2` / `astc` features), KTX2Loader for KTX2 files that
  hold those formats directly (Basis transcoding later, if feasible in a
  job). Since: a CPU decoding fallback (BC1-5, BC7, ETC1/2, EAC, ASTC LDR
  in every footprint, in a job for large textures) for devices without the
  format, browsers included.
- Examples `Environments` (cube, .hdr and .exr environments, a roughness
  sweep, CubeCamera reflections) and `Textures` (uv transforms, uv1, KTX2).

### M8: materials completeness (done)

Goal: every three.js material option, so ported scenes and glTF assets
render as authored.

- **M8a, more maps (done).** `bumpMap`, `displacementMap` (vertex stage),
  `lightMap`, `specularMap`, object-space normal maps (`normalMapType`),
  the `tangent` attribute (and `computeTangents`), Lambert/Phong `envMap`
  with `combine`, `reflectivity`, `refractionRatio`; clearcoat reflecting
  the environment; the physical maps (clearcoat, sheen, specular,
  iridescence).
- **M8b, physical extensions (done).** MeshPhysicalMaterial `transmission`,
  `thickness`, `attenuationColor/Distance` (the opaque scene rendered to a
  mipmapped transmission target first, as three.js), `iridescence`,
  `anisotropy`, `dispersion`.
- **M8c, clipping and stencil (done).** `renderer.clippingPlanes`,
  `localClippingEnabled`, `material.clippingPlanes`, `clipIntersection`,
  `clipShadows`; material stencil state (`stencilWrite`, `stencilFunc`,
  `stencilRef`, masks and ops) on Rive's stencil pipelines.
- **M8d, shadow and alpha options (done; alphaToCoverage as alphaHash).** ShadowMaterial, MeshDistanceMaterial,
  alpha-tested shadows and `customDepthMaterial` /
  `customDistanceMaterial`, `shadowSide`, `alphaHash`, `alphaToCoverage`.
- **M8e, shader material reach (done; no `defines`: Rive has no
  pipeline-overridable constants).** A WGSL chunk library (three.js's
  ShaderChunk counterpart: lights, fog, tone mapping, colour space
  functions) ShaderMaterials can reuse, `lights: true` / `fog: true`
  support, and `defines` as WGSL pipeline-overridable constants if Rive
  exposes them.
- Example `MaterialsPlus`: glass, iridescent and anisotropic spheres, a
  clipped and capped model (stencil), bump and displacement.

### M9: lighting at scale (done)

- **M9a, many lights (done: 32 a render, 31 per draw, culled by range).** Lift the 8-light cap (light data in a storage or
  larger uniform buffer, per-object light lists or clustered lighting).
- **M9b, area and probe lights (done; LTC tables at 32 x 32; probes from
  equirectangular data).** RectAreaLight with three.js's LTC tables
  shipped as a blob asset (RectAreaLightUniformsLib), LightProbe,
  SphericalHarmonics3, LightProbeGenerator, HemisphereLightProbe.
- **M9c, shadows at scale (done: 24 layers in a 64 MB budget, CSM; real
  VSM and SpotLight.map left out, see DEVIATIONS).** More than 12 shadow layers (atlas sizing per
  light), CSM (cascaded shadow maps addon), real VSM, spot light `map`
  (projected textures, three.js r162+).
- Example `Lights`: a night street of point and area lights with cascaded
  sun shadows.

### M10: scene tools (done)

Goal: the helpers, utilities and controls that three.js examples lean on.

- **M10a, helpers (done).** AxesHelper, GridHelper, PolarGridHelper, BoxHelper,
  Box3Helper, PlaneHelper, ArrowHelper, CameraHelper,
  Directional/Point/Spot/HemisphereLightHelper, SkeletonHelper,
  VertexNormalsHelper (addon).
- **M10b, object and geometry utilities (done; events take listener objects).** Deep `Object3D.clone/copy`,
  `BufferGeometry.clone/copy/toNonIndexed`, InterleavedBuffer and
  InterleavedBufferAttribute, EventDispatcher with typed events (`change`
  on controls, `added`/`removed`, `dispose`), BufferGeometryUtils
  (`mergeGeometries`, `mergeVertices`, `computeMikkTSpaceTangents`),
  SceneUtils, SkeletonUtils (`clone`, `retarget`).
- **M10c, more geometries (done; TeapotGeometry left out).** RoundedBoxGeometry, ParametricGeometry,
  ConvexGeometry (ConvexHull), DecalGeometry, TeapotGeometry, and
  TextGeometry: FontLoader's typeface JSON, plus Rive-only text from a Rive
  `Font`'s glyph outlines (`rive/text`).
- **M10d, wide lines (done; no worldUnits).** Line2, LineSegments2, LineMaterial, LineGeometry
  (screen-space quads with width in pixels or world units, dashes), so
  lines need not be one pixel wide.
- **M10e, more controls (done; ArcballControls left out).** TrackballControls, ArcballControls,
  FlyControls, FirstPersonControls, DragControls, TransformControls (with
  its gizmo), on Rive pointer events (PointerLockControls has no Rive
  counterpart).
- **M10f, BatchedMesh (done).** Many geometries in one draw (per-instance
  geometry ranges, visibility, matrices and colours), with its
  `optimize` and sorting.
- Examples `Editor` (TransformControls, helpers, wide lines, addon
  geometry) and `Batched` (600 instances of four geometries).

### M11: loaders and formats (done)

- **M11a, glTF breadth (done; Draco, Basis and variants left out).** KHR_texture_transform, KHR_materials_*
  (transmission, volume, ior, specular, iridescence, anisotropy,
  emissive_strength, dispersion, unlit), KHR_mesh_quantization, sparse
  accessors, multiple UV sets, texture samplers per texture,
  EXT_meshopt_compression (meshopt decoder ported to AnimaScript).
  Draco and Basis later (decoder size and speed to be measured).
- **M11b, loading off the main lane (done: decoding in a job; Blob
  uploads left for later).** Parsing and decoding in Rive jobs
  (`rive/jobs`), vertex and index buffers created from Blobs
  (`GPUBuffer.fromBlob`), `loadAsync` returning a Rive `Promise`, so big
  models stay within the init budget and never stall a frame.
- **M11c, URLs (done).** `load(url)` through `rive/net` `fetch` where the host
  allows it (LoadingManager, `setPath`, progress callbacks as a listener
  interface).
- **M11d, other formats.** STLLoader, PLYLoader (done), SVGLoader (done: to
  ShapePaths, createShapes, strokes; also usable straight as Rive paths
  with `rivePathFromShapePath`; XML through `addons/libs/dom_parser`),
  FontLoader, ObjectLoader and `toJSON` (round trips of scenes, geometries,
  materials; **done**: toJSON returns a Dynamic, `THREE.JSON.stringify`
  writes it; ObjectLoader, MaterialLoader, BufferGeometryLoader; BatchedMesh
  and addon geometries' parameters left out), FBXLoader (binary and ASCII; done),
  GLTFExporter (**done**: r170's writer and default plugins, .glb bytes or
  .gltf text; images as PNGs encoded from pixels in memory, so Rive images,
  canvases and compressed textures are left out; no JPEG, no compression
  of PNGs, no KHR_mesh_quantization output).
- Example `Models`: a glTF with the extensions above, an STL and an SVG
  extruded, loaded asynchronously with a progress bar artboard.

### M12: rendering features and post-processing breadth (done)

- **M12a, views (done; example `Views`).** `setViewport`, `setScissor`, `setScissorTest` (split
  screens, insets), ArrayCamera, StereoCamera, multiple scenes in one
  canvas, `renderer.compile`, `info.memory`.
- **M12b, render target features (done; no readRenderTargetPixels: Rive has no GPU readback; logarithmic depth, not reversed).** Multiple render targets (`count`,
  textures array), depth textures, `readRenderTargetPixels`,
  `copyFramebufferToTexture`, `copyTextureToTexture`, reversed or
  logarithmic depth for large scenes.
- **M12c, anti-aliasing and AO passes (done; prepasses as three.js r170, MRT only through GTAOPass.setGBuffer).** SMAAPass, SSAARenderPass,
  TAARenderPass, SSAOPass, GTAOPass, SAOPass (normal and depth prepass
  via MRT).
- **M12d, effect passes (done; masks emulated without stencil).** OutlinePass, BokehPass, AfterimagePass,
  FilmPass, GlitchPass, DotScreenPass, HalftonePass, LUTPass (+ LUT
  loaders), RenderPixelatedPass, TexturePass, ClearPass,
  MaskPass/ClearMaskPass (stencil), selective bloom with layers.
- Example `Effects` (done): a pass picker (a Rive layout and view model) over one scene.

### M13: animation depth and Rive integration (done)

- **M13a, animation utilities (done).** AnimationUtils (`subclip`,
  `makeClipAdditive`), additive blending, AnimationObjectGroup, morph
  targets on the GPU (target texture, any number of targets),
  InstancedMesh morphs (`setMorphAt`), skeletons above 256 bones (bone
  texture).
- **M13b, 2D overlays (done).** The CSS2DRenderer / CSS3DRenderer counterpart:
  Rive artboards drawn in 2D at projected 3D positions (labels, tooltips,
  HUD markers), occluded on request (by raycast: scripts cannot read
  depth back), taking pointer events.
- **M13c, data binding (done).** Helpers that bind scene properties (transforms,
  material colours, light intensities, animation weights) to Rive view
  model properties both ways, so a Rive state machine or the editor can
  drive a three.js scene without script changes.
- **M13d, Rive-driven animation (done, within the scripting API: bones
  by name, timelines sampled; see DEVIATIONS).** Retarget Rive skeleton/bone animations
  onto three.js Skeletons, and Rive timelines onto Object3D transforms
  (beyond `copyNodeTransform`).
- Examples `Animation` (done) and `RiveDriven` (done).
- Not planned: audio (no Rive scripting audio API yet), XR, node materials
  and TSL (WGSL is the shading language here).

### M14: performance and shipping (done)

Numbers, method and the three.js comparison recipe: [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

- **M14a, measure (done).** `renderer.info.timings` (CPU per render
  stage), Benchmark `--arg profile|meshes|instances|still|serialcull`,
  `tools/screenshots.sh` + `tools/compare_shots.py` (every example, twice,
  before/after). Baseline: interpreted render 7.21 ms, AOT 2.46 ms.
- **M14b, CPU work per frame (done).** Object blocks keep their arena slot
  and are rewritten and uploaded (in runs) only when they change; material
  blocks once a view per material; per-view caches (geometries, material
  state, ShaderMaterial pipelines), pooled draw items, no per-frame garbage
  in the renderer's frame path. Interpreted render 7.21 -> 3.7 ms (still
  boxes 7.43 -> 3.24). From M13: morph texel conversion in a Rive job
  joined before the first pass (115 ms on the main lane interpreted for the
  Animation blob), MorphU blocks in one shared buffer at dynamic offsets,
  big bone textures upload only moved bones, overlay occlusion stops at
  the first hit. Pixel-identical (58 screenshots).
- **M14c, parallelism (done, partial by measurement).** Frustum culling in
  a `rive/parallel` call from 2048 candidates (pays from about that size
  compiled; interpreted from 1000). Skinning is on the GPU and
  Skeleton.update uses native Mat4 (parts cannot call the host); the CPU
  morph blend is a rare fallback: neither moved.
- **M14d, prebaked shader variants (done, optional).** As planned below:
  three.wgsl reads its fragment features through `v_*` functions;
  `GPURenderer.programKey`; `tools/bake_shaders.sh` (bash: record with
  `--arg threeShaderKeys=1`, generate `three/shaders/baked/*.wgsl` with
  only the key's two entry points, write `gpu/BakedShaders.as` with
  three.wgsl's hash; `--check`, `--clean`, `--max`, `--keys`); runtime
  fallback to the uber-shader, unbaked keys logged once unless
  `THREE_RELEASE`; same bind group layouts; `renderer.compile` pre-warms
  baked pipelines. AOT render with all 94 example keys baked: Benchmark
  2.43 -> 0.98 ms, Lights 2.71 -> 0.99, Environment 0.82 -> 0.08; the
  .riv grows about 0.5 MB a variant (9.2 -> 58.7 MB). Baked renders differ
  from the uber-shader at a few edge pixels (no `discard` plus folded
  constants; each feature alone is bit-exact). The repository ships no
  bake; WebGL2 and mobile timing still to do before recommending it.
- **M14e, CI (done).** `tools/bench.sh`: verify, test, bake freshness,
  release-build GLSL check, Benchmark interpreted and AOT against
  `tools/bench_baseline.txt` (30% + 0.1 ms), optional `--manifests`.
  `make_gallery.py --thumbs` fails on blank or tiny thumbnails.
- **M14f, WebGPU validation (done, own validator).** Rive's
  `tools/webgpu_validate` is not shipped; `tools/validate_manifest.py`
  checks every example's `--gpu-manifest` descriptors against WebGPU rules
  and the web limits (all pass). Not covered: draw-time dynamic offsets,
  same-pass read/write hazards, device-specific format support.
- **M14g, three.js comparison (documented, not run).** The matching
  scenes and what to measure: docs/PERFORMANCE.md.
- Not done: `--publish=web` and publishing the library (left to the main
  session), three.js measurements, baked-mode timing on WebGL2 and mobile.
- **Packaging (done).** The repository is two Rive projects:
  packages/threeas (the engine, published as the library `threeas`, on UAT
  for now) and packages/gallery (the page and the examples, one folder
  each), which imports the engine with `lib:threeas/...` and builds it from
  the sources next door through a library override. `tools/publish.sh`
  publishes the library (UAT or production) and the gallery.

The plan this milestone started from:

- Skip unchanged object blocks and uploads; per-frame allocation audit
  (no garbage in steady state).
- Skinning, morphs and culling of big scenes in parallel calls
  (`rive/parallel`) or compute, where Rive exposes it.
- Benchmarks with the ahead-of-time tier (`--aot`), against the same
  scenes in three.js in a browser; a regression bench in CI.
- **Prebaked shader variants (optional, "optimized" mode).** The default
  stays the uber-shader (one `three.wgsl`, features chosen by uniform
  flags), which always works. A bash script, `tools/bake_shaders.sh`, bakes
  specialized variants for what a project actually draws:
  1. The renderer computes a program key per draw, as three.js's
     `getProgramCacheKey`: material kind, maps present, skinning, morphs,
     fog, shadows, clipping, light counts by type.
  2. The script runs every artboard headless with a recording flag
     (`--arg`), collecting the keys the renderer logs.
  3. It generates WGSL per key from `three.wgsl`, the features as `const`
     booleans and constant light counts, so the compiler drops dead
     branches and unrolls loops (three.js's `#ifdef`s), as entry points of
     one generated asset (or one asset each), plus a registry module
     (key -> module and entry point, and a hash of `three.wgsl`).
  4. At runtime the renderer uses a baked variant when the key is in the
     registry and the hash matches, else falls back to the uber-shader
     (logging the unbaked key once in development builds).
  5. Variants keep the uber-shader's bind group layout first, so groups
     and the pipeline cache stay shared; stripping unused bindings per
     variant (more texture slots) comes after.
  Check freshness in CI (rerun the script, fail on a diff, then
  `tools/check_glsl.py` on the release .riv), cap the variant count, and
  benchmark both modes (load time and frame time, WebGL2 and mobile
  especially) before making it the recommended setup. `renderer.compile`
  pre-warms baked pipelines.
- From M13: morph textures are converted to half floats on the main lane
  when first drawn (the Animation example spreads its setup over frames
  to stay in the per-call budget: move the conversion into a job, or
  cache it); a big skeleton's bone texture is re-uploaded every
  frame; the MorphU block is a 16 KB buffer per morphed mesh; overlay
  occlusion raycasts the whole scene per label (pass `occluders`). The
  morph, bone-texture and instanced-morph paths are uniform branches in
  the uber-shader's vertex stage: candidates for baked variant flags.
- WebGPU validation of every example's `--gpu-manifest`, then
  `--publish=web` and publishing the library to the Rive community.

### M15: Draco geometry compression (done)

Done as below. The decoder is in `packages/threeas/three/addons/libs/draco/`
(Draco 1.5.7's decode paths, Apache 2.0); tests in `tests/draco_test.as`
against Draco's testdata (OBJ ground truth, bitstreams 1.1 to 2.3),
three.js's `bunny.drc` (Stanford bunny reference numbers) and Khronos
glTF-Draco samples beside their glTF variants (Box, Avocado, WaterBottle
for valence Edgebreaker, RiggedSimple for integer joints). Decode times
(bunny.drc, 69451 faces): 56 ms interpreted, 5.4 ms AOT. Ported but not
exercised by any fixture (old encoders wrote them): the deprecated predictive
Edgebreaker, multi-parallelogram and float tex-coord predictors, the
non-canonical octahedron transform with geometric normals, kd-tree levels
below 6. Not ported: kd-tree point clouds before bitstream 2.3.

- **DRACOLoader** (three.js `examples/jsm/loaders/DRACOLoader.js` API:
  `setDecoderPath` / `setDecoderConfig` / `preload` kept as no-ops or
  documented, `parse`, `load(name)`, `loadAsync(url)`,
  `decodeDracoFile`), with the decoder itself **ported to AnimaScript**
  (`packages/threeas/three/addons/libs/draco/`, from Google's Draco C++
  decoder or its spec): the `.drc` container, sequential and Edgebreaker
  (standard and valence) connectivity, the attribute decoders with
  quantization, the prediction schemes (delta, parallelogram,
  multi-parallelogram, constrained multi-parallelogram, tex-coords
  portable, geometric normal) and transforms (octahedron normals,
  wrap), and the rANS entropy coder. Point clouds too.
- Decoding runs in a Rive job (the pattern of GLTFLoader's `decodeGLTF`),
  so big meshes stay off the main lane.
- **GLTFLoader `KHR_draco_mesh_compression`** through
  `setDRACOLoader(dracoLoader)`, as three.js, in `load`, `parse` and the
  async path.
- Fixtures: real Draco files (Khronos glTF-Sample-Assets' `glTF-Draco`
  variants, three.js's `bunny.drc`), downloaded as data, licences noted;
  tests compare decoded attributes with the uncompressed versions.
- Example: the Models example gains a Draco-compressed glTF and a `.drc`
  point cloud.

### M16: popular addons (done)

All from three.js r170 `examples/jsm/objects/`, faithful ports in
`packages/threeas/three/addons/objects/`, each in the gallery:
- **Reflector**: planar mirror (virtual camera, clip plane, render target,
  texture matrix), `getRenderTarget`, `dispose`.
- **Refractor**: planar refraction, same machinery.
- **Water** (`Water.js`: mirror + normal map scrolling, sun light,
  distortion) and **Water2** (`Water2.js`: Reflector + Refractor + flow
  map or flow direction).
- **Sky** (Preetham model: turbidity, rayleigh, mie, sun position),
  usable with PMRemGenerator for environment lighting, as three.js's
  `webgl_shaders_sky` example.
- **Lensflare** and `LensflareElement` (occlusion through
  `copyFramebufferToTexture`, no readback needed).
- **MarchingCubes** (`MarchingCubes.js`: metaballs, planes, the field,
  `update()`), with its geometry built on the CPU each frame and uploaded.
- Example `Addons`: a scene with a mirror, refractive glass, an ocean
  (Water) under a Sky with a lens flare on the sun, and animated
  metaballs.

Done: all seven, plus WaterRefractionShader (webgl_refraction's rippled
glass), with tests of the MarchingCubes field and polygonization, the
Reflector / Refractor matrices and oblique clipping, and the shaders'
uniform layouts (tests/marching_cubes_test.as, tests/objects_test.as). The
renderer gained `Object3D.onBeforeRender` / `onAfterRender` (called before
and after a render's pass: a hook that renders makes the render collect
again) and `renderBufferDirect`, and now reads the camera's position from
its `matrixWorld` (it used to recompute `matrixWorld` from `matrix`, which
put cameras with `matrixAutoUpdate` off, a StereoCamera's eyes and the
Refractor's camera, at the origin; the Views example's stereo half is lit
from the right place now); the gallery's `Addons` example (a Water
ocean under a Sky lighting the scene through a PMREM, a Lensflare on the
sun, a Reflector, a Refractor with WaterRefractionShader, a Water2 pool on
a flow map, MarchingCubes metaballs) takes about 4.5 ms advance and 5.8 ms
render a frame interpreted, 0.3 ms and 2.3 ms ahead of time (800 x 600). The gallery carries copies of
the new shaders (`packages/gallery/three/shaders/objects/`) until the
engine library is republished; see docs/DEVIATIONS.md.

### M17: spatial audio (done)

three.js's audio API (`src/audio/`), on Rive's audio API (`rive/audio`)
instead of Web Audio:
- **AudioListener** (an Object3D, usually on the camera: `setMasterVolume`,
  `getMasterVolume`, `context` replaced by the Rive audio engine, filters).
- **Audio** (non-positional: `setBuffer` / `setMediaElementSource`
  replaced by Rive audio assets, `play`, `pause`, `stop`, `setLoop`,
  `setLoopStart/End`, `setVolume`, `setPlaybackRate`, `setDetune`,
  `offset`, `duration`, `autoplay`, `onEnded` as a listener).
- **PositionalAudio** (panner and distance model as Web Audio's
  PannerNode: `setRefDistance`, `setRolloffFactor`, `setDistanceModel`
  linear / inverse / exponential, `setMaxDistance`,
  `setDirectionalCone(inner, outer, outerGain)`; equal-power stereo
  panning, plus a simple interaural delay and head-shadow low-pass for
  depth; no HRTF).
- **AudioAnalyser** (`getFrequencyData`, `getAverageFrequency`: an FFT on
  the mixed signal of an Audio, results back through a snapshot).
- **AudioLoader** (Rive audio assets by name; `loadAsync`; urls where the
  host allows fetching and decoding them).
- **PositionalAudioHelper**.
- How: each source decodes to PCM in a job (`AudioSource.toBlob`); one
  `AudioProcessor` mixes every playing voice on the audio thread (looping,
  playback rate, gain ramps to avoid clicks); the main lane computes each
  voice's gains, pan, delay and filter from the listener's and the
  object's world matrices every frame and publishes them through a
  `Snapshot`. Checked headless with `--render-audio` (levels and panning
  per channel against expected values).
- Example `Audio`: a few sound emitters moving around the camera (one
  with a cone), a non-positional ambience, an analyser bar graph, and
  the PositionalAudioHelper cones.

Done: `three/audio/` (AudioListener, Audio, PositionalAudio,
AudioAnalyser, AudioContext, the Web Audio node stand-ins in AudioNodes,
AudioMath, the mixer in AudioMixer, a WAV decoder), `loaders/AudioLoader`,
`addons/helpers/PositionalAudioHelper`; the gallery's `Audio` example and
its `AudioCheck` artboard; `tools/make_audio_samples.py` (the example's
original sounds) and `tools/check_audio.py` (panning, the three distance
models, cones, seamless loops, click-free stop and pause, the analyser's
peak, measured from `--render-audio` WAVs); `tests/audio_test.as`. The
listener publishes in `updateMatrixWorld` (as three.js) and in an explicit
`listener.update()` for frames without a render. The mixer costs about
0.03 ms per 512-frame block for eight panned, delayed and shadowed voices
compiled (0.3% of the block), 0.47 ms interpreted (4.4%). Left out: HRTF
convolution (equal-power panning plus an interaural delay and a head-shadow
low-pass instead), media streams, Web Audio nodes beyond gain, panner,
biquad, oscillator and analyser, `fftSize` above 4096, MP3 / FLAC from
fetched bytes (Rive decodes them only from audio assets). Still to do by
ear: a listening pass on desktop and on the web (a page with cross origin
isolation, where processors run; elsewhere the fallback plays assets
through Rive's `Audio.play` without panning). The gallery as it ships
(`tools/release_build.sh` without `--override`, on `.libraries/`) builds
once the engine library is republished with `three/audio/`.

## Deviations from three.js

Every difference is listed in [docs/DEVIATIONS.md](docs/DEVIATIONS.md),
kept current with the code; agents porting three.js sources read it first
(see [AGENTS.md](AGENTS.md)).
