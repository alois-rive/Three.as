#!/usr/bin/env bash
# Screenshots of every example artboard (and the Gallery) from one headless
# build, for before/after comparisons of renderer changes:
#
#   tools/screenshots.sh build/shots/before            # capture
#   tools/screenshots.sh build/shots/after --aot       # extra flags go to rive
#   python3 tools/compare_shots.py build/shots/before build/shots/after
#
# Each artboard is captured after 1 s (60 frames) and again after 3 s.
set -euo pipefail

out="${1:?usage: tools/screenshots.sh <out-dir> [rive flags...]}"
shift
cd "$(dirname "$0")/.."
mkdir -p "$out"

# Every isComponent artboard of examples.rml, plus the Gallery.
artboards=$(grep -o '<Artboard isComponent="true"[^>]*name="[^"]*"' examples/examples.rml \
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
if ! rive . --commands="$commands" "$@" > "$log" 2>&1; then
    echo "rive failed; see $log" >&2
    exit 1
fi
if grep -q "^err" "$log"; then
    grep "^err" "$log" >&2
    exit 1
fi
echo "$(echo $artboards | wc -w | tr -d " ") artboards captured twice in $out"
