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
#
# The lab job's host ports are the workflow's own `env:` (LAB_HTTP_PORT,
# LAB_HTTPS_PORT), not knobs here: ci.sh reads them out of ci.yml so its
# preflight cannot drift from what the job publishes. Change them there.
#
# Logs are written to integration/.act/ (git-ignored).
set -euo pipefail

SCRIPT_DIR=$(
    unset CDPATH
    cd -- "$(dirname -- "$0")" && pwd
)
REPO_DIR=$(
    unset CDPATH
    cd -- "$SCRIPT_DIR/../.." && pwd
)
WORKFLOW="$REPO_DIR/.github/workflows/ci.yml"
LOG_DIR="$REPO_DIR/integration/.act"

ACT_VERSION=${ACT_VERSION:-0.2.98}
ACT_IMAGE=${ACT_IMAGE:-catthehacker/ubuntu:act-24.04}
ACT_DIND_IMAGE=${ACT_DIND_IMAGE:-docker:dind}
DIND_CONTAINER=${CI_DIND_CONTAINER:-nodus-act-dind}
DIND_PORT=${CI_DIND_PORT:-2375}
DIND_HOST="tcp://127.0.0.1:${DIND_PORT}"

# The lab job publishes Caddy on these host ports (workflow `env:`), and dind
# runs with `--network host`, so anything else listening there makes compose
# fail deep inside the daemon:
#   failed to set up container networking: … failed to bind host port
#   0.0.0.0:18443/tcp: address already in use
# Read the pair from the workflow rather than repeating it here.
workflow_port() {
    sed -n "s/^  $1: '\([0-9][0-9]*\)'.*/\1/p" "$WORKFLOW" | head -n 1
}
LAB_HTTP_PORT=$(workflow_port LAB_HTTP_PORT)
LAB_HTTPS_PORT=$(workflow_port LAB_HTTPS_PORT)

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

# A dind container started before the workspace mount was added would quietly
# keep failing every compose `up`, so `cmd_up` replaces it rather than trusting
# the name.
dind_has_workspace() {
    docker inspect --format '{{range .Mounts}}{{println .Source}}{{end}}' \
        "$DIND_CONTAINER" 2>/dev/null | grep -qx "$REPO_DIR"
}

cmd_up() {
    require_docker
    mkdir -p "$LOG_DIR"
    if dind_running && dind_has_workspace; then
        wait_for_dind
        printf 'dind already running: %s\n' "$DIND_HOST"
        return 0
    fi
    if dind_running; then
        printf 'recreating %s: %s is not mounted in the daemon\n' \
            "$DIND_CONTAINER" "$REPO_DIR" >&2
    fi
    docker rm -f "$DIND_CONTAINER" >/dev/null 2>&1 || true
    # TLS is off on purpose: the image then serves the API on 0.0.0.0:2375, which
    # --network host makes reachable as 127.0.0.1:2375 for the duration of a local
    # run. Do not add --host here; dockerd-entrypoint.sh already passes one.
    # The compose client runs inside the act job container, where `--bind` puts
    # the checkout at $REPO_DIR; the daemon is dind, whose filesystem has no
    # /var/home/lux/... unless it is given it. Without this mount, the first
    # compose service with a relative bind source died in runc with
    #   error mounting "/var/home/lux/Projects/MastodonReccom/integration/Caddyfile"
    #   to rootfs at "/etc/caddy/Caddyfile": not a directory
    # because the daemon resolved a path it could not see. So mount the
    # repository at its own absolute path, writable: compose bind sources
    # (integration/state/ca, integration/initdb, integration/Caddyfile) are only
    # read by the containers, but e2e.sh runs the Playwright image with
    # `-v "$REPO_DIR:/work"` against this daemon and the suite writes
    # test-results/ and playwright-report/ back into the tree.
    docker run -d --name "$DIND_CONTAINER" \
        --privileged --network host \
        -e DOCKER_TLS_CERTDIR= \
        -v "${DIND_CONTAINER}-data:/var/lib/docker" \
        -v "${REPO_DIR}:${REPO_DIR}" \
        "$ACT_DIND_IMAGE" >/dev/null
    wait_for_dind
    printf 'dind listening on %s\n' "$DIND_HOST"
}

cmd_down() {
    if dind_running; then
        # No -v: the named volume is the image cache, and re-pulling Postgres,
        # the Playwright image and the lab base images is the slow part of a
        # cold `lab` run.
        docker rm -f "$DIND_CONTAINER" >/dev/null
        printf 'stopped %s (volume %s-data kept)\n' "$DIND_CONTAINER" "$DIND_CONTAINER"
    fi
}

# Paths the job container writes as root through `--bind`, plus the e2e output
# directories written through the dind daemon's copy of the same path. A
# host-side `cargo test` after an act run already failed with Permission denied
# once in this project, so every run hands them back to the invoking user.
RECLAIM_PATHS=(
    nodus-backend/target
    web/target
    web/dist
    integration/state
    integration/e2e/test-results
    integration/e2e/playwright-report
    web/e2e/test-results
    web/e2e/playwright-report
)

# One container per path, the pattern this repository already uses to fix
# ownership from inside a container: the host user need not be able to chown
# root's files itself.
reclaim_workspace() {
    local reclaimed=()
    local rel path
    for rel in "${RECLAIM_PATHS[@]}"; do
        path="$REPO_DIR/$rel"
        [ -e "$path" ] || continue
        docker run --rm -v "$path:/t" alpine:latest \
            chown -R "$(id -u):$(id -g)" /t
        reclaimed+=("$rel")
    done
    if [ "${#reclaimed[@]}" -gt 0 ]; then
        printf 'reclaimed root-owned writes as %s:%s: %s\n' \
            "$(id -u)" "$(id -g)" "${reclaimed[*]}"
    fi
}

# Ports the lab job needs, checked before act starts. A developer lab
# (`integration/scripts/up.sh`) holds 18080/18443 on this host, which is why
# the workflow uses a pair of its own; if something else sits on the CI pair,
# say which port and what usually owns it instead of letting dind surface it.
require_free_lab_ports() {
    local port holders
    command -v ss >/dev/null || {
        printf 'ci.sh: ss not found; skipping the lab port preflight\n' >&2
        return 0
    }
    for port in "$LAB_HTTP_PORT" "$LAB_HTTPS_PORT"; do
        [ -n "$port" ] || continue
        holders=$(ss -ltnH "sport = :${port}" 2>/dev/null | awk '{print $4}' |
            paste -sd' ' -)
        [ -n "$holders" ] || continue
        die "port ${port} is already in use (${holders}); the lab job publishes it and dind shares the host network, so compose cannot bind it. Stop what holds it (a developer lab: integration/scripts/down.sh), or move the CI pair in the workflow env."
    done
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
        # Without this, act copies the workspace into the job container with
        # `docker cp`, and the copy included nodus-backend/target (128 GB) and
        # web/target (136 GB): the first rust-tests attempt never got as far as
        # its first step. A bind also means the container's cargo writes the
        # same target/ a local `cargo test` uses, so the compile is shared.
        --bind
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
        require_free_lab_ports
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
    reclaim_workspace || printf 'ci.sh: reclaim failed; check ownership of %s\n' \
        "${RECLAIM_PATHS[*]}" >&2
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
up)
    shift
    cmd_up "$@"
    ;;
down)
    shift
    cmd_down "$@"
    ;;
run)
    shift
    run_act "$@"
    ;;
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
