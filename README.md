# ThreeAS

[three.js](https://threejs.org) for Rive. Scenes are written in AnimaScript
with three.js's API, rendered with Rive's `GPUCanvas`, and composited into
the artboard, so they sit in layouts, take script inputs, and can show live
Rive artboards as textures.

![FirstScene](docs/first_scene.png)

```as
import * as THREE from "../three/Three";

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

## Run it

Needs the Rive CLI (`rive --version` 1.9.2 or later).

```bash
rive .                                            # live preview (FirstScene)
rive . --artboard=HelloCube                       # three.js's first tutorial
rive . --artboard=Geometries                      # every built-in geometry
rive . --artboard=Materials                       # materials, lights, fog, sky
rive . --artboard=Primitives                      # instancing, points, lines, sprites
rive . --artboard=Shapes                          # curves, extrusion, a Rive path in 3D
rive . --artboard=Interactive                     # orbit, click a Rive switch in 3D, render target
rive . --artboard=Deform                          # GPU skinning and morph targets
rive . --artboard=Model                           # a glTF model, animated
rive . --artboard=CustomShader                    # a WGSL ShaderMaterial on a live artboard
rive . --artboard=Environment                     # image-based lighting
rive . --artboard=Environments                    # cube map, .hdr, .exr environments; CubeCamera
rive . --artboard=Textures                        # uv transforms, uv1, KTX2 compressed textures
rive . --artboard=MaterialsPlus                   # extra maps, glass, iridescence, anisotropy
rive . --artboard=Clipping                        # clipping planes, stencil caps, clipShadows
rive . --artboard=Shadows                         # directional, spot and point shadows
rive . --artboard=PostProcessing                  # EffectComposer: bloom, tone mapping, FXAA
rive . --artboard=Benchmark --bench=300           # 1000 meshes + 10000 instances, timed
rive . --test                                     # math and geometry tests
rive . --screenshot=build/s.png --advance=1s      # headless render
```

## Gallery

`gallery/` is the project's landing page, built in Rive (RML, no HTML) in
the Rive brand: install, quickstart, features, and a card per example.
Clicking a card plays that example artboard live on the page's stage, full
size, with its pointer input (orbit, zoom, clicks).

```bash
rive . --artboard=Gallery                         # the landing page
python3 gallery/make_gallery.py                   # regenerate gallery/gallery.rml
python3 gallery/make_gallery.py --thumbs          # ... and the card thumbnails (macOS)
```

The stage is a nested artboard whose artboard is bound to a view model
property that the cards' listeners write, so the example artboards are
marked `isComponent="true"` in `examples/examples.rml`.

## What is there

Milestone 1: math (Vector2/3/4, Quaternion, Euler, Matrix3/4, Color,
MathUtils), Object3D, BufferGeometry, Scene, Group, Mesh, perspective and
orthographic cameras, Box/Plane/Sphere geometries (and, from M2,
Circle/Ring/Cylinder/Cone/Torus/TorusKnot/Lathe/Capsule/Polyhedra/Edges/
Wireframe, Box3/Sphere/Plane/Ray/Triangle/Frustum, frustum culling), Basic/Normal/Lambert/
Standard materials, ambient/directional/point lights, Texture, DataTexture,
CanvasTexture, TextureLoader, ArtboardTexture, and `GPURenderer` (MSAA,
depth, transparency sorting, sRGB output).

## Use it in another project

Copy `three/` into the project (shaders included), or publish this project
as a Rive library and import it (needs a Rive account; `rive library
publish` pushes the project first):

```bash
rive login
rive library publish --description="ThreeAS"
# in the other project:
rive library search
rive library add --library=<id>
```

- [PLAN.md](PLAN.md): the milestones.
- [docs/DEVIATIONS.md](docs/DEVIATIONS.md): where and why the API differs
  from three.js. Read it before porting three.js code.
