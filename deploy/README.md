# Deploy

`release-118.sh` installs the six backend binaries on LXC 118; `release-100.sh` installs the
web shell, wasm bundle and Caddy site block on LXC 100. Both consume artifacts that
`deploy/build.sh` produces, and both install them with a stamp so the previous set can be
restored with `--rollback <stamp>`.

## Release sequence

`<stamp>` is any `[A-Za-z0-9._-]` suffix, usually a date. `OUT` is an artifact directory;
a non-empty one is only reused when `build.sh` wrote it (it must contain `BUILD-INFO`).

```sh
# 0. artifacts, from the submodule commits the superproject records (git ls-tree HEAD)
#    --worktree builds the working trees instead; either way the commits are printed.
deploy/build.sh all ~/.cache/nodus-artifacts/2026-11-23

OUT=~/.cache/nodus-artifacts/2026-11-23
STAMP=2026-11-23

# 1. backend: six binaries to CT 118, health-checked role by role
deploy/release-118.sh "$OUT" "$STAMP"

# 2. web: binary + dist to CT 100, Caddy config validated and reloaded
deploy/release-100.sh "$OUT/nodus-web-server" "$OUT/dist" "$STAMP"

# 3. verify the live services
ssh root@hyper.luxuride.eu 'pct exec 118 -- curl -fsS http://127.0.0.1:3001/api/v1/meta | jq ".features|length"'
curl -fsS -o /dev/null -w '%{http_code}\n' https://nodus.luxuride.eu/healthz
curl -fsS -o /dev/null -D - -H 'Accept-Encoding: zstd' \
  https://nodus.luxuride.eu/nodus-web-*.js | grep -i '^content-encoding: zstd'

# 4. rollback, if a release must be undone: same stamp, previous set goes back
deploy/release-118.sh --rollback "$STAMP"
deploy/release-100.sh --rollback "$STAMP"
```

The release scripts also verify the artifact set itself: `BUILD-INFO` must name the right
`target` (`backend`/`web`/`all`) and `SHA256SUMS` must match the files. A directory without
`BUILD-INFO` is treated as hand-built — one line in the log says the pins are unverified,
and the release proceeds.

## Build notes

- Everything is built in `rust:1-bookworm` (glibc 2.36) because CT 118 and CT 100 run
  Debian 12. `build.sh` also reads each binary's highest `GLIBC_2.x` symbol and refuses a
  build that would need a newer one, so the release scripts' glibc gate is a second fence,
  not the first.
- The pinned source is `git archive`d per submodule into a throwaway context; the
  worktree is never written to unless `--worktree` is passed. Build output lands on the
  host by `docker cp`, owned by the invoking user.
- The builder image (node, pinned trunk and wasm-opt, `wasm32-unknown-unknown`) is cached
  by a hash of its Dockerfile. Cargo reuses the host `CARGO_HOME` registry and a per-target
  cache under `~/.cache/nodus-release-build`, so a second build is minutes.
- `dist/` ships `.gz`/`.zst` siblings written by `deploy/precompress-bundle.sh`; the release
  scripts refuse a bundle whose wasm is not served with `content-encoding: zstd`.
