#!/usr/bin/env bash
# The measurement stack: its own database, its own Valkey, its own media volume
# and its own origin port. Nothing here writes to the e2e lab's database, and
# only `up`/`down` touch containers, all of them named nodus-load-*.
#
#   integration/scripts/load.sh up       start the stack (creates nodusload)
#   integration/scripts/load.sh seed     bulk-seed + an API-created auth account
#   integration/scripts/load.sh run      all four k6 scenarios + resource samples
#   integration/scripts/load.sh down     stop the stack, keep volumes
#   integration/scripts/load.sh report   render out/*.json as markdown tables
#
# Every command is safe to rerun. `seed` clears the previous bulk accounts
# (cascading to their rows) before inserting, so counts are stable rather than
# doubled.
set -euo pipefail

SCRIPT_DIR=$(
    unset CDPATH
    cd -- "$(dirname -- "$0")" && pwd
)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

LOAD_DIR="$INTEGRATION_DIR/load"
OUT_DIR="$LOAD_DIR/out"
LOAD_COMPOSE="$INTEGRATION_DIR/compose.load.yml"
LOAD_PROJECT=nodus-load
BASE=http://127.0.0.1:18100
PG_CONTAINER=nodus-lab-postgres
VALKEY_CONTAINER=nodus-load-valkey
K6_IMAGE=grafana/k6:latest
K6_DIGEST=sha256:3d8e5c7f1d53ec59408c2ffbd9943602a0985ffcbd4a2430ec00f3ffca89796e
SERVER_IMAGE=nodus-lab/server:0.1.0

for tool in curl jq openssl sha256sum stat python3; do
    command -v "$tool" >/dev/null || {
        printf 'load.sh needs %s\n' "$tool" >&2
        exit 1
    }
done

mkdir -p "$OUT_DIR"

load_compose() {
    docker compose --project-name "$LOAD_PROJECT" \
        --env-file "$INTEGRATION_DIR/.env" \
        --file "$LOAD_COMPOSE" "$@"
}

die() {
    printf 'load.sh: %s\n' "$*" >&2
    exit 1
}

db_password() { env_value NODUS_DB_PASSWORD; }

psql_load() {
    PGPASSWORD=$(db_password) docker exec -i "$PG_CONTAINER" \
        psql -U nodus -d nodusload -v ON_ERROR_STOP=1 -q -tA "$@"
}

valkey_cli() {
    docker exec -i "$VALKEY_CONTAINER" valkey-cli --no-auth-warning \
        -a "$(env_value VALKEY_PASSWORD)" "$@"
}

# ---- up -------------------------------------------------------------------

