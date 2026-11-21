#!/bin/sh
# Runs the Playwright suite inside the official Playwright image, pinned to the
# exact @playwright/test version in integration/e2e/package.json.
#
# The renderer is the reason this exists. Visual baselines are rasterised by the
# chromium build in that image, so a screenshot difference is a change in the
# product, not a difference between two Linux hosts' fonts. A host
# `npx playwright test` still works for the functional specs, but it is not
# authoritative for `*-visual.spec.mjs` (see integration/README.md).
#
#   integration/scripts/e2e.sh                      # the whole suite
#   integration/scripts/e2e.sh --project=desktop    # one project
#   integration/scripts/e2e.sh --grep home          # one test
#   integration/scripts/e2e.sh --update-snapshots   # rewrite every baseline
#
# Every argument is forwarded to `playwright test`; one leading `--` is
# dropped, so `e2e.sh -- --project=desktop` is the same as above.
set -eu

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

REPO_DIR=$(unset CDPATH; cd -- "$INTEGRATION_DIR/.." && pwd)
E2E_DIR="$INTEGRATION_DIR/e2e"

# The runner and the browser are one artifact: the image tag tracks the pin in
# package.json, so bumping @playwright/test and forgetting the image is not
# possible. `-noble` is the Ubuntu 24.04 variant, the one CI's runner matches.
PLAYWRIGHT_VERSION=$(sed -n \
	's/.*"@playwright\/test": *"\([0-9][^"]*\)".*/\1/p' \
	"$E2E_DIR/package.json")
if [ -z "$PLAYWRIGHT_VERSION" ]; then
	printf 'e2e.sh: no "@playwright/test" pin in %s\n' "$E2E_DIR/package.json" >&2
	exit 1
fi
PLAYWRIGHT_IMAGE="mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble"

# Dependencies live in a named volume, mounted over the checkout's
# node_modules. The host's tree is never reinstalled, and the container gets a
# node_modules built for its own node. `npm ci` runs on every invocation, so a
# stale volume cannot silently serve the wrong lockfile.
NODE_MODULES_VOLUME=nodus-lab-e2e-node-modules

command -v docker >/dev/null || {
	printf 'e2e.sh needs docker\n' >&2
	exit 1
}
docker info >/dev/null 2>&1 || {
	printf 'e2e.sh: the docker daemon is not reachable\n' >&2
	exit 1
}

# Host ports of the lab. Same knobs as up.sh: NODUS_HTTP_PORT/NODUS_HTTPS_PORT
# in integration/.env, overridable by LAB_HTTP_PORT/LAB_HTTPS_PORT, and
# LAB_BASE_URL wins outright for a lab that is not on this host.
if [ -f "$INTEGRATION_DIR/.env" ]; then
	port=$(http_port)
	https_port=$(env_value NODUS_HTTPS_PORT || true)
else
	port=8080
	https_port=
fi
port=${LAB_HTTP_PORT:-${port:-8080}}
https_port=${LAB_HTTPS_PORT:-${https_port:-18443}}
base_url=${LAB_BASE_URL:-http://127.0.0.1:${port}}

# `--network host` puts 127.0.0.1 inside the container on the host: the lab's
# Caddy port is reached exactly as a host run reaches it. A bridge network with
# the docker host gateway would make the instance `host.docker.internal`, and
# the client only defaults a bare instance to plain http when it is an IP
# loopback (web/crates/web-client/src/state/oauth/mod.rs), so sign-in would go
# to https and fail. The resolver rule in playwright.config.mjs keeps mapping
# nodus:443 to LAB_HTTPS_PORT, so absolute media URLs work unchanged.
if [ "${1-}" = "--" ]; then
	shift
fi

printf 'playwright image  %s\n' "$PLAYWRIGHT_IMAGE"
printf 'base url          %s\n' "$base_url"
printf 'nodus:443 target  127.0.0.1:%s\n' "$https_port"
printf 'args              %s\n' "$*"

docker volume create "$NODE_MODULES_VOLUME" >/dev/null

# The volume is created root-owned; the suite runs as the invoking user so the
# report and test-results land on the host with the right owner.
docker run --rm --user 0:0 \
	-v "$NODE_MODULES_VOLUME:/mnt" \
	--entrypoint sh \
	"$PLAYWRIGHT_IMAGE" -c "chown $(id -u):$(id -g) /mnt" >/dev/null

# --ipc=host is the Playwright image's documented requirement for chromium's
# shared memory. HOME and the npm cache point at /tmp so nothing is written
# outside the checkout and the two volumes.
docker run --rm --init \
	--network host \
	--ipc host \
	--user "$(id -u):$(id -g)" \
	-v "$REPO_DIR:/work" \
	-v "$NODE_MODULES_VOLUME:/work/integration/e2e/node_modules" \
	-w /work/integration/e2e \
	-e HOME=/tmp \
	-e npm_config_cache=/tmp/npm-cache \
	-e LAB_BASE_URL="$base_url" \
	-e LAB_HTTPS_PORT="$https_port" \
	"$PLAYWRIGHT_IMAGE" \
	sh -c 'npm ci --no-audit --no-fund && exec ./node_modules/.bin/playwright test "$@"' \
	e2e "$@"
