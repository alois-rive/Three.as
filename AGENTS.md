# Working on ThreeAS

ThreeAS is three.js ported to Rive: AnimaScript (`.as`) scripts that render
with Rive's `GPUCanvas` and WGSL shaders. Read these before changing code:

- [docs/DEVIATIONS.md](docs/DEVIATIONS.md): every difference from three.js.
  **Read it before porting anything from three.js sources**, and update it
  in the same change when you add, remove or alter a deviation.
- [PLAN.md](PLAN.md): milestones and what is in scope now.
- [README.md](README.md): the two projects and how they fit.
- `rive docs animascript/protocols`, `rive docs gpu`,
  `rive docs animascript/api/<module>`, `rive docs project/rive-yaml`
  (Libraries): the language and the Rive APIs.

## Two projects

The repository root is not a Rive project. Each package is one, with its
own `rive.yaml`, and every `rive` command runs in (or names) a package:

- **`packages/threeas/`**: the engine, published as the Rive library
  `threeas` (UAT: file 38630, library 761, in project 44599 "Rive Public
  Libraries"; production: the "ThreeAS" project, see `tools/publish.sh`).
  `three/` is the library, `tests/` its suites and `tests/fixtures/` the
  blobs they read by file stem. No example or gallery content here.
- **`packages/gallery/`**: the gallery page (`gallery/`) and the examples
  (`examples/<name>/`: `<name>.as`, `<name>.rml` with its artboards, and
  the assets only it uses; `examples/shared/` for what several use). Bound
  to the UAT file 38626 and the `threeas` web page.

The gallery imports the engine as a library, through `threeas.rml` (the
`LibraryAsset`), `rive.yaml`'s `libraries:` and `.libraries/` (the
downloaded snapshot, committed). Modules are named `lib:threeas/` plus
their path in the library:

```as
import * as THREE from "lib:threeas/three/Three";
import { OrbitControls } from "lib:threeas/three/addons/controls/OrbitControls";
```

Inside the engine, modules import each other by relative path, and the
renderer finds its shaders by asset name (`three/shaders/three` ...), from
the gallery as well. `override: ../threeas` under the library in the
gallery's `rive.yaml` builds the gallery against the engine sources, so an
engine edit shows in the gallery without publishing:

- It is honoured only while `packages/threeas/rive.yaml` pushes to the
  library's file (38630, the UAT binding). Keep that binding committed;
  `tools/publish.sh` swaps in production's for a production publish.
- The build says `library override ../threeas provides none of the N
  components`: that line counts markup components; the override's scripts
  and shaders are used all the same.
