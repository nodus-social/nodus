#!/usr/bin/env bash
# Runs this repository's own GitHub Actions workflow locally with nektos/act.
#
# The workflow is the source of truth: act executes .github/workflows/ci.yml,
# job for job, in the same container images GitHub would use. Runner minutes are
# expensive, so a normal check is a local `ci.sh all`; a dispatched run is for
# proving the workflow itself (see integration/docs/ci.md).
#
#   integration/scripts/ci.sh                    # same as `ci.sh all`
#   integration/scripts/ci.sh up                 # start the Docker-in-Docker daemon only
#   integration/scripts/ci.sh run                # run every job, keep dind running
#   integration/scripts/ci.sh run --job preflight
#   integration/scripts/ci.sh run --job rust-tests --job lab
#   integration/scripts/ci.sh down               # stop the dind container
#   integration/scripts/ci.sh all                # up, run every job, down (on exit)
#   integration/scripts/ci.sh preflight          # shorthand for `run --job preflight`
#   integration/scripts/ci.sh rust-tests|lab|gate
#
# Requirements: docker (the host daemon), curl, tar, and network access the
# first time (to fetch act and the runner image). `ci.sh` installs act into
# ~/.local/bin when it is absent. The lab job additionally needs the pinned
# images/build cache space; its nested `docker build`/`docker compose` run
# against the dind daemon, not the host's.
#
# Knobs (environment):
#   ACT_VERSION       act release to install, default 0.2.80
#   ACT_IMAGE         runner image for ubuntu-24.04, default catthehacker/ubuntu:act-24.04
#   ACT_DIND_IMAGE    Docker-in-Docker image, default docker:dind
#   CI_DIND_PORT      dind API port on 127.0.0.1, default 2375
#   CI_KEEP_DIND=1    leave dind running after `run`/`all` (faster next run)
#   LAB_HTTP_PORT     forwarded to the workflow (the lab job publishes this port)
#   NODUS_HTTPS_PORT  forwarded when set (the lab job publishes Caddy's 443)
#
# Logs are written to integration/.act/ (git-ignored).
set -euo pipefail

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(unset CDPATH; cd -- "$SCRIPT_DIR/../.." && pwd)
WORKFLOW="$REPO_DIR/.github/workflows/ci.yml"
LOG_DIR="$REPO_DIR/integration/.act"

ACT_VERSION=${ACT_VERSION:-0.2.98}
ACT_IMAGE=${ACT_IMAGE:-catthehacker/ubuntu:act-24.04}
ACT_DIND_IMAGE=${ACT_DIND_IMAGE:-docker:dind}
DIND_CONTAINER=${CI_DIND_CONTAINER:-nodus-act-dind}
DIND_PORT=${CI_DIND_PORT:-2375}
DIND_HOST="tcp://127.0.0.1:${DIND_PORT}"

usage() {
	sed -n '2,36p' "$SCRIPT_DIR/ci.sh" | sed 's/^# \{0,1\}//'
}

die() {
	printf 'ci.sh: %s\n' "$*" >&2
	exit 1
}

require_docker() {
	command -v docker >/dev/null || die "docker is required"
	docker info >/dev/null 2>&1 || die "the docker daemon is not reachable"
}

# act is a single static binary; keep it beside the other user tools rather than
# in /tmp (tmpfs on this host) or a root-owned prefix.
ensure_act() {
	if command -v act >/dev/null 2>&1; then
		return 0
	fi
	local target="$HOME/.local/bin"
	printf 'installing act v%s into %s ...\n' "$ACT_VERSION" "$target"
	mkdir -p "$target" "$LOG_DIR"
	local archive="$LOG_DIR/act_Linux_x86_64.tar.gz"
	curl -fsSL --retry 2 \
		"https://github.com/nektos/act/releases/download/v${ACT_VERSION}/act_Linux_x86_64.tar.gz" \
		-o "$archive" || die "could not download act v${ACT_VERSION}"
	tar -xzf "$archive" -C "$target" act || die "could not unpack $archive"
	chmod +x "$target/act"
	export PATH="$target:$PATH"
	command -v act >/dev/null || die "act was installed to $target but is not on PATH"
}

dind_running() {
	docker ps --format '{{.Names}}' | grep -qx "$DIND_CONTAINER"
}

