#!/usr/bin/env bash
# The host-side development loop: infrastructure in the lab, code on the host.
#
#   integration/scripts/dev.sh infra          start Postgres + Valkey with host ports
#   integration/scripts/dev.sh infra down     stop them, keeping the volumes
#   integration/scripts/dev.sh api            run nodus-api on the host (3300)
#   integration/scripts/dev.sh feed           run nodus-feed on the host (3303)
#   integration/scripts/dev.sh worker [role]  run media (default), scan, prune or calc
#   integration/scripts/dev.sh web [--ssr]    trunk serve (default) or the SSR shell (3301)
#
# The containers are the same ones the full lab uses: Postgres holds the same
# database and Valkey the same cache. `dev.sh infra` layers compose.dev.yml on
# compose.yml to publish 55432 and 56379 on loopback; nothing else is started.
# The binaries are built in debug mode into integration/state/target-dev, and
# the media tree lives in integration/state/dev, so a dev run never writes into
# the images' volumes.
#
# Ports (override with the environment):
#   NODUS_DEV_API_PORT=3300     NODUS_DEV_WEB_PORT=3301
#   NODUS_DEV_MEDIA_PORT=3302   NODUS_DEV_FEED_PORT=3303
#   NODUS_DEV_DB_PORT=55432     NODUS_DEV_VALKEY_PORT=56379
#   NODUS_DEV_SCAN_PORT=3310    NODUS_DEV_PRUNE_PORT=3311  NODUS_DEV_CALC_PORT=3312
#
# There is no file watcher: cargo and trunk rebuild on the next command, and a
# host process keeps the binary it started with. Restart the mode after a
# rebuild; docs/dev-loop.md states the measured costs and the traps.
set -euo pipefail

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

REPO_DIR=$(unset CDPATH; cd -- "$INTEGRATION_DIR/.." && pwd)
COMPOSE_DEV_FILE="$INTEGRATION_DIR/compose.dev.yml"
DEV_DIR="$INTEGRATION_DIR/state/dev"
TARGET_DIR="$INTEGRATION_DIR/state/target-dev"
BACKEND_MANIFEST="$REPO_DIR/nodus-backend/Cargo.toml"
WEB_MANIFEST="$REPO_DIR/web/Cargo.toml"

API_PORT=${NODUS_DEV_API_PORT:-3300}
WEB_PORT=${NODUS_DEV_WEB_PORT:-3301}
MEDIA_PORT=${NODUS_DEV_MEDIA_PORT:-3302}
FEED_PORT=${NODUS_DEV_FEED_PORT:-3303}
DB_PORT=${NODUS_DEV_DB_PORT:-55432}
VALKEY_PORT=${NODUS_DEV_VALKEY_PORT:-56379}
SCAN_PORT=${NODUS_DEV_SCAN_PORT:-3310}
PRUNE_PORT=${NODUS_DEV_PRUNE_PORT:-3311}
CALC_PORT=${NODUS_DEV_CALC_PORT:-3312}

export NODUS_DEV_DB_PORT=$DB_PORT
export NODUS_DEV_VALKEY_PORT=$VALKEY_PORT

usage() {
    sed -n '2,26p' "$SCRIPT_DIR/dev.sh" | sed 's/^# \{0,1\}//'
}

die() {
    printf 'dev.sh: %s\n' "$*" >&2
    exit 1
}

dev_compose() {
    docker compose --project-name "$PROJECT" \
        --env-file "$INTEGRATION_DIR/.env" \
        --file "$COMPOSE_FILE" \
        --file "$COMPOSE_DEV_FILE" "$@"
}

require_docker() {
    command -v docker >/dev/null 2>&1 || die "docker is not installed"
    docker info >/dev/null 2>&1 || die "the docker daemon is not reachable; start Docker and retry"
}

port_in_use() {
    local port=$1
    if command -v ss >/dev/null 2>&1; then
        if ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .; then
            return 0
        fi
    fi
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null
}

require_port_free() {
    local port=$1 what=$2 knob=$3
    if port_in_use "$port"; then
        printf 'dev.sh: %s port %s is already in use\n' "$what" "$port" >&2
        printf '  owner:        ss -ltnp '"'"'sport = :%s'"'"'\n' "$port" >&2
        printf '  free it, or:  %s=<another-port> %s\n' \
            "$knob" "${0} ${WHAT_COMMAND:-}" >&2
        exit 1
    fi
}

