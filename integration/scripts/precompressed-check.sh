#!/usr/bin/env bash
# Proves the production Caddy asset handler end to end without touching production.
#
# deploy/ct100/nodus.caddy is mounted beside integration/precompressed/Caddyfile and run
# in a throwaway caddy:2.6.2 container (the version CT 100 runs). The check replays the
# release sequence on a bundle that has `.zst`/`.gz` siblings:
#
#   1. start with the handler drifted (no `precompressed`), as production was, and show
#      that `Accept-Encoding: zstd` still gets the identity wasm — the bug being fixed;
#   2. install deploy/ct100/nodus.caddy, `caddy validate`, `caddy reload`;
#   3. ask for the same wasm three ways and assert gzip/zstd come back encoded.
#
# It also reloads the drifted config back to prove the rollback direction. Any failure
# exits non-zero; the container and temp tree are removed on exit.
#
# usage: integration/scripts/precompressed-check.sh
# env:   CADDY_IMAGE (default caddy:2.6.2-alpine), PORT (default: a free ephemeral port)
set -Eeuo pipefail

REPO=$(
  unset CDPATH
  cd -- "$(dirname -- "$0")/../.." && pwd
)
IMAGE=${CADDY_IMAGE:-caddy:2.6.2-alpine}
NAME=${NAME:-nodus-precompressed-check}
if [ -z "${PORT:-}" ]; then
  for candidate in $(shuf -i 19000-29000 -n 10); do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$candidate") 2>/dev/null; then
      PORT=$candidate
      break
    fi
  done
  [ -n "${PORT:-}" ] || { echo "FAIL: no free local port for the throwaway caddy" >&2; exit 1; }
fi
DIST_SRC=${DIST_SRC:-$REPO/web/dist}
AUTHORITATIVE=$REPO/deploy/ct100/nodus.caddy

command -v docker >/dev/null 2>&1 || { echo "FAIL: docker is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "FAIL: curl is required" >&2; exit 1; }
[ -f "$AUTHORITATIVE" ] || { echo "FAIL: missing $AUTHORITATIVE" >&2; exit 1; }
[ -f "$DIST_SRC/index.html" ] || { echo "FAIL: $DIST_SRC has no index.html" >&2; exit 1; }

TMP=$(mktemp -d -t nodus-precompressed.XXXXXX)
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/cfg" "$TMP/dist"
cp -a "$DIST_SRC/." "$TMP/dist/"
cp "$REPO/integration/precompressed/Caddyfile" "$TMP/cfg/Caddyfile"
sh "$REPO/deploy/precompress-bundle.sh" "$TMP/dist"

wasm=$(cd "$TMP/dist" && find . -maxdepth 1 -name '*_bg.wasm' -printf '%f\n' | head -1)
[ -n "$wasm" ] || { echo "FAIL: no *_bg.wasm in $DIST_SRC" >&2; exit 1; }

probe() {
  local enc=$1 hdr=$TMP/hdr.$1 code size got
  local args=(-sS -o /dev/null -D "$hdr" -H "Host: nodus.luxuride.eu")
  [ "$enc" != identity ] && args+=(-H "Accept-Encoding: $enc")
  read -r code size < <(curl "${args[@]}" -w '%{http_code} %{size_download}' \
    "http://127.0.0.1:$PORT/$wasm")
  got=$(tr -d '\r' <"$hdr" | grep -i '^content-encoding:' | tail -1 | sed 's/^[^:]*: *//')
  printf '%s %s %s %s\n' "$enc" "$code" "${got:-identity}" "$size"
}

await_serving() {
  local _
  for _ in $(seq 1 60); do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: nodus.luxuride.eu' \
      "http://127.0.0.1:$PORT/$wasm")" = 200 ]; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

start_caddy() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --name "$NAME" \
    -p "127.0.0.1:$PORT:80" \
    -v "$TMP/cfg:/etc/caddy" \
    -v "$TMP/dist:/srv/nodus:ro" \
    "$IMAGE" >/dev/null
  await_serving || { echo "FAIL: throwaway caddy did not answer :$PORT" >&2; docker logs "$NAME" >&2 || true; exit 1; }
}

# Validate is exactly what release-100.sh runs before it swaps the file in.
validate() {
  docker exec "$NAME" caddy validate --config /etc/caddy/Caddyfile 2>&1 | sed 's/^/   /'
}

reload() {
  docker exec "$NAME" caddy reload --config /etc/caddy/Caddyfile --force 2>&1 | sed 's/^/   /'
}

# Only the listener line is rewritten: the site block's address implies TLS, and a
# workstation has no certificate for nodus.luxuride.eu. Everything below that line —
# in particular the @assets handler under test — is copied verbatim.
install_config() {
  sed 's|^nodus\.luxuride\.eu {|http://:80 {|' "$1" >"$TMP/cfg/nodus.caddy"
}

show() {
  local label=$1 out
  out=$(probe identity; probe gzip; probe zstd)
  { printf '%s\n' "$out" | sed "s/^/   $label /"; } >&2
  printf '%s\n' "$out"
}

echo "== 1. drifted handler (what production ran before the fix) =="
sed '/precompressed zstd gzip/d' "$AUTHORITATIVE" >"$TMP/drifted.caddy"
install_config "$TMP/drifted.caddy"
# Validate before the throwaway server ever starts, as the release does.
docker run --rm -v "$TMP/cfg:/etc/caddy" "$IMAGE" \
  caddy validate --config /etc/caddy/Caddyfile 2>&1 | sed 's/^/   /'
start_caddy
drifted=$(show drifted)
drifted_zstd=$(printf '%s\n' "$drifted" | awk '$1 == "zstd" { print $3 }')
[ "$drifted_zstd" = identity ] || {
  echo "FAIL: the drifted handler already answered zstd; the negative control is not negative" >&2
  exit 1
}
echo "   OK: without precompressed, a .zst sibling exists but zstd gets identity"

echo "== 2. install the authoritative config, validate, reload =="
install_config "$AUTHORITATIVE"
validate
reload
for _ in $(seq 1 20); do
  reloaded=$(show reloaded)
  [ "$(printf '%s\n' "$reloaded" | awk '$1 == "zstd" { print $3 }')" = zstd ] && break
  sleep 0.5
done
for enc in identity gzip zstd; do
  [ "$(printf '%s\n' "$reloaded" | awk -v e="$enc" '$1 == e { print $2 }')" = 200 ] || {
    echo "FAIL: $enc request did not answer 200" >&2
    exit 1
  }
done
[ "$(printf '%s\n' "$reloaded" | awk '$1 == "zstd" { print $3 }')" = zstd ] || {
  echo "FAIL: authoritative handler did not serve the wasm as zstd" >&2
  exit 1
}
echo "   OK: authoritative handler serves gzip and zstd"

echo "== 3. rollback direction: drifted config again =="
sed '/precompressed zstd gzip/d' "$AUTHORITATIVE" >"$TMP/drifted.caddy"
install_config "$TMP/drifted.caddy"
validate
reload
for _ in $(seq 1 20); do
  rolled=$(show rolled)
  [ "$(printf '%s\n' "$rolled" | awk '$1 == "zstd" { print $3 }')" = identity ] && break
  sleep 0.5
done
[ "$(printf '%s\n' "$rolled" | awk '$1 == "zstd" { print $3 }')" = identity ] || {
  echo "FAIL: after rollback the wasm was still encoded; reload did not take" >&2
  exit 1
}
echo "   OK: rollback reload restores the identity path"
echo "PRECOMPRESSED CHECK OK"
