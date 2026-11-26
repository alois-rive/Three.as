#!/usr/bin/env bash
# Bakes ThreeAS shader variants for a Rive project that imports the engine
# ("optimized" mode, PLAN.md M18). Optional: without a bake every draw uses
# the uber-shader, three/shaders/three.wgsl, which handles any material.
#
#   tools/threeas_bake.sh <project-dir> [options]
#
#   --artboard=A,B     record these artboards (default: every artboard in the
#                      project's .rml files)
#   --main             record the main artboard (rive.yaml's main:) only
#   --time=3s          how long each artboard plays (N frames, Ns or Nms;
#                      drawn after 1 s and at the end; default 3s)
#   --scenario=FILE    also play a `rive --commands` script (pointer events,
#                      `data` writes, later frames ...) from a fresh main
#                      artboard; repeatable
#   --keys=FILE        also bake the program keys in FILE (any text: a log of
#                      `rive <dir> --arg threeShaderKeys=1` while someone
#                      played it, a web console ...); repeatable
#   --max=N            bake at most N variants, the keys most artboards draw
#                      first (default 48)
#   --engine=DIR       bake from DIR/three/shaders/three.wgsl (engine sources,
#                      e.g. a library override) instead of the snapshot the
#                      project imports (.libraries/threeas@*/)
#   --dry-run          record and report; write nothing
#   --check            record again and fail if <project>/threeas_baked
#                      differs (stale keys, or variants of another three.wgsl)
#   --clean            remove <project>/threeas_baked (uber-shader only)
#   --self-test        check the variant name hash against its test vectors
#   -h, --help         this text
#
# It runs the project headless (one build, `rive --commands`) with
# `--arg threeShaderKeys=1`: each renderer logs every program key it draws
# once (GPURenderer.programKey, three.js's getProgramCacheKey). Scenes are
# built by script code at runtime, so recording is how a project is
# analysed: states reached only by interaction need a --scenario or --keys.
#
# For each key it writes <project>/threeas_baked/v_<h>.wgsl, <h> the 64-bit
# FNV-1a hash of "<THREE_WGSL_HASH>|<key>": three.wgsl with the lines between
# `// @variant-begin` and `// @variant-end` replaced by the key's constants
# (the compiler drops the branches and samples the draw does not need and
# unrolls its light loop) and only the key's two entry points. The renderer
# finds a variant by that name (three/renderers/gpu/ShaderVariants.as);
# a key with none, or a bake from another three.wgsl, draws with the
# uber-shader. threeas_baked/keys.txt lists the keys, their assets and the
# artboards that drew them (for people and --check; not read at runtime).
#
# Each variant adds compiled shaders for every backend to the .riv (about
# 0.5 MB). After baking, build a release .riv and check its WebGL2 GLSL:
#   rive <dir> --publish --output-dir=build/release   (a copy without push:)
#   python3 tools/check_glsl.py build/release/<name>.riv
set -euo pipefail
export LC_ALL=C

RIVE="${RIVE:-rive}"
OUT_NAME=threeas_baked
EST_KB_PER_VARIANT=500

die() { echo "threeas_bake: $*" >&2; exit 1; }
note() { echo "threeas_bake: $*" >&2; }

# ------------------------------------------------------------------ hashing

