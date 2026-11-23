#!/usr/bin/env bash
# Builds the artifacts deploy/release-118.sh and deploy/release-100.sh install.
#
#   deploy/build.sh backend <out-dir>   six binaries: nodus-{calc,scan,prune,feed,media,api}
#   deploy/build.sh web <out-dir>       nodus-web-server and dist/ (hashed bundle + .gz/.zst)
#   deploy/build.sh all <out-dir>       both
#   deploy/build.sh all <out-dir> --worktree
#
# The default source is the superproject pins: each submodule is `git archive`d at the
# gitlink `git ls-tree HEAD` records, the same rule integration/scripts/build.sh uses.
# --worktree builds the working trees instead, for a checkout whose edits are what you
# mean to ship; every resolved commit is printed either way.
#
# Everything is compiled in rust:1-bookworm (glibc 2.36) because both release targets run
# Debian 12. The container runs as the invoking uid/gid, so it writes no root-owned files
# into the checkout or the cache. The host cargo registry and a per-target cache under
# ~/.cache/nodus-release-build make a rebuild minutes rather than tens of minutes.
#
# <out-dir> receives BUILD-INFO and SHA256SUMS next to the artifacts. The release scripts
# read them: BUILD-INFO names the target and resolved commits, SHA256SUMS proves the files
# are the ones this script produced. A directory without BUILD-INFO is accepted as a
# hand-built set, and the release scripts say so in one line.
set -Eeuo pipefail

ROOT=$(
    unset CDPATH
    cd -- "$(dirname -- "$0")/.." && pwd
)
SUBMODULES="nodus-backend recommender sdk server-sdk web"
ROLES="calc scan prune feed media api"

# shellcheck source=pins.sh
. "$ROOT/deploy/pins.sh"

# The builder image is derived from the same pins integration/Dockerfile.web uses. Trunk
# must stay on a release bookworm's glibc starts without warnings (0.22.1 prints
# `GLIBC_2.39 not found` at startup); wasm-opt is matched to wasm-bindgen's externref
# tables (bookworm's binaryen 108 breaks the bundle).
BASE_IMAGE=rust:1-bookworm
NODE_IMAGE=22-bookworm-slim
TRUNK_VERSION=0.21.14
WASM_OPT_VERSION=version_123
MAX_GLIBC=2.36

CACHE=${NODUS_BUILD_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/nodus-release-build}
HOST_CARGO=${CARGO_HOME:-$HOME/.cargo}

TARGET=''
OUT=''
SOURCE_MODE=''
SRC=''
CTX=''
CID=''
IMAGE=''
STARTED=$(date +%s)

declare -A PIN=()
declare -A DIRTY=()

log() { printf '%s\n' "$*"; }
die() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
usage: deploy/build.sh <backend|web|all> <out-dir> [--worktree]

  backend    six binaries: nodus-calc nodus-scan nodus-prune nodus-feed nodus-media nodus-api
  web        nodus-web-server plus dist/ with the hashed bundle and its .gz/.zst siblings
  all        both sets in one directory

  --worktree build the working trees instead of the superproject's pinned commits

Environment: NODUS_BUILD_CACHE (default ~/.cache/nodus-release-build),
             CARGO_HOME (default ~/.cargo)
USAGE
}

cleanup() {
    if [ -n "$CID" ]; then
        docker rm -f "$CID" >/dev/null 2>&1 || true
    fi
    if [ -n "$CTX" ] && [ -d "$CTX" ]; then
        rm -rf "$CTX"
    fi
}
trap cleanup EXIT

for arg in "$@"; do
    case $arg in
    --worktree) SOURCE_MODE=worktree ;;
    -h | --help)
        usage
        exit 0
        ;;
    -*)
        usage >&2
        exit 2
        ;;
    *)
        if [ -z "$TARGET" ]; then
            TARGET=$arg
        elif [ -z "$OUT" ]; then
            OUT=$arg
        else
            usage >&2
            exit 2
        fi
        ;;
    esac
