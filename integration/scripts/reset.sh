#!/bin/sh
# Drops the lab's containers, network and named volumes: the next up.sh starts
# from an empty Postgres and Valkey. The guard in assert_own_project refuses to
# run if a container labelled nodus-lab was not created by this checkout's
# compose.yml.
set -eu

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

ensure_env
assert_own_project

compose down --volumes --remove-orphans
printf 'nodus-lab reset: containers, network and volumes removed\n'
