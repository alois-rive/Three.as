#!/usr/bin/env bash
# Publishes the engine library (packages/threeas) to UAT or production, then
# republishes the gallery (packages/gallery) on UAT against it.
#
#   tools/publish.sh                          engine to UAT, then the gallery
#   tools/publish.sh --env=prod               engine to production, then the gallery
#   tools/publish.sh --env=both               engine to UAT and production, then the gallery
#   tools/publish.sh --no-gallery             the engine only
#   tools/publish.sh --description="..."      the library version's note
#   tools/publish.sh --dry-run                print the steps, run nothing
#   tools/publish.sh --yes                    no confirmation prompt (CI)
#
# Steps, in order (any failure stops the run):
#  1. Checks: verify and test both packages; a shader bake in the gallery
#     (packages/gallery/threeas_baked/, optional) is fresh for the engine
#     about to be published (tools/threeas_bake.sh --check; nothing to check
#     without one); release builds of both (tools/release_build.sh) and
#     tools/check_glsl.py on each .riv, since WebGL2 rejects GLSL the native
#     backends accept.
#  2. Engine, per environment: swap that environment's push binding
#     (packages/threeas/bindings/<env>.yaml) into packages/threeas/rive.yaml;
#     on a first production publish (no fileId yet), `rive push
#     --project=<id>` creates the library file and the fileId is saved to
#     bindings/prod.yaml; then `rive library publish`. Its first run often
#     only pushes and asks for a rerun, so it runs a second time when the
#     first did not print "Published v<N>". The UAT binding is put back
#     afterwards, even on failure: the gallery's `override: ../threeas` only
#     works while the engine pushes to the UAT library file.
#  3. Gallery (UAT): `rive library update --uat` (newest engine version into
#     threeas.rml, rive.yaml and .libraries/), verify, a release build and
#     check_glsl.py of the gallery as it ships, `rive push --uat` to
#     its file (38626), then `--publish=web --uat` to the threeas page of the
#     UAT Rive workspace (41013), from a copy
#     without the library override, so the page runs the published engine.
#
# Afterwards commit what changed: packages/gallery/{threeas.rml,rive.yaml,
# .libraries/} and, after a first production publish,
# packages/threeas/bindings/prod.yaml. Needs `rive login` on each
# environment used (`rive login --uat` for UAT).
set -euo pipefail

UAT_PAGES_WORKSPACE=41013   # UAT "Rive" workspace: https://threeas-inksqd.uat.rive.to
PAGES_NAME=threeas
cd "$(dirname "$0")/.."

ENGINE=packages/threeas
GALLERY=packages/gallery
WORK=build/publish
env=uat
gallery=1
dry=0
yes=0
description=""
for arg in "$@"; do
    case "$arg" in
        --env=*) env="${arg#--env=}" ;;
        --no-gallery) gallery=0 ;;
        --description=*) description="${arg#--description=}" ;;
        --dry-run) dry=1 ;;
        --yes|-y) yes=1 ;;
        -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
        *) echo "unknown option $arg" >&2; exit 2 ;;
    esac
done
case "$env" in
    uat) envs=(uat) ;;
    prod) envs=(prod) ;;
    both) envs=(uat prod) ;;
    *) echo "--env is uat, prod or both" >&2; exit 2 ;;
esac
for e in "${envs[@]}"; do
    if grep -q PRODUCTION_PROJECT_ID "$ENGINE/bindings/$e.yaml"; then
        echo "$ENGINE/bindings/$e.yaml has no project id yet (PRODUCTION_PROJECT_ID): fill it in first" >&2
        exit 2
    fi
done
mkdir -p "$WORK"

run() {   # prints a step, and runs it unless --dry-run
    echo "+ $*"
    [ "$dry" = 1 ] || "$@"
}
env_flag() { [ "$1" = uat ] && echo "--uat" || true; }
yaml_value() {   # file, key: the value of "  key: value" in a push: block
    sed -n "s/^  $2: *\([0-9A-Za-z_]*\).*/\1/p" "$1" | head -n 1
}
binding_block() {   # the push: block of a bindings file
    awk '/^push:/ { p = 1; print; next } p && /^  / { print; next } { p = 0 }' "$1"
}
set_binding() {   # env: packages/threeas/rive.yaml with that environment's push: block
    local tmp="$WORK/rive.yaml"
    awk '/^push:/ { skip = 1; next } skip && /^  / { next } { skip = 0; print }' "$ENGINE/rive.yaml" > "$tmp"
    binding_block "$ENGINE/bindings/$1.yaml" >> "$tmp"
    cp "$tmp" "$ENGINE/rive.yaml"
}
restore_uat() {
    [ "$dry" = 1 ] && return
    set_binding uat
    echo "packages/threeas/rive.yaml: UAT binding restored"
}

echo "publish: engine to ${envs[*]}$([ "$gallery" = 1 ] && echo ", then the gallery on UAT")"
if [ "$dry" = 0 ] && [ "$yes" = 0 ]; then
    read -r -p "continue? [y/N] " answer
    [ "$answer" = y ] || [ "$answer" = Y ] || exit 1
fi

