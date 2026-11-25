#!/bin/sh
# Builds both lab images from the commits the superproject records.
#
#   integration/scripts/build.sh              build
#   integration/scripts/build.sh --no-cache   ignore the BuildKit caches
#   integration/scripts/build.sh --help       this text
#
# The context is materialised with `git archive` of each submodule at the gitlink
# in the superproject's HEAD, not from the submodules' working trees. A lab run
# therefore proves what is committed and pinned; uncommitted work is NOT under
# test. The script prints every resolved commit and warns when a submodule is
# dirty so a green run is never mistaken for coverage of in-flight edits.
#
# LAB_BUILD_FROM_WORKTREE=1 builds the superproject root as it stands instead,
# which is the way to test uncommitted work (and to reproduce a dirty build
# failure). It is deliberately opt-in: the web submodule is mid-flight at the
# time of writing, and its working tree does not compile.
#
# The pinned commits are checked for composition first (`deploy/check-pins.sh`): a
# ten-minute image build is a slow way to learn that two pins disagree. Pass
# LAB_SKIP_PIN_CHECK=1 to skip it.
#
# LAB_DOCKER_BUILD_ARGS appends extra arguments to `docker compose build`
# (word-split, so `--build-arg A=1 --build-arg B=2` works). CI uses it to pass
# builder options without editing this script. Empty by default: the command is
# then exactly `docker compose build`, unchanged.
set -eu

SCRIPT_DIR=$(
    unset CDPATH
    cd -- "$(dirname -- "$0")" && pwd
)
. "$SCRIPT_DIR/common.sh"

usage() {
    sed -n '2,22p' "$SCRIPT_DIR/build.sh" | sed 's/^# \{0,1\}//'
}

no_cache=
for arg in "$@"; do
    case $arg in
    --no-cache) no_cache=1 ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        printf 'unknown option: %s\n\n' "$arg" >&2
        usage >&2
        exit 2
        ;;
    esac
done

ensure_env

# A docker build that dies on a compile error wastes ten minutes to learn what the pin
# gate answers in one. That is not hypothetical: an SDK commit added an error variant,
# nothing else in the set learned it, and this script found out at the `cargo build` step
# while `deploy/check-pins.sh` would have said so in a minute. The gate is skipped when
# asked (`LAB_SKIP_PIN_CHECK=1`) and when the context is a working tree rather than the
# pins, since then there is no pin set to compose.
if [ "${LAB_BUILD_FROM_WORKTREE:-0}" = 1 ]; then
    printf 'pin gate: skipped (LAB_BUILD_FROM_WORKTREE=1 builds a working tree, not the pins)\n'
elif [ "${LAB_SKIP_PIN_CHECK:-0}" = 1 ]; then
    printf 'pin gate: skipped (LAB_SKIP_PIN_CHECK=1)\n'
elif command -v cargo >/dev/null 2>&1 && [ -x "$INTEGRATION_DIR/../deploy/check-pins.sh" ]; then
    if ! "$INTEGRATION_DIR/../deploy/check-pins.sh"; then
        printf '\nthe pinned commits do not compose; nothing was built.\n' >&2
        printf 'fix the pin or the code, or pass LAB_SKIP_PIN_CHECK=1 to build anyway.\n' >&2
        exit 1
    fi
else
    printf 'pin gate: skipped (cargo or deploy/check-pins.sh unavailable)\n'
fi

SUBMODULES="nodus-backend recommender sdk server-sdk web"
BUILD_CONTEXT_DIR="$INTEGRATION_DIR/volumes/build-context"

# The recorded gitlink is authoritative except where the pins themselves do not
# agree yet. nodus-backend 16a5ce2 imports `HttpSigner`, which exists only from
# server-sdk 8baa97d, while the superproject still records dba7629; the operator
# is expected to update the gitlink. Until then the lab overrides that one pin,
# and says so on every build. Drop the override once `git ls-tree HEAD server-sdk`
# reports 8baa97d.
SERVER_SDK_PIN=8baa97d61a10971ab8d609410c9bb226aef4a9bb

# The context is the only thing the Dockerfile sees, so it must contain the
# superproject files the build reads (`deploy/` for the reference Dockerfiles)
# and its own Dockerfiles at their context-relative names.
materialise_pinned_context() {
    root=$1
    ctx=$2
    rm -rf "$ctx"
    mkdir -p "$ctx"
    for sub in $SUBMODULES; do
        pin=$(git -C "$root" ls-tree HEAD -- "$sub" | awk '{print $3}')
        if [ "$sub" = server-sdk ] && [ "$pin" != "$SERVER_SDK_PIN" ]; then
            printf '  %-14s %s (lab override; the gitlink records %s)\n' \
                "$sub" "$SERVER_SDK_PIN" "$pin"
            pin=$SERVER_SDK_PIN
        fi
        if [ -z "$pin" ]; then
            printf 'no gitlink for %s in %s\n' "$sub" "$root" >&2
            return 1
        fi
        mkdir -p "$ctx/$sub"
        git -C "$root/$sub" archive --format=tar "$pin" | tar -x -C "$ctx/$sub"
        printf '  %-14s %s\n' "$sub" "$pin"
        if [ -n "$(git -C "$root/$sub" status --porcelain 2>/dev/null)" ]; then
            printf '    WARNING: %s has uncommitted changes; uncommitted work is NOT under test\n' "$sub" >&2
        fi
        head=$(git -C "$root/$sub" rev-parse HEAD 2>/dev/null || true)
        if [ -n "$head" ] && [ "$head" != "$pin" ]; then
            printf '    note: %s HEAD is %s, the build uses the recorded gitlink above\n' "$sub" "$head"
        fi
    done
    git -C "$root" archive --format=tar HEAD deploy | tar -x -C "$ctx"
    cp "$INTEGRATION_DIR/Dockerfile.server" "$INTEGRATION_DIR/Dockerfile.web" "$ctx/"
}

if [ "${LAB_BUILD_FROM_WORKTREE:-0}" = 1 ]; then
    printf 'LAB_BUILD_FROM_WORKTREE=1: building the working trees, not the pinned commits\n' >&2
    export NODUS_BUILD_CONTEXT=$(
        unset CDPATH
        cd -- "$INTEGRATION_DIR/.." && pwd
    )
    export NODUS_DOCKERFILE=integration/Dockerfile.server
    export NODUS_DOCKERFILE_WEB=integration/Dockerfile.web
else
    printf 'resolving pinned commits ...\n'
    materialise_pinned_context "$(
        unset CDPATH
        cd -- "$INTEGRATION_DIR/.." && pwd
    )" "$BUILD_CONTEXT_DIR"
    export NODUS_BUILD_CONTEXT="$BUILD_CONTEXT_DIR"
    export NODUS_DOCKERFILE=Dockerfile.server
    export NODUS_DOCKERFILE_WEB=Dockerfile.web
fi

# Unquoted on purpose: this is a whitespace-separated argument list.
extra_build_args=${LAB_DOCKER_BUILD_ARGS:-}
if [ -n "$no_cache" ]; then
    printf 'building nodus-lab images without cache ...\n'
    # shellcheck disable=SC2086
    compose build --no-cache $extra_build_args
else
    printf 'building nodus-lab images ...\n'
    # shellcheck disable=SC2086
    compose build $extra_build_args
fi