# 64-bit FNV-1a of an ASCII string, 16 lowercase hex digits. Bash arithmetic
# is signed 64-bit and wraps, which is the unsigned product's bit pattern;
# printf %x prints those bits.
fnv1a64() {
    local s="$1" h=$((0xcbf29ce484222325)) i c
    for ((i = 0; i < ${#s}; i++)); do
        printf -v c '%d' "'${s:i:1}"
        h=$(( (h ^ c) * 0x100000001b3 ))
    done
    printf '%016x\n' "$h"
}

# The asset name of a key's variant: $1 THREE_WGSL_HASH, $2 the key.
variant_name() { echo "$OUT_NAME/v_$(fnv1a64 "$1|$2")"; }

# The same vectors as packages/threeas/tests/shader_variants_test.as.
self_test() {
    local key="kind=3;present=1;roles=0;flags=0;cutout=0;flat=0;env=0;scene=0;fog=0;hemi=1;linear=0;lights=d;vs=vs_main;fs=fs_main"
    local failed=0 got want input
    while IFS='=' read -r want input; do
        got=$(fnv1a64 "$input")
        if [ "$got" != "$want" ]; then echo "FAIL fnv1a64('$input') = $got, want $want"; failed=1; fi
    done <<EOF
cbf29ce484222325=
af63dc4c8601ec8c=a
85944171f73967e8=foobar
12602aff92ec183d=0123456789abcdef|$key
EOF
    got=$(variant_name 0123456789abcdef "$key")
    [ "$got" = "$OUT_NAME/v_12602aff92ec183d" ] || { echo "FAIL variant_name = $got"; failed=1; }
    [ "$failed" = 0 ] && echo "self-test passed (5 vectors)"
    return $failed
}

# ------------------------------------------------------------------ options
project=""
engine=""
artboard_list=""
main_only=0
time_arg=3s
max=48
mode=bake
scenarios=()
keys_files=()
for arg in "$@"; do
    case "$arg" in
        --artboard=*) artboard_list="${arg#--artboard=}" ;;
        --main) main_only=1 ;;
        --time=*) time_arg="${arg#--time=}" ;;
        --scenario=*) scenarios+=("${arg#--scenario=}") ;;
        --keys=*) keys_files+=("${arg#--keys=}") ;;
        --max=*) max="${arg#--max=}" ;;
        --engine=*) engine="${arg#--engine=}" ;;
        --dry-run) mode=dry ;;
        --check) mode=check ;;
        --clean) mode=clean ;;
        --self-test) self_test; exit $? ;;
        -h|--help) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option $arg (see --help)" ;;
        *) [ -z "$project" ] || die "one project directory, not '$project' and '$arg'"; project="$arg" ;;
    esac
done
[ -n "$project" ] || die "usage: tools/threeas_bake.sh <project-dir> [options] (see --help)"
[ -f "$project/rive.yaml" ] || die "$project is not a Rive project (no rive.yaml)"
case "$max" in ''|*[!0-9]*) die "--max wants a number, not '$max'" ;; esac
project="$(cd "$project" && pwd)"
out="$project/$OUT_NAME"
for f in ${scenarios[@]+"${scenarios[@]}"} ${keys_files[@]+"${keys_files[@]}"}; do
    [ -f "$f" ] || die "no file $f"
done

if [ "$mode" = clean ]; then
    if [ -d "$out" ]; then
        rm -rf "$out"
        echo "removed $out: every draw uses the uber-shader"
    else
        echo "nothing baked in $project"
    fi
    exit 0
fi
if [ "$mode" = check ] && [ ! -f "$out/keys.txt" ]; then
    echo "no $OUT_NAME/keys.txt in $project (uber-shader only): nothing to check"
    exit 0
fi

# ------------------------------------------------------- the engine baked
sha256_prefix() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -c1-16
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -c1-16
    else
        die "neither shasum nor sha256sum found"
    fi
}

rml_files() {
    find "$project" \( -name '.?*' -o -path "$project/build" -o -path "$out" \) -prune -o -name '*.rml' -print0
}

cat_rml_files() {
    local f
    while IFS= read -r -d '' f; do
        cat "$f"
    done < <(rml_files)
}

if [ -n "$engine" ]; then
    [ -d "$engine" ] || die "no engine directory $engine"
    engine="$(cd "$engine" && pwd)"
    src="$engine/three/shaders/three.wgsl"
    hash_as="$engine/three/renderers/gpu/ShaderSourceHash.as"
    renderer_as="$engine/three/renderers/GPURenderer.as"
    [ -f "$src" ] || die "no three/shaders/three.wgsl in $engine (is it the threeas engine?)"
else
    # The snapshot the project imports: .libraries/<name>@<assetId>/, the one
    # the project's markup names (LibraryAsset assetId) when there are several.
    snapshots=()
    for f in "$project"/.libraries/*/three_shaders_three.wgsl; do
        [ -f "$f" ] && snapshots+=("$(dirname "$f")")
    done
    [ ${#snapshots[@]} -gt 0 ] || die "no threeas library in $project/.libraries (rive library update <project>, or pass --engine=DIR)"
    snapshot="${snapshots[0]}"
    if [ ${#snapshots[@]} -gt 1 ]; then
        used=$(cat_rml_files | tr '\n' ' ' | { grep -o '<LibraryAsset [^>]*>' || true; } | sed -n 's/.* assetId="\([0-9]*\)".*/\1/p')
        for s in "${snapshots[@]}"; do
            for id in $used; do [ "${s##*@}" = "$id" ] && snapshot="$s"; done
        done
    fi
    src="$snapshot/three_shaders_three.wgsl"
    hash_as="$snapshot/three/renderers/gpu/ShaderSourceHash.as"
    renderer_as="$snapshot/three/renderers/GPURenderer.as"
    if grep -q '^ *override:' "$project/rive.yaml"; then
        note "rive.yaml overrides a library: if it is threeas, previews run its sources; pass --engine=<override dir> to bake for them"
    fi
