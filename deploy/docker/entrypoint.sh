#!/usr/bin/env bash
# Start a complete single-container instance: Postgres, the server, the shell and Caddy.
set -euo pipefail

export NODUS_DOMAIN="${NODUS_DOMAIN:-localhost}"
# Nothing inside the container listens on a port: the ingress and the two processes meet on
# sockets in one shared directory, which is also where the API asks itself for telemetry.
APP_RUN="/var/run/app"
export NODUS_LISTEN="${NODUS_LISTEN:-unix:${APP_RUN}/shell.sock}"
# Every service answers about itself on its own socket, and the API is the one that asks:
# the list is how it knows what should be there, so a missing worker shows up as dead
# instead of absent.
export NODUS_TELEMETRY="${NODUS_TELEMETRY:-feed=unix:${APP_RUN}/feed-telemetry.sock,scan=unix:${APP_RUN}/scan.sock,prune=unix:${APP_RUN}/prune.sock,calc=unix:${APP_RUN}/calc.sock}"
export NODUS_BASE_URL="${NODUS_BASE_URL:-http://localhost:8080}"
DB_PASSWORD_FILE="/var/lib/nodus/db-password"

# Debian keeps the cluster binaries out of PATH: /usr/lib/postgresql/<major>/bin.
for candidate in /usr/lib/postgresql/*/bin; do
    if [[ -x "${candidate}/initdb" ]]; then
        export PATH="${candidate}:${PATH}"
        break
    fi
done

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

# The ingress writes temporary bodies, and the services create their sockets here; a killed
# process leaves its socket behind, so the directory starts empty.
install -d -m 0775 -o nodus -g nodus "${APP_RUN}"
install -d -m 0755 /var/lib/nodus/caddy
rm -f "${APP_RUN}"/*.sock

log "starting postgres"
su postgres -c "pg_ctl -D ${PGDATA} -l /var/lib/postgresql/postgres.log -o '-c listen_addresses=127.0.0.1' start" >/dev/null
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

ROLES="${NODUS_ROLES:-api,feed,scan,prune,calc}"
TOKEN_KEY_FILE="/var/lib/nodus/token-enc-key"

# The calculator seals and opens sync tokens. A key generated here is a key that survives a
# restart because it is kept beside the volume, and a deployment that already has one in its
# environment is never overridden.
if [[ ",${ROLES}," == *,calc,* && -z "${TOKEN_ENC_KEY:-}" ]]; then
	if [[ -f "${TOKEN_KEY_FILE}" ]]; then
		export TOKEN_ENC_KEY="$(cat "${TOKEN_KEY_FILE}")"
	else
		export TOKEN_ENC_KEY="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
		install -m 0600 -o nodus -g nodus /dev/null "${TOKEN_KEY_FILE}"
		printf '%s' "${TOKEN_ENC_KEY}" >"${TOKEN_KEY_FILE}"
		log "generated a token sealing key in ${TOKEN_KEY_FILE}"
	fi
fi

pids=()
cleanup() {
	log "stopping"
	for pid in "${pids[@]}"; do kill -TERM "${pid}" 2>/dev/null || true; done
	wait || true
	su postgres -c "pg_ctl -D ${PGDATA} stop -m fast" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# Each service is its own process and its own unit in a spread-out deployment; here they
# share one container, one database and one socket directory, and talk over gRPC.
spawn() {
	local name="$1"
	local binary="$2"
	local spec="$3"
	log "starting ${name}"
	# shellcheck disable=SC2086
	su nodus -s /bin/bash -c "RUST_LOG=${RUST_LOG:-info} ${spec} exec /usr/local/bin/${binary}" &
	pids+=("$!")
}

if [[ ",${ROLES}," == *,api,* ]]; then
	spawn api nodus-api "NODUS_NODE_NAME=api NODUS_BIND=unix:${APP_RUN}/api.sock NODUS_TELEMETRY_SOCKET=unix:${APP_RUN}/api-telemetry.sock NODUS_DATABASE_URL='${NODUS_DATABASE_URL}'"
fi
if [[ ",${ROLES}," == *,feed,* ]]; then
	spawn feed nodus-feed "NODUS_NODE_NAME=feed NODUS_BIND=unix:${APP_RUN}/feed.sock NODUS_TELEMETRY_SOCKET=unix:${APP_RUN}/feed-telemetry.sock NODUS_DATABASE_URL='${NODUS_DATABASE_URL}'"
fi
if [[ ",${ROLES}," == *,scan,* ]]; then
	spawn scan nodus-scan "NODUS_NODE_NAME=scan NODUS_TELEMETRY_SOCKET=unix:${APP_RUN}/scan.sock NODUS_DATABASE_URL='${NODUS_DATABASE_URL}'"
fi
if [[ ",${ROLES}," == *,prune,* ]]; then
	spawn prune nodus-prune "NODUS_NODE_NAME=prune NODUS_TELEMETRY_SOCKET=unix:${APP_RUN}/prune.sock NODUS_DATABASE_URL='${NODUS_DATABASE_URL}' NODUS_MEDIA_DIR=/var/lib/nodus/media NODUS_MEDIA_VARIANTS_DIR=/var/lib/nodus/media/variants"
fi
if [[ ",${ROLES}," == *,calc,* ]]; then
	spawn calc nodus-calc "NODUS_NODE_NAME=calc NODUS_TELEMETRY_SOCKET=unix:${APP_RUN}/calc.sock NODUS_DATABASE_URL='${NODUS_DATABASE_URL}' TOKEN_ENC_KEY='${TOKEN_ENC_KEY}'"
fi

# A container that names roles without `api` is a worker: it has no pages to serve and
# nothing to publish, so the shell and the ingress stay out of its process table.
if [[ ",${ROLES}," == *,api,* ]]; then
	log "starting the shell"
	su nodus -s /bin/bash -c "exec /usr/local/bin/nodus-web-server" &
	pids+=("$!")

	# A typo in the routing should be a log line and a stopped container, not a listener that
	# answers the wrong process.
	if ! caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null; then
		log "the ingress configuration is not valid"
		caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile || true
		exit 1
	fi
	log "starting caddy on 8080"
	caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
	pids+=("$!")
	log "started as ${ROLES}"
else
	log "no ingress in this container: roles=${ROLES}"
fi

# tini forwards the stop signal; the first child to exit ends the container so a crash is
# visible in the exit code instead of a half-running instance.
wait -n
