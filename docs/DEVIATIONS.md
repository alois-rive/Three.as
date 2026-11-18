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
| `setAnimationLoop(fn)` | the script's `advance(seconds)` |
| `WebGLRendererParameters` | `GPURendererParameters`: `antialias` (4x MSAA), `alpha` (transparent clear) only |
| `outputColorSpace`, `toneMapping` | fixed: sRGB output, no tone mapping (M5) |
| output | premultiplied alpha, composited with `srcOver` |
| `info.render.calls/triangles` | same, plus `info.render.culled` (meshes frustum culled); `info.memory` is missing |

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
  - `scene.background` is a `Color` (or null); textures come in M2.
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
- `castShadow` defaults to false and is ignored until shadows land (M5).
- The polyhedron presets (`IcosahedronGeometry`, `OctahedronGeometry`,
  `TetrahedronGeometry`, `DodecahedronGeometry`) live in
  `geometries/PolyhedronGeometry.as` rather than a file each; through the
  `THREE` namespace nothing changes.

## Lighting

- Intensities are three.js's physically based ones (r155+, no legacy
  lights): diffuse is `irradiance * albedo / PI`. Sources written for
  `useLegacyLights = true` need their intensities multiplied by PI.
- At most **8** directional and point lights reach the shader (the rest are
  ignored, with one log line). Ambient lights are summed, without limit.
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
  ignored for now. No mipmaps yet (M2): mipmap filters sample level 0.

## Rive-only additions

- `ArtboardTexture(artboard, width = 0, height = 0)`: a live artboard as a
  texture. Call `texture.advance(seconds)` from the script's `advance`; it
  redraws only after a change. `texture.artboard` is the instance.
- `Color.alphaOf(argb)` and `color.getRiveColor(alpha)` convert to Rive
  colours; `setHex` accepts a Rive `Color` (alpha ignored), so `Color` script
  inputs plug straight in.

## Not yet supported

Missing so far, planned in [../PLAN.md](../PLAN.md): Line/Points/Sprite/
InstancedMesh (so EdgesGeometry and WireframeGeometry build but cannot be
drawn yet), material arrays and geometry groups, Shape/ShapeGeometry/
ExtrudeGeometry/TubeGeometry, Phong/Physical/Toon/Matcap/Depth/line/points materials,
maps other than `map`, `wireframe`, `vertexColors`, SpotLight,
HemisphereLight, RectAreaLight, fog, background textures, shadows,
environment maps, tone mapping, ShaderMaterial, render targets,
Raycaster, curves, loaders other
than TextureLoader, animation (AnimationMixer), skinning, controls,
post-processing, `EventDispatcher` events (`dispose` events are internal).