fi
hash=$(sha256_prefix "$src")
if [ -f "$hash_as" ]; then
    declared=$(sed -n 's/.*THREE_WGSL_HASH: string = "\([0-9a-f]*\)".*/\1/p' "$hash_as")
    [ "$declared" = "$hash" ] || die "$hash_as says three.wgsl is $declared, it is $hash (engine sources: run tools/make_shader_chunks.py)"
fi
if [ -f "$renderer_as" ] && ! grep -q "ShaderVariants" "$renderer_as"; then
    note "warning: this threeas predates project bakes (M18) and ignores $OUT_NAME/; update the library first"
fi

# -------------------------------------------------------------- the scenes
main_artboard=$(sed -n 's/^main: *"\{0,1\}\([^"#]*[^"# ]\)"\{0,1\} *\(#.*\)\{0,1\}$/\1/p' "$project/rive.yaml" | head -n 1)
artboards=()
if [ -n "$artboard_list" ]; then
    IFS=',' read -r -a artboards <<< "$artboard_list"
elif [ "$main_only" = 1 ]; then
    [ -n "$main_artboard" ] || die "rive.yaml has no main: artboard (use --artboard=NAME)"
    artboards=("$main_artboard")
else
    while IFS= read -r a; do [ -n "$a" ] && artboards+=("$a"); done < <(cat_rml_files | tr '\n' ' ' \
        | { grep -o '<Artboard [^>]*>' || true; } | sed -n 's/.* name="\([^"]*\)".*/\1/p')
