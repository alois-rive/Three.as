#!/usr/bin/env bash
# End-to-end check of tools/threeas_bake.sh on a project outside the
# repository: tools/bake_fixture/ (two artboards of a small scene and a
# --scenario) is copied to a temporary folder with the gallery's library
# import (.libraries/, threeas.rml) and an override to packages/threeas,
# as a project working on engine sources would have. Then:
#
#   1. bake it (every artboard plus the scenario) and --check it;
#   2. run it: every recorded key finds its variant;
#   3. screenshots baked vs uber-shader (--arg threeUberShader=1), compared
#      with tools/compare_shots.py --tolerance=2 --max-differing=1 (baked
#      variants differ at a few edge pixels, docs/DEVIATIONS.md);
#   4. the cost of a miss: the Lit artboard's --bench render mean baked,
#      unbaked (each key looked up once, not found) and with lookups off;
#   5. --check fails on an edited variant; --clean; the default engine
#      source (the downloaded snapshot) in a --dry-run.
#
#   tools/bake_e2e.sh            the checks above
#   tools/bake_e2e.sh --glsl     also a release build of the baked project
#                                and tools/check_glsl.py on it (rive login)
#   tools/bake_e2e.sh --keep     keep the temporary folder (printed)
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(pwd)
keep=0
glsl=0
for arg in "$@"; do
    case "$arg" in
        --keep) keep=1 ;;
        --glsl) glsl=1 ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "unknown option $arg" >&2; exit 2 ;;
    esac
done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/threeas_bake_e2e.XXXXXX")
cleanup() { if [ "$keep" = 1 ]; then echo "kept $tmp"; else rm -rf "$tmp"; fi; }
trap cleanup EXIT
failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
ok() { echo "ok   $*"; }

# The project: the fixture, the gallery's import of the engine library, and
# its libraries: entry with an override to the engine sources.
make_project() {   # $1: dir, $2: 1 for the override
    mkdir -p "$1"
    cp tools/bake_fixture/bake_scene.as tools/bake_fixture/bake_scene.rml "$1/"
    cp -R packages/gallery/.libraries "$1/"
    cp packages/gallery/threeas.rml "$1/"
    {
        echo "name: bake_fixture"
        echo "main: Lit"
        echo "scripting: wasm"
        echo "exclude:"
        echo "  - build"
        echo "libraries:"
        echo '  "threeas":'
        grep -E '^    (fileId|libraryId|version):' packages/gallery/rive.yaml
        if [ "$2" = 1 ]; then echo "    override: $root/packages/threeas"; fi
    } > "$1/rive.yaml"
}
proj="$tmp/bake_fixture"
make_project "$proj" 1
scenario=tools/bake_fixture/late.commands

# ---------------------------------------------------------------- 1. bake
if tools/threeas_bake.sh "$proj" --engine=packages/threeas --scenario="$scenario" > "$tmp/bake.log" 2>&1; then
    variants=$(ls "$proj"/threeas_baked/v_*.wgsl 2>/dev/null | wc -l | tr -d ' ')
    ok "bake: $variants variants"
    sed -n '/^program keys per source/,/distinct keys/p' "$tmp/bake.log" | sed 's/^/     /'
    late=$(awk '$1 == "scenario:late.commands" { print $2 }' "$tmp/bake.log")
    [ "${late:-0}" -gt 0 ] || fail "the scenario recorded no keys"
    [ "$variants" -gt 0 ] || fail "no variants written"
else
    cat "$tmp/bake.log"
    fail "bake"
    exit 1
fi
if tools/threeas_bake.sh "$proj" --engine=packages/threeas --scenario="$scenario" --check > "$tmp/check.log" 2>&1; then
    ok "$(tail -n 1 "$tmp/check.log")"
else
    cat "$tmp/check.log"
    fail "--check right after the bake"
fi

