#!/bin/sh
# Shared plumbing for the lab scripts. Sourced, not executed.
#
# The compose project is pinned to `nodus-lab` everywhere: reset.sh deletion is
# only ever allowed to touch containers carrying that label, and running the
# scripts from another checkout must not adopt whatever project name the
# directory happens to produce.

INTEGRATION_DIR=$(
    unset CDPATH
    cd -- "$(dirname -- "$0")/.." && pwd
)
COMPOSE_FILE="$INTEGRATION_DIR/compose.yml"
PROJECT=nodus-lab

compose() {
    docker compose --project-name "$PROJECT" \
        --env-file "$INTEGRATION_DIR/.env" \
        --file "$COMPOSE_FILE" "$@"
}

generate_hex() {
    openssl rand -hex 32
}

generate_base64() {
    openssl rand -base64 32 | tr -d '\n'
}

# First run copies the documented template and fills the generated secrets.
# Later runs still fill a key that is missing or left as a marker, so adding a
# secret to .env.example upgrades an existing .env instead of silently blanking
# it. Existing values are never rewritten: volumes and passwords stay in step.
ensure_env() {
    if [ ! -f "$INTEGRATION_DIR/.env" ]; then
        cp "$INTEGRATION_DIR/.env.example" "$INTEGRATION_DIR/.env"
        printf 'created %s from .env.example\n' "$INTEGRATION_DIR/.env"
    fi
    for key in NODUS_DB_PASSWORD POSTGRES_PASSWORD VALKEY_PASSWORD NODUS_DRIVE_SHARE_SECRET; do
        fill_secret "$key" generate_hex
    done
    fill_secret TOKEN_ENC_KEY generate_base64
}

# Replaces an empty or __GENERATE__ value for one key, leaving a real one alone.
fill_secret() {
    key=$1
    generator=$2
    case $(env_value "$key") in
    '' | __GENERATE__ | __GENERATE_BASE64__)
        value=$($generator)
        if grep -q "^${key}=" "$INTEGRATION_DIR/.env"; then
            sed -i "s|^${key}=.*|${key}=${value}|" "$INTEGRATION_DIR/.env"
        else
            printf '%s=%s\n' "$key" "$value" >>"$INTEGRATION_DIR/.env"
        fi
        ;;
    esac
}

env_value() {
    sed -n "s|^$1=||p" "$INTEGRATION_DIR/.env" | tail -n 1
}

http_port() {
    port=$(env_value NODUS_HTTP_PORT)
    printf '%s\n' "${port:-8080}"
}

wait_for_url() {
    url=$1
    attempts=${2:-120}
    i=0
    while [ "$i" -lt "$attempts" ]; do
        if curl -fsS -o /dev/null "$url" 2>/dev/null; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    printf 'timed out waiting for %s\n' "$url" >&2
    return 1
}

# Refuses to touch a compose project whose containers were not created from this
# directory's compose.yml. reset.sh uses it before deleting volumes.
assert_own_project() {
    ids=$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")
    [ -n "$ids" ] || return 0
    expected="$COMPOSE_FILE"
    for id in $ids; do
        files=$(docker inspect \
            --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' \
            "$id" 2>/dev/null || true)
        case ",$files," in
        *",$expected,"*) ;;
        *)
            printf 'refusing to reset: container %s belongs to %s, not %s\n' \
                "$id" "$files" "$expected" >&2
            return 1
            ;;
        esac
    done
}

# The feed answers `/api/v1/meta` with exactly its own three names
# (recommender/crates/feeds/src/routes/meta.rs). The API's answer is the instance's whole
# vocabulary, so an answer of three names came from the feed, not from the API.
FEED_HANDSHAKE_FEATURES=3

# One image carries every server role; the other carries the shell and Caddy. Each is
# built from the submodules below, which is what the pins label records and what a
# staleness check has to compare.
SERVER_SUBMODULES="nodus-backend recommender sdk server-sdk"
WEB_SUBMODULES="web sdk"

repo_dir() {
    unset CDPATH
    cd -- "$(dirname -- "$INTEGRATION_DIR")" && pwd
}

# The commit the superproject records for one submodule (`git ls-tree HEAD`).
recorded_pin() {
    git -C "$(repo_dir)" ls-tree HEAD -- "$1" | awk '{print $3}'
}