- Local engine scripts are all compiled, new ones included. A **new
  engine shader** (a new `.wgsl` under `three/`) does not reach the
  gallery until the library is republished and the gallery updated (baked
  variants are the gallery's own files, so they do). Until then
  the gallery carries copies under the engine's asset names: the addon
  objects' shaders (`three/shaders/objects/`, M16) are copied to
  `packages/gallery/three/shaders/objects/` by
  `tools/make_shader_chunks.py` (run it after editing them; delete the
  gallery's `three/` once the published library has them).
- Likewise an example importing an engine module the published library
  lacks (the Addons example and `three/addons/objects/`) only builds with
  the override: `tools/release_build.sh` without `--override` (and
  tools/publish.sh's pre-publish release build) fails on it until the
  engine is republished.
- The gallery's `rive . --test` runs the engine's suites too (the override
  brings them), without `tests/fixtures/`: a suite skips a fixture it
  cannot find, and `tests/fixtures_test.as` checks, in packages/threeas,
  that every fixture in `tests/fixtures/fixtures.txt` is there.
- A release build with the override carries the library's shaders twice;
  `tools/release_build.sh` builds the gallery without it, as it ships.

## Rules

- **Keep three.js names and signatures.** Port from three.js's source
  (`src/` layout is mirrored under `packages/threeas/three/`), keeping
  method names, argument order, defaults and constants. Where AnimaScript
  forces a change (no unions, overloads, closures or `undefined`), use the
  patterns already in the code: generic methods for "number or object"
  arguments, typed `*Parameters` classes for parameter objects, `T?` +
  `null`.
- **Prefer an existing Rive API to new code**: `Mat4` (projection, multiply,
  invert), `Image`/`Canvas` for textures, `context.image/blob/shader` for
  assets, `advance` for time, Rive pointer events for input.
- **Rive-only features go in `three/rive/`** (e.g. `ArtboardTexture`,
  `ThreeLayout`); ports of three.js addons (`examples/jsm/...`) go in
  `three/addons/` with three.js's folder names, and are not re-exported from
  `Three.as` (import them by path, as three.js's `three/addons/...`).
- **Export every public class from `three/Three.as`.**
- Engine files under `three/` declare no protocol classes (no `Layout`,
  `Node` ...), so they never become script assets of their own.
- A script's name in the library is its file stem, and its module path its
  folder plus stem: keep stems unique across `three/` and `tests/` (a test
  suite's stem ends in `_test`; those are not published).
- WGSL lives in `three/shaders/`; its uniform layouts are mirrored by hand in
  `three/renderers/gpu/Layout.as` (keep both in sync). After editing
  `three.wgsl`, run `python3 tools/make_shader_chunks.py` (from the root):
  it regenerates the ShaderChunk library (`three/shaders/lib/three_chunks.wgsl`),
  the gallery's `examples/custom_shader/lit.wgsl` and
  `three/renderers/gpu/ShaderSourceHash.as` (baked variants are named from
  that hash, so those of an older three.wgsl are then never found). Read
  fragment features through the `v_*` functions between
  `// @variant-begin` and `// @variant-end` (tools/threeas_bake.sh replaces
  them with constants), and keep `GPURenderer.programKey` in step with them
  (and the tool's `variant_block`, which parses the key).
- Baked shader variants belong to the project that draws, never the engine:
  `tools/threeas_bake.sh <project>` writes `<project>/threeas_baked/`
  (`v_<h>.wgsl`, h the FNV-1a hash of `THREE_WGSL_HASH|<programKey>`,
  `gpu/ShaderVariants.as`). Its hash and `tests/shader_variants_test.as`
  share test vectors (`tools/threeas_bake.sh --self-test`): change both or
  neither. The engine ships no variants and no registry.
- No WGSL identifier named `gl` or starting with `gl_` (WebGL2 reserves them).
- Write `T?`, never `T | null` (a union is a compile error in parameters).

- A new example is a folder `packages/gallery/examples/<name>/` with
  `<name>.as` and `<name>.rml` (its artboard with `isComponent="true"`, so
  the gallery can nest it, and its `ScriptAsset`; ids unique across the
  gallery), plus a line in `gallery/make_gallery.py`'s `EXAMPLES`; then run
  `python3 gallery/make_gallery.py --thumbs` in packages/gallery. Its
  assets go in its folder, or `examples/shared/` when several examples use
  them. Shader assets are named by path: `examples/<name>/<shader>`.
- A new test fixture goes in `packages/threeas/tests/fixtures/` and its
  stem in `fixtures.txt`; a generated one gets a line in
  `tools/sample_paths.py` (with the gallery folders that need a copy).

## Commands

```bash
cd packages/threeas
rive . --verify                                  # compile the engine and its tests
rive . --test                                    # tests/*.as, headless

cd packages/gallery
rive . --verify                                  # compile scripts, RML, shaders (engine via the override)
rive . --screenshot=build/s.png --advance=1s     # render the main artboard (Gallery)
rive . --artboard=HelloCube --screenshot=build/h.png --advance=1s
rive .                                           # live preview window
```

From the repository root:

```bash
tools/bench.sh                     # CI: verify and test both packages, bake tool self-test
                                   # and freshness, release GLSL checks, Benchmark interp +
                                   # AOT against tools/bench_baseline.txt (--bake-e2e: also
                                   # tools/bake_e2e.sh)
tools/bench.sh --update            # refresh the baseline after an intended change
rive packages/gallery --artboard=Benchmark --bench=300 --arg profile=1   # per-stage render times
tools/screenshots.sh build/shots/before                   # every example, twice
python3 tools/compare_shots.py build/shots/before build/shots/after
tools/threeas_bake.sh packages/gallery --engine=packages/threeas   # optional "optimized"
                                   # mode: bake the gallery's shader variants (any project:
                                   # tools/threeas_bake.sh <dir>; README.md)
tools/threeas_bake.sh packages/gallery --clean   # back to the uber-shader (the default)
tools/bake_e2e.sh                  # the bake tool end to end on tools/bake_fixture/, a
                                   # project outside the repository (3 minutes)
python3 tools/validate_manifest.py --all   # every example's --gpu-manifest checked against
                                           # WebGPU rules and the web limits (no GPU)
python3 tools/check_audio.py       # audio: --render-audio the gallery's AudioCheck scenarios
                                   # and measure panning, distance, cones, loops, fades
python3 tools/make_audio_samples.py        # regenerate the Audio example's sounds
tools/release_build.sh build/release       # release .rivs of the engine and the gallery
python3 tools/check_glsl.py build/release/gallery/three_as.riv
tools/publish.sh                   # publish the engine library and the gallery (below)
```

Rive's own WebGPU validator (`tools/webgpu_validate`, named by `rive --help`
for `--gpu-manifest`) does not ship with the CLI; validate_manifest.py checks
the descriptors (see its docstring for what it cannot see). Run it after
changing bindings, layouts, vertex layouts or shaders, and before
publishing.

Optimizations must not change pixels: capture `tools/screenshots.sh` before
and after and compare (the uber-shader path is pixel-identical across M14;
baked variants differ at a few edge pixels, see docs/DEVIATIONS.md). The
same capture order matters: a session's first artboards can differ by a
level or two at 1 s. To compare a bake with the uber-shader, capture with
`--arg threeUberShader=1` and without, and pass `--tolerance=2
--max-differing=1` to compare_shots.py. The repository commits the gallery
unbaked; a committed bake is checked by `tools/threeas_bake.sh
packages/gallery --engine=packages/threeas --check` (tools/bench.sh and
tools/publish.sh run it; it passes when nothing is baked).

`--verify` does not compile the GL backend's GLSL either. Before publishing
after a shader change, build release `.riv`s (`tools/release_build.sh
build/release`) and run `python3 tools/check_glsl.py` on both (needs
glslangValidator; tools/publish.sh does): WebGL2 rejects what the native
backends accept, e.g. a WGSL local named `gl` (escaped to the reserved
`gl_1`). The gallery's release has 95 GLSL shaders (the engine's 89 and the
examples' 6).

## Publishing

`tools/publish.sh` publishes the engine library, then the gallery:

```bash
tools/publish.sh --dry-run                 # print the steps
tools/publish.sh                           # engine to UAT, then the gallery
tools/publish.sh --env=prod                # engine to production, then the gallery
tools/publish.sh --env=both --description="v1.2"
tools/publish.sh --no-gallery              # the engine only
```

In order: verify and test both packages; release builds and
`check_glsl.py` on both; for each environment, swap
`packages/threeas/bindings/<env>.yaml` into the engine's `rive.yaml`
(`rive.yaml` has one `push:` binding), create the library file on a first
publish (`rive push --project=<id>`, its fileId saved to the bindings
file), and run `rive library publish` (a second time when the first run
only pushed); put the UAT binding back; then in packages/gallery `rive
library update --uat`, verify, `rive push --uat` (file 38626) and
`--publish=web` (from a copy without the override). Commit what it
changed: `packages/gallery/{threeas.rml,rive.yaml,.libraries/}` and, after
a first production publish, `packages/threeas/bindings/prod.yaml`.
Production's project id is a placeholder in `bindings/prod.yaml` until the
"ThreeAS" project exists; the script refuses `--env=prod` until it is set.
The gallery always imports the UAT library.

## Notes

`--verify` does not look at pixels: after a rendering change, take a
screenshot and look at it. Interaction can be scripted headless:
`--pointer=click@x,y`, `--pointer='drag@x1,y1>x2,y2:steps'` (quote it: `>`
is a shell redirect), `--pointer=wheel@x,y:dx,dy`, `--touch=down:1@x,y`
(multi-touch), and `--probe=x,y` prints a pixel. Headless runs advance
without drawing, so world matrices can be stale between frames.

Rive GPU limits that shape the renderer: bindings 0-7 in each bind group
(textures, samplers and buffers together), 4 bind groups, 8 vertex
buffers a pipeline (`context.features()` has the rest). Texture uploads
of block-compressed data: `bytesPerRow` is a row of blocks, but the data
must be at least `bytesPerRow x texel rows` long (pad it).

Gotchas: integer `/` truncates and `<f64>(a / b)` divides as floats (see
DEVIATIONS.md); `Array.splice` cannot insert; arrays are invariant; Rive
paints the first-declared shape on top; `Layout` already has an `update()`
hook; generic code is only type-checked once instantiated, so test it.
`context.viewModel()` on an artboard with no view model stops the script
silently (nothing renders): go through `context.dataContext()`. A
script's `init` and each `advance`/`draw` have a time budget (about
200 ms headless): spread heavy setup over frames. `context.blob(name)`
returns a `BlobAsset` (Rive CLI 1.10): `toArrayBuffer()` copies its bytes.
Test blobs (`this.blob(name)` in a suite) are found by file stem.
`gallery/make_gallery.py`, `tools/make_effects_ui.py` and
`tools/make_rive_driven_ui.py` regenerate markup without the ids the
editor added when the file was published; review the diff before
committing their output.

## Layout

```
packages/threeas/   the engine (Rive library project; see PLAN.md for the module list)
  three/            the library
  tests/            rive --test suites; fixtures/ they read
  bindings/         push bindings per environment (tools/publish.sh)
  tools/            make_ltc_tables.py
packages/gallery/   the gallery (Rive project, imports the engine library)
  gallery/          the landing page and its generator
  examples/<name>/  one example each; shared/ for common content
  tools/            make_effects_ui.py, make_rive_driven_ui.py
  threeas.rml, .libraries/   the library import
tools/              cross-package scripts (publish, bench, screenshots, shaders, samples)
docs/               DEVIATIONS.md, PERFORMANCE.md
```
