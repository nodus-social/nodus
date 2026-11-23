#!/usr/bin/env bash
# Deploys the server-rendered web shell — the `nodus-server` binary, the wasm bundle,
# and the Caddy site block that serves it — to LXC 100 and rolls them back as one unit.
#
# On this container `nodus-server` is the web shell, not the API: nodus-ssr.service
# runs it with NODUS_ASSET_DIR=/srv/nodus behind Caddy on 127.0.0.1:8080. Binary, bundle
# and deploy/ct100/nodus.caddy are one release: they move together or neither does.
# Every artifact and every backup is hashed where it lands before any live path changes,
# and index.html is checked against the files it names while the bundle is still staged
# in /srv/nodus.new — a bundle that does not match its own integrity hashes fails there,
# before the live tree is touched.
#
# The Caddy file is installed only after `caddy validate` accepts it against the live
# /etc/caddy/Caddyfile, and the release fails unless the served wasm answers
# `content-encoding: zstd`. Shipping `.zst`/`.gz` siblings to a server whose asset
# handler ignores them is the failure this script exists to make impossible.
set -Eeuo pipefail

HOST=${HOST:-root@hyper.luxuride.eu}
CT=${CT:-100}
SITE=${SITE:-nodus.luxuride.eu}
UNIT=nodus-ssr
BIN=/usr/local/bin/nodus-server
ASSET_DIR=/srv/nodus
PREFLIGHT_PORT=${PREFLIGHT_PORT:-18081}

BINARY_STAGE=/root/nodus-web-server.new
TARBALL_STAGE=/root/nodus-dist.new.tar.gz
CADDY_STAGE=/root/nodus.caddy.new
CADDY_CONF=/etc/caddy/nodus.caddy

SCRIPT_DIR=$(
    unset CDPATH
    cd -- "$(dirname -- "$0")" && pwd
)
# shellcheck source=artifact-manifest.sh
. "$SCRIPT_DIR/artifact-manifest.sh"

CADDY_SRC=$SCRIPT_DIR/ct100/nodus.caddy

SWAPPED=0
CADDY_INSTALLED=0
TARBALL=''
INSTALLED_SHA=''
EXPECTED_JS=''

log() { printf '%s\n' "$*"; }

usage() {
    cat <<'USAGE'
usage: release-100.sh <server-binary> <dist-dir> <stamp>
       release-100.sh --rollback <stamp>

  server-binary  the SSR server built for this release (nodus-web-server)
  dist-dir       the wasm bundle built for the same pins (index.html and friends)
  stamp          suffix for the backups: <path>.bak-<stamp>

Environment: HOST (default root@hyper.luxuride.eu), CT (default 100),
             PREFLIGHT_PORT (default 18081)
USAGE
}

# Runs a bash script on the Proxmox host. CT, STAMP, UNIT and PREFLIGHT_PORT are
# exported as shell variables, so the body can stay a quoted heredoc and never be
# expanded here.
# The host login shell is fish, hence `ssh ... bash -s` rather than a command string.
host_run() {
    {
        printf 'set -euo pipefail\n'
        printf 'CT=%q\nSTAMP=%q\nUNIT=%q\nPREFLIGHT_PORT=%q\nSITE=%q\n' "$CT" "$STAMP" "$UNIT" "$PREFLIGHT_PORT" "$SITE"
        cat
    } | ssh "$HOST" bash -s
}

# Removes only the staging files this script created: the pushed artifacts on the
# host and in the container, and /srv/nodus.new. Backups are never touched.
cleanup_staging() {
    host_run <<'REMOTE'
rm -f /root/nodus-web-server.new /root/nodus-dist.new.tar.gz /root/nodus-web-server.probe /root/nodus.caddy.new
pct exec "$CT" -- bash -c 'rm -f /root/nodus-web-server.new /root/nodus-dist.new.tar.gz /root/nodus-web-server.probe /root/nodus.caddy.new; rm -rf /srv/nodus.new'
true
REMOTE
}

wait_active() {
    local state
    for _ in $(seq 1 30); do
        state=$(
            host_run <<'REMOTE'
pct exec "$CT" -- systemctl is-active "$UNIT" 2>/dev/null || true
REMOTE
        )
        [ "$state" = active ] && return 0
        sleep 1
    done
    return 1
}

