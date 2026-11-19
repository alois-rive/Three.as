# Performance

What M14 measured and changed, how to measure, and how to compare ThreeAS
with three.js in a browser. Numbers are from an Apple M-series Mac
(arm64), headless `rive --bench` (rive 1.9.2), means over 300 frames;
`--bench` times a frame's script call and, for `render`, the GPU work it
waits for. Your machine will differ: compare runs on one machine.

## Measuring

```bash
rive . --artboard=Benchmark --bench=300            # interpreted tier
rive . --artboard=Benchmark --bench=300 --aot      # ahead of time (as devices run it)
rive . --artboard=Benchmark --bench=600 --arg profile=1   # + per-stage render times
tools/bench.sh                                     # CI: checks + bench against the baseline
```

The Benchmark artboard (`examples/benchmark.as`) is 1000 separate
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
- **Baked shader variants** (`tools/bake_shaders.sh`, optional): on this
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

M13 follow-ups: the 48-target morph texture of the Animation example took
115 ms on the main lane interpreted (31 ms AOT) and now converts in a job;
MorphU blocks share one buffer; a big skeleton's bone texture uploads only
when bones moved; overlay occlusion stops at the first hit.

## Comparing with three.js in a browser

Not run here (no downloaded code in this environment). To do it:

1. **Build both sides.** ThreeAS: `rive . --publish=web` (or a local web
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
   from `examples/*.as`, which keep three.js's calls.
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
   (`tools/bake_shaders.sh`), on WebGPU and WebGL2, desktop and a phone, to
   decide whether to recommend the baked mode (it costs file size).

## Not done in M14

- No three.js run (above). No mobile or WebGL2 timing of the baked mode.
- Skinning stays on the GPU; Skeleton.update multiplies with Rive's native
  `Mat4`, which parallel parts cannot call, so it was not moved. The CPU
  morph blend (only for morph textures bigger than the device allows) was
  not parallelized.
- Sorting opaque draws by material too (three.js's order) did not help
  the Benchmark and was left out.
