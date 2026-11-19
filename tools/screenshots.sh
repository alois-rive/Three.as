#!/usr/bin/env bash
# Screenshots of every example artboard (and the Gallery) from one headless
# build of the gallery, for before/after comparisons of renderer changes:
#
#   tools/screenshots.sh build/shots/before            # capture
#   tools/screenshots.sh build/shots/after --aot       # extra flags go to rive
#   tools/screenshots.sh build/shots/x --project=DIR   # another gallery checkout
#   python3 tools/compare_shots.py build/shots/before build/shots/after
#
# The gallery builds the engine from packages/threeas (its library
# override), so engine edits show here without publishing. Each artboard is
# captured after 1 s (60 frames) and again after 3 s. Paths are relative to
# the repository root.
set -euo pipefail

out="${1:?usage: tools/screenshots.sh <out-dir> [--project=DIR] [rive flags...]}"
shift
cd "$(dirname "$0")/.."
project=packages/gallery
flags=()
for arg in "$@"; do
    case "$arg" in
        --project=*) project="${arg#--project=}" ;;
        *) flags+=("$arg") ;;
    esac
done
mkdir -p "$out"
out="$(cd "$out" && pwd)"

# Every isComponent artboard of the examples, plus the Gallery.
artboards=$(cat "$project"/examples/*/*.rml | grep -o '<Artboard isComponent="true"[^>]*name="[^"]*"' \
    | sed 's/.*name="\([^"]*\)"/\1/')
artboards="$artboards Gallery"

commands="$out/commands.txt"
: > "$commands"
for a in $artboards; do
    {
        echo "artboard $a"
        echo "advance 1s"
        echo "screenshot $out/$a.png"
        echo "advance 2s"
        echo "screenshot $out/$a.3s.png"
    } >> "$commands"
done
echo "quit" >> "$commands"

log="$out/rive.log"
if ! rive "$project" --commands="$commands" ${flags[@]+"${flags[@]}"} > "$log" 2>&1; then
    echo "rive failed; see $log" >&2
    exit 1
fi
if grep -q "^err" "$log"; then
    grep "^err" "$log" >&2
    exit 1
fi
echo "$(echo $artboards | wc -w | tr -d " ") artboards captured twice in $out"
