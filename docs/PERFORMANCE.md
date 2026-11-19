# Performance

What M14 measured and changed, how to measure, and how to compare ThreeAS
with three.js in a browser. Numbers are from an Apple M-series Mac
(arm64), headless `rive --bench` (rive 1.9.2), means over 300 frames;
`--bench` times a frame's script call and, for `render`, the GPU work it
waits for. Your machine will differ: compare runs on one machine.

## Measuring

```bash
cd packages/gallery
rive . --artboard=Benchmark --bench=300            # interpreted tier
rive . --artboard=Benchmark --bench=300 --aot      # ahead of time (as devices run it)
rive . --artboard=Benchmark --bench=600 --arg profile=1   # + per-stage render times
../../tools/bench.sh                               # CI: checks + bench against the baseline
```

The gallery builds the engine from packages/threeas (its library
override), so these time the local engine.

The Benchmark artboard (`packages/gallery/examples/benchmark/benchmark.as`) is 1000 separate
MeshStandardMaterial boxes (8 materials, each its own draw) and one
InstancedMesh of 10000 Lambert icosahedra, everything moving. Its `--arg`s:
`profile=1` logs `renderer.info.timings` (CPU per render stage), `meshes=N`
and `instances=N` resize it, `still=1` stops the boxes (their object blocks
then stay unchanged), `serialcull=1` turns parallel culling off.
`--arg threeUberShader=1` ignores baked shader variants (any artboard).

## M14 results

| Benchmark artboard, mean ms | before M14 | after M14 |
|---|---|---|
| interpreted, advance (the example's animation loop) | 5.52 | 5.07-5.19 |
| interpreted, render | 7.21 | 3.56-3.78 |
| interpreted, render, boxes still | 7.43 | 3.24 |
| AOT, advance | 0.41 | 0.39-0.42 |
| AOT, render (uber-shader) | 2.46 | 2.40-2.48 |
| AOT, render, all program keys baked | - | 0.98 |

Render script time by stage, interpreted / AOT (ms, `--arg profile=1`):

| stage | before | after |
|---|---|---|
| matrices (updateMatrixWorld) | 0.32 / 0.05 | 0.32 / 0.05 |
| collect (culling, draw items) | 2.75 / 0.21 | 1.02-1.23 / 0.10-0.14 |
| prepare (frame block, sort) | 0.30 / 0.04 | 0.30 / 0.04 |
| write (object blocks, bind groups) | 2.77 / 0.30 | 0.85 / 0.15 |
| draw (pass recording) | 0.43 / 0.17 | 0.43 / 0.17 |

What did it:

- **Object blocks kept across frames** (a slot per draw, rewritten and
  uploaded only when its matrix, lights or material changed) and **material
  blocks built once a view per material** instead of once per draw.
- **Per-view caches**: geometry checks (nine attribute lookups a draw),
  material state, ShaderMaterial pipelines; pooled draw items; no garbage
  in steady state in the renderer's frame path (pass descriptors, bind
  groups and typed-array views reused).
- **Parallel frustum culling** (`rive/parallel`) from 2048 candidates:
  slower than the main lane for 1000 objects compiled (0.14 vs 0.12 ms),
  faster for 8000 (0.83 vs 0.95 ms) and interpreted (1.02 vs 1.24 ms).
- **Baked shader variants** (`tools/threeas_bake.sh`, optional): on this
  GPU the uber-shader's fragment work dominated the compiled frame.

Baked variants, AOT render ms, uber-shader -> every key baked: Benchmark
2.43 -> 0.98, Environment 0.82 -> 0.08, Lights 2.71 -> 0.99, MaterialsPlus
2.07 -> 0.94, Shadows 1.82 -> 0.50 (interpreted Benchmark: 3.80 -> 3.83,
CPU-bound). Costs: the .riv went from 9.2 MB to 58.7 MB with 94 variants
(about 0.5 MB each, compiled for five shader backends; `shaderOutputs` in
rive.yaml can drop backends a target does not use), the build from 5.5 s to
15-35 s, and a pipeline compile per variant on first use (the slowest bench
frame, a proxy for load time: Benchmark 9.9 -> 2.4 ms, Lights 5.5 -> 1.6,
Environment 3.0 -> 0.2, so smaller specialized pipelines compiled faster
here). Mobile and WebGL2 were not measured: do that before recommending
the mode (see below).

