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

```
three/            the library (no protocol classes; import "three/Three")
  Three.as        re-exports everything: import * as THREE from "../three/Three"
  constants.as    sides, colour spaces, wrapping and filter constants
  math/           Vector2/3/4, Quaternion, Euler, Matrix3/4, Color, MathUtils
  core/           Object3D, BufferAttribute, BufferGeometry
  objects/        Mesh, Group
  scenes/         Scene
  cameras/        Camera, PerspectiveCamera, OrthographicCamera
  lights/         AmbientLight, DirectionalLight, PointLight
  materials/      MeshBasic/Normal/Lambert/StandardMaterial
  geometries/     Box, Plane, Sphere
  textures/       Texture, DataTexture, CanvasTexture
  loaders/        TextureLoader (Rive image assets)
  renderers/      GPURenderer (+ gpu/ internals)
  rive/           ArtboardTexture and other Rive integrations
  shaders/        WGSL
examples/         example artboards (examples.rml + one .as each)
tests/            rive --test suites
docs/             DEVIATIONS.md
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

### M4: assets and animation

- GLTFLoader from a `BlobAsset` (`.glb`, meshopt), with materials, embedded
  textures, cameras, lights and node hierarchy.
- SkinnedMesh, Skeleton, Bone (GPU skinning); morph targets.
- AnimationMixer, AnimationClip, AnimationAction, KeyframeTracks (number,
  vector, quaternion, color), PropertyBinding by name.
- OBJLoader, a `.json` ObjectLoader subset.

### M5: lighting quality

- Shadows: DirectionalLight, SpotLight, PointLight (cube) shadow maps with
  PCF/PCFSoft/VSM, `castShadow`/`receiveShadow`.
- Environment: equirect/cube environment maps, a PMREMGenerator
  equivalent, `scene.environment`, `envMap` and `envMapIntensity`.
- Tone mapping (Linear, Reinhard, Cineon, ACESFilmic, AgX, Neutral) and
  `toneMappingExposure`.
- ShaderMaterial / RawShaderMaterial with WGSL shader assets and typed
  uniforms.

### M6: post-processing and performance

- EffectComposer with RenderPass, ShaderPass, UnrealBloomPass, OutputPass,
  FXAA/SMAA.
- Batching and sorting by pipeline/material, instancing paths, uploads
  from `Blob`s off the main lane.
- Benchmarks against equivalent three.js scenes; the published-web check
  (`--publish=web`) for WebGPU validity.

## Deviations from three.js

Every difference is listed in [docs/DEVIATIONS.md](docs/DEVIATIONS.md),
kept current with the code; agents porting three.js sources read it first
(see [AGENTS.md](AGENTS.md)).
