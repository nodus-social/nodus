#!/bin/sh
# Builds (unless --skip-build), starts and waits for the single-origin stack.
#
#   integration/scripts/up.sh
#   integration/scripts/up.sh --skip-build   # reuse the images already built
set -eu

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

skip_build=0
for arg in "$@"; do
	case "$arg" in
	--skip-build) skip_build=1 ;;
	*)
		printf 'usage: %s [--skip-build]\n' "$0" >&2
		exit 2
		;;
	esac
done

ensure_env
port=$(http_port)

if [ "$skip_build" -eq 0 ]; then
	"$SCRIPT_DIR/build.sh"
fi

printf 'starting the nodus-lab stack ...\n'
compose up -d --wait --wait-timeout 300

printf 'waiting for the API through Caddy ...\n'
wait_for_url "http://localhost:${port}/healthz" 120
wait_for_url "http://localhost:${port}/api/v1/healthz" 120
wait_for_url "http://localhost:${port}/api/v1/instance" 120

printf 'waiting for Postgres ...\n'
compose exec -T postgres pg_isready -U nodus -d nodus >/dev/null

printf '\nnodus-lab is up\n'
printf '  URL              http://localhost:%s\n' "$port"
printf '  in-network       http://nodus:8080\n'
printf '  admin login      %s / %s\n' \
	"$(env_value NODUS_BOOTSTRAP_EMAIL)" "$(env_value NODUS_BOOTSTRAP_PASSWORD)"
printf '  seed users       integration/scripts/seed.sh (ada, grace)\n'
printf '  logs             docker compose -p %s logs -f\n' "$PROJECT"
printf '  stop             integration/scripts/down.sh\n'
printf '  reset (volumes)  integration/scripts/reset.sh\n'