M18 moved the bake into the project (`tools/threeas_bake.sh <project>`;
variants are found by name, no registry). Its costs, measured on the
gallery with every one of its 106 keys baked: the release .riv from 15.6
to 68.9 MB (0.50 MB a variant), Benchmark AOT render 2.46 -> 1.15 ms
(p50). Without a bake, each program key costs one `context.shader` lookup
the first time a renderer sees it (about 0.8 µs interpreted) and the
per-draw key check M14d only ran with a bake: Benchmark AOT render 2.54-2.55
ms with lookups, 2.56-2.60 ms with them off (`--arg threeUberShader=1`),
within noise.

M13 follow-ups: the 48-target morph texture of the Animation example took
115 ms on the main lane interpreted (31 ms AOT) and now converts in a job;
MorphU blocks share one buffer; a big skeleton's bone texture uploads only
when bones moved; overlay occlusion stops at the first hit.

## Pointer events in big scenes

ThreeLayout used to update every world matrix and raycast the whole scene
(every triangle the ray's bounds let through, skinned meshes skinned a
corner at a time, every instance and point) at each pointer event, then
sort the hits, only to learn whether the nearest one showed an interactive
ArtboardTexture, even in scenes without one. Measured with
`packages/threeas/tests/pointer_test.as` ("pointer stress", which logs
its times): 3000 boxes, a sphere of 1M triangles, 4 skinned cylinders of
8k triangles, an InstancedMesh of 10000 icosahedra, 100000 points; a
layout of 800 x 600. Before, a pointer event over the big sphere cost
0.8 s interpreted (the sphere's triangles 757 ms, the skinned cylinders
40 ms each when the ray crossed them, points 14 ms, instances 11 ms,
3000 boxes 1.5 ms, matrices 1.2 ms; 52-69 ms compiled): four times the
200 ms headless call budget, and past the suite's 2 s for three events.

Now (`ArtboardPicker`, `GeometryBVH`, see DEVIATIONS.md): without an
ArtboardTexture nothing is raycast; with one, only the meshes that show
it, then an any-hit occluder walk in front of the hit; matrices once a
frame; big geometries through a BVH built in a job; skinned meshes posed
once a raycast. Per event, ms (`rive . --test`, interpreted / `--aot`):

| event | before | after |
|---|---|---|
| move over the sphere, no ArtboardTexture | 806-835 / 52-69 | 0.003 / 0.0 (the first event of a frame updates the matrices: 1.7 / 0.18) |
| press there | 825 / 59-72 | 0.003 / 0.0 |
| move over boxes and instances, no ArtboardTexture | 52-120 / 4.6-14 | 0.003 / 0.0 |
| move over the sphere, an artboard plane behind it, tree built | ~806 / ~52 | 1.3 / 0.09 (press 1.1 / 0.08) |
| same, tree building (occluded meanwhile) | - | 2.3 / 0.11 (first event, starting the job: 54 / 3.6) |
| move over an unoccluded artboard plane | 49-109 / 4.6-11 | 20 / 1.1 (first event of a frame 23 / 1.3) |
| move beside the artboards (every candidate missed) | 14-80 / 1.3-9 | 0.008 / 0.001 |

Ranges: a warm event and the first one (bounding spheres computed, a
fresh scene). Over the unoccluded plane the occluder walk visits the 3000
objects; the instances and a skinned cylinder near the ray take most of
it. The very first event of a scene also computes bounds and starts the
trees' jobs (113 / 5.6 ms here).

