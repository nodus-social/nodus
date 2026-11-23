#!/usr/bin/env bash
# Deploys the six per-role backend binaries to LXC 118 and rolls them back as a set.
#
# Supersedes deploy-profiles.sh, which pushed one multi-role `nodus-server` for a
# `nodus-backend.service` that no longer exists; its old binary would bind :3001 and fight
# nodus-api. Every unit here gets its own binary, and each backup is verified before any
# live file moves.
set -Eeuo pipefail

HOST=${HOST:-root@hyper.luxuride.eu}
CT=${CT:-118}
# The published vocabulary is one array in one file, with its length in the type:
# `pub const FEATURES: [&str; 65] = [`. Reading the length from source instead of pinning a
# number here is what keeps this check honest — a release that installs an older image than
# the checkout fails, and adding a name does not require remembering to edit this script.
# The count the checkout says it publishes, or empty when the file cannot be read (the check
# below then reports the number it found without pretending to know what was wanted).
feature_count_from_source() {
    local repo source
    repo=${REPO:-$(git rev-parse --show-toplevel 2>/dev/null || true)}
    [ -n "$repo" ] || return 0
    source="$repo/nodus-backend/crates/api/src/meta.rs"
    [ -r "$source" ] || return 0
    sed -n 's/^pub const FEATURES: \[&str; \([0-9][0-9]*\)\] = \[$/\1/p' "$source" | head -n 1
}

EXPECTED_FEATURES=${EXPECTED_FEATURES:-$(feature_count_from_source)}
ROLES=(calc scan prune feed media api)
BACKUPS_READY=0

log() { printf '%s\n' "$*"; }

SCRIPT_DIR=$(
    unset CDPATH
    cd -- "$(dirname -- "$0")" && pwd
)
# shellcheck source=artifact-manifest.sh
. "$SCRIPT_DIR/artifact-manifest.sh"

usage() {
    cat <<'USAGE'
usage: release-118.sh <artifact-dir> <stamp>
       release-118.sh --rollback <stamp>

  artifact-dir  directory holding nodus-calc, nodus-scan, nodus-prune,
                nodus-feed, nodus-media and nodus-api
  stamp         suffix for the backups: /usr/local/bin/<name>.bak-<stamp>

Environment: HOST (default root@hyper.luxuride.eu), CT (default 118)
USAGE
}

# Runs a bash script on the host. CT, STAMP and an optional NAME are exported as shell
# variables, so the body can stay a quoted heredoc and never be expanded locally.
host_run() {
    {
        printf 'set -euo pipefail\n'
        printf 'CT=%q\nSTAMP=%q\nNAME=%q\n' "$CT" "$STAMP" "${1:-}"
        cat
    } | ssh "$HOST" bash -s
}

cleanup_staging() {
    host_run <<'REMOTE'
for n in nodus-calc nodus-scan nodus-prune nodus-feed nodus-media nodus-api; do
  rm -f "/root/$n.new"
done
pct exec "$CT" -- bash -c '
  for n in nodus-calc nodus-scan nodus-prune nodus-feed nodus-media nodus-api; do
    rm -f "/root/$n.new"
  done
'
REMOTE
}

# Prints the highest GLIBC_2.x symbol version an ELF binary requires.
artifact_glibc_ceiling() {
    local bin=$1 ceiling
    command -v objdump >/dev/null 2>&1 || {
        log "FAIL: objdump is required to compute the GLIBC ceiling of $bin"
        return 1
    }
    ceiling=$(objdump -T "$bin" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sed 's/^GLIBC_//' | sort -Vu | tail -1 || true)
    [ -n "$ceiling" ] || {
        log "FAIL: $bin has no versioned glibc symbols to check"
        return 1
    }
    printf '%s\n' "$ceiling"
}

target_glibc_version() {
    host_run <<'REMOTE'
pct exec "$CT" -- ldd --version | awk 'NR==1 { print $NF }'
REMOTE
}

