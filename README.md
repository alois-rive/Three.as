# ThreeAS

[three.js](https://threejs.org) for Rive. Scenes are written in AnimaScript
with three.js's API, rendered with Rive's `GPUCanvas`, and composited into
the artboard, so they sit in layouts, take script inputs, and can show live
Rive artboards as textures.

![FirstScene](docs/first_scene.png)

```as
import * as THREE from "lib:threeas/three/Three";

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(75, width / height, 0.1, 1000);
const renderer = new THREE.GPURenderer(context, { antialias: true });

const cube = new THREE.Mesh(
    new THREE.BoxGeometry(1, 1, 1),
    new THREE.MeshStandardMaterial({ color: 0x44aa88, roughness: 0.4 }));
scene.add(cube);
scene.add(new THREE.DirectionalLight(0xffffff, 3));

// in draw(renderer):
renderer.render(scene, camera);
renderer.present(riveRenderer);
```

A live artboard as a texture:

```as
@input screen: Artboard? = null;
...
const texture = new THREE.ArtboardTexture(screen!, 512, 512);
material.map = texture;
// in advance(seconds):
texture.advance(seconds);
```

Or as an app, with controls and pointer handling done for you:

```as
import * as THREE from "lib:threeas/three/Three";
import { OrbitControls } from "lib:threeas/three/addons/controls/OrbitControls";

export class Demo extends THREE.ThreeLayout {
    cube: THREE.Mesh = new THREE.Mesh(new THREE.BoxGeometry(), new THREE.MeshNormalMaterial());
    override setup(context: Context): bool {
        this.scene.add(this.cube);
        this.camera.position.z = 3;
        this.controls = new OrbitControls(this.camera, this.renderer);
        return true;
    }
    override animate(seconds: f64): void {
        this.cube.rotation.y += seconds;
    }
}
```

## Two projects

The repository holds two Rive CLI projects (each a directory with its own
`rive.yaml`):

```
packages/threeas/   the engine, published as the Rive library "threeas"
  three/            the library: three.js's src/ layout, addons/, rive/, shaders/
  tests/            rive --test suites, and fixtures/ they read by name
  threeas.rml       a placeholder artboard (the library's file needs markup)
  bindings/         the push binding per environment (tools/publish.sh)
packages/gallery/   the gallery and every example, built on the engine
  gallery/          the landing page: gallery.rml, its generator, brand, fonts, thumbs, hero
  examples/<name>/  one example each: <name>.as, <name>.rml (its artboards), its assets
  examples/shared/  what several examples use (the Screen artboard, studio_rgbe.hdr)
  threeas.rml       the engine library import (written by rive library add/update)
  .libraries/       the published engine snapshot the gallery builds against
tools/              scripts across both: publishing, screenshots, bench, samples
docs/               DEVIATIONS.md, PERFORMANCE.md, screenshots
```

The gallery imports the engine as a Rive library, the way any project
would: `"lib:threeas/<path in the library>"`, e.g. `lib:threeas/three/Three`.
Its `rive.yaml` names the library and sets `override: ../threeas`, so the
gallery builds against the engine sources next door and an engine edit
shows in the gallery without publishing. The override replaces the
library's published scripts and shaders with the local ones and compiles
local scripts the published version lacks; a new shader (a new `.wgsl`,
baked variants included) only reaches the gallery once the library is
republished and the gallery updated (`tools/publish.sh`).

## Run it

Needs the Rive CLI (`rive --version` 1.10.0 or later).

```bash
cd packages/gallery
rive .                                            # live preview: the Gallery
rive . --artboard=FirstScene                      # the scene above
rive . --artboard=HelloCube                       # three.js's first tutorial
rive . --artboard=Geometries                      # every built-in geometry
rive . --artboard=Materials                       # materials, lights, fog, sky
rive . --artboard=Primitives                      # instancing, points, lines, sprites
rive . --artboard=Shapes                          # curves, extrusion, a Rive path in 3D
rive . --artboard=Interactive                     # orbit, click a Rive switch in 3D, render target
rive . --artboard=Deform                          # GPU skinning and morph targets
rive . --artboard=Model                           # a glTF model, animated
rive . --artboard=Models                          # glTF extensions, meshopt, Draco, SVG, FBX
rive . --artboard=CustomShader                    # a WGSL ShaderMaterial on a live artboard
rive . --artboard=Environment                     # image-based lighting
rive . --artboard=Environments                    # cube map, .hdr, .exr environments; CubeCamera
rive . --artboard=Textures                        # uv transforms, uv1, KTX2 compressed textures
rive . --artboard=MaterialsPlus                   # extra maps, glass, iridescence, anisotropy
rive . --artboard=Clipping                        # clipping planes, stencil caps, clipShadows
rive . --artboard=Lights                          # area lights, lamps, a light probe, CSM moonlight
rive . --artboard=Editor                          # helpers, controls, scene utilities
rive . --artboard=Batched                         # BatchedMesh: 600 instances, four geometries
rive . --artboard=Shadows                         # directional, spot and point shadows
rive . --artboard=PostProcessing                  # EffectComposer: bloom, tone mapping, FXAA
rive . --artboard=Benchmark --bench=300           # 1000 meshes + 10000 instances, timed
rive . --screenshot=build/s.png --advance=1s      # headless render

cd packages/threeas
rive . --test                                     # the engine's test suites
```

## Gallery

`packages/gallery/gallery/` is the project's landing page, built in Rive
(RML, no HTML) in rive.app's style: a hero over a screenshot of the Lights
example, a card per example, install, quickstart and features. It is made
of Rive layouts, so it reflows to the window (two columns when wide, one on
a phone) and scrolls. Clicking a card plays that example artboard live on
the page's stage, at the stage's size, with its pointer input (orbit, zoom,
clicks). The stage sits above the cards and sticks to the top of the window
while they scroll under it, then leaves with the Examples section.

```bash
cd packages/gallery
rive . --artboard=Gallery                         # the landing page
python3 gallery/make_gallery.py                   # regenerate gallery/gallery.rml
python3 gallery/make_gallery.py --thumbs          # ... and the thumbnails and hero image (macOS)
```

The stage is a nested artboard whose artboard is bound to a view model
property that the cards' listeners write, so the example artboards are
marked `isComponent="true"` in their `examples/<name>/<name>.rml`. Rive has
no sticky positioning: the page binds laid-out values (the stage slot's
position, the grid's height, the window's size) back into its view model,
and formula converters derive the stage's offset and height from them. The
cards that pass behind the stage are clipped off, which also keeps them
from the pointer.

## What is there

Milestone 1: math (Vector2/3/4, Quaternion, Euler, Matrix3/4, Color,
MathUtils), Object3D, BufferGeometry, Scene, Group, Mesh, perspective and
orthographic cameras, Box/Plane/Sphere geometries (and, from M2,
Circle/Ring/Cylinder/Cone/Torus/TorusKnot/Lathe/Capsule/Polyhedra/Edges/
Wireframe, Box3/Sphere/Plane/Ray/Triangle/Frustum, frustum culling), Basic/Normal/Lambert/
Standard materials, ambient/directional/point lights, Texture, DataTexture,
CanvasTexture, TextureLoader, ArtboardTexture, and `GPURenderer` (MSAA,
depth, transparency sorting, sRGB output). The milestones since are in
[PLAN.md](PLAN.md).

## Use it in another project

Import the library (needs a Rive account; `scripting: wasm` in the
project's `rive.yaml`), then import its modules by their path in the
library:

```bash
rive login
rive library search                    # the libraries this project may import, with ids
rive library add --library=<id>        # e.g. the threeas library
```

```as
import * as THREE from "lib:threeas/three/Three";
import { GLTFLoader } from "lib:threeas/three/addons/loaders/GLTFLoader";
```

Or copy `packages/threeas/three/` into the project (shaders included) and
import it by relative path (`"../three/Three"`).

Publishing the library and the gallery is `tools/publish.sh` (see
[AGENTS.md](AGENTS.md)).

- [PLAN.md](PLAN.md): the milestones.
- [docs/DEVIATIONS.md](docs/DEVIATIONS.md): where and why the API differs
  from three.js. Read it before porting three.js code.
