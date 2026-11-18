# Working on ThreeAS

ThreeAS is three.js ported to Rive: AnimaScript (`.as`) scripts that render
with Rive's `GPUCanvas` and WGSL shaders. Read these before changing code:

- [docs/DEVIATIONS.md](docs/DEVIATIONS.md): every difference from three.js.
  **Read it before porting anything from three.js sources**, and update it
  in the same change when you add, remove or alter a deviation.
- [PLAN.md](PLAN.md): milestones and what is in scope now.
- `rive docs animascript/protocols`, `rive docs gpu`,
  `rive docs animascript/api/<module>`: the language and the Rive APIs.

## Rules

- **Keep three.js names and signatures.** Port from three.js's source
  (`src/` layout is mirrored under `three/`), keeping method names, argument
  order, defaults and constants. Where AnimaScript forces a change (no
  unions, overloads, closures or `undefined`), use the patterns already in
  the code: generic methods for "number or object" arguments, typed
  `*Parameters` classes for parameter objects, `T?` + `null`.
- **Prefer an existing Rive API to new code**: `Mat4` (projection, multiply,
  invert), `Image`/`Canvas` for textures, `context.image/blob/shader` for
  assets, `advance` for time, Rive pointer events for input.
- **Rive-only features go in `three/rive/`** (e.g. `ArtboardTexture`).
- **Export every public class from `three/Three.as`.**
- Library files under `three/` declare no protocol classes (no `Layout`,
  `Node` ...), so they never become script assets of their own.
- WGSL lives in `three/shaders/`; its uniform layouts are mirrored by hand in
  `three/renderers/GPURenderer.as` (keep both in sync).
- Write `T?`, never `T | null` (a union is a compile error in parameters).

## Commands

```bash
rive . --verify                                  # compile scripts, RML, shaders
rive . --test                                    # tests/*.as, headless
rive . --screenshot=build/s.png --advance=1s     # render the main artboard
rive . --artboard=HelloCube --screenshot=build/h.png --advance=1s
rive .                                           # live preview window
```

`--verify` does not look at pixels: after a rendering change, take a
screenshot and look at it.

## Layout

```
three/        the library (see PLAN.md for the module list)
examples/     example artboards: examples.rml + one .as per example
tests/        rive --test suites
docs/         DEVIATIONS.md
```