# The application role `nodus` is deliberately not a superuser and has no
# CREATEDB, so the database is created as the `postgres` role over the
# container's local socket and handed to `nodus`. This is the only statement in
# the harness that runs as postgres, and it touches nothing in the `nodus`
# database.
create_database() {
    local present
    present=$(docker exec -i "$PG_CONTAINER" psql -U postgres -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname = 'nodusload'")
    if [ "$present" = "1" ]; then
        printf 'database nodusload already exists\n'
        return 0
    fi
    docker exec -i "$PG_CONTAINER" psql -U postgres -d postgres -q -c \
        'CREATE DATABASE nodusload OWNER nodus'
    printf 'created database nodusload\n'
}

cmd_up() {
    ensure_env
    docker network inspect nodus-lab >/dev/null 2>&1 ||
        die 'the nodus-lab network is missing; start the lab stack first'
    create_database
    load_compose up -d --wait --wait-timeout 180
    wait_for_url "$BASE/healthz" 120 ||
        die "the load stack is not answering on $BASE"
    printf 'load stack up on %s (database nodusload)\n' "$BASE"
}

# ---- auth -----------------------------------------------------------------

csrf_from() {
    sed -n 's/.*name="csrf_token" value="\([^"]*\)".*/\1/p' "$1" | head -n 1
}

# A bearer token for the bootstrap admin, through the same PKCE flow the web
# client uses. The token and account id are cached in out/auth.json; a rerun
# reuses them until the API starts answering 401, at which point they are
# minted again.
ensure_auth() {
    local cached="$OUT_DIR/auth.json"
    if [ -s "$cached" ]; then
        local token id
        token=$(jq -r .token "$cached")
        id=$(jq -r .id "$cached")
        if [ -n "$token" ] && [ "$token" != null ] &&
            curl -fsS -o /dev/null -H "Authorization: Bearer $token" \
                "$BASE/api/v1/accounts/verify_credentials"; then
            printf '%s %s\n' "$token" "$id"
            return 0
        fi
    fi

    local work
    work=$(mktemp -d)
    local email username password
    email=$(env_value NODUS_BOOTSTRAP_EMAIL)
    username=$(env_value NODUS_BOOTSTRAP_USERNAME)
    password=$(env_value NODUS_BOOTSTRAP_PASSWORD)
    local redirect="http://127.0.0.1:18100/oauth/callback"
    local scopes='read write follow' state=load

    local app client_id client_secret
    app=$(curl -fsS -X POST "$BASE/api/v1/apps" \
        -H 'content-type: application/json' \
        -d "$(jq -nc --arg name 'nodus load harness' --arg redirect "$redirect" \
            --arg scopes "$scopes" \
            '{client_name: $name, redirect_uris: $redirect, scopes: $scopes}')")
    client_id=$(printf '%s' "$app" | jq -r .client_id)
    client_secret=$(printf '%s' "$app" | jq -r .client_secret)

    local jar="$work/jar" page="$work/login.html" code csrf
    curl -fsS -c "$jar" "$BASE/auth/login" -o "$page"
    csrf=$(csrf_from "$page")
    [ -n "$csrf" ] || die 'no csrf token on the login page'
    code=$(curl -sS -o /dev/null -w '%{http_code}' -b "$jar" -c "$jar" \
        --data-urlencode "email=$email" \
        --data-urlencode "password=$password" \
        --data-urlencode "return_to=/" \
        --data-urlencode "csrf_token=$csrf" \
        "$BASE/auth/login")
    if [ "$code" != "303" ]; then
        rm -rf "$work"
        die "login for $username returned HTTP $code (bootstrap credentials?)"
    fi

    local verifier challenge
    verifier=$(openssl rand -hex 32)
    challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary |
        openssl base64 -A | tr '+/' '-_' | tr -d '=')

    local consent="$work/consent.html" headers="$work/consent.headers"
    code=$(curl -sS -o "$consent" -D "$headers" -w '%{http_code}' \
        -b "$jar" -c "$jar" -G "$BASE/oauth/authorize" \
        --data-urlencode 'response_type=code' \
        --data-urlencode "client_id=$client_id" \
        --data-urlencode "redirect_uri=$redirect" \
        --data-urlencode "scope=$scopes" \
        --data-urlencode "state=$state" \
        --data-urlencode "code_challenge=$challenge" \
        --data-urlencode 'code_challenge_method=S256')
    [ "$code" = "200" ] || {
        rm -rf "$work"
        die "authorize page returned HTTP $code"
    }
    csrf=$(csrf_from "$consent")
    code=$(curl -sS -o /dev/null -D "$headers" -w '%{http_code}' \
        -b "$jar" -c "$jar" -X POST "$BASE/oauth/authorize" \
        --data-urlencode "client_id=$client_id" \
        --data-urlencode "redirect_uri=$redirect" \
        --data-urlencode "scopes=$scopes" \
        --data-urlencode "state=$state" \
        --data-urlencode "code_challenge=$challenge" \
        --data-urlencode "csrf_token=$csrf" \
        --data-urlencode 'decision=allow')
    [ "$code" = "303" ] || {
        rm -rf "$work"
        die "consent returned HTTP $code"
    }
    local location auth_code
    location=$(sed -n 's/^[Ll]ocation: //p' "$headers" | tr -d '\r' | tail -n 1)
    auth_code=$(printf '%s' "$location" |
        sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')
    [ -n "$auth_code" ] || {
        rm -rf "$work"
        die "no authorization code in $location"
    }
    local token id
    token=$(curl -fsS -X POST "$BASE/oauth/token" \
        --data-urlencode 'grant_type=authorization_code' \
        --data-urlencode "code=$auth_code" \
        --data-urlencode "client_id=$client_id" \
        --data-urlencode "client_secret=$client_secret" \
        --data-urlencode "redirect_uri=$redirect" \
        --data-urlencode "code_verifier=$verifier" | jq -r .access_token)
    id=$(curl -fsS -H "Authorization: Bearer $token" \
        "$BASE/api/v1/accounts/verify_credentials" | jq -r .id)
    rm -rf "$work"
    [ -n "$token" ] && [ "$token" != null ] && [ -n "$id" ] ||
        die 'token exchange produced no usable token'
    jq -nc --arg token "$token" --arg id "$id" \
        '{token: $token, id: $id}' >"$cached"
    printf '%s %s\n' "$token" "$id"
}

# ---- seed -----------------------------------------------------------------

# A real PNG served by the media worker itself, copied into the volume under
# the digest the seeded media rows name. `serve_variant` falls back to the
# original when no variant exists, so this is the byte path the scenario
# measures without needing a resize run.
ensure_media_fixture() {
    local fixture="$OUT_DIR/fixture.png"
    if [ ! -s "$fixture" ]; then
        curl -fsS "$BASE/media/default-avatar.png" -o "$fixture" ||
            die 'could not fetch the default avatar as a media fixture'
    fi
    local digest size
    digest=$(sha256sum "$fixture" | cut -d' ' -f1)
    size=$(stat -c %s "$fixture")
    docker exec -i nodus-load-media-worker sh -c \
        "cat > /var/lib/nodus/media/$digest" <"$fixture"
    printf '%s %s\n' "$digest" "$size"
}

cmd_seed() {
    cmd_up
    read -r token auth_id <<<"$(ensure_auth)"
    read -r digest size <<<"$(ensure_media_fixture)"

    python3 "$LOAD_DIR/seed.py" \
        --accounts "${NODUS_LOAD_ACCOUNTS:-10000}" \
        --statuses "${NODUS_LOAD_STATUSES:-200000}" \
        --media "${NODUS_LOAD_MEDIA:-20000}" \
        --media-digest "$digest" \
        --media-size "$size" \
        --auth-id "$auth_id" \
        --out "$OUT_DIR/seed"

    valkey_cli <"$OUT_DIR/seed/valkey.txt" >/dev/null
    printf 'warmed home timeline for %s\n' "$auth_id"

    verify_seed
}

# The proof that the rows this seeder wrote are the rows the API serves. The
# responses are kept under out/verify/ so the report can quote them.
verify_seed() {
    local profile_id status_id media_id
    profile_id=$(jq -r .profile_account_id "$OUT_DIR/seed/manifest.json")
    status_id=$(jq -r .profile_status_id "$OUT_DIR/seed/manifest.json")
    media_id=$(jq -r .media_id "$OUT_DIR/seed/manifest.json")
    mkdir -p "$OUT_DIR/verify"

    local timeline profile permalink media
    timeline=$(curl -fsS "$BASE/api/v1/timelines/public?limit=20")
    profile=$(curl -fsS "$BASE/api/v1/accounts/$profile_id")
    permalink=$(curl -fsS "$BASE/api/v1/statuses/$status_id")
    media=$(curl -fsS -o "$OUT_DIR/verify/media.png" -w '%{http_code} %{size_download}' \
        "$BASE/media/$media_id/compressed")

    printf '%s' "$timeline" >"$OUT_DIR/verify/public_timeline.json"
    printf '%s' "$profile" >"$OUT_DIR/verify/profile.json"
    printf '%s' "$permalink" >"$OUT_DIR/verify/permalink.json"

    local timeline_count
    timeline_count=$(printf '%s' "$timeline" | jq 'length')
    [ "$timeline_count" = "20" ] ||
        die "public timeline returned $timeline_count rows, not 20"
    printf '%s' "$profile" | jq -e --arg id "$profile_id" '.id == $id' >/dev/null ||
        die 'profile page did not return the seeded account'
    printf '%s' "$permalink" | jq -e --arg id "$status_id" '.id == $id' >/dev/null ||
        die 'permalink did not return the seeded status'
    printf 'verified: 20 public statuses, profile %s, permalink %s, media %s\n' \
        "$profile_id" "$status_id" "$media"
    jq '{profile_username, profile_account_id, media_id, counts, hubs,
         max_tail_followers}' "$OUT_DIR/seed/manifest.json"
}

