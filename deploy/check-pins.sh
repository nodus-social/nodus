#!/usr/bin/env bash
# Compiles every workspace that consumes the SDK against the pinned submodule contents.
#
#   deploy/check-pins.sh
#
# A pin that matches its recorded gitlink can still fail to compose: sdk adds an error
# variant, and every exhaustive `match` downstream becomes non-exhaustive (E0004). Nothing
# in the tree is dirty and no hash comparison can see it. This gate compiles the pins
# `deploy/build.sh` builds (`git ls-tree HEAD` + `git archive`, via deploy/pins.sh), so
# that class fails here in seconds instead of after a ten-minute build.
#
# `cargo check --workspace` is the cheapest check that catches it. It covers libraries and
# binaries, NOT tests or examples: a test-only break needs `cargo check --workspace
# --all-targets`, which is a slower, separate question this gate does not answer.
#
# A workspace whose toolchain is missing is skipped with its reason, not failed. The
# shared target directory and the staged pin context live under ~/.cache/nodus-check-pins
# and survive between runs; the context is re-extracted only when a pin changes, and the
# files are then touched so cargo cannot mistake the commit-dated mtimes for older
# artifacts. Never /tmp: this host's /tmp is RAM-backed, and a large target directory
# there has OOM-killed the machine.
#
# Exit: 0 every runnable check passed, 1 a check failed, 2 nothing could run.
set -Eeuo pipefail

ROOT=$(
    unset CDPATH
    cd -- "$(dirname -- "$0")/.." && pwd
)
# shellcheck source=pins.sh
. "$ROOT/deploy/pins.sh"

# Every submodule is staged because path dependencies cross them: `recommender` and `web`
# use ../sdk, `nodus-backend` uses ../server-sdk.
SUBMODULES="nodus-backend recommender sdk server-sdk web"
CACHE=${NODUS_CHECK_PINS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/nodus-check-pins}
SRC=$CACHE/src
TARGET=$CACHE/target
LOGS=$CACHE/logs
STARTED=$SECONDS

log() { printf '%s\n' "$*"; }
die() {
    printf 'check-pins: %s\n' "$*" >&2
    exit 2
}