done

case $TARGET in
backend | web | all) ;;
*)
    usage >&2
    exit 2
    ;;
esac
SOURCE_MODE=${SOURCE_MODE:-pins}
[ -n "$OUT" ] || {
    usage >&2
    exit 2
}

for tool in docker git tar sha256sum objdump find sort touch; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required on the host"
done

# Run the composition gate before BUILD-INFO or any artifact is written. A recorded
# gitlink matching its submodule says nothing about whether the pins compile together;
# deploy/check-pins.sh answers that in seconds and names the workspace that broke.
set +e
"$ROOT/deploy/check-pins.sh"
CHECK_PINS_STATUS=$?
set -e
case $CHECK_PINS_STATUS in
0) ;;
1) die "the pinned submodules do not compose; deploy/check-pins.sh named the workspace" ;;
*) log "check-pins: no check could run (see the SKIP lines above); continuing" ;;
esac

# --- identity --------------------------------------------------------------------------

SUPERPROJECT=$(git -C "$ROOT" rev-parse HEAD)
SUPERPROJECT_DIRTY=0
if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
    SUPERPROJECT_DIRTY=1
fi
CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- output directory ------------------------------------------------------------------

mkdir -p "$OUT"
OUT=$(
    unset CDPATH
    cd -- "$OUT" && pwd
)
[ "$OUT" = / ] && die "refusing to build into /"
if [ -n "$(ls -A "$OUT")" ]; then
    if [ -f "$OUT/BUILD-INFO" ]; then
        # A previous run's directory: replace only what this script owns.
        for name in nodus-api nodus-media nodus-feed nodus-scan nodus-prune nodus-calc nodus-web-server; do
            rm -f "$OUT/$name"
        done
        rm -rf "$OUT/dist" "$OUT/SHA256SUMS" "$OUT/BUILD-INFO"
    else
        die "refusing to write into non-empty $OUT: it has no BUILD-INFO, so it may hold artifacts this script did not build; choose an empty directory"
    fi
fi

# BUILD-INFO goes down before the build so a run that dies halfway is recognisable as
# this script's, and rebuildable: the release scripts then see a manifest with no
# SHA256SUMS and refuse it as incomplete instead of deploying half a set.
{
    printf '# Written by deploy/build.sh; deploy/release-118.sh and deploy/release-100.sh read it.\n'
    printf 'manifest_version=1\n'
    printf 'tool=deploy/build.sh\n'
    printf 'target=%s\n' "$TARGET"
    printf 'source=%s\n' "$SOURCE_MODE"
    printf 'created=%s\n' "$CREATED"
    printf 'superproject=%s\n' "$SUPERPROJECT"
    printf 'superproject_dirty=%s\n' "$SUPERPROJECT_DIRTY"
} >"$OUT/BUILD-INFO"

# --- source context --------------------------------------------------------------------

if [ "$SOURCE_MODE" = worktree ]; then
    SRC=$ROOT
    log "building the working trees (--worktree), not the pinned commits"
else
    SOURCE_MODE=pins
    log "resolving pinned commits from $ROOT (git ls-tree HEAD) ..."
    CTX=$(mktemp -d "${TMPDIR:-/tmp}/nodus-build.XXXXXX")
    for sub in $SUBMODULES; do
        pin=$(pin_of "$ROOT" "$sub")
        [ -n "$pin" ] || die "no gitlink for $sub in $ROOT HEAD"
        archive_pin "$ROOT" "$sub" "$pin" "$CTX/$sub" ||
            die "cannot archive $sub at $pin; run git submodule update --init"
        PIN[$sub]=$pin
    done
    git -C "$ROOT" archive --format=tar HEAD deploy | tar -x -C "$CTX" ||
        die "cannot archive deploy/ from $ROOT HEAD"
    # git archive stamps the commit time on every file; a cached target directory can be
    # newer, which makes cargo reuse artifacts of the previous commit. The context is a
    # throwaway copy, so touching every file costs nothing and forces a correct build.
    find "$CTX" -type f -exec touch {} +
    SRC=$CTX