# ---- run ------------------------------------------------------------------

sample_start() {
    local name=$1
    (
        while :; do
            printf '%s\t' "$(date +%s%3N)"
            PGPASSWORD=$(db_password) docker exec -i "$PG_CONTAINER" psql -U nodus \
                -d nodusload -tA -F ' ' -c "
                SELECT
                  (SELECT count(*) FROM pg_stat_activity
                    WHERE datname = 'nodusload'),
                  (SELECT count(*) FROM pg_stat_activity
                    WHERE datname = 'nodusload' AND state = 'active'),
                  (SELECT count(*) FROM pg_stat_activity
                    WHERE datname = 'nodusload' AND wait_event_type = 'Lock'),
                  (SELECT count(*) FROM pg_stat_activity
                    WHERE datname = 'postgres' AND backend_type = 'client backend');" \
                2>/dev/null | tr -d '\n'
            printf '\t'
            docker stats --no-stream --format \
                '{{.Name}}={{.CPUPerc}}/{{.MemUsage}}' \
                nodus-load-api nodus-load-media-worker nodus-load-caddy \
                2>/dev/null | paste -sd, -
            sleep 2
        done
    ) >>"$OUT_DIR/$name.resources.tsv" &
    SAMPLE_PID=$!
}

sample_stop() {
    if [ -n "${SAMPLE_PID:-}" ]; then
        kill "$SAMPLE_PID" 2>/dev/null || true
        wait "$SAMPLE_PID" 2>/dev/null || true
        SAMPLE_PID=
    fi
}

