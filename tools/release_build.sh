#!/usr/bin/env bash
# Release builds (signed .riv files, as a publish ships them) of the engine
# and the gallery, for tools/check_glsl.py:
#
#   tools/release_build.sh build/release
#     -> build/release/threeas/threeas.riv     the engine as packages/threeas
#                                              holds it: every engine shader
#     -> build/release/gallery/three_as.riv    the gallery as it ships: on the
#                                              published engine in .libraries/
#   tools/release_build.sh build/release --override
#     the gallery on packages/threeas instead (its library override; such a
#     build carries the library's shaders twice, so check_glsl.py counts
#     the engine's twice)
#
# Both are built from copies with rive.yaml's push: and pages: bindings
# removed, since a local --publish of a bound project counts against the
# bound file's workspace. Needs `rive login`.
set -euo pipefail
out="${1:?usage: tools/release_build.sh <out-dir> [--override]}"
override=0
[ "${2:-}" = --override ] && override=1
cd "$(dirname "$0")/.."
mkdir -p "$out"
out="$(cd "$out" && pwd)"
src=build/release-src
rm -rf "$src"
mkdir -p "$src/packages"
for p in threeas gallery; do
    rsync -a --exclude build "packages/$p/" "$src/packages/$p/"
done
unbind() {   # rive.yaml without its push: and pages: blocks, on stdout
    awk '/^(push|pages):/ { skip = 1; next } skip && /^  / { next } { skip = 0; print }' "$1"
}

unbind packages/threeas/rive.yaml > "$src/packages/threeas/rive.yaml"
rm -rf "$out/threeas"
rive "$src/packages/threeas" --publish --output-dir="$out/threeas" > "$out/threeas.log" 2>&1 \
    || { echo "engine release build failed; see $out/threeas.log" >&2; exit 1; }

if [ "$override" = 1 ]; then
    cp packages/threeas/rive.yaml "$src/packages/threeas/rive.yaml"   # the override checks its fileId
    unbind packages/gallery/rive.yaml > "$src/packages/gallery/rive.yaml"
else
    unbind packages/gallery/rive.yaml | grep -v '^ *override:' > "$src/packages/gallery/rive.yaml"
fi
rm -rf "$out/gallery"
rive "$src/packages/gallery" --publish --output-dir="$out/gallery" > "$out/gallery.log" 2>&1 \
    || { echo "gallery release build failed; see $out/gallery.log" >&2; exit 1; }
if [ "$override" = 1 ] && grep -q "falling back to the downloaded library" "$out/gallery.log"; then
    echo "warning: the gallery release used the published engine, not packages/threeas:" >&2
    grep "falling back" "$out/gallery.log" >&2
fi
ls "$out"/threeas/*.riv "$out"/gallery/*.riv
