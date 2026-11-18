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

## Run it

Needs the Rive CLI (`rive --version` 1.9.2 or later).

```bash
rive .                                            # live preview (FirstScene)
rive . --artboard=HelloCube                       # three.js's first tutorial
rive . --artboard=Geometries                      # every built-in geometry
rive . --artboard=Materials                       # materials, lights, fog, sky
rive . --artboard=Primitives                      # instancing, points, lines, sprites
rive . --artboard=Shapes                          # curves, extrusion, a Rive path in 3D
rive . --test                                     # math and geometry tests
rive . --screenshot=build/s.png --advance=1s      # headless render
```

## What is there

Milestone 1: math (Vector2/3/4, Quaternion, Euler, Matrix3/4, Color,
MathUtils), Object3D, BufferGeometry, Scene, Group, Mesh, perspective and
orthographic cameras, Box/Plane/Sphere geometries (and, from M2,
Circle/Ring/Cylinder/Cone/Torus/TorusKnot/Lathe/Capsule/Polyhedra/Edges/
Wireframe, Box3/Sphere/Plane/Ray/Triangle/Frustum, frustum culling), Basic/Normal/Lambert/
Standard materials, ambient/directional/point lights, Texture, DataTexture,
CanvasTexture, TextureLoader, ArtboardTexture, and `GPURenderer` (MSAA,
depth, transparency sorting, sRGB output).

- [PLAN.md](PLAN.md): the milestones.
- [docs/DEVIATIONS.md](docs/DEVIATIONS.md): where and why the API differs
  from three.js. Read it before porting three.js code.
