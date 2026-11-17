#!/usr/bin/env bash
# Start a complete single-container instance: Postgres, the server, the shell and nginx.
set -euo pipefail

export NODUS_DOMAIN="${NODUS_DOMAIN:-localhost}"
export NODUS_BASE_URL="${NODUS_BASE_URL:-http://localhost:8080}"
DB_PASSWORD_FILE="/var/lib/nodus/db-password"

log() { printf '[aio] %s\n' "$*"; }

# The database password is generated once and kept beside the volume, so a restart keeps
# working against the cluster it already initialised.
if [[ -z "${NODUS_DB_PASSWORD:-}" ]]; then
    if [[ -f "${DB_PASSWORD_FILE}" ]]; then
        NODUS_DB_PASSWORD="$(cat "${DB_PASSWORD_FILE}")"
    else
        NODUS_DB_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
        install -m 0600 -o nodus -g nodus /dev/null "${DB_PASSWORD_FILE}"
        printf '%s' "${NODUS_DB_PASSWORD}" >"${DB_PASSWORD_FILE}"
    fi
fi

if [[ ! -s "${PGDATA}/PG_VERSION" ]]; then
    log "initialising the cluster in ${PGDATA}"
    install -d -o postgres -g postgres "${PGDATA}"
    su postgres -c "initdb -D ${PGDATA} --auth-local=trust --auth-host=scram-sha-256" >/dev/null
fi

log "starting postgres"
su postgres -c "pg_ctl -D ${PGDATA} -l /var/log/postgres.log -o '-c listen_addresses=127.0.0.1' start" >/dev/null
until su postgres -c "pg_isready -h 127.0.0.1" >/dev/null 2>&1; do sleep 0.2; done

if ! su postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='nodus'\"" | grep -qx 1; then
    log "creating the nodus role and database"
    su postgres -c "psql -q -c \"CREATE ROLE nodus LOGIN PASSWORD '${NODUS_DB_PASSWORD}'\"" >/dev/null
    su postgres -c "psql -q -c 'CREATE DATABASE nodus OWNER nodus'" >/dev/null
    # The migrations create citext and pg_trgm; both are trusted extensions, so the database
    # owner may install them without superuser.
    su postgres -c "psql -q -d nodus -c 'CREATE EXTENSION IF NOT EXISTS citext'" >/dev/null
    su postgres -c "psql -q -d nodus -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm'" >/dev/null
fi
su postgres -c "psql -q -c \"ALTER ROLE nodus PASSWORD '${NODUS_DB_PASSWORD}'\"" >/dev/null

export NODUS_DATABASE_URL="${NODUS_DATABASE_URL/postgres:\/\/nodus@/postgres:\/\/nodus:${NODUS_DB_PASSWORD}@}"

pids=()
cleanup() {
    log "stopping"
    for pid in "${pids[@]}"; do kill -TERM "${pid}" 2>/dev/null || true; done
    wait || true
    su postgres -c "pg_ctl -D ${PGDATA} stop -m fast" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

log "starting the backend"
su nodus -s /bin/bash -c "RUST_LOG=${RUST_LOG:-info} /usr/local/bin/nodus-backend --roles=api,scan,prune" &
pids+=("$!")

log "starting the shell"
su nodus -s /bin/bash -c "/usr/local/bin/nodus-web-server" &
pids+=("$!")

log "starting nginx on 8080"
nginx -g 'daemon off;' &
pids+=("$!")

# tini forwards the stop signal; the first child to exit ends the container so a crash is
# visible in the exit code instead of a half-running instance.
wait -n