wait_tcp() {
    local port=$1 what=$2
    i=0
    while [ "$i" -lt 30 ]; do
        if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    die "$what is not accepting connections on 127.0.0.1:$port"
}

container_maps_port() {
    local container=$1 private=$2 wanted=$3 mapped
    mapped=$(docker port "$container" "$private" 2>/dev/null | head -n 1)
    case $mapped in
    *":$wanted") return 0 ;;
    *) return 1 ;;
    esac
}

infra_running() {
    [ "$(docker inspect -f '{{.State.Running}}' nodus-lab-postgres 2>/dev/null || true)" = true ] &&
        [ "$(docker inspect -f '{{.State.Running}}' nodus-lab-valkey 2>/dev/null || true)" = true ] &&
        container_maps_port nodus-lab-postgres 5432/tcp "$DB_PORT" &&
        container_maps_port nodus-lab-valkey 6379/tcp "$VALKEY_PORT"
}

db_url() {
    printf 'postgres://nodus:%s@127.0.0.1:%s/nodus' \
        "$(env_value NODUS_DB_PASSWORD)" "$DB_PORT"
}

valkey_url() {
    printf 'redis://:%s@127.0.0.1:%s/0' \
        "$(env_value VALKEY_PASSWORD)" "$VALKEY_PORT"
}

infra_up() {
    ensure_env
    require_docker
    if infra_running; then
        printf 'dev.sh: infra already up (postgres 127.0.0.1:%s, valkey 127.0.0.1:%s)\n' \
            "$DB_PORT" "$VALKEY_PORT"
        return 0
    fi
    # A container that is running with the wrong mapping would be recreated, and
    # compose can only publish the port once the old listener is gone.
    if port_in_use "$DB_PORT"; then
        die "Postgres port $DB_PORT is held by another process; stop it or set NODUS_DEV_DB_PORT"
    fi
    if port_in_use "$VALKEY_PORT"; then
        die "Valkey port $VALKEY_PORT is held by another process; stop it or set NODUS_DEV_VALKEY_PORT"
    fi
    printf 'dev.sh: starting postgres + valkey with host ports %s/%s ...\n' "$DB_PORT" "$VALKEY_PORT"
    dev_compose up -d --wait postgres valkey ||
        die "compose could not start the infra; inspect: docker compose -p $PROJECT -f $COMPOSE_FILE -f $COMPOSE_DEV_FILE logs postgres valkey"
    wait_tcp "$DB_PORT" "postgres"
    wait_tcp "$VALKEY_PORT" "valkey"
    printf 'dev.sh: infra up\n'
}

infra_down() {
    require_docker
    dev_compose stop postgres valkey ||
        die "could not stop the infra containers"
    printf 'dev.sh: infra stopped (volumes kept; integration/scripts/reset.sh drops them)\n'
}

require_infra() {
    if ! infra_running; then
        die "infra is not up (nodus-lab-postgres + nodus-lab-valkey with host ports $DB_PORT/$VALKEY_PORT)
  start it: integration/scripts/dev.sh infra"
    fi
    wait_tcp "$DB_PORT" "postgres"
    wait_tcp "$VALKEY_PORT" "valkey"
    password=$(env_value NODUS_DB_PASSWORD)
    if ! docker exec -e PGPASSWORD="$password" nodus-lab-postgres \
        psql -h 127.0.0.1 -U nodus -d nodus -tAc 'select 1' >/dev/null 2>&1; then
        die "postgres rejects NODUS_DB_PASSWORD from integration/.env
  The named volume keeps the role password from the run that created it, so a
  regenerated or restored .env no longer matches. Realign the role in place:
    docker exec nodus-lab-postgres psql -U postgres -c \"ALTER ROLE nodus PASSWORD '$password'\"
  or drop the volume (this deletes the lab database):
    integration/scripts/reset.sh && integration/scripts/dev.sh infra"
    fi
}