fi

if [ "$SOURCE_MODE" = worktree ]; then
    for sub in $SUBMODULES; do
        PIN[$sub]=$(git -C "$ROOT/$sub" rev-parse HEAD 2>/dev/null || echo unknown)
        if [ -n "$(git -C "$ROOT/$sub" status --porcelain 2>/dev/null)" ]; then
            DIRTY[$sub]=1
        else
            DIRTY[$sub]=0
        fi
    done
fi

log "resolved commits ($SOURCE_MODE):"
for sub in $SUBMODULES; do
    note=''
    if [ "${DIRTY[$sub]:-0}" = 1 ]; then note=' (dirty)'; fi
    printf '   %-14s %s%s\n' "$sub" "${PIN[$sub]}" "$note"
done
printf '   %-14s %s%s\n' superproject "$SUPERPROJECT" "$([ "$SUPERPROJECT_DIRTY" = 1 ] && echo ' (dirty)')"

# --- builder image ---------------------------------------------------------------------

DOCKERFILE=$(
    cat <<DOCKER
FROM node:${NODE_IMAGE} AS node
FROM ${BASE_IMAGE}
ARG TRUNK_VERSION=${TRUNK_VERSION}
ARG WASM_OPT_VERSION=${WASM_OPT_VERSION}
RUN apt-get update \\
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils gzip zstd binutils \\
 && rm -rf /var/lib/apt/lists/*
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \\
 && ln -sf ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \\
 && node --version \\
 && npm --version
RUN curl -fsSL --retry 5 --retry-delay 2 --max-time 600 \\
      "https://github.com/trunk-rs/trunk/releases/download/v\${TRUNK_VERSION}/trunk-x86_64-unknown-linux-gnu.tar.gz" \\
      | tar -xz -C /usr/local/bin trunk \\
 && trunk --version
RUN curl -fsSL --retry 5 --retry-delay 2 --max-time 600 \\
      "https://github.com/WebAssembly/binaryen/releases/download/\${WASM_OPT_VERSION}/binaryen-\${WASM_OPT_VERSION}-x86_64-linux.tar.gz" \\
      | tar -xz -C /tmp \\
 && install -m 0755 "/tmp/binaryen-\${WASM_OPT_VERSION}/bin/wasm-opt" /usr/local/bin/wasm-opt \\
 && rm -rf "/tmp/binaryen-\${WASM_OPT_VERSION}" \\
 && wasm-opt --version
ENV TRUNK_TOOLS_WASM_OPT_VERSION=\${WASM_OPT_VERSION}
RUN rustup target add wasm32-unknown-unknown
DOCKER
)

IMAGE="nodus-release-builder:bookworm-$(printf '%s' "$DOCKERFILE" | sha256sum | cut -c1-12)"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log "building $IMAGE (first run only; the tool layer is cached afterwards) ..."
    empty=$(mktemp -d)
    if ! printf '%s\n' "$DOCKERFILE" | docker build --tag "$IMAGE" --file - "$empty"; then
        rmdir "$empty"
        die "could not build the builder image $IMAGE"
    fi
    rmdir "$empty"
fi
log "builder image: $IMAGE"

mkdir -p "$CACHE/home" "$CACHE/target-backend" "$CACHE/target-web-server" "$CACHE/target-web-wasm"
[ -d "$HOST_CARGO" ] || mkdir -p "$HOST_CARGO"

# --- container execution ---------------------------------------------------------------

run_step() {
    local desc=$1 workdir=$2 target_dir=$3 script=$4
    log "$desc"
    CID=$(docker create \
        --name "nodus-build-$$-$RANDOM" \
        --user "$(id -u):$(id -g)" \
        -e "HOME=$CACHE/home" \
        -e "CARGO_HOME=$HOST_CARGO" \
        -e "SRC=$SRC" \
        -e "MAX_GLIBC=$MAX_GLIBC" \
        -e "CARGO_TARGET_DIR=$target_dir" \
        -v "$CACHE:$CACHE" \
        -v "$HOST_CARGO:$HOST_CARGO" \
        -v "$SRC:$SRC" \
        -w "$workdir" \
        "$IMAGE" bash -c "$script") || die "docker create failed"
    if ! docker start -a "$CID"; then
        docker rm -f "$CID" >/dev/null 2>&1 || true
        CID=''
        die "$desc failed"
    fi
}

# A missing tool must fail the build with its name, not skip the step that needed it.
NEED='need() { command -v "$1" >/dev/null 2>&1 || { printf "FAIL: %s is missing in the builder image\n" "$1" >&2; exit 1; }; };'

collect() {
    docker cp "$CID:/tmp/out/." "$OUT/" || die "could not copy the artifacts out of the container"
    docker rm -f "$CID" >/dev/null 2>&1 || true
    CID=''
}

build_backend() {
    local script
    script=$(
        cat <<INNER
set -euo pipefail
$NEED
for tool in cargo objdump; do need "\$tool"; done
cd "\$SRC/nodus-backend"
cargo build --release \\
  --bin nodus-api --bin nodus-media --bin nodus-feed \\
  --bin nodus-scan --bin nodus-prune --bin nodus-calc
install -d /tmp/out
for role in api media feed scan prune calc; do
  cp "\$CARGO_TARGET_DIR/release/nodus-\$role" /tmp/out/
done
INNER
    )
    run_step "building the six backend binaries ..." "$SRC/nodus-backend" "$CACHE/target-backend" "$script"
    collect
    for role in $ROLES; do
        [ -f "$OUT/nodus-$role" ] || die "the build produced no nodus-$role"
    done
}

build_web_server() {
    local script
    script=$(
        cat <<INNER
set -euo pipefail
$NEED
for tool in cargo objdump; do need "\$tool"; done
cd "\$SRC/web"
cargo build --release --bin nodus-web-server
install -d /tmp/out
cp "\$CARGO_TARGET_DIR/release/nodus-web-server" /tmp/out/
INNER
    )
    run_step "building nodus-web-server ..." "$SRC/web" "$CACHE/target-web-server" "$script"
    collect
    [ -f "$OUT/nodus-web-server" ] || die "the build produced no nodus-web-server"
}

build_web_dist() {
    local script
    script=$(
        cat <<INNER
set -euo pipefail
$NEED
for tool in cargo node npm trunk wasm-opt gzip zstd; do need "\$tool"; done
printf '   node %s, npm %s, trunk %s, wasm-opt %s\n' \\
  "\$(node --version)" "\$(npm --version)" "\$(trunk --version)" "\$(wasm-opt --version)"
cd "\$SRC/web"
npm ci --no-audit --no-fund --include=optional
# npm 9 drops the optional platform binary of @tailwindcss/oxide that the lockfile names;
# installing it explicitly at the resolved version keeps the Tailwind 4 CLI loadable.
node -e "const {version} = require('./node_modules/@tailwindcss/oxide/package.json');\
require('child_process').execSync('npm install --no-save --no-audit --no-fund @tailwindcss/oxide-linux-x64-gnu@' + version, {stdio: 'inherit'});"
node js/build.mjs
node js/css.mjs
trunk build --release
sh "\$SRC/deploy/precompress-bundle.sh" "\$SRC/web/dist"
install -d /tmp/out
cp -a "\$SRC/web/dist" /tmp/out/dist
INNER
    )
    run_step "building the wasm bundle ..." "$SRC/web" "$CACHE/target-web-wasm" "$script"
    collect
    [ -f "$OUT/dist/index.html" ] || die "the web build produced no dist/index.html"
    [ "$(find "$OUT/dist" -type f -name '*.zst' | wc -l)" -gt 0 ] ||
        die "the web bundle has no .zst siblings; precompression did not run"
}

case $TARGET in
backend) build_backend ;;
web)
    build_web_server
    build_web_dist
    ;;
all)
    build_backend
    build_web_server
    build_web_dist
    ;;
esac

# --- glibc gate ------------------------------------------------------------------------

# The bookworm image is the guarantee; this check is the fence around it. A binary that
# needs a newer symbol would fail on CT 118/100 at the first call that uses it, which is a
# production crash rather than a failed deploy.
artifact_glibc() {
    local bin=$1 ceiling
    ceiling=$(objdump -T "$bin" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sed 's/^GLIBC_//' | sort -Vu | tail -1 || true)
    [ -n "$ceiling" ] || {
        printf 'FAIL: %s carries no versioned glibc symbols to check\n' "$bin" >&2
        return 1
    }
    printf '%s\n' "$ceiling"
}

CEILINGS=''
for bin in "$OUT"/nodus-*; do
    [ -f "$bin" ] || continue
    case ${bin##*/} in
    nodus-api | nodus-media | nodus-feed | nodus-scan | nodus-prune | nodus-calc | nodus-web-server) ;;
    *) continue ;;
    esac
    ceiling=$(artifact_glibc "$bin") || exit 1
    if [ "$(printf '%s\n%s\n' "$ceiling" "$MAX_GLIBC" | sort -V | tail -1)" != "$MAX_GLIBC" ]; then
        die "${bin##*/} needs GLIBC_$ceiling; the bookworm targets have $MAX_GLIBC"
    fi
    CEILINGS="$CEILINGS$ceiling