case $CACHE in
/tmp | /tmp/*) die "NODUS_CHECK_PINS_CACHE=$CACHE is under /tmp, which is RAM-backed on this host; choose a disk path" ;;
esac

for tool in git tar find awk; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required on the host"
done

mkdir -p "$SRC" "$TARGET" "$LOGS"

# --- pinned context --------------------------------------------------------------------

PIN_LINES=''
for sub in $SUBMODULES; do
    pin=$(pin_of "$ROOT" "$sub")
    [ -n "$pin" ] || die "no gitlink for $sub in $ROOT HEAD"
    PIN_LINES="$PIN_LINES$sub=$pin
"
done

log "=== pinned-workspace compile check ==="
log "superproject: $(git -C "$ROOT" rev-parse --short HEAD)"
log "pins (git ls-tree HEAD):"
for sub in $SUBMODULES; do
    printf '   %-14s %s\n' "$sub" "$(printf '%s\n' "$PIN_LINES" | sed -n "s/^${sub}=//p" | cut -c1-7)"
done

if [ -f "$CACHE/pins" ]; then
    OLD_PINS=$(cat "$CACHE/pins")
else
    OLD_PINS=''
fi

# Re-extract only a submodule whose pin moved (or whose staged tree is gone). Touching
# every file in the changed tree defeats cargo's newer-artifact shortcut; touching the
# unchanged ones would force needless rebuilds.
declare -a CHANGED=()
for sub in $SUBMODULES; do
    pin=$(printf '%s\n' "$PIN_LINES" | sed -n "s/^${sub}=//p")
    old=$(printf '%s\n' "$OLD_PINS" | sed -n "s/^${sub}=//p")
    if [ ! -d "$SRC/$sub" ] || [ "$old" != "$pin" ]; then
        archive_pin "$ROOT" "$sub" "$pin" "$SRC/$sub" ||
            die "cannot archive $sub at $pin; run git submodule update --init"
        CHANGED+=("$sub")
    fi
done
if [ "${#CHANGED[@]}" -gt 0 ]; then
    log "context: staged ${CHANGED[*]} into $SRC"
    for sub in "${CHANGED[@]}"; do
        # git archive stamps the commit time on every file; a cached target directory can
        # be newer, which would make cargo reuse artifacts of the previous pin.
        find "$SRC/$sub" -type f -exec touch {} +
    done
    printf '%s' "$PIN_LINES" >"$CACHE/pins"
else
    log "context: reusing $SRC (pins unchanged)"
fi
log "target:  $TARGET"

# --- checks ----------------------------------------------------------------------------

FAILED=0
RAN=0
SKIPPED=0
declare -a RAN_NAMES=()
declare -a SKIPPED_NOTES=()

slug() { printf '%s' "$1" | tr ' /()' '----'; }

skip() {
    local label=$1 why=$2
    printf '   %-24s SKIP  %s\n' "$label" "$why"
    SKIPPED=$((SKIPPED + 1))
    SKIPPED_NOTES+=("$label: $why")
}

# run_check LABEL WORKDIR ARGS... -> cargo check in WORKDIR, log under $LOGS.
run_check() {
    local label=$1 workdir=$2
    shift 2
    local logfile start elapsed
    logfile=$LOGS/$(slug "$label").log
    start=$SECONDS
    if (cd "$workdir" && CARGO_TARGET_DIR=$TARGET cargo "$@") >"$logfile" 2>&1; then
        elapsed=$((SECONDS - start))
        printf '   %-24s PASS  %3ss  cargo %s\n' "$label" "$elapsed" "$*"
        RAN=$((RAN + 1))
        RAN_NAMES+=("$label")
    else
        elapsed=$((SECONDS - start))
        printf '   %-24s FAIL  %3ss  cargo %s\n' "$label" "$elapsed" "$*"
        printf '      workspace: %s\n' "$label"
        # The parser's own words: from the first error through its notes and source span.
        sed -n '/^error\[\|^error:/,$p' "$logfile" | sed -n '1,30p' | sed 's/^/      /'
        printf '      log: %s\n' "$logfile"
        FAILED=1
        RAN=$((RAN + 1))
        RAN_NAMES+=("$label")
    fi
}

if ! command -v cargo >/dev/null 2>&1; then
    for label in sdk recommender nodus-backend web web-client; do
        skip "$label" "cargo is not on PATH"
    done
elif ! command -v rustc >/dev/null 2>&1; then
    for label in sdk recommender nodus-backend web web-client; do
        skip "$label" "rustc is not on PATH"
    done
else
    run_check sdk "$SRC/sdk" check --workspace
    run_check recommender "$SRC/recommender" check --workspace
    run_check nodus-backend "$SRC/nodus-backend" check --workspace

    # nodus-web-client depends on wasm-bindgen/web-sys and only compiles for the wasm
    # target; pages and ui compile for both, so the host check covers their shared code.
    run_check web "$SRC/web" check --workspace --exclude nodus-web-client
    if command -v rustup >/dev/null 2>&1 &&
        ! rustup target list --installed 2>/dev/null | grep -qx wasm32-unknown-unknown; then
        skip web-client "wasm32-unknown-unknown is not installed (rustup target add wasm32-unknown-unknown)"
    else
        run_check web-client "$SRC/web" check -p nodus-web-client --target wasm32-unknown-unknown
    fi
fi

# --- summary ---------------------------------------------------------------------------

elapsed=$((SECONDS - STARTED))
log ""
log "ran ${RAN} check(s): ${RAN_NAMES[*]:-none}"
if [ "$SKIPPED" -gt 0 ]; then
    log "skipped ${SKIPPED}:"
    for note in "${SKIPPED_NOTES[@]}"; do
        printf '   %s\n' "$note"
    done
fi
log "note: cargo check covers libraries and binaries, not tests or examples (--all-targets)"
log "elapsed: ${elapsed}s"

if [ "$FAILED" -eq 1 ]; then
    printf '\nFAIL: the pinned submodules do not compose (the named workspace does not compile).\n' >&2
    printf '      A matching pin is not the same as a composing pin.\n' >&2
    exit 1
fi
if [ "$RAN" -eq 0 ]; then
    printf '\nSKIPPED: no check could run; the gate proved nothing.\n' >&2
    exit 2
fi
log "the pinned submodules compose"