journal_errors() {
    local hits
    hits=$(
        host_run <<'REMOTE'
pct exec "$CT" -- bash -c 'journalctl -u nodus-ssr --since "-3min" --no-pager -o cat | grep -E "ERROR|panicked" || true'
REMOTE
    )
    printf '%s' "$hits"
}

# A binary built elsewhere carries the libc it was linked against. One built against a
# newer glibc than the container's fails to start with "version `GLIBC_x.y' not found"
# — sometimes only on the first call that needs the symbol, which is a crash in
# production rather than a failed deploy. Compare the highest symbol version the
# artifact needs with the container's ldd before pushing 22 MB at it.
glibc_gate() {
    local binary=$1 need have
    command -v objdump >/dev/null 2>&1 || {
        log "FAIL: objdump is needed to read the binary's glibc needs"
        return 1
    }
    need=$(objdump -T "$binary" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sed 's/^GLIBC_//' | sort -Vu | tail -1)
    if [ -z "$need" ]; then
        log "   glibc gate: no versioned glibc symbols (static binary), skipping"
        return 0
    fi
    have=$(
        host_run <<'REMOTE'
pct exec "$CT" -- bash -c 'ldd --version | head -1' | grep -oE '[0-9]+\.[0-9]+$'
REMOTE
    )
    [ -n "$have" ] || {
        log "FAIL: glibc gate could not read the container's ldd version"
        return 1
    }
    if [ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | tail -1)" != "$have" ]; then
        log "FAIL: the binary needs GLIBC_$need but CT $CT has $have; build it against the container's libc"
        return 1
    fi
    log "   glibc gate: binary needs <= GLIBC_$need, CT $CT has $have"
}

# Caddy's asset handler serves `<asset>.zst` / `<asset>.gz` when the client offers the
# encoding (see integration/Caddyfile and deploy/docker/Caddyfile). The builder emits them
# too, but a bundle can reach this script from a host-side build that did not, and the
# tarball is the last point before production. The helper refuses to run without `zstd`,
# so a missing tool is a failed deploy rather than a bundle that silently ships 6.2 MB.
precompress_bundle() {
    local dist=$1 script count
    script=$(
        unset CDPATH
        cd -- "$(dirname -- "$0")" && pwd
    )/precompress-bundle.sh
    [ -f "$script" ] || {
        log "FAIL: precompression helper not found: $script"
        return 1
    }
    sh "$script" "$dist" || {
        log "FAIL: could not precompress the bundle in $dist"
        return 1
    }
    count=$(find "$dist" -type f -name '*.zst' | wc -l)
    log "   precompressed: $count .zst and $count .gz siblings"
}

push_artifact() {
    local src=$1 dest=$2 local_sha host_sha ct_sha
    [ -f "$src" ] || {
        log "missing artifact $src"
        return 1
    }
    local_sha=$(sha256sum "$src" | cut -d' ' -f1)
    scp -q "$src" "$HOST:$dest"
    host_sha=$(
        host_run <<REMOTE
sha256sum "$dest" | cut -d' ' -f1
REMOTE
    )
    [ "$host_sha" = "$local_sha" ] || {
        log "FAIL: host staging sha $host_sha != local $local_sha for $dest"
        return 1
    }
    host_run <<REMOTE
pct push "$CT" "$dest" "$dest"
REMOTE
    ct_sha=$(
        host_run <<REMOTE
pct exec "\$CT" -- sha256sum "$dest" | cut -d' ' -f1
REMOTE
    )
    [ "$ct_sha" = "$local_sha" ] || {
        log "FAIL: container staging sha $ct_sha != local $local_sha for $dest"
        return 1
    }
    log "   staged $dest sha256=$ct_sha"
}

# The live binary is copied and the copy is hashed before anything else moves: a
# backup that is taken after the unit stops can capture the new file or a truncated
# one, which is how a rollback path quietly stops existing.
backup_binary() {
    host_run <<'REMOTE'
pct exec "$CT" -- bash -c '
  set -euo pipefail
  live=$1
  bak=$live.bak-$2
  [ -f "$live" ] || { echo "missing live binary $live" >&2; exit 1; }
  cp -f "$live" "$bak"
  live_sha=$(sha256sum "$live" | cut -d" " -f1)
  bak_sha=$(sha256sum "$bak" | cut -d" " -f1)
  [ "$live_sha" = "$bak_sha" ] || { echo "backup mismatch for $live: $live_sha != $bak_sha" >&2; exit 1; }
  printf "   %s sha256=%s\n" "$bak" "$bak_sha"
' _ /usr/local/bin/nodus-server "$STAMP"
REMOTE
}