fi
[ ${#artboards[@]} -gt 0 ] || [ ${#scenarios[@]} -gt 0 ] || [ ${#keys_files[@]} -gt 0 ] \
    || die "no artboards found in $project's .rml files"
[ -n "$main_artboard" ] || main_artboard="${artboards[0]:-}"

# --time in ms (N frames at 60 fps, Ns or Nms), split into the first capture
# (at 1 s, or the whole time when shorter) and the rest.
total_ms=$(awk -v t="$time_arg" 'BEGIN {
    if (t ~ /^[0-9.]+ms$/) v = substr(t, 1, length(t) - 2);
    else if (t ~ /^[0-9.]+s$/) v = substr(t, 1, length(t) - 1) * 1000;
    else if (t ~ /^[0-9]+$/) v = t * 1000 / 60;
    else v = -1;
    printf "%d", v }')
[ "$total_ms" -gt 0 ] || die "--time wants N (frames), Ns or Nms, not '$time_arg'"
first_ms=$(( total_ms < 1000 ? total_ms : 1000 ))
rest_ms=$(( total_ms - first_ms ))

WORK=$(mktemp -d "${TMPDIR:-/tmp}/threeas_bake.XXXXXX")
keep_work=0
restore=""
cleanup() {
    if [ -n "$restore" ] && [ -d "$restore" ]; then
        rm -rf "$out"
        mv "$restore" "$out"
    fi
    if [ "$keep_work" = 0 ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT
mkdir -p "$WORK/marks"

# One command stream: each source (an artboard or a scenario) ends with a
# capture named for it, and the keys its frames log before that capture's
# "wrote" line are its own.
sources="$WORK/sources.txt"
commands="$WORK/commands.txt"
: > "$sources"
: > "$commands"
n=0
for a in ${artboards[@]+"${artboards[@]}"}; do
    n=$((n + 1))
    printf '%s\t%s\n' "m$n" "$a" >> "$sources"
    {
        echo "artboard $a"
        echo "advance ${first_ms}ms"
        echo "screenshot $WORK/marks/m${n}_first.png"
        if [ "$rest_ms" -gt 0 ]; then
            echo "advance ${rest_ms}ms"
            echo "screenshot $WORK/marks/m$n.png"
        fi
    } >> "$commands"
done
for f in ${scenarios[@]+"${scenarios[@]}"}; do
    n=$((n + 1))
    printf '%s\t%s\n' "m$n" "scenario:$(basename "$f")" >> "$sources"
    [ -n "$main_artboard" ] && echo "artboard $main_artboard" >> "$commands"
    grep -v '^[[:space:]]*quit[[:space:]]*$' "$f" >> "$commands" || true
    echo "" >> "$commands"
    echo "screenshot $WORK/marks/m$n.png" >> "$commands"
done
echo "quit" >> "$commands"

# Moved aside while recording (old variants may not build); put back unless
# a bake replaces them.
if [ "$mode" = bake ] && [ -d "$out" ]; then
    restore="$WORK/previous"
    mv "$out" "$restore"
fi

recorded="$WORK/recorded.tsv"   # key <TAB> source <TAB> the name the renderer looked up
: > "$recorded"
if [ -s "$sources" ]; then
    count_sources=$(wc -l < "$sources" | tr -d ' ')
    note "recording $count_sources artboards/scenarios in $project for ${total_ms} ms each..."
    log="$WORK/record.log"
    started=$SECONDS
    if ! "$RIVE" "$project" --commands="$commands" --arg threeShaderKeys=1 > "$log" 2>&1; then
        keep_work=1
        die "rive failed; see $log"
    fi
    if grep -q "^err" "$log"; then
        keep_work=1
        grep "^err" "$log" >&2
        die "a command failed; see $log"
    fi
    if [ -n "$engine" ] && grep -q "falling back to the downloaded library" "$log"; then
        keep_work=1
        grep "falling back" "$log" >&2
        die "--engine=$engine, but the project built its downloaded library (the override was refused); see $log"
    fi
    awk -F '\t' -v sources="$sources" '
        BEGIN { while ((getline line < sources) > 0) { split(line, f, "\t"); name[f[1]] = f[2] } }
        /three shader key: kind=/ {
            s = $0; sub(/.*three shader key: /, "", s)
            n = split(s, w, " ")
            pending[++np] = w[1] "\t" (n >= 2 ? w[2] : "")
            next
        }
        / wrote .*\/marks\/m[0-9]+(_first)?\.png/ {
            m = $0; sub(/.*\/marks\//, "", m); sub(/(_first)?\.png.*/, "", m)
            for (i = 1; i <= np; i++) { split(pending[i], p, "\t"); print p[1] "\t" name[m] "\t" p[2] }
            np = 0
        }
    ' "$log" > "$recorded"
    note "recorded in $((SECONDS - started)) s"
fi
for f in ${keys_files[@]+"${keys_files[@]}"}; do
    sed -n 's/.*\(kind=[^ ]*;fs=[a-z_]*\).*/\1/p' "$f" | awk -v src="keys:$(basename "$f")" '{ print $0 "\t" src "\t" }' >> "$recorded"
done

# The renderer named each key from the three.wgsl it runs: it must be the
# one baked from, or no variant would ever be found.
mismatch=""
old_engine=0
while IFS=$'\t' read -r key source looked; do
    case "$source" in keys:*) continue ;; esac
    if [ -z "$looked" ]; then old_engine=1; continue; fi
    if [ "$looked" != "$(variant_name "$hash" "$key")" ]; then mismatch="$key"; break; fi
done < <(sort -u -t $'\t' -k1,1 "$recorded")
if [ -n "$mismatch" ]; then
    keep_work=1
    die "the project runs another three.wgsl than $src ($hash): its renderer named $mismatch's variant differently. Bake from what it runs (--engine=DIR for a library override, or rive pull)"
fi
[ "$old_engine" = 0 ] || note "warning: the renderer did not name variants (a threeas older than M18): the bake will not be used until the library is updated"

# --------------------------------------------------------------- the keys
# Each key once per source; past --max, the keys most sources draw first.
cut -f1,2 "$recorded" | sort -u > "$WORK/pairs.tsv"
awk -F '\t' '{ c[$1]++; s[$1] = (s[$1] == "" ? $2 : s[$1] "," $2) } END { for (k in c) print c[k] "\t" k "\t" s[k] }' \
    "$WORK/pairs.tsv" | sort -t $'\t' -k1,1nr -k2,2 > "$WORK/counted.tsv"
total_keys=$(wc -l < "$WORK/counted.tsv" | tr -d ' ')
shared=$(awk -F '\t' '$1 > 1' "$WORK/counted.tsv" | wc -l | tr -d ' ')
head -n "$max" "$WORK/counted.tsv" | sort -t $'\t' -k2,2 > "$WORK/selected.tsv"
tail -n +"$((max + 1))" "$WORK/counted.tsv" > "$WORK/dropped.tsv"
selected=$(wc -l < "$WORK/selected.tsv" | tr -d ' ')

# ---------------------------------------------------------------- generate
bool() { [ "$1" = 1 ] && echo true || echo false; }

# A key's entry points, comma separated (its vs= and fs= fields).
entry_points() {
    local key="$1" vs fs
    vs=$(printf '%s' "$key" | sed -n 's/.*;vs=\([a-z_]*\).*/\1/p')
    fs=$(printf '%s' "$key" | sed -n 's/.*;fs=\([a-z_]*\).*/\1/p')
    echo "${vs:-vs_main},${fs:-fs_main}"
}

# three.wgsl with the variant block replaced and only the key's two entry
# points (a variant draws one pipeline family; each entry point costs a
# compiled shader per backend in the .riv). A vertex entry that does not
# skin (or morph) keeps the bone (and morph) block bound by reading one
# value of it: the bind group layouts stay the uber-shader's.
specialize() {   # $1: block file, $2: entry points
    awk -v block="$1" -v keep="$2" '
        BEGIN { n = split(keep, names, ","); for (i = 1; i <= n; i++) wanted[names[i]] = 1 }
        /\/\/ @variant-begin/ { while ((getline line < block) > 0) print line; skip = 1; next }
        /\/\/ @variant-end/ { skip = 0; next }
        skip { next }
        /^@vertex$|^@fragment$/ { attr = $0; pending = 1; next }
        pending {
            pending = 0
            name = $0; sub(/^fn /, "", name); sub(/\(.*/, "", name)
            if (!(name in wanted)) { dropping = 1; next }
            print attr; print
            if (attr == "@vertex" && name !~ /skinned/) print "    let keep_bones = B.bones[0][0].x;"
            if (attr == "@vertex" && name !~ /vs_main|vs_displaced|skinned|morph_instanced/) print "    let keep_morph = M.info.x;"
            next
        }
        dropping { if ($0 == "}") dropping = 0; next }
        { print }
    ' "$src"
}

# The variant block for one key, on stdout.
variant_block() {
    local key="$1" kind=0 present=0 roles=0 flags=0 cutout=1 flat=0 env=0 scene=0 fog=0 hemi=0 linear=0 lights=-
    local IFS=';' field name value
    for field in $key; do
        name="${field%%=*}"
        value="${field#*=}"
        case "$name" in
            kind) kind=$value ;; present) present=$value ;; roles) roles=$value ;; flags) flags=$value ;;
            cutout) cutout=$value ;; flat) flat=$value ;; env) env=$value ;; scene) scene=$value ;;
            fog) fog=$value ;; hemi) hemi=$value ;; linear) linear=$value ;; lights) lights=$value ;;
            vs|fs) ;;   # the entry points: kept by entry_points
            *) echo "unknown key field $name in $key" >&2; return 1 ;;
        esac
    done
    unset IFS
    [ "$lights" = "-" ] && lights=""
    echo "// @variant-begin"
    echo "fn v_kind() -> u32 { return ${kind}u; }"
    echo "fn v_present() -> u32 { return ${present}u; }"
    echo "fn v_flags() -> u32 { return ${flags}u; }"
    echo "fn v_role(role: u32) -> bool { return ((${roles}u >> role) & 1u) != 0u; }"
    echo "fn v_cutout() -> bool { return $(bool "$cutout"); }"
    echo "fn v_flat() -> bool { return $(bool "$flat"); }"
    echo "fn v_own_env() -> bool { return $(bool "$env"); }"
    echo "fn v_scene_env() -> bool { return $(bool "$scene"); }"
    echo "fn v_fog() -> f32 { return ${fog}.0; }"
    echo "fn v_hemi() -> bool { return $(bool "$hemi"); }"
    echo "fn v_linear() -> bool { return $(bool "$linear"); }"
    echo "fn v_light_count() -> u32 { return ${#lights}u; }"
    echo "fn v_light_type(k: u32, light: Light) -> f32 {"
    local i t
    for ((i = 0; i < ${#lights}; i++)); do
        t=0.0
        case "${lights:i:1}" in d) t=0.0 ;; p) t=1.0 ;; s) t=2.0 ;; r) t=3.0 ;; esac
        echo "    if (k == ${i}u) { return $t; }"
    done
    echo "    return 0.0;"
    echo "}"
    echo "// @variant-end"
}