# Refuses the deploy before any systemctl stop when an artifact needs a newer glibc
# than the container has. An earlier run installed glibc-2.38 binaries on 2.36 and had
# to roll back; this check is that lesson, enforced here rather than in the operator's head.
glibc_preflight() {
    local target role ceiling
    target=$(target_glibc_version)
    if ! printf '%s' "$target" | grep -qE '^[0-9]+\.[0-9]+$'; then
        log "FAIL: cannot read glibc version from CT $CT (got '${target:-nothing}')"
        return 1
    fi
    log "   CT $CT glibc: $target"
    for role in "${ROLES[@]}"; do
        ceiling=$(artifact_glibc_ceiling "$ART/nodus-$role") || return 1
        if [ "$(printf '%s\n%s\n' "$target" "$ceiling" | sort -V | tail -1)" != "$target" ]; then
            log "FAIL: nodus-$role needs $ceiling, CT $CT has glibc $target"
            return 1
        fi
        log "   nodus-$role needs <= $ceiling"
    done
}

# Refuses the deploy when the container cannot render what it will be asked to render.
#
# ffmpeg and ffprobe are how the API derives every image and video variant in-process
# (docs/09-deployment.md). CT 118 ran for a fortnight without them and every upload
# failed with `media processing failed: No such file or directory (os error 2)` while
# the service itself stayed healthy, so nothing else in this script noticed. The
# encoder list is checked too: a build whose default codec is VP8 is useless on an
# ffmpeg that has no libvpx.
runtime_prerequisites() {
    local found encoders
    found=$(
        host_run <<'REMOTE'
pct exec "$CT" -- bash -c '
  for tool in ffmpeg ffprobe; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing $tool"; }
  done
'
REMOTE
    )
    if [ -n "$found" ]; then
        log "FAIL: CT $CT is missing: $(printf '%s' "$found" | tr '\n' ' ')"
        log "      install it before deploying: pct exec $CT -- apt-get install -y --no-install-recommends ffmpeg"
        return 1
    fi
    encoders=$(
        host_run <<'REMOTE'
pct exec "$CT" -- bash -c '
  ffmpeg -hide_banner -encoders 2>/dev/null | grep -cE "libvpx-vp9|libvpx " || true
'
REMOTE
    )
    case $encoders in
    '' | 0)
        log "FAIL: CT $CT has no libvpx encoder, so a VP8/VP9 rendition cannot be produced"
        return 1
        ;;
    esac
    log "   CT $CT renderer: ffmpeg, ffprobe, $encoders libvpx encoder(s)"
}

# Restarts the second process of a role, when the container runs one.
#
# The second API and media instances execute the SAME paths as the first, so replacing a
# binary and restarting only the first unit leaves the twin running the previous inode:
# the deploy looks complete while half the processes still answer with old code. The
# role list deliberately stays the artifact list, because a twin has no artifact of its
# own.
restart_twins() {
    local twin code='' i
    for twin in nodus-api2 nodus-media2; do
        # host_run forwards its argument as NAME for the quoted heredoc below.
        host_run "$twin" <<'REMOTE'
pct exec "$CT" -- systemctl cat "$NAME.service" >/dev/null 2>&1 || exit 0
pct exec "$CT" -- systemctl restart "$NAME.service"
REMOTE
        if [ "$twin" = nodus-api2 ]; then
            for _ in $(seq 1 90); do
                code=$(
                    host_run "$twin" <<'REMOTE'
pct exec "$CT" -- curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:3004/healthz" || true
REMOTE
                )
                [ "$code" = 200 ] && break
                sleep 1
            done
            [ "$code" = 200 ] || {
                log "FAIL: nodus-api2 answered $code on :3004 after restart"
                return 1
            }
            log "   nodus-api2 restarted, :3004 healthz 200"
        else
            sleep 2
            host_run "$twin" <<'REMOTE'
pct exec "$CT" -- systemctl is-active "$NAME.service" | grep -qx active
REMOTE
            log "   nodus-media2 restarted"
        fi
    done
}