# ------------------------------------------------- 2. and 3. run and look
shots() {   # $1: out dir, extra rive flags...
    local dir="$1"
    shift
    mkdir -p "$dir"
    printf 'artboard Plain\nadvance 1s\nscreenshot %s/plain.png\nartboard Lit\nadvance 1s\nscreenshot %s/lit.png\nadvance 4s\nscreenshot %s/lit.5s.png\nquit\n' \
        "$dir" "$dir" "$dir" > "$tmp/shots.commands"
    rive "$proj" --commands="$tmp/shots.commands" "$@" > "$dir/rive.log" 2>&1
}
shots "$tmp/baked" --arg threeShaderKeys=1
shots "$tmp/uber" --arg threeUberShader=1
found=$(grep -c "three shader key: .* baked$" "$tmp/baked/rive.log" || true)
missed=$(grep -c "three shader key: .* uber$" "$tmp/baked/rive.log" || true)
if [ "$found" -gt 0 ] && [ "$missed" = 0 ]; then
    ok "run: every key drew its variant ($found lookups found)"
else
    fail "run: $found keys found a variant, $missed did not (see $tmp/baked/rive.log)"
fi
if python3 -W ignore tools/compare_shots.py "$tmp/uber" "$tmp/baked" --tolerance=2 --max-differing=1 \
    > "$tmp/compare.log" 2>&1; then
    ok "pixels: baked vs uber-shader, at most 1% of the pixels off by more than 2 levels"
else
    fail "pixels: baked vs uber-shader"
fi
sed 's/^/     /' "$tmp/compare.log"

# --------------------------------------------------------- 4. miss cost
bench() {   # label, flags...
    local label="$1"
    shift
    rive "$proj" --artboard=Lit --bench=300 "$@" > "$tmp/bench.log" 2>&1 || { fail "bench $label"; return; }
    printf '     %-34s %s\n' "$label" "$(sed -n 's/.*bench render: \(mean [0-9.]*ms\).*/\1/p' "$tmp/bench.log")"
}
echo "     Lit, --bench=300 render (interpreted):"
bench "baked"
cp -R "$proj/threeas_baked" "$tmp/saved_bake"
rm -rf "$proj/threeas_baked"
bench "no bake (lookups miss)"
bench "no bake, lookups off (threeUberShader)" --arg threeUberShader=1
cp -R "$tmp/saved_bake" "$proj/threeas_baked"

# ------------------------------------------ 5. stale, clean, snapshot
first=$(ls "$proj"/threeas_baked/v_*.wgsl | head -n 1)
echo "// edited" >> "$first"
if tools/threeas_bake.sh "$proj" --engine=packages/threeas --scenario="$scenario" --check > "$tmp/stale.log" 2>&1; then
    fail "--check passed with an edited variant"
else
    ok "--check fails on an edited variant: $(tail -n 1 "$tmp/stale.log")"
fi
tools/threeas_bake.sh "$proj" --clean > /dev/null
if [ -d "$proj/threeas_baked" ]; then fail "--clean left $proj/threeas_baked"; else ok "--clean"; fi

plain="$tmp/snapshot_fixture"
make_project "$plain" 0
if tools/threeas_bake.sh "$plain" --main --dry-run > "$tmp/snapshot.log" 2>&1; then
    ok "snapshot $(tail -n 1 "$tmp/snapshot.log")"
    grep "warning" "$tmp/snapshot.log" | sed 's/^/     /' || true
else
    cat "$tmp/snapshot.log"
    fail "dry run against the downloaded snapshot"
fi

# ------------------------------------------------------------- GLSL
if [ "$glsl" = 1 ]; then
    tools/threeas_bake.sh "$proj" --engine=packages/threeas --scenario="$scenario" > /dev/null 2>&1
    if rive "$proj" --publish --output-dir="$tmp/release" > "$tmp/release.log" 2>&1; then
        riv=$(ls "$tmp"/release/*.riv | head -n 1)
        if python3 tools/check_glsl.py "$riv" > "$tmp/glsl.log" 2>&1; then
            ok "release $(du -h "$riv" | cut -f1): $(tail -n 1 "$tmp/glsl.log")"
        else
            cat "$tmp/glsl.log"
            fail "GLSL of the baked release"
        fi
    else
        fail "release build (see $tmp/release.log; needs rive login)"
        keep=1
    fi
fi

if [ "$failures" -gt 0 ]; then
    echo "$failures failure(s)"
    keep=1
    exit 1
fi
echo "all passed"
