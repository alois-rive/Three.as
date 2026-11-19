#!/usr/bin/env bash
# The regression bench for CI: compiles and tests both projects
# (packages/threeas, the engine, and packages/gallery), checks the WebGL2
# GLSL of their release builds and the baked shader variants' freshness,
# then times the gallery's Benchmark artboard (interpreted and ahead of
# time; the gallery builds packages/threeas through its library override)
# and compares the means with tools/bench_baseline.txt.
#
#   tools/bench.sh                    everything; exit 1 on a failure or regression
#   tools/bench.sh --update           rewrite the baseline from this run
#   tools/bench.sh --tolerance=40     allowed slowdown in percent (default 30)
#   tools/bench.sh --skip-glsl        no release build (it takes a minute or two)
#   tools/bench.sh --frames=600       frames a bench times (default 300)
#   tools/bench.sh --manifests        also check every example's --gpu-manifest
#                                     (tools/validate_manifest.py --all, 3 minutes)
# Logs go to build/bench/ at the repository root.
#
# Timings depend on the machine: keep one baseline per CI machine (the
# stored one is from the M-series Mac M14 was measured on) and refresh it
# with --update after an intended change. A metric fails when it is slower
# than baseline x (1 + tolerance) + 0.1 ms; wasm memory must not grow.
set -uo pipefail
cd "$(dirname "$0")/.."

tolerance=30
update=0
glsl=1
frames=300
manifests=0
for arg in "$@"; do
    case "$arg" in
        --update) update=1 ;;
        --tolerance=*) tolerance="${arg#--tolerance=}" ;;
        --skip-glsl) glsl=0 ;;
        --frames=*) frames="${arg#--frames=}" ;;
        --manifests) manifests=1 ;;
        -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
        *) echo "unknown option $arg" >&2; exit 2 ;;
    esac
done

BASELINE=tools/bench_baseline.txt
WORK=build/bench
ENGINE=packages/threeas
GALLERY=packages/gallery
mkdir -p "$WORK"
failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }

step() {   # name, command...: runs it into $WORK/<name>.log
    local name="$1"; shift
    if "$@" > "$WORK/$name.log" 2>&1; then
        echo "ok   $name"
    else
        fail "$name (see $WORK/$name.log)"
    fi
}

step verify-engine rive "$ENGINE" --verify
grep -q " 0 warnings" "$WORK/verify-engine.log" || fail "engine verify has warnings (see $WORK/verify-engine.log)"
step verify-gallery rive "$GALLERY" --verify
grep -q " 0 warnings" "$WORK/verify-gallery.log" || fail "gallery verify has warnings (see $WORK/verify-gallery.log)"
grep -q "falling back to the downloaded library" "$WORK/verify-gallery.log" \
    && fail "the gallery's library override was refused: it builds the published engine (see $WORK/verify-gallery.log)"
step test-engine rive "$ENGINE" --test
step test-gallery rive "$GALLERY" --test
step bake-check tools/bake_shaders.sh --check

if [ "$glsl" = 1 ]; then
    # Release .rivs of the engine (every engine shader) and of the gallery
    # as it ships, built from copies without the push bindings.
    step release tools/release_build.sh "$WORK/release"
    for riv in "$WORK"/release/threeas/threeas.riv "$WORK"/release/gallery/three_as.riv; do
        name=$(basename "$(dirname "$riv")")
        if [ -f "$riv" ]; then
            step "glsl-$name" python3 tools/check_glsl.py "$riv"
            echo "     $name: $(tail -n 1 "$WORK/glsl-$name.log")"
        else
            fail "release build wrote no $riv"
        fi
    done
fi

if [ "$manifests" = 1 ]; then
    step manifests python3 tools/validate_manifest.py --all
    grep -c ": ok$" "$WORK/manifests.log" | sed 's/^/     artboards with valid manifests: /'
fi

# ------------------------------------------------------------------- bench
measure() {   # tier, extra flags...: prints "<tier>.advance <ms>" and "<tier>.render <ms>"
    local tier="$1"; shift
    local log="$WORK/bench-$tier.log"
    if ! rive "$GALLERY" --artboard=Benchmark --bench="$frames" "$@" > "$log" 2>&1; then
        fail "bench $tier (see $log)"
        return
    fi
    sed -n "s/.*bench advance: mean \([0-9.]*\)ms.*/$tier.advance \1/p" "$log"
    sed -n "s/.*bench render: mean \([0-9.]*\)ms.*/$tier.render \1/p" "$log"
    local growth
    growth=$(sed -n 's/.*wasm pages (+\([0-9]*\)).*/\1/p' "$log")
    [ "${growth:-0}" = 0 ] || fail "bench $tier: wasm memory grew $growth pages"
}

{
    measure interp
    measure aot --aot
} > "$WORK/results.txt"
echo "bench (Benchmark artboard, $frames frames, mean ms):"
sed 's/^/     /' "$WORK/results.txt"

if [ "$update" = 1 ]; then
    {
        echo "# tools/bench.sh baseline: Benchmark artboard means in ms ($(uname -m), $(date +%Y-%m-%d))."
        echo "# Refresh with tools/bench.sh --update after an intended change."
        cat "$WORK/results.txt"
    } > "$BASELINE"
    echo "wrote $BASELINE"
elif [ -f "$BASELINE" ]; then
    while read -r metric value; do
        case "$metric" in \#*|"") continue ;; esac
        base=$(awk -v m="$metric" '$1 == m { print $2 }' "$BASELINE")
        if [ -z "$base" ]; then
            echo "     $metric: no baseline"
            continue
        fi
        verdict=$(awk -v v="$value" -v b="$base" -v t="$tolerance" \
            'BEGIN { limit = b * (1 + t / 100) + 0.1; printf "%s %.3f %+.0f%%", (v > limit ? "slow" : "ok"), limit, (v / b - 1) * 100 }')
        set -- $verdict
        if [ "$1" = slow ]; then
            fail "$metric $value ms > $2 ms (baseline $base, $3)"
        else
            echo "ok   $metric $value ms (baseline $base, $3)"
        fi
    done < "$WORK/results.txt"
else
    echo "no $BASELINE: run tools/bench.sh --update"
fi

if [ "$failures" -gt 0 ]; then
    echo "$failures failure(s)"
    exit 1
fi
echo "all passed"