wait_for_dind() {
	local i=0
	while [ "$i" -lt 60 ]; do
		if docker -H "$DIND_HOST" info >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	docker logs --tail 20 "$DIND_CONTAINER" >&2 || true
	die "dind did not become reachable at $DIND_HOST"
}

cmd_up() {
	require_docker
	mkdir -p "$LOG_DIR"
	if dind_running; then
		wait_for_dind
		printf 'dind already running: %s\n' "$DIND_HOST"
		return 0
	fi
	docker rm -f "$DIND_CONTAINER" >/dev/null 2>&1 || true
	# TLS is off on purpose: the image then serves the API on 0.0.0.0:2375, which
	# --network host makes reachable as 127.0.0.1:2375 for the duration of a local
	# run. Do not add --host here; dockerd-entrypoint.sh already passes one.
	docker run -d --name "$DIND_CONTAINER" \
		--privileged --network host \
		-e DOCKER_TLS_CERTDIR= \
		-v "${DIND_CONTAINER}-data:/var/lib/docker" \
		"$ACT_DIND_IMAGE" >/dev/null
	wait_for_dind
	printf 'dind listening on %s\n' "$DIND_HOST"
}

cmd_down() {
	if dind_running; then
		docker rm -f "$DIND_CONTAINER" >/dev/null
		printf 'stopped %s\n' "$DIND_CONTAINER"
	fi
}

# Maps ci.sh's --job to act's -j and keeps every other argument for act.
run_act() {
	ensure_act
	cmd_up

	local jobs=()
	local passthrough=()
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--job)
			[ "$#" -ge 2 ] || die "--job needs a value"
			jobs+=(-j "$2")
			shift 2
			;;
		--job=*)
			jobs+=(-j "${1#*=}")
			shift
			;;
		*)
			passthrough+=("$1")
			shift
			;;
		esac
	done

	local args=(
		workflow_dispatch
		-W "$WORKFLOW"
		-P "ubuntu-24.04=${ACT_IMAGE}"
		--container-architecture linux/amd64
		--env "DOCKER_HOST=${DIND_HOST}"
	)
	# The lab job's nested docker and published ports need the host network
	# (dind is `--network host` too). The rust-tests service container is reached
	# as `postgres:5432`, which only resolves on act's own bridge network, so do
	# not force host networking for a job that does not need it.
	local host_network=0
	if [ "${#jobs[@]}" -eq 0 ]; then
		host_network=1
	else
		for candidate in "${jobs[@]}"; do
			[ "$candidate" = lab ] && host_network=1
		done
	fi
	if [ "$host_network" -eq 1 ]; then
		args+=(--network host)
	fi
	if [ -n "${LAB_HTTP_PORT:-}" ]; then
		args+=(--env "LAB_HTTP_PORT=${LAB_HTTP_PORT}")
	fi
	if [ -n "${NODUS_HTTPS_PORT:-}" ]; then
		args+=(--env "NODUS_HTTPS_PORT=${NODUS_HTTPS_PORT}")
	fi
	args+=("${jobs[@]}" "${passthrough[@]}")

	local label=all
	if [ "${#jobs[@]}" -gt 0 ]; then
		label=${jobs[1]}
	fi
	mkdir -p "$LOG_DIR"
	local log="$LOG_DIR/run-${label}.log"
	printf 'act %s (log: %s)\n' "${args[*]}" "$log"
	set +e
	(
		cd "$REPO_DIR"
		act "${args[@]}" 2>&1 | tee "$log"
		exit "${PIPESTATUS[0]}"
	)
	local status=$?
	set -e
	[ "$status" -eq 0 ] || printf 'act exited %s; see %s\n' "$status" "$log" >&2
	return "$status"
}

finish() {
	if [ "${CI_KEEP_DIND:-0}" != 1 ]; then
		cmd_down || true
	fi
}

command=${1:-all}
case "$command" in
up) shift; cmd_up "$@" ;;
down) shift; cmd_down "$@" ;;
run) shift; run_act "$@" ;;
all)
	shift
	trap finish EXIT
	run_act "$@"
	;;
preflight | rust-tests | lab | gate)
	trap finish EXIT
	run_act --job "$command" "${@:2}"
	;;
-h | --help | help) usage ;;
*)
	printf 'unknown command: %s\n\n' "$command" >&2
	usage >&2
	exit 2
	;;
esac
