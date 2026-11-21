#!/bin/sh
# Stops the lab's containers and removes its network. Named volumes, and with
# them the seeded database, survive; reset.sh is the destructive one.
set -eu

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

ensure_env
compose down --remove-orphans
printf 'nodus-lab stopped; volumes kept (integration/scripts/reset.sh drops them)\n'