# Every recorded pin as one no-space label value: `nodus-backend@<sha>,web@<sha>,...`.
# No spaces, because it travels through the word-split LAB_DOCKER_BUILD_ARGS into
# `docker build --build-arg`.
recorded_pins_label() {
    label=
    for sub in $SERVER_SUBMODULES $WEB_SUBMODULES; do
        pin=$(recorded_pin "$sub")
        label="${label:+$label,}$sub@${pin:-unknown}"
    done
    printf '%s\n' "$label"
}

# The features the API crate in this checkout publishes, one name per line, read from the
# array that answers the handshake. This is the code, not the container: comparing a
# running API against it is what tells a stale image from a correct one.
source_meta_features() {
    file="$(repo_dir)/nodus-backend/crates/api/src/meta.rs"
    if [ ! -f "$file" ]; then
        printf 'FAIL: %s is missing, so the handshake cannot be compared with the code\n' \
            "$file" >&2
        return 1
    fi
    sed -n '/^pub const FEATURES/,/^];/p' "$file" |
        sed -n 's/^[[:space:]]*"\([a-z_]*\)".*/\1/p'
}

# The API's own answer, asked over its own socket inside the network. Same origin, but
# nothing between it and the process: this is what the route table should be handing back.
fetch_meta_direct() {
    compose exec -T nodus-api curl -fsS http://127.0.0.1:3000/api/v1/meta
}

# Prints what one image was built from, for the line next to the handshake.
print_image_pin() {
    image=$1
    if ! created=$(docker image inspect --format '{{.Created}}' "$image" 2>/dev/null); then
        printf '  image            %s is not built\n' "$image"
        return 0
    fi
    built=$(printf '%s' "$created" | sed 's/T/ /; s/\..*//')
    pin_label=$(docker image inspect \
        --format '{{ index .Config.Labels "nodus.pins" }}' "$image" 2>/dev/null || true)
    case $pin_label in
    worktree)
        printf '  image            %-24s WORKTREE build (built %s): not a pinned image\n' \
            "$image" "$built"
        return 0
        ;;
    '' | '<no value>' | unknown)
        # No label: the image predates the pins label, or build.sh was run directly. The
        # creation time is the only evidence left, and it can only prove a mismatch: a pin
        # committed after the image was built cannot be inside it.
        later=$(pins_newer_than "$created" "$(lab_image_submodules "$image")")
        if [ -n "$later" ]; then
            printf '  image            %-24s unlabelled (built %s); newer than the image:%s\n' \
                "$image" "$built" "$later"
        else
            printf '  image            %-24s unlabelled (built %s); which commits it holds is unproven\n' \
                "$image" "$built"
        fi
        return 0
        ;;
    esac
    printf '  image            %-24s %s (built %s)\n' "$image" "$pin_label" "$built"
}

# The submodules an image is built from, keyed by the image name compose assigns it.
lab_image_submodules() {
    case $1 in
    *web*) printf '%s\n' "$WEB_SUBMODULES" ;;
    *) printf '%s\n' "$SERVER_SUBMODULES" ;;
    esac
}

# Prints ` sub@sha (<date>)` for every pin committed after the given image timestamp.
pins_newer_than() {
    created=$1
    created_epoch=$(date -d "$created" +%s 2>/dev/null || true)
    [ -n "$created_epoch" ] || return 0
    shift
    # Word-split on purpose: the caller hands the image's submodule list over as one string.
    # shellcheck disable=SC2048,SC2086
    for sub in $*; do
        pin=$(recorded_pin "$sub")
        [ -n "$pin" ] || continue
        committed=$(git -C "$(repo_dir)/$sub" show -s --format=%ct "$pin" 2>/dev/null || true)
        if [ -n "$committed" ] && [ "$committed" -gt "$created_epoch" ]; then
            # No spaces in an entry: the caller splits the printed list on whitespace.
            printf ' %s@%s(%s)' "$sub" "$(printf '%s' "$pin" | cut -c1-7)" \
                "$(date -d "@$committed" +'%Y-%m-%dT%H:%M')"
        fi
    done
}

# The images compose builds for this lab, and only those (postgres and valkey are pulled).
lab_images() {
    compose config --images 2>/dev/null | sed -n 's|^\(nodus-lab/.*\)$|\1|p' | sort -u
}