run_k6() {
    local name=$1 script=$2
    shift 2
    local start_ms
    start_ms=$(date +%s%3N)
    printf '\n=== %s ===\n' "$name"
    sample_start "$name"
    set +e
    docker run --rm --network host \
        --user "$(id -u):$(id -g)" \
        -v "$LOAD_DIR:/load" \
        "$K6_IMAGE" run \
        --summary-export "/load/out/$name.json" \
        -e "BASE_URL=$BASE" \
        -e "START_MS=$start_ms" \
        "$@" \
        "/load/k6/$script" 2>&1 | tee "$OUT_DIR/$name.log"
    local rc=${PIPESTATUS[0]}
    set -e
    sample_stop
    printf '{"name":"%s","script":"%s","started_ms":%s,"exit":%s,"k6_image":"%s","server_image":"%s"}\n' \
        "$name" "$script" "$start_ms" "$rc" "$K6_DIGEST" "$SERVER_IMAGE" \
        >"$OUT_DIR/$name.meta.json"
    [ "$rc" -eq 0 ] || printf 'k6 %s exited %s (report continues)\n' "$name" "$rc" >&2
}

cmd_run() {
    [ -s "$OUT_DIR/seed/manifest.json" ] || die 'run "load.sh seed" first'
    [ -s "$OUT_DIR/auth.json" ] || die 'no auth token; run "load.sh seed"'
    local profile_id status_id media_id auth_token
    profile_id=$(jq -r .profile_account_id "$OUT_DIR/seed/manifest.json")
    status_id=$(jq -r .profile_status_id "$OUT_DIR/seed/manifest.json")
    media_id=$(jq -r .media_id "$OUT_DIR/seed/manifest.json")
    auth_token=$(jq -r .token "$OUT_DIR/auth.json")

    trap sample_stop EXIT

    run_k6 anonymous anonymous.js \
        -e "PROFILE_ID=$profile_id" \
        -e "STATUS_ID=$status_id" \
        -e "MEDIA_ID=$media_id"

    valkey_cli <"$OUT_DIR/seed/valkey.txt" >/dev/null
    run_k6 auth-warm authenticated.js \
        -e "PROFILE_ID=$profile_id" \
        -e "AUTH_TOKEN=$auth_token" \
        -e MODE=warm

    # Nothing in the read mix writes a status, so one flush leaves the whole
    # run cold; the sampler shows whether the API ever repopulates it.
    valkey_cli FLUSHDB >/dev/null
    run_k6 auth-cold authenticated.js \
        -e "PROFILE_ID=$profile_id" \
        -e "AUTH_TOKEN=$auth_token" \
        -e MODE=cold

    # The write mix ramps 5 -> 30 VUs, so its buckets are labelled with those
    # targets and with its own stage boundaries (15/30/30/30/15 s).
    run_k6 write write.js \
        -e "AUTH_TOKEN=$auth_token" \
        -e "STATUS_ID=$status_id" \
        -e LEVEL_NAMES=5,10,20,30,rampdown \
        -e STAGE_ENDS=15,45,75,105

    # Leave the stack warm for a rerun of the read scenarios.
    valkey_cli <"$OUT_DIR/seed/valkey.txt" >/dev/null
    printf '\nsummaries under %s; run "load.sh report"\n' "$OUT_DIR"
}

# ---- down / report --------------------------------------------------------

cmd_down() {
    load_compose down --remove-orphans
    printf 'stopped nodus-load containers; volumes load-media-data and caddy data kept\n'
}

cmd_report() {
    python3 "$LOAD_DIR/report.py" --out "$OUT_DIR"
}

case "${1:-}" in
up) cmd_up ;;
seed) cmd_seed ;;
run) cmd_run ;;
down) cmd_down ;;
report) cmd_report ;;
*)
    printf 'usage: %s up|seed|run|down|report\n' "$0" >&2
    exit 2
    ;;
esac
