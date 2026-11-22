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

# The images are stamped with the commits they were handed, so a stack that is running
# yesterday's build says so instead of passing for one built from this tree (see
# check-pins.sh). build.sh's LAB_DOCKER_BUILD_ARGS is the only channel it offers for an
# extra --build-arg, so the label travels that way; a worktree build is labelled
# `worktree` because no pin describes it.
if [ "${LAB_BUILD_FROM_WORKTREE:-0}" = 1 ]; then
	pins_label=worktree
else
	pins_label=$(recorded_pins_label)
fi
export LAB_DOCKER_BUILD_ARGS="${LAB_DOCKER_BUILD_ARGS:-} --build-arg NODUS_PINS=$pins_label"

if [ "$skip_build" -eq 0 ]; then
	"$SCRIPT_DIR/build.sh"
fi

# Caddy first, alone: it mints the lab's internal CA on a fresh nodus-data
# volume, and every service that fetches from a peer reads that root at start
# (SSL_CERT_FILE names a bundle its entrypoint builds). The dependency cannot be
# a `depends_on` on the API, because caddy already waits for the API's
# healthcheck — that pair would be a cycle. Caddy tolerates absent upstreams
# (reverse_proxy dials lazily), so starting it with --no-deps and exporting the
# root before the rest of the stack is the ordering that does not deadlock.
printf 'starting caddy to mint the lab CA ...\n'
compose up -d --no-deps caddy
"$SCRIPT_DIR/ca.sh" export

printf 'starting the nodus-lab stack ...\n'
compose up -d --wait --wait-timeout 300

printf 'waiting for the API through Caddy ...\n'
wait_for_url "http://localhost:${port}/healthz" 120
wait_for_url "http://localhost:${port}/api/v1/healthz" 120
wait_for_url "http://localhost:${port}/api/v1/instance" 120

# The shell reads its capability list from this same-origin path, and the route table has
# two processes that answer it. Assert the API's answer won, and that the API is the code
# in this tree rather than an image older than it; see common.sh for why.
for image in $(lab_images); do
	print_image_pin "$image"
done
assert_meta_contract "http://localhost:${port}/api/v1/meta"

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