# The Caddy site block is part of the release: back it up with the same stamp as the
# binary and bundle so `--rollback` can put the whole set back.
backup_caddy() {
    host_run <<'REMOTE'
pct exec "$CT" -- bash -c '
  set -euo pipefail
  live=$1
  bak=$live.bak-$2
  [ -f "$live" ] || { echo "missing live caddy config $live" >&2; exit 1; }
  cp -f "$live" "$bak"
  live_sha=$(sha256sum "$live" | cut -d" " -f1)
  bak_sha=$(sha256sum "$bak" | cut -d" " -f1)
  [ "$live_sha" = "$bak_sha" ] || { echo "backup mismatch for $live: $live_sha != $bak_sha" >&2; exit 1; }
  printf "   %s sha256=%s\n" "$bak" "$bak_sha"
' _ /etc/caddy/nodus.caddy "$STAMP"
REMOTE
}

# Installs the candidate but does not reload: Caddy keeps answering with the loaded
# config until `reload_caddy`. If validation fails, the backup goes back on disk so a
# later restart cannot pick up a file this script refused.
install_caddy() {
    host_run <<'REMOTE'
pct exec "$CT" -- bash -c '
  set -euo pipefail
  conf=$1
  main=$2
  bak=$conf.bak-$3
  install -o root -g root -m 644 /root/nodus.caddy.new "$conf"
  if ! out=$(caddy validate --config "$main" 2>&1); then
    printf "%s\n" "$out" | sed "s/^/   /" >&2
    install -o root -g root -m 644 "$bak" "$conf"
    echo "FAIL: caddy validate rejected the new $conf; restored $bak, Caddy still runs its previous config" >&2
    exit 1
  fi
  echo "   caddy validate --config $main: valid"
' _ /etc/caddy/nodus.caddy /etc/caddy/Caddyfile "$STAMP"
REMOTE
}

reload_caddy() {
    host_run <<'REMOTE'
pct exec "$CT" -- systemctl reload caddy || {
  echo "FAIL: caddy reload of /etc/caddy/nodus.caddy failed" >&2
  exit 1
}
echo "   caddy reloaded"
REMOTE
}

restore_caddy() {
    host_run <<'REMOTE'
pct exec "$CT" -- bash -c '
  set -euo pipefail
  conf=$1
  bak=$conf.bak-$2
  [ -f "$bak" ] || { echo "missing caddy backup $bak" >&2; exit 1; }
  install -o root -g root -m 644 "$bak" "$conf"
  echo "   restored $conf from $bak"
' _ /etc/caddy/nodus.caddy "$STAMP"
REMOTE
}

# Unpacks the bundle into /srv/nodus.new and checks it against its own index.html.
# Every sha384 entry must match the bytes of the file it names, and every hash-named
# asset the page references must exist in the staged tree.
stage_bundle() {
    host_run <<'REMOTE'
pct exec "$CT" -- bash -c '
  set -euo pipefail
  stage=/srv/nodus.new
  case $stage in /srv/nodus) echo "refusing to stage over the live tree" >&2; exit 1 ;; esac
  rm -rf "$stage"
  mkdir -p "$stage"
  tar -xzf /root/nodus-dist.new.tar.gz -C "$stage"
  chown -R caddy:caddy "$stage"
' 
REMOTE
    log "   unpacked /srv/nodus.new"
}