# The feed and calc roles seal stored instance tokens with `TOKEN_ENC_KEY`. A host without
# a usable key serves every `/api/v1/sync/*` call as 503 `sync_disabled` while
# `/api/v1/meta` still advertises `sync_token`, and every health check stays green; CT 118
# ran that way for days. Own the variable here: create it once when it is absent, never
# overwrite an existing one, and refuse a value that is not a 32-byte base64 key. Rotating
# it silently would orphan every token already sealed with it.
token_key_preflight() {
    local status
    status=$(
        host_run <<'REMOTE'
pct exec "$CT" -- bash -c '
  set -euo pipefail
  file=/etc/nodus-backend.env
  [ -f "$file" ] || { echo missing-env-file; exit 0; }
  value=$(sed -n "s/^TOKEN_ENC_KEY=//p" "$file" | tail -n 1 | tr -d "[:space:]")
  if [ -z "$value" ]; then
    value=$(head -c 32 /dev/urandom | base64 | tr -d "\n")
    printf "\nTOKEN_ENC_KEY=%s\n" "$value" >>"$file"
    echo generated
    exit 0
  fi
  if ! bytes=$(printf "%s" "$value" | base64 -d 2>/dev/null | wc -c); then
    bytes=invalid
  fi
  echo "present:$(printf "%s" "$bytes" | tr -d " ")"
'
REMOTE
    )
    case $status in
    generated) log "   TOKEN_ENC_KEY: absent, generated once into /etc/nodus-backend.env" ;;
    present:32) log "   TOKEN_ENC_KEY: present, base64 of 32 bytes" ;;
    missing-env-file)
        log "FAIL: CT $CT has no /etc/nodus-backend.env, so TOKEN_ENC_KEY cannot be owned"
        return 1
        ;;
    present:*)
        log "FAIL: TOKEN_ENC_KEY is not a base64 32-byte key (decoded: ${status#present:});"
        log "      refusing to overwrite it — inspect /etc/nodus-backend.env on CT $CT"
        return 1
        ;;
    *)
        log "FAIL: could not verify TOKEN_ENC_KEY on CT $CT (got '${status:-nothing}')"
        return 1
        ;;
    esac
}

wait_active() {
    local role=$1 state
    for _ in $(seq 1 30); do
        state=$(
            host_run "$role" <<'REMOTE'
pct exec "$CT" -- systemctl is-active "nodus-$NAME.service" 2>/dev/null || true
REMOTE
        )
        [ "$state" = active ] && return 0
        sleep 1
    done
    return 1
}

journal_clean() {
    local role=$1 hits
    hits=$(
        host_run "$role" <<'REMOTE'
pct exec "$CT" -- bash -c '
  journalctl -u "nodus-$1.service" --since "-2min" --no-pager -o cat | grep -E "ERROR|panicked" || true
' _ "$NAME"
REMOTE
    )
    [ -z "$hits" ] || {
        printf '%s\n' "$hits" >&2
        return 1
    }
}

check_role() {
    local role=$1
    local unit="nodus-$role.service" code='' port='' up='' sock=''
    wait_active "$role" || {
        log "FAIL: $unit did not become active"
        return 1
    }

    case $role in
    api)
        for _ in $(seq 1 90); do
            code=$(
                host_run "$role" <<'REMOTE'
pct exec "$CT" -- curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3001/healthz || true
REMOTE
            )
            [ "$code" = 200 ] && break
            sleep 1
        done
        [ "$code" = 200 ] || {
            log "FAIL: $unit /healthz returned ${code:-nothing}, want 200"
            return 1
        }
        ;;
    feed | media)
        case $role in feed) port=3002 ;; media) port=3003 ;; esac
        for _ in $(seq 1 30); do
            up=$(
                host_run "$role" <<'REMOTE'
pct exec "$CT" -- bash -c '
  case $1 in feed) p=3002;; media) p=3003;; esac
  ss -ltn | grep -q ":$p " && echo up || true