gen="$WORK/$OUT_NAME"
mkdir -p "$gen"
{
    echo "# Written by tools/threeas_bake.sh: the program keys this project's shader"
    echo "# variants were baked for, from three.wgsl $hash. Not read at runtime: the"
    echo "# renderer finds a key's variant by its name. Rebake rather than edit."
    echo "# key<TAB>asset<TAB>drawn by"
} > "$gen/keys.txt"
while IFS=$'\t' read -r count key drawn; do
    asset=$(variant_name "$hash" "$key")
    variant_block "$key" > "$WORK/block.wgsl"
    {
        echo "// Generated by tools/threeas_bake.sh from three.wgsl $hash: the uber-shader"
        echo "// specialized for the program key"
        echo "// $key"
        echo "// Do not edit; rebake."
        specialize "$WORK/block.wgsl" "$(entry_points "$key")"
    } > "$WORK/$asset.wgsl"
    printf '%s\t%s\t%s\n' "$key" "$asset" "$drawn" >> "$gen/keys.txt"
done < "$WORK/selected.tsv"

# ------------------------------------------------------------------ report
echo "program keys per source:"
awk -F '\t' 'NR == FNR { order[++n] = $2; next } { c[$2]++ } END { for (i = 1; i <= n; i++) printf "  %-28s %d\n", order[i], c[order[i]] }' \
    <(awk -F '\t' '{ print $1 "\t" $2 }' "$sources"; for f in ${keys_files[@]+"${keys_files[@]}"}; do printf 'k\tkeys:%s\n' "$(basename "$f")"; done) \
    "$WORK/pairs.tsv"