verify_bundle() {
    local out
    out=$(
        host_run <<'REMOTE'
pct exec "$CT" -- python3 - /srv/nodus.new <<'PY'
import base64, hashlib, re, sys, pathlib

root = pathlib.Path(sys.argv[1])
html = (root / "index.html").read_text(encoding="utf-8")

problems = []
tags = re.findall(r"<[^>]*\bintegrity=\"sha384-[^\"]+\"[^>]*>", html)
if not tags:
    problems.append("index.html carries no sha384 integrity entries")

for tag in tags:
    digest = re.search(r'integrity="sha384-([^"]+)"', tag).group(1)
    href = re.search(r'(?:href|src)="([^"]+)"', tag)
    if not href:
        problems.append(f"integrity entry without href/src: {tag[:60]}")
        continue
    name = href.group(1).lstrip("/")
    path = root / name
    if not path.is_file():
        problems.append(f"{name}: named by integrity but missing from the staged tree")
        continue
    got = base64.b64encode(hashlib.sha384(path.read_bytes()).digest()).decode()
    if got != digest:
        problems.append(f"{name}: sha384 {got[:16]}... != index.html {digest[:16]}...")

refs = sorted(set(re.findall(r"/((?:nodus-web|tailwind)-[a-z0-9]+(?:_bg\.wasm|\.js|\.css))", html)))
if not refs:
    problems.append("index.html references no hash-named bundle assets")
for ref in refs:
    if not (root / ref).is_file():
        problems.append(f"{ref}: referenced by index.html but missing from the staged tree")

if problems:
    for p in problems:
        print(f"   FAIL: {p}", file=sys.stderr)
    sys.exit(1)

script = re.search(r"/(nodus-web-[a-z0-9]+\.js)", html).group(1)
print(f"   verified {len(tags)} sha384 entr{'y' if len(tags) == 1 else 'ies'} against {len(refs)} referenced assets")
print(f"   script={script}")
PY
REMOTE
    )
    printf '%s\n' "$out"
    EXPECTED_JS=$(printf '%s\n' "$out" | sed -n 's/^ *script=\(nodus-web-[a-z0-9]*\.js\)$/\1/p')
    [ -n "$EXPECTED_JS" ] || {
        log "FAIL: could not read the bundle's script name from the staged index.html"
        return 1
    }
}

