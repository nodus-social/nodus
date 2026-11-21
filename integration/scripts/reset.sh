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

# The peers (compose.peers.yml) are orphans of the core file: `compose down`
# stops and removes their containers, but not the named volumes they own. Drop
# those too, otherwise Mastodon keeps a schema that no longer matches a rebuilt
# peer image. Core volumes are untouched.
for volume in nodus-lab-mastodon-db nodus-lab-mastodon-system \
    nodus-lab-misskey-db nodus-lab-misskey-files; do
    docker volume rm "$volume" >/dev/null 2>&1 || true
done
printf 'nodus-lab reset: containers, network and volumes removed\n'