export_common_env() {
    export NODUS_DATABASE_URL
    NODUS_DATABASE_URL=$(db_url)
    export NODUS_VALKEY_URL
    NODUS_VALKEY_URL=$(valkey_url)
    # The federation identity stays the lab's name so account addresses and
    # absolute links agree with the full stack; the URL the host browser uses is
    # the loopback dev port.
    export NODUS_DOMAIN=${NODUS_DEV_DOMAIN:-nodus.test}
    export NODUS_BASE_URL=${NODUS_DEV_BASE_URL:-http://localhost:$API_PORT}
    export NODUS_TITLE=${NODUS_DEV_TITLE:-Nodus Dev}
    export NODUS_DESCRIPTION=${NODUS_DEV_DESCRIPTION:-Host process against lab infrastructure}
    export NODUS_CONTACT_EMAIL=${NODUS_DEV_CONTACT_EMAIL:-dev@nodus.test}
    export NODUS_AUTH_SECURE_COOKIES=false
    export NODUS_REGISTRATIONS_OPEN=true
    export NODUS_AUTHORIZED_FETCH=false
    export NODUS_DATABASE_CONNECTIONS=${NODUS_DEV_DATABASE_CONNECTIONS:-5}
    export NODUS_HOME_CAP=${NODUS_HOME_CAP:-400}
    export NODUS_HOME_SHARDS=${NODUS_HOME_SHARDS:-1}
    export NODUS_VALKEY_CHANNEL=${NODUS_VALKEY_CHANNEL:-nodus:home}
    export NODUS_MEDIA_DIR="$DEV_DIR/media"
    export NODUS_MEDIA_VARIANTS_DIR="$DEV_DIR/media/variants"
    export NODUS_MEDIA_ENDPOINT="http://127.0.0.1:$MEDIA_PORT"
    export NODUS_MEDIA_NODE=media-dev
    mkdir -p "$NODUS_MEDIA_VARIANTS_DIR"
    # Only the API creates the bootstrap account; the role already exists in the
    # shared lab database, so this is harmless on a database the lab seeded.
    export NODUS_BOOTSTRAP_EMAIL
    NODUS_BOOTSTRAP_EMAIL=$(env_value NODUS_BOOTSTRAP_EMAIL)
    export NODUS_BOOTSTRAP_USERNAME
    NODUS_BOOTSTRAP_USERNAME=$(env_value NODUS_BOOTSTRAP_USERNAME)
    export NODUS_BOOTSTRAP_PASSWORD
    NODUS_BOOTSTRAP_PASSWORD=$(env_value NODUS_BOOTSTRAP_PASSWORD)
    export TOKEN_ENC_KEY
    TOKEN_ENC_KEY=$(env_value TOKEN_ENC_KEY)
}

build_backend() {
    package=$1
    bin=$2
    start=$(date +%s)
    CARGO_TARGET_DIR="$TARGET_DIR" cargo build \
        --manifest-path "$BACKEND_MANIFEST" \
        --package "$package" --bin "$bin"
    end=$(date +%s)
    printf 'dev.sh: built %s in %ss (%s/debug/%s)\n' \
        "$bin" "$((end - start))" "$TARGET_DIR" "$bin"
}

run_api() {
    WHAT_COMMAND="api"
    require_infra
    require_port_free "$API_PORT" "api" "NODUS_DEV_API_PORT"
    export_common_env
    export NODUS_BIND="127.0.0.1:$API_PORT"
    build_backend nodus-api nodus-api
    printf 'dev.sh: applying migrations ...\n'
    "$TARGET_DIR/debug/nodus-api" --migrate-only
    printf 'dev.sh: api on http://localhost:%s (sign in with that URL; media in %s)\n' \
        "$API_PORT" "$NODUS_MEDIA_DIR"
    exec "$TARGET_DIR/debug/nodus-api"
}

run_feed() {
    WHAT_COMMAND="feed"
    require_infra
    require_port_free "$FEED_PORT" "feed" "NODUS_DEV_FEED_PORT"
    export_common_env
    export NODUS_BIND="127.0.0.1:$FEED_PORT"
    build_backend nodus-feed nodus-feed
    printf 'dev.sh: feed on http://localhost:%s\n' "$FEED_PORT"
    exec "$TARGET_DIR/debug/nodus-feed"
}

run_worker() {
    role=${1:-media}
    case $role in
    media)
        package=nodus-media
        bin=nodus-media
        port=$MEDIA_PORT
        knob=NODUS_DEV_MEDIA_PORT
        ;;
    scan) package=nodus-scan; bin=nodus-scan; port=$SCAN_PORT; knob=NODUS_DEV_SCAN_PORT ;;
    prune) package=nodus-prune; bin=nodus-prune; port=$PRUNE_PORT; knob=NODUS_DEV_PRUNE_PORT ;;
    calc) package=nodus-calc; bin=nodus-calc; port=$CALC_PORT; knob=NODUS_DEV_CALC_PORT ;;
    *)
        die "unknown worker role: $role (expected media, scan, prune or calc)"
        ;;
    esac
    WHAT_COMMAND="worker $role"
    require_infra
    require_port_free "$port" "$role" "$knob"
    export_common_env
    if [ "$role" = media ]; then
        export NODUS_BIND="127.0.0.1:$port"
    else
        # scan/prune/calc only expose their gRPC control listener.
        export NODUS_TELEMETRY_BIND="127.0.0.1:$port"
    fi
    build_backend "$package" "$bin"
    printf 'dev.sh: %s on 127.0.0.1:%s\n' "$role" "$port"
    exec "$TARGET_DIR/debug/$bin"
}