# Runs the pushed binary against the staged tree on a scratch port. A binary that
# cannot start here — wrong libc, missing assets — is found now, while the live tree
# is still live, instead of after the swap.
preflight_binary() {
    host_run <<'REMOTE'
pct exec "$CT" -- bash -c '
  set -uo pipefail
  port=$1
  log=/tmp/nodus-preflight.log
  chmod 755 /root/nodus-web-server.new
  NODUS_LISTEN=127.0.0.1:$port \
  NODUS_ASSET_DIR=/srv/nodus.new \
  NODUS_SESSIONS=/tmp/nodus-preflight-sessions.json \
  NODUS_INSTANCE_HOST=nodus.luxuride.eu \
  RUST_LOG=info \
    timeout 15 /root/nodus-web-server.new >"$log" 2>&1 &
  pid=$!
  code=
  for _ in $(seq 1 20); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$port/healthz" 2>/dev/null || true)
    [ "$code" = 200 ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if [ "$code" != 200 ]; then
    echo "FAIL: the new binary does not serve /healthz on 127.0.0.1:$port (got ${code:-nothing}); it was not installed" >&2
    sed "s/^/   /" "$log" >&2 || true
    rm -f "$log" /tmp/nodus-preflight-sessions.json
    exit 1
  fi
  echo "   preflight: /healthz 200 on 127.0.0.1:$port from the staged tree"
  rm -f "$log" /tmp/nodus-preflight-sessions.json
' _ "$PREFLIGHT_PORT"
REMOTE
}

swap() {
    host_run <<'REMOTE'
pct exec "$CT" -- bash -c '
  set -euo pipefail
  bin=/usr/local/bin/nodus-server
  live=/srv/nodus
  stage=/srv/nodus.new
  bak=$live.bak-$1
  [ -d "$stage" ] || { echo "no staged tree at $stage" >&2; exit 1; }
  [ -e "$bak" ] && { echo "backup $bak already exists; refusing to overwrite a previous release" >&2; exit 1; }
  systemctl stop nodus-ssr
  mv "$live" "$bak"
  mv "$stage" "$live"
  install -o root -g root -m 755 /root/nodus-web-server.new "$bin"
  systemctl start nodus-ssr
  echo "   live tree is now $live (previous at $bak)"
' _ "$STAMP"
REMOTE
}

# The guard that makes this release own the handler: ask Caddy for the hashed wasm
# with each encoding and read what came back. Identity 6.2 MB with no
# `content-encoding: zstd` means the `.zst` sibling was shipped but the asset handler
# that is actually loaded does not use it — exactly the drift this release prevents.
# Sizes are printed for all three variants so the release log records the bytes served.
check_wasm_encoding() {
    local out asset identity_bytes gzip_bytes zstd_bytes zstd_enc
    out=$(
        host_run <<'REMOTE'
pct exec "$CT" -- bash -c '
  set -uo pipefail
  site=$1
  shift
  wasm=$(curl -s http://127.0.0.1:8080/ | grep -oE "nodus-web-[a-z0-9]+_bg\.wasm" | sort -u | head -1)
  [ -n "$wasm" ] || { echo "FAIL: the served index.html names no *_bg.wasm; cannot check the asset handler" >&2; exit 1; }
  printf "asset %s\n" "$wasm"
  probe() {
    enc=$1
    hdr=$(mktemp)
    args=(-sS -o /dev/null -D "$hdr" --resolve "$site:443:127.0.0.1")
    [ "$enc" != identity ] && args+=(-H "Accept-Encoding: $enc")
    meta=$(curl "${args[@]}" -w "%{http_code} %{size_download}" "https://$site/$wasm")
    status=$?
    if [ "$status" -ne 0 ]; then
      rm -f "$hdr"
      echo "FAIL: GET $wasm with Accept-Encoding: $enc failed (curl status $status)" >&2
      exit 1
    fi
    set -- $meta
    got=$(tr -d "\r" <"$hdr" | grep -i "^content-encoding:" | tail -1 | sed "s/^[^:]*: *//")
    printf "encoding %s %s %s %s\n" "$enc" "$1" "${got:-identity}" "$2"
    rm -f "$hdr"
  }
  probe identity
  probe gzip
  probe zstd
' _ "$SITE"
REMOTE
    )
    printf '%s\n' "$out" | sed 's/^/   /'
    asset=$(printf '%s\n' "$out" | awk '$1 == "asset" { print $2; exit }')
    identity_bytes=$(printf '%s\n' "$out" | awk '$1 == "encoding" && $2 == "identity" { print $5; exit }')
    gzip_bytes=$(printf '%s\n' "$out" | awk '$1 == "encoding" && $2 == "gzip" { print $5; exit }')
    zstd_enc=$(printf '%s\n' "$out" | awk '$1 == "encoding" && $2 == "zstd" { print $4; exit }')
    zstd_bytes=$(printf '%s\n' "$out" | awk '$1 == "encoding" && $2 == "zstd" { print $5; exit }')
    if [ "$zstd_enc" != zstd ]; then
        log "FAIL: /$asset answered content-encoding '${zstd_enc:-none}' (${zstd_bytes:-?} bytes) for Accept-Encoding: zstd, identity is ${identity_bytes:-?} bytes"
        log "      the .zst sibling was shipped but the loaded @assets handler does not serve it; release refused"
        return 1
    fi
    log "   wasm $asset: identity ${identity_bytes:-?} / gzip ${gzip_bytes:-?} / zstd ${zstd_bytes:-?} bytes (content-encoding zstd)"
}

check_live() {
    local want_sha=$1 code served installed_sha errors
    wait_active || {
        log "FAIL: nodus-ssr.service did not become active"
        return 1
    }

    for _ in $(seq 1 20); do
        code=$(
            host_run <<'REMOTE'
pct exec "$CT" -- curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/healthz || true
REMOTE
        )
        [ "$code" = 200 ] && break
        sleep 1
    done
    [ "$code" = 200 ] || {
        log "FAIL: /healthz returned ${code:-nothing} on 127.0.0.1:8080, want 200"
        return 1
    }

    served=$(
        host_run <<'REMOTE'
pct exec "$CT" -- bash -c 'curl -s http://127.0.0.1:8080/ | grep -oE "nodus-web-[a-z0-9]+" | sort -u | head -1'
REMOTE
    )
    [ "$served" = "${EXPECTED_JS%.js}" ] || {
        log "FAIL: / serves ${served:-nothing}, want ${EXPECTED_JS%.js} from the staged bundle"
        return 1
    }

    installed_sha=$(
        host_run <<'REMOTE'
pct exec "$CT" -- sha256sum /usr/local/bin/nodus-server | cut -d' ' -f1
REMOTE
    )
    [ "$installed_sha" = "$want_sha" ] || {
        log "FAIL: installed binary sha $installed_sha != artifact $want_sha"
        return 1
    }

    errors=$(journal_errors)
    [ -z "$errors" ] || {
        printf '%s\n' "$errors" >&2
        log "FAIL: nodus-ssr logged ERROR or panicked in the last 3 minutes"
        return 1
    }

    check_wasm_encoding || return 1

    INSTALLED_SHA=$installed_sha
    log "   nodus-ssr active, /healthz 200, serving $served, installed sha256=$installed_sha"
    log "   journal clean (no ERROR/panicked in the last 3 minutes)"
}

do_rollback() {
    local stamp=$1 code served
    log "=== rolling back CT $CT to .bak-$stamp ==="
    host_run <<'REMOTE'
pct exec "$CT" -- bash -c '
  set -euo pipefail
  live=/srv/nodus
  bak=$live.bak-$1
  failed=$live.failed-$1
  bin=/usr/local/bin/nodus-server
  binbak=$bin.bak-$1
  caddy=/etc/caddy/nodus.caddy
  caddybak=$caddy.bak-$1
  [ -d "$bak" ] || { echo "missing tree backup $bak" >&2; exit 1; }
  [ -f "$binbak" ] || { echo "missing binary backup $binbak" >&2; exit 1; }
  [ -f "$caddybak" ] || { echo "missing caddy backup $caddybak" >&2; exit 1; }
  systemctl stop nodus-ssr
  rm -rf "$failed"
  [ -d "$live" ] && mv "$live" "$failed"
  mv "$bak" "$live"
  install -o root -g root -m 755 "$binbak" "$bin"
  install -o root -g root -m 644 "$caddybak" "$caddy"
  systemctl start nodus-ssr
  systemctl reload caddy
  echo "   restored $live from $bak, $bin from $binbak, and $caddy from $caddybak"
' _ "$STAMP"
REMOTE
    wait_active || {
        log "ROLLBACK FAILED: nodus-ssr.service is not active"
        return 1
    }
    for _ in $(seq 1 20); do
        code=$(
            host_run <<'REMOTE'
pct exec "$CT" -- curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/healthz || true
REMOTE
        )
        [ "$code" = 200 ] && break
        sleep 1
    done
    [ "$code" = 200 ] || {
        log "ROLLBACK FAILED: /healthz is ${code:-nothing}"
        return 1
    }
    served=$(
        host_run <<'REMOTE'
pct exec "$CT" -- bash -c 'curl -s http://127.0.0.1:8080/ | grep -oE "nodus-web-[a-z0-9]+" | sort -u | head -1'
REMOTE
    )
    log "rollback complete: nodus-ssr active, /healthz=200, serving ${served:-unknown}, caddy config restored"
}

deploy_failed() {
    local code=${1:-1}
    trap - ERR
    set +e
    printf '\n*** DEPLOY FAILED (status %s) ***\n' "$code" >&2
    if [ "$SWAPPED" != 1 ]; then
        if [ "$CADDY_INSTALLED" = 1 ]; then
            # The candidate is on disk but was never reloaded; put the backup back so a
            # later restart cannot load a config this release refused.
            (
                set -e
                restore_caddy
            ) || {
                printf 'ROLLBACK FAILED: could not restore /etc/caddy/nodus.caddy; inspect now.\n' >&2
                cleanup_staging
                exit 2
            }
        fi
        printf 'The live tree and binary never moved; production is untouched, nothing to roll back.\n' >&2
        cleanup_staging
        exit "$code"
    fi
    if (
        set -e
        do_rollback "$STAMP"
    ); then
        printf 'ROLLBACK COMPLETE: the previous tree, binary and caddy config are live again.\n' >&2
    else
        printf 'ROLLBACK FAILED: production state is inconsistent, inspect now.\n' >&2
        cleanup_staging
        exit 2
    fi
    cleanup_staging
    exit "$code"
}

main() {
    local mode=deploy binary='' dist=''

    if [ $# -eq 2 ] && [ "$1" = "--rollback" ]; then
        mode=rollback
        STAMP=$2
    elif [ $# -eq 3 ]; then
        binary=$1
        dist=${2%/}
        STAMP=$3
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
        log "rollback exit OK"
        exit 0
    fi

    [ -f "$binary" ] || {
        log "server binary not found: $binary"
        exit 2
    }
    [ -f "$dist/index.html" ] || {
        log "bundle directory has no index.html: $dist"
        exit 2
    }

    # BUILD-INFO lives next to the artifact directory the builder filled. When it is
    # present the passed binary must be the one it covers, not merely a binary of the
    # right name; a directory without it is a hand-built set and is accepted as such.
    local artifact_root passed_sha built_sha
    artifact_root=$(
        unset CDPATH
        cd -- "$(dirname -- "$dist")" && pwd
    )
    artifact_manifest_check "$artifact_root" web || exit 2
    if [ -f "$artifact_root/BUILD-INFO" ] && [ -f "$artifact_root/nodus-web-server" ]; then
        passed_sha=$(sha256sum "$binary" | cut -d' ' -f1)
        built_sha=$(sha256sum "$artifact_root/nodus-web-server" | cut -d' ' -f1)
        [ "$passed_sha" = "$built_sha" ] || {
            log "FAIL: the binary you passed is not the one BUILD-INFO covers"
            log "      passed $passed_sha, built $built_sha"
            exit 2
        }
    fi

    # TARBALL stays global so the EXIT trap can still name it after main returns.
    local want_sha tar_sha unit_state
    want_sha=$(sha256sum "$binary" | cut -d' ' -f1)
    TARBALL=$(mktemp -t nodus-dist.XXXXXX.tar.gz)
    trap 'rm -f "${TARBALL:-}"' EXIT
    trap 'deploy_failed $?' ERR

    log "deploying $binary + $dist -> $HOST CT $CT (stamp $STAMP)"
    log "-- phase 0: check the target can run this build, then pack the bundle --"
    glibc_gate "$binary"
    precompress_bundle "$dist"
    tar -C "$dist" -czf "$TARBALL" .
    tar_sha=$(sha256sum "$TARBALL" | cut -d' ' -f1)
    log "   tarball sha256=$tar_sha ($(du -h "$TARBALL" | cut -f1))"

    [ -f "$CADDY_SRC" ] || {
        log "caddy config not found: $CADDY_SRC"
        return 1
    }

    log "-- phase 1: push and verify the binary, bundle and caddy config inside CT $CT --"
    push_artifact "$binary" "$BINARY_STAGE"
    push_artifact "$TARBALL" "$TARBALL_STAGE"
    push_artifact "$CADDY_SRC" "$CADDY_STAGE"
    [ "$(
        host_run <<REMOTE
pct exec "\$CT" -- sha256sum "$TARBALL_STAGE" | cut -d' ' -f1
REMOTE
    )" = "$tar_sha" ] || {
        log "FAIL: staged bundle tarball sha does not match the local one"
        return 1
    }

    log "-- phase 2: back up the live binary and caddy config, and verify both backups --"
    unit_state=$(
        host_run <<'REMOTE'
pct exec "$CT" -- systemctl is-active nodus-ssr 2>/dev/null || true
REMOTE
    )
    log "   unit before deploy: ${unit_state:-unknown}"
    backup_binary
    backup_caddy

    log "-- phase 3: stage the bundle and check it against its own index.html --"
    stage_bundle
    verify_bundle
    preflight_binary

    log "-- phase 4: install and validate the caddy config (not yet loaded) --"
    install_caddy
    CADDY_INSTALLED=1

    log "-- phase 5: swap tree and binary, then reload caddy --"
    swap
    SWAPPED=1
    reload_caddy

    log "-- phase 6: verify what is live, including the precompressed wasm --"
    check_live "$want_sha"

    trap - ERR
    cleanup_staging
    log ""
    log "=== deploy summary ==="
    log "   CT            $CT ($HOST)"
    log "   binary        $BIN sha256=$INSTALLED_SHA"
    log "   bundle        scripts $EXPECTED_JS served from $ASSET_DIR"
    log "   caddy         $CADDY_CONF reloaded from deploy/ct100/nodus.caddy"
    log "   backups       $ASSET_DIR.bak-$STAMP, $BIN.bak-$STAMP and $CADDY_CONF.bak-$STAMP"
    log "   rollback      $0 --rollback $STAMP"
    log "DEPLOY OK"
}

main "$@"