' _ "$NAME"
REMOTE
            )
            if [ "$up" = up ]; then break; fi
            sleep 1
        done
        [ "$up" = up ] || {
            log "FAIL: $unit is not listening on :$port"
            return 1
        }
        code=$(
            host_run "$role" <<'REMOTE'
pct exec "$CT" -- bash -c '
  case $1 in feed) p=3002;; media) p=3003;; esac
  curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$p/healthz" || true
' _ "$NAME"
REMOTE
        )
        # media answers 401 once NODUS_MEDIA_CLUSTER_TOKEN is configured: the probe is
        # gated by the cluster token, so any HTTP answer proves the listener is serving
        # and the token is enforced. feed has no token and keeps answering 404.
        case $role in
        media) want='404 or 401' ;;
        *) want=404 ;;
        esac
        case "$code" in
        404) ;;
        401) [ "$role" = media ] || {
            log "FAIL: $unit /healthz returned 401, want 404"
            return 1
        } ;;
        *)
            log "FAIL: $unit /healthz returned ${code:-nothing}, want $want"
            return 1
            ;;
        esac
        ;;
    calc | scan | prune)
        for _ in $(seq 1 15); do
            sock=$(
                host_run "$role" <<'REMOTE'
pct exec "$CT" -- test -S "/var/lib/nodus/run/$NAME.sock" && echo yes || true
REMOTE
            )
            if [ "$sock" = yes ]; then break; fi
            sleep 1
        done
        [ "$sock" = yes ] || {
            log "FAIL: $unit did not create /var/lib/nodus/run/$role.sock"
            return 1
        }
        ;;
    esac

    journal_clean "$role" || {
        log "FAIL: $unit logged ERROR or panicked in the last 2 minutes"
        return 1
    }
    if [ "$role" = feed ]; then
        # `/api/v1/meta` publishes `sync_token` on this unit's behalf; a feed without the
        # sealing key still passes every health probe while the capability answers 503.
        local key=ok
        key=$(
            host_run feed <<'REMOTE'
pct exec "$CT" -- bash -c '
  pid=$(pgrep -x nodus-feed | head -n 1)
  value=$(tr "\0" "\n" < "/proc/$pid/environ" | sed -n "s/^TOKEN_ENC_KEY=//p" | head -n 1)
  [ -n "$value" ] || { echo missing; exit 0; }
  bytes=$(printf "%s" "$value" | base64 -d 2>/dev/null | wc -c | tr -d " ") || { echo invalid; exit 0; }
  [ "$bytes" = 32 ] && echo ok || echo invalid
'
REMOTE
        )
        [ "$key" = ok ] || {
            log "FAIL: nodus-feed has $key TOKEN_ENC_KEY; /api/v1/meta advertises sync_token but /api/v1/sync/* would answer 503 sync_disabled"
            return 1
        }
    fi
    log "   $unit active (${port:+:$port }${code:+healthz $code})"
}

push_artifact() {
    local name=$1 src="$ART/$1" local_sha host_sha ct_sha
    local_sha=$(sha256sum "$src" | cut -d' ' -f1)
    scp -q "$src" "$HOST:/root/$name.new"
    host_sha=$(
        host_run "$name" <<'REMOTE'
sha256sum "/root/$NAME.new" | cut -d' ' -f1
REMOTE
    )
    [ "$host_sha" = "$local_sha" ] || {
        log "FAIL: $name host staging sha $host_sha != local $local_sha"
        return 1
    }
    host_run "$name" <<'REMOTE'
pct push "$CT" "/root/$NAME.new" "/root/$NAME.new"
REMOTE
    ct_sha=$(
        host_run "$name" <<'REMOTE'
pct exec "$CT" -- sha256sum "/root/$NAME.new" | cut -d' ' -f1
REMOTE
    )
    [ "$ct_sha" = "$local_sha" ] || {
        log "FAIL: $name container staging sha $ct_sha != local $local_sha"
        return 1
    }
    log "   $name staged sha256=$ct_sha"
}

