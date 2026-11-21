#!/bin/sh
# Stops the lab's containers and removes its network. Named volumes, and with
# them the seeded database, survive; reset.sh is the destructive one.
set -eu

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

ensure_env
compose down --remove-orphans

# The peers (compose.peers.yml) are orphans of the core file: `compose down`
# stops and removes their containers, but not the named volumes they own. Drop
# those too, otherwise Mastodon keeps a schema that no longer matches a rebuilt
# peer image. Core volumes are untouched.
for volume in nodus-lab-mastodon-db nodus-lab-mastodon-system \
    nodus-lab-misskey-db nodus-lab-misskey-files; do
    docker volume rm "$volume" >/dev/null 2>&1 || true
done
printf 'nodus-lab stopped; volumes kept (integration/scripts/reset.sh drops them)\n'