# Prints the names that appear on one side only.
print_name_diff() {
    left_file=$(mktemp)
    right_file=$(mktemp)
    printf '%s\n' "$1" | grep . | sort >"$left_file"
    printf '%s\n' "$2" | grep . | sort >"$right_file"
    only_left=$(comm -23 "$left_file" "$right_file" | tr '\n' ' ')
    only_right=$(comm -13 "$left_file" "$right_file" | tr '\n' ' ')
    printf '      only in %s: %s\n' "$3" "${only_left% }"
    printf '      only in %s: %s\n' "$4" "${only_right% }"
    rm -f "$left_file" "$right_file"
}

# Asserts that the same-origin handshake is the API's, and that the API is this checkout.
#
# Two comparisons, because two different failures answer the same URL:
#
#   1. same origin vs the API's own socket. One path, two processes: the API answers every
#      capability the instance serves, the feed the three it serves itself. A feed answer
#      here is not cosmetic: the shell, the SSR host and the e2e suites all gate their UI on
#      this list, so three names means a server that appears to do nothing.
#   2. the API's answer vs nodus-backend/crates/api/src/meta.rs. A threshold cannot see a
#      stale image: an API built eight hours ago answers a well-formed list that is simply
#      not the list this tree publishes, and the run then tests a binary nobody edits. The
#      count and the names have to match the code, so being behind is a failure, not a
#      smaller number that passes.
assert_meta_contract() {
    url=$1
    if ! body=$(curl -fsS "$url"); then
        printf 'FAIL: %s did not answer, so the handshake cannot be checked\n' "$url" >&2
        return 1
    fi
    if ! origin_count=$(printf '%s' "$body" | jq -er '.features | length' 2>/dev/null); then
        printf 'FAIL: %s did not return a features array\n' "$url" >&2
        return 1
    fi
    origin_names=$(printf '%s' "$body" | jq -r '.features[]' 2>/dev/null)

    if ! direct=$(fetch_meta_direct 2>/dev/null) || [ -z "$direct" ]; then
        printf 'FAIL: nodus-api did not answer http://127.0.0.1:3000/api/v1/meta itself,\n' >&2
        printf '      so the route cannot be separated from the process\n' >&2
        return 1
    fi
    api_count=$(printf '%s' "$direct" | jq -r '.features | length' 2>/dev/null)
    api_names=$(printf '%s' "$direct" | jq -r '.features[]' 2>/dev/null)

    if [ "$origin_count" -ne "$api_count" ] ||
        [ "$(printf '%s\n' "$origin_names" | sort)" != "$(printf '%s\n' "$api_names" | sort)" ]; then
        printf 'FAIL: %s answers %s features, the API answers %s\n' \
            "$url" "$origin_count" "$api_count" >&2
        print_name_diff "$origin_names" "$api_names" "origin" "the API" >&2
        if [ "$origin_count" -le "$FEED_HANDSHAKE_FEATURES" ]; then
            printf '      That is the feed process answering, not the API. The Caddyfile\n' >&2
            printf '      route table let the feed claim /api/v1/meta: the @feed matcher must\n' >&2
            printf '      not list it, so the /api/* rule answers it instead.\n' >&2
        else
            printf '      The origin and the API disagree, so something between them is\n' >&2
            printf '      rewriting the handshake. Compare the Caddyfile route table with the\n' >&2
            printf '      API it proxies to.\n' >&2
        fi
        return 1
    fi

    if ! code_names=$(source_meta_features); then
        return 1
    fi
    code_count=$(printf '%s\n' "$code_names" | grep -c . || true)
    if [ "$origin_count" -ne "$code_count" ] ||
        [ "$(printf '%s\n' "$origin_names" | sort)" != "$(printf '%s\n' "$code_names" | sort)" ]; then
        printf 'FAIL: the lab serves %s features, the code in this checkout publishes %s\n' \
            "$origin_count" "$code_count" >&2
        print_name_diff "$origin_names" "$code_names" "the lab" "the code" >&2
        printf '      The image is older than the tree: it answers a list that was correct\n' >&2
        printf '      when it was built and is not the list this checkout publishes. Rebuild\n' >&2
        printf '      before trusting the run; integration/scripts/check-pins.sh names the\n' >&2
        printf '      submodule the image is behind.\n' >&2
        return 1
    fi

    printf '  handshake        %s features: origin %s, API %s, code %s\n' \
        "$code_count" "$origin_count" "$api_count" "$code_count"
}