backup_live() {
    local name=$1 out
    out=$(
        host_run "$name" <<'REMOTE'
pct exec "$CT" -- bash -c '
  set -euo pipefail
  live=/usr/local/bin/$1
  bak=$live.bak-$2
  cp -f "$live" "$bak"
  live_sha=$(sha256sum "$live" | cut -d" " -f1)
  bak_sha=$(sha256sum "$bak" | cut -d" " -f1)
  [ "$live_sha" = "$bak_sha" ] || { echo "backup mismatch for $live: $live_sha != $bak_sha" >&2; exit 1; }
  printf "%s sha256=%s\n" "$bak" "$bak_sha"
' _ "$NAME" "$STAMP"
REMOTE
    )
    log "   $out"
}

install_and_start() {
    local role=$1 name="nodus-$1" local_sha installed_sha
    local_sha=$(sha256sum "$ART/$name" | cut -d' ' -f1)
    host_run "$role" <<'REMOTE'
pct exec "$CT" -- bash -c '
  set -euo pipefail
  name=nodus-$1
  unit=$name.service
  systemctl stop "$unit"
  install -o root -g root -m 755 "/root/$name.new" "/usr/local/bin/$name"
  systemctl start "$unit"
' _ "$NAME"
REMOTE
    installed_sha=$(
        host_run "$role" <<'REMOTE'
pct exec "$CT" -- sha256sum "/usr/local/bin/nodus-$NAME" | cut -d' ' -f1
REMOTE
    )
    [ "$installed_sha" = "$local_sha" ] || {
        log "FAIL: installed $name sha $installed_sha != local $local_sha"
        return 1
    }
    INSTALLED_SHA[$role]=$installed_sha
    log "   $name installed sha256=$installed_sha"
}

migration_report() {
    local lines
    lines=$(
        host_run api <<'REMOTE'
pct exec "$CT" -- bash -c 'journalctl -u nodus-api --since "-5min" --no-pager -o cat | grep -i migrat || true'
REMOTE
    )
    log "-- nodus-api migration output --"
    if [ -n "$lines" ]; then
        printf '%s\n' "$lines" | sed 's/^/   /'
    else
        log "   (no migration lines logged)"
    fi
    if printf '%s' "$lines" | grep -Eqi 'error|fail'; then
        log "FAIL: a migration reported an error"
        return 1
    fi
}

feature_count() {
    local body count
    body=$(
        host_run <<'REMOTE'
pct exec "$CT" -- curl -fsS http://127.0.0.1:3001/api/v1/meta
REMOTE
    )
    if command -v jq >/dev/null 2>&1; then
        count=$(printf '%s' "$body" | jq '.features|length')
    else
        count=$(printf '%s' "$body" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["features"]))')
    fi
    printf '%s\n' "$count"
}

do_rollback() {
    local stamp=$1 role code=
    log "=== rolling back every binary to .bak-$stamp ==="
    for role in "${ROLES[@]}"; do
        host_run "$role" <<'REMOTE'
pct exec "$CT" -- bash -c '
  set -euo pipefail
  name=nodus-$1
  bak=/usr/local/bin/$name.bak-$2
  live=/usr/local/bin/$name
  unit=$name.service
  [ -f "$bak" ] || { echo "missing backup $bak" >&2; exit 1; }
  systemctl stop "$unit"
  install -o root -g root -m 755 "$bak" "$live"
  systemctl start "$unit"
  bak_sha=$(sha256sum "$bak" | cut -d" " -f1)
  live_sha=$(sha256sum "$live" | cut -d" " -f1)
  [ "$bak_sha" = "$live_sha" ] || { echo "rollback mismatch for $name: $bak_sha != $live_sha" >&2; exit 1; }
  echo "restored $name sha256=$live_sha"
' _ "$NAME" "$STAMP"
REMOTE
        wait_active "$role" || {
            log "ROLLBACK FAILED: nodus-$role.service is not active"
            return 1
        }
    done
    for _ in $(seq 1 90); do
        code=$(
            host_run api <<'REMOTE'
pct exec "$CT" -- curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3001/healthz || true
REMOTE
        )
        [ "$code" = 200 ] && break
        sleep 1
    done
    [ "$code" = 200 ] || {
        log "ROLLBACK FAILED: nodus-api /healthz is ${code:-nothing}"
        return 1
    }
    log "rollback complete: all six units restarted, nodus-api /healthz=200"
}