"
done
GLIBC_CEILING=$(printf '%s' "$CEILINGS" | sort -Vu | tail -1)

# --- manifest and checksums ------------------------------------------------------------

write_sums() {
    (
        cd "$OUT"
        case $TARGET in
        backend | all)
            for role in $ROLES; do printf 'nodus-%s\n' "$role"; done | xargs sha256sum
            ;;
        esac
        case $TARGET in
        web | all)
            sha256sum nodus-web-server
            # The compressed siblings are derived; only the bundle the builder emitted is
            # listed, so a later precompress-bundle.sh run does not invalidate the sums.
            find dist -type f ! -name '*.gz' ! -name '*.zst' -print0 | sort -z | xargs -0 sha256sum
            ;;
        esac
    ) >"$OUT/SHA256SUMS"
}

write_manifest() {
    {
        printf '# Written by deploy/build.sh; deploy/release-118.sh and deploy/release-100.sh read it.\n'
        printf 'manifest_version=1\n'
        printf 'tool=deploy/build.sh\n'
        printf 'target=%s\n' "$TARGET"
        printf 'source=%s\n' "$SOURCE_MODE"
        printf 'created=%s\n' "$CREATED"
        printf 'builder_image=%s\n' "$IMAGE"
        printf 'base_image=%s\n' "$BASE_IMAGE"
        printf 'glibc_ceiling=%s\n' "$GLIBC_CEILING"
        printf 'superproject=%s\n' "$SUPERPROJECT"
        printf 'superproject_dirty=%s\n' "$SUPERPROJECT_DIRTY"
        for sub in $SUBMODULES; do
            printf '%s=%s\n' "$sub" "${PIN[$sub]}"
            if [ "$SOURCE_MODE" = worktree ]; then
                printf '%s.dirty=%s\n' "$sub" "${DIRTY[$sub]}"
            fi
        done
    } >"$OUT/BUILD-INFO"
}

write_sums
write_manifest

# --- summary ---------------------------------------------------------------------------

elapsed=$(($(date +%s) - STARTED))
log ""
log "=== $TARGET artifacts in $OUT ==="
while read -r hash name; do
    printf '   %s  %s  %s\n' "$(stat -c %s "$OUT/$name")" "$hash" "$name"
done <"$OUT/SHA256SUMS"
log "   glibc ceiling: $GLIBC_CEILING (targets run $MAX_GLIBC)"
log "   manifest: $OUT/BUILD-INFO"
log "   checksums: $OUT/SHA256SUMS"
log "elapsed: ${elapsed}s"