echo "$total_keys distinct keys, $shared drawn by more than one source"
if [ -s "$WORK/dropped.tsv" ]; then
    echo "--max=$max left out $(wc -l < "$WORK/dropped.tsv" | tr -d ' ') keys (raise --max to bake them; they draw with the uber-shader):"
    awk -F '\t' '{ printf "  %s  (%s)\n", $2, $3 }' "$WORK/dropped.tsv"
fi
estimate=$(awk -v n="$selected" -v kb="$EST_KB_PER_VARIANT" 'BEGIN { printf "%.1f", n * kb / 1024 }')

case "$mode" in
    dry)
        echo "dry run: would write $selected variants to $out (about $estimate MB more in the .riv)"
        ;;
    check)
        if diff -r -q "$gen" "$out" > "$WORK/diff.txt" 2>&1; then
            baked=$(grep -c " baked$" "$WORK/record.log" 2>/dev/null || true)
            echo "baked shaders are fresh: $selected variants of three.wgsl $hash (renderers found a variant ${baked:-0} times)"
            exit 0
        fi
        stale=$(sed -n 's/.*from three.wgsl \([0-9a-f]*\)\..*/\1/p' "$out/keys.txt" | head -n 1)
        sed 's/^/  /' "$WORK/diff.txt" | sed "s|$WORK/||g" >&2
        if [ -n "$stale" ] && [ "$stale" != "$hash" ]; then
            die "the bake is stale: baked from three.wgsl $stale, the project runs $hash (rerun tools/threeas_bake.sh, or --clean)"
        fi
        die "the bake is stale: the project draws other keys now (rerun tools/threeas_bake.sh, or --clean)"
        ;;
    bake)
        rm -rf "$out"
        mv "$gen" "$out"
        restore=""
        if [ "$selected" = 0 ]; then
            rm -rf "$out"
            echo "no program keys recorded: nothing baked (does the project draw with a THREE.GPURenderer?)"
        else
            echo "wrote $selected variants and keys.txt to $out (about $estimate MB more in the .riv;" \
                "$(du -sk "$out" | cut -f1) KB of WGSL)"
            echo "next: rive $project --verify, then a release build and tools/check_glsl.py (WebGL2)"
        fi
        ;;
esac