# ------------------------------------------------------------------ 1. checks
run rive "$ENGINE" --verify --quiet
run rive "$ENGINE" --test --quiet
run rive "$GALLERY" --verify --quiet
run rive "$GALLERY" --test --quiet
run tools/threeas_bake.sh "$GALLERY" --engine="$ENGINE" --check
# The gallery against the local engine (its override): the engine is what
# this run is about to publish, and gallery code using new engine API would
# not build against the previous snapshot in .libraries/.
run tools/release_build.sh "$WORK/release" --override
run python3 tools/check_glsl.py "$WORK/release/threeas/threeas.riv"
# Not the gallery's GLSL here: under the override, the engine's existing
# shaders still come from the .libraries/ snapshot (only new scripts and
# shader names come from packages/threeas), so a fixed engine shader would
# fail this check until it is published. Step 3 checks the gallery after
# `rive library update`, before pushing and publishing it.

# ------------------------------------------------------------------ 2. engine
trap restore_uat EXIT
for e in "${envs[@]}"; do
    flag=$(env_flag "$e")
    echo "== engine: $e"
    [ "$dry" = 1 ] || set_binding "$e"
    if [ -z "$(yaml_value "$ENGINE/bindings/$e.yaml" fileId)" ]; then
        # A first publish: create the library file, then keep its fileId.
        project=$(yaml_value "$ENGINE/bindings/$e.yaml" projectId)
        run env RIVE_NO_TUI=1 rive push "$ENGINE" $flag --project="$project" --yes --name="tools/publish.sh: library file"
        if [ "$dry" = 0 ]; then
            file=$(sed -n '/^push:/,$ s/^  fileId: *\([0-9]*\).*/\1/p' "$ENGINE/rive.yaml" | head -n 1)
            [ -n "$file" ] || { echo "rive push wrote no fileId into $ENGINE/rive.yaml" >&2; exit 1; }
            printf '  fileId: %s\n' "$file" >> "$ENGINE/bindings/$e.yaml"
            echo "saved fileId $file to $ENGINE/bindings/$e.yaml: commit it"
        fi
    fi
    publish=(env RIVE_NO_TUI=1 rive library publish "$ENGINE" $flag --yes)
    [ -n "$description" ] && publish+=(--description="$description")
    if [ "$dry" = 1 ]; then
        run "${publish[@]}"
        echo "+ (again if the first run did not publish)"
    else
        for attempt in 1 2; do
            echo "+ ${publish[*]}   (run $attempt)"
            "${publish[@]}" 2>&1 | tee "$WORK/library-publish-$e-$attempt.log" | grep -v '^  \(Script\|Shader\) '
            if grep -q "^Published v" "$WORK/library-publish-$e-$attempt.log"; then break; fi
            [ "$attempt" = 2 ] && { echo "rive library publish did not publish on $e (see $WORK/library-publish-$e-*.log)" >&2; exit 1; }
        done
    fi
done
restore_uat
trap - EXIT

# ----------------------------------------------------------------- 3. gallery
if [ "$gallery" = 1 ]; then
    echo "== gallery (UAT)"
    run env RIVE_NO_TUI=1 rive library update "$GALLERY" --uat --yes
    # An update keeps the previous version's LibraryAsset when the new one
    # dropped a script: the page would ship the engine twice. Remove it by hand.
    if [ "$dry" = 0 ] && [ "$(grep -c '<LibraryAsset ' "$GALLERY/threeas.rml")" -gt 1 ]; then
        echo "$GALLERY/threeas.rml holds more than one LibraryAsset after the update: delete the" >&2
        echo "older version's block (and its .libraries/threeas@<assetId>/), then run the remaining gallery steps by hand (the end of this script)" >&2
        exit 1
    fi
    run rive "$GALLERY" --verify --quiet
    # The gallery as it ships (on the engine just published), before it goes out.
    run tools/release_build.sh "$WORK/release-page"
    run python3 tools/check_glsl.py "$WORK/release-page/gallery/three_as.riv"
    run env RIVE_NO_TUI=1 rive push "$GALLERY" --uat --yes --name="tools/publish.sh"
    # The page from a copy without the override: it runs the published engine.
    run rm -rf "$WORK/gallery"
    run rsync -a --exclude build "$GALLERY/" "$WORK/gallery/"
    if [ "$dry" = 1 ]; then
        echo "+ (drop the override: line from $WORK/gallery/rive.yaml)"
    else
        grep -v '^ *override:' "$GALLERY/rive.yaml" > "$WORK/gallery/rive.yaml"
    fi
    # The gallery is a UAT file: its page goes to the UAT workspace. (The
    # pages: binding in its rive.yaml is the older production page, which is
    # only republished by hand.)
    run rive "$WORK/gallery" --publish=web --uat --workspace="$UAT_PAGES_WORKSPACE" --name="$PAGES_NAME"
    # The page's own build (on the published engine): WebGL2 check.
    run python3 tools/check_glsl.py "$WORK/gallery/build/three_as.riv"
fi

echo "done. Commit packages/gallery/{threeas.rml,rive.yaml,.libraries} (and packages/threeas/bindings/ after a first production publish)."