find_trunk() {
    if command -v trunk >/dev/null 2>&1; then
        command -v trunk
        return 0
    fi
    if [ -x "$INTEGRATION_DIR/state/bin/trunk" ]; then
        printf '%s\n' "$INTEGRATION_DIR/state/bin/trunk"
        return 0
    fi
    die "trunk is required for the web loop
  install it: cargo install trunk --locked
  or place the release binary at $INTEGRATION_DIR/state/bin/trunk:
    curl -sL https://github.com/trunk-rs/trunk/releases/download/v0.22.2/trunk-x86_64-unknown-linux-gnu.tar.gz | tar -xz -C $INTEGRATION_DIR/state/bin trunk"
}

run_web() {
    ssr=0
    for arg in "$@"; do
        case $arg in
        --ssr) ssr=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown web option: $arg (expected --ssr)" ;;
        esac
    done
    WHAT_COMMAND="web"
    require_infra
    require_port_free "$WEB_PORT" "web" "NODUS_DEV_WEB_PORT"
    trunk=$(find_trunk)
    cd "$REPO_DIR/web"
    if [ "$ssr" -eq 1 ]; then
        printf 'dev.sh: building the web bundle ...\n'
        "$trunk" build
        start=$(date +%s)
        CARGO_TARGET_DIR="$TARGET_DIR" cargo build \
            --manifest-path "$WEB_MANIFEST" --package nodus-web-server --bin nodus-web-server
        end=$(date +%s)
        printf 'dev.sh: built nodus-web-server in %ss\n' "$((end - start))"
        mkdir -p "$DEV_DIR"
        export NODUS_LISTEN="127.0.0.1:$WEB_PORT"
        export NODUS_ASSET_DIR="$REPO_DIR/web/dist"
        export NODUS_SESSIONS="$DEV_DIR/sessions.json"
        # The SSR host only accepts https public instance URLs, so it cannot
        # proxy a loopback API. The landing page and the static shell render;
        # signed-in API calls go directly from the browser to the dev API.
        export NODUS_INSTANCE_HOST=${NODUS_DEV_ORIGIN:-http://localhost:$API_PORT}
        printf 'dev.sh: SSR shell on http://localhost:%s (assets %s)\n' \
            "$WEB_PORT" "$NODUS_ASSET_DIR"
        printf 'dev.sh: note: SSR sign-in refuses loopback origins; use `dev.sh web` for the app\n' >&2
        exec "$TARGET_DIR/debug/nodus-web-server"
    fi
    printf 'dev.sh: trunk serve on http://localhost:%s (proxying /api to :%s)\n' \
        "$WEB_PORT" "$API_PORT"
    exec "$trunk" serve \
        --address 127.0.0.1 \
        --port "$WEB_PORT" \
        --proxy-backend "http://127.0.0.1:$API_PORT" \
        --proxy-rewrite /api
}

command=${1:-}
case $command in
infra)
    shift
    case ${1:-up} in
    up) infra_up ;;
    down) infra_down ;;
    *) die "usage: dev.sh infra [up|down]" ;;
    esac
    ;;
api)
    run_api
    ;;
feed)
    run_feed
    ;;
worker)
    shift
    run_worker "${1:-media}"
    ;;
web)
    shift
    run_web "$@"
    ;;
-h | --help | help)
    usage
    ;;
*)
    usage >&2
    exit 2
    ;;
esac
