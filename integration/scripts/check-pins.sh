#!/bin/sh
# Answers "is this stack running the current code?" without rebuilding anything.
#
#   integration/scripts/check-pins.sh              # every image compose builds
#   integration/scripts/check-pins.sh IMAGE...    # just these images
#
# Compares each lab image's `nodus.pins` label (stamped at build time from
# `git ls-tree HEAD`, see up.sh) against the pins this checkout records now, and names
# every submodule that disagrees. Nothing is built, pulled or started: it only reads
# `docker image inspect` and the superproject's gitlinks.
#
# Images built before the label existed carry none, and a `LAB_BUILD_FROM_WORKTREE=1`
# build carries `worktree`. Neither can be verified against a pin. For the unlabelled
# case the creation time is the only evidence left, and it can prove one thing: a pin
# committed after the image was built cannot be inside it. Those are reported as behind.
#
# Exit: 0 every image verified, 1 a submodule is behind (named), 2 nothing could verify.
set -eu

SCRIPT_DIR=$(
    unset CDPATH
    cd -- "$(dirname -- "$0")" && pwd
)
. "$SCRIPT_DIR/common.sh"

if [ ! -f "$INTEGRATION_DIR/.env" ]; then
    printf 'check-pins.sh: %s does not exist, so nothing has been built here yet\n' \
        "$INTEGRATION_DIR/.env" >&2
    exit 2
fi

behind=0
unverified=0

# Word-split on purpose: image names contain no spaces.
# shellcheck disable=SC2046
[ "$#" -gt 0 ] || set -- $(lab_images)
for image in "$@"; do
    if ! created=$(docker image inspect --format '{{.Created}}' "$image" 2>/dev/null); then
        printf '  %-24s not built\n' "$image"
        unverified=1
        continue
    fi
    built=$(printf '%s' "$created" | sed 's/T/ /; s/\..*//')
    pin_label=$(docker image inspect \
        --format '{{ index .Config.Labels "nodus.pins" }}' "$image" 2>/dev/null || true)
    submodules=$(lab_image_submodules "$image")

    case $pin_label in
    worktree)
        printf '  %-24s WORKTREE build (built %s): no pin describes it\n' "$image" "$built"
        unverified=1
        ;;
    '' | '<no value>' | unknown)
        printf '  %-24s unlabelled (built %s)\n' "$image" "$built"
        later=$(pins_newer_than "$created" "$submodules")
        if [ -n "$later" ]; then
            for entry in $later; do
                sub=${entry%%@*}
                printf '    BEHIND: %-14s pin %s was committed after the image was built\n' \
                    "$sub" "$(recorded_pin "$sub" | cut -c1-7)"
            done
            behind=1
        else
            printf '    cannot verify: no label, and no pin is newer than the image\n'
            unverified=1
        fi
        ;;
    *)
        stale=
        for sub in $submodules; do
            image_pin=$(printf '%s' "$pin_label" | tr ',' '\n' |
                sed -n "s|^${sub}@||p")
            recorded=$(recorded_pin "$sub")
            if [ "$image_pin" != "$recorded" ]; then
                printf '    MISMATCH: %-12s image %s, checkout %s\n' \
                    "$sub" "$(printf '%s' "${image_pin:-none}" | cut -c1-7)" \
                    "$(printf '%s' "${recorded:-none}" | cut -c1-7)"
                behind=1
                stale=1
            fi
        done
        if [ -z "$stale" ]; then
            printf '  %-24s pinned and current: %s\n' "$image" "$pin_label"
        fi
        ;;
    esac
done

if [ "$behind" -eq 1 ]; then
    printf '\nFAIL: the running stack is not the code this checkout records.\n' >&2
    printf '      Rebuild before trusting a run: integration/scripts/up.sh\n' >&2
    exit 1
fi
if [ "$unverified" -eq 1 ]; then
    printf '\nUNVERIFIED: some images carry no pin, so "current" cannot be shown.\n' >&2
    printf '      Rebuild them: integration/scripts/up.sh\n' >&2
    exit 2
fi
printf '\nthe running stack is the code this checkout records\n'