deploy_failed() {
    local code=${1:-1}
    trap - ERR
    set +e
    printf '\n*** DEPLOY FAILED (status %s) ***\n' "$code" >&2
    if [ "$BACKUPS_READY" != 1 ]; then
        printf 'No live binary has moved yet; production is untouched, nothing to roll back.\n' >&2
        cleanup_staging
        exit "$code"
    fi
    (
        set -e
        do_rollback "$STAMP"
    )
    if [ $? -eq 0 ]; then
        printf 'ROLLBACK COMPLETE: the previous binaries are live again.\n' >&2
        cleanup_staging
        exit "$code"
    fi
    printf 'ROLLBACK FAILED: production state is inconsistent, inspect now.\n' >&2
    cleanup_staging
    exit 2
}

print_summary() {
    local role
    log ""
    log "=== installed sha256 ==="
    for role in "${ROLES[@]}"; do
        printf '   %-11s %s\n' "nodus-$role" "${INSTALLED_SHA[$role]}"
    done
    log "=== systemctl is-active ==="
    for role in "${ROLES[@]}"; do
        printf '   nodus-%s.service %s\n' "$role" \
            "$(
                host_run "$role" <<'REMOTE'
pct exec "$CT" -- systemctl is-active "nodus-$NAME.service" 2>/dev/null || true
REMOTE
            )"
    done
    log "=== listeners (3001/3002/3003) ==="
    host_run <<'REMOTE'
pct exec "$CT" -- ss -ltn | grep -E ':300[123] ' || true
REMOTE
}

main() {
    local mode=deploy role count

    if [ $# -eq 2 ] && [ "$1" = "--rollback" ]; then
        mode=rollback
        STAMP=$2
    elif [ $# -eq 2 ]; then
        ART=$1
        STAMP=$2
    else
        usage >&2
        exit 2
    fi

    case $STAMP in
    '' | *[!A-Za-z0-9._-]*)
        log "stamp may contain only letters, digits, dot, underscore and dash"
        exit 2
        ;;
    esac

    if [ "$mode" = rollback ]; then
        do_rollback "$STAMP"
        cleanup_staging
        log "rollback exit: feature count is now $(feature_count) (the previous build's)"
        exit 0
    fi

    [ -d "$ART" ] || {
        log "artifact directory not found: $ART"
        exit 2
    }
    for role in "${ROLES[@]}"; do
        [ -f "$ART/nodus-$role" ] || {
            log "missing artifact $ART/nodus-$role; refusing a partial set"
            exit 2
        }
    done

    log "deploying $ART -> $HOST CT $CT (stamp $STAMP)"
    log "-- phase 0: preflight, before any service is touched --"
    artifact_manifest_check "$ART" backend || exit 1
    glibc_preflight
    runtime_prerequisites
    token_key_preflight || exit 1

    declare -gA INSTALLED_SHA=()
    trap 'deploy_failed $?' ERR

    log "-- phase 1: stage and verify every binary --"
    for role in "${ROLES[@]}"; do push_artifact "nodus-$role"; done
    log "-- phase 2: back up every live binary and verify the backup --"
    for role in "${ROLES[@]}"; do backup_live "nodus-$role"; done
    BACKUPS_READY=1
    log "-- phase 3: install and restart in order: ${ROLES[*]} --"
    for role in "${ROLES[@]}"; do
        install_and_start "$role"
        check_role "$role"
    done
    log "-- phase 4: restart the second instances that share these binaries --"
    restart_twins

    migration_report
    count=$(feature_count)
    log "features: $count (want $EXPECTED_FEATURES)"
    [ "$count" = "$EXPECTED_FEATURES" ] || {
        log "FAIL: /api/v1/meta advertises $count features"
        return 1
    }

    cleanup_staging
    trap - ERR
    print_summary
    log "DEPLOY OK"
}

main "$@"
