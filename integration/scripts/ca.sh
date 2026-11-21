#!/bin/sh
# Exports the lab CA that Caddy signs with to the one generated path every TLS
# client mounts (state/ca/nodus-lab-ca.crt). Caddy mints its internal authority
# when it first starts on a nodus-data volume, so reset.sh — which drops that
# volume — makes the old root meaningless: the new authority has the same
# subject and a different key, and any client still trusting the old file fails
# with `BadSignature`. This script is the only producer of the exported file;
# up.sh calls it between the caddy start and the services that read the CA at
# boot, and peers.sh up refuses to start without it.
#
#   integration/scripts/ca.sh export    (re)write state/ca/nodus-lab-ca.crt
#   integration/scripts/ca.sh require   fail unless that file is the running
#                                       caddy's root
set -eu

SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/common.sh"

CA_DIR="$INTEGRATION_DIR/state/ca"
CA_FILE="$CA_DIR/nodus-lab-ca.crt"
# The Caddyfile's `storage file_system /var/lib/nodus/caddy`; the pki app keeps
# the local authority under it.
CADDY_ROOT=/var/lib/nodus/caddy/pki/authorities/local/root.crt

die() {
    printf 'ca: %s\n' "$*" >&2
    exit 1
}

caddy_running() {
    [ "$(docker inspect --format '{{.State.Running}}' nodus-lab-caddy 2>/dev/null)" = true ]
}

# The running caddy's root on stdout. Fails while the authority is not written
# yet, which is the first second of a fresh volume.
running_root() {
    compose exec -T caddy cat "$CADDY_ROOT" 2>/dev/null
}

# Docker creates a directory in place of a bind-mounted file that does not
# exist, so a failed earlier start can leave one where the export goes.
clear_stale_dir() {
    [ -d "$CA_FILE" ] || return 0
    rmdir "$CA_FILE" 2>/dev/null ||
        die "$CA_FILE is a directory with content; remove it, then re-run"
}

cmd_export() {
    ensure_env
    ensure_dir
    caddy_running ||
        die "caddy is not running, so it has no authority to export: run integration/scripts/up.sh"
    clear_stale_dir
    tmp=$(mktemp)
    # The authority appears once caddy has loaded a site that needs it; poll
    # rather than assume the file is there the instant the container is up.
    i=0
    while [ "$i" -lt 60 ]; do
        if running_root >"$tmp" 2>/dev/null && openssl x509 -in "$tmp" -noout 2>/dev/null; then
            chmod 644 "$tmp"
            mv "$tmp" "$CA_FILE"
            printf 'lab CA exported to %s\n' "$CA_FILE"
            openssl x509 -in "$CA_FILE" -noout -subject -fingerprint -sha256 |
                sed 's/^/  /'
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    rm -f "$tmp"
    die "caddy did not publish $CADDY_ROOT within 60s: check docker logs nodus-lab-caddy"
}

# Cheap guard for anything that starts a client of the lab CA. Fails when the
# file is missing, or when it no longer matches the root of the caddy beside it
# (the state left behind by a reset that was not followed by up.sh).
cmd_require() {
    ensure_env
    [ -s "$CA_FILE" ] ||
        die "the lab CA is missing: run integration/scripts/up.sh (it exports it), or integration/scripts/ca.sh export then restart the peers"
    caddy_running ||
        die "caddy is not running, so the lab CA cannot be confirmed: run integration/scripts/up.sh"
    tmp=$(mktemp)
    if ! running_root >"$tmp" 2>/dev/null; then
        rm -f "$tmp"
        die "caddy has not written its root yet: re-run integration/scripts/ca.sh export"
    fi
    if ! cmp -s "$tmp" "$CA_FILE"; then
        rm -f "$tmp"
        die "$CA_FILE is not the root the running caddy signs with (a reset replaced the authority): run integration/scripts/ca.sh export, then restart the peers"
    fi
    rm -f "$tmp"
}

ensure_dir() {
    mkdir -p "$CA_DIR"
}

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

case ${1-} in
export) cmd_export ;;
require) cmd_require ;;
*) usage; exit 2 ;;
esac