The tree of the 1M-triangle sphere builds in about 0.1 s compiled (106 ms
on the main lane; as a job, done 109 ms after it started, 6 pool
threads) and 2 s interpreted (250k triangles: 455 / 18 ms on the main
lane). It has 340k nodes, about 15 MB (4 bytes a triangle, 32 a node);
the job copies the positions and index once. With it, a raycast of the
sphere takes 0.02 ms interpreted. Moves along the same ray in one frame
reuse the last answer; hover is still resolved at every move (each
move's uv goes to the artboard).

Not done: per-instance bounds for InstancedMesh (10000 instances cost
about 10 ms interpreted / 1 ms compiled when the ray crosses the whole
mesh's sphere before the hit); trees for skinned and morphed meshes
(refitting); building trees in a browser without threads, where a job
runs on the page's thread at an advance and a very big geometry may
exceed that call's budget.

## Comparing with three.js in a browser

Not run here (no downloaded code in this environment). To do it:

1. **Build both sides.** ThreeAS: the gallery's `--publish=web` (or a local web
   build) of the artboards below. three.js: a page of the same scene with
   the same three.js version the port follows (r170), `WebGLRenderer` and
   `WebGPURenderer`, served locally.
2. **Match the scenes exactly**: canvas size in pixels, devicePixelRatio 1,
   `antialias: true` (ThreeAS's ThreeLayout default, 4x MSAA), the same
   tone mapping and output colour space, the same geometry segment counts,
   materials and lights, and the same animation per frame. The Benchmark
   artboard in three.js:

   ```js
   const scene = new THREE.Scene();
   scene.background = new THREE.Color(0x111318);
   scene.add(new THREE.HemisphereLight(0xffffff, 0x404050, 1.2));
   const sun = new THREE.DirectionalLight(0xffffff, 2);
   sun.position.set(3, 5, 4);
   scene.add(sun);
   const box = new THREE.BoxGeometry(0.3, 0.3, 0.3);
   const materials = [...Array(8)].map((_, i) => new THREE.MeshStandardMaterial({
       color: new THREE.Color().setHSL(i / 8, 0.6, 0.55), roughness: 0.5 }));
   const side = Math.ceil(Math.cbrt(1000)), cubes = [];
   for (let i = 0; i < 1000; i++) {
       const m = new THREE.Mesh(box, materials[i % 8]);
       const x = i % side, y = Math.floor(i / side) % side, z = Math.floor(i / (side * side));
       m.position.set((x - side / 2) * 0.5, (y - side / 2) * 0.5, (z - side / 2) * 0.5);
       scene.add(m); cubes.push(m);
   }
   const swarm = new THREE.InstancedMesh(new THREE.IcosahedronGeometry(0.05, 0),
       new THREE.MeshLambertMaterial({ color: 0xffcc66 }), 10000);
   scene.add(swarm);
   camera.position.set(0, 2, 12); camera.lookAt(0, 0, 0);   // PerspectiveCamera(75, w / h, 0.1, 1000)
   // per frame, t in seconds: cubes[i].rotation.set(t + i * 0.01, t * 0.7 + i * 0.02, 0);
   // swarm instance i: angle a = i * 0.618 + t * 0.2, radius r = 3 + (i % 100) * 0.03,
   //   position (cos(a) * r, sin(i * 0.37 + t) * 2, sin(a) * r), identity rotation and scale.
   ```

   Then the GPU-heavy scenes, where shading cost dominates: Environment
   (a 5 x 3 grid of MeshStandardMaterial spheres under an equirectangular
   environment), Lights (RectAreaLights, a street of point lights, a light
   probe, CSM) and MaterialsPlus (physical materials). Copy their scenes
   from the gallery's `examples/*/*.as`, which keep three.js's calls.
3. **Measure**, interleaving the pages and dropping the first round (see
   `rive docs gpu-performance`, "Measuring"):
   - frame time to the GPU's finish, not to the end of submission: three.js
     with `EXT_disjoint_timer_query_webgl2` / WebGPU timestamp queries, or
     both sides by `requestAnimationFrame` deltas with vsync off
     (`--disable-gpu-vsync --disable-frame-rate-limit` in Chrome);
   - CPU per frame on the page (`performance.now()` around
     `renderer.render`; for Rive, the runtime's script time), and in the
     GPU process (Chrome's tracing, `chrome://tracing`, "gpu" category);
   - draw calls (`renderer.info.render.calls` on both sides);
   - load: time to first rendered frame, shader compiles (three.js
     programs vs ThreeAS pipelines; with and without baked variants), and
     the downloaded size (three.js bundle + assets vs the .riv);
   - memory: JS heap vs the wasm memory pages `--bench` reports.
4. **Both ThreeAS modes**: the uber-shader (default) and a baked build
   (`tools/threeas_bake.sh`), on WebGPU and WebGL2, desktop and a phone, to
   decide whether to recommend the baked mode (it costs file size).

## Not done in M14

- No three.js run (above). No mobile or WebGL2 timing of the baked mode.
- Skinning stays on the GPU; Skeleton.update multiplies with Rive's native
  `Mat4`, which parallel parts cannot call, so it was not moved. The CPU
  morph blend (only for morph textures bigger than the device allows) was
  not parallelized.
- Sorting opaque draws by material too (three.js's order) did not help
  the Benchmark and was left out.
