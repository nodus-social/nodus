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
# (recommender/crates/feeds/src/routes/meta.rs). Any answer at or below that count came from
# the feed, not from the API.
FEED_HANDSHAKE_FEATURES=3

# Asserts that the same-origin handshake is the API's, not the feed's.
#
# One path, two processes: the API answers it with every capability the instance serves,
# the feed with the three it serves itself. The route table is the only place one is chosen
# over the other, and nothing downstream can tell the difference except by counting. A
# feed answer here is not cosmetic: the shell, the SSR host and the e2e suites all gate
# their UI on this list, so three names means a server that appears to do nothing.
assert_meta_contract() {
    url=$1
    if ! body=$(curl -fsS "$url"); then
        printf 'FAIL: %s did not answer, so the handshake cannot be checked\n' "$url" >&2
        return 1
    fi
    if ! count=$(printf '%s' "$body" | jq -e '.features | length' 2>/dev/null); then
        printf 'FAIL: %s did not return a features array\n' "$url" >&2
        return 1
    fi
    if [ "$count" -le "$FEED_HANDSHAKE_FEATURES" ]; then
        printf 'FAIL: %s advertises only %s features: %s\n' \
            "$url" "$count" "$(printf '%s' "$body" | jq -c '.features' 2>/dev/null)" >&2
        printf '      That is the feed process answering, not the API. Clients gate their\n' >&2
        printf '      whole UI on this list, so they draw three surfaces and hide the rest.\n' >&2
        printf '      The Caddyfile route table let the feed claim /api/v1/meta: the @feed\n' >&2
        printf '      matcher must not list it, so the /api/* rule answers it instead.\n' >&2
        return 1
    fi
    printf '  handshake        %s features at %s\n' "$count" "$url"
}
