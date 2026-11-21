# The development loop

The lab has two loops. They use the same Postgres volume and the same Valkey
data, so they are two ways to run one stack, not two stacks.

| | Host loop | Full stack |
|---|---|---|
| Runs | Postgres + Valkey in containers; `nodus` roles and the web client on the host | all ten containers |
| Code comes from | your working tree, built by cargo/trunk on the host | the committed pins, or the working tree with `LAB_BUILD_FROM_WORKTREE=1` |
| Restart cost | seconds (debug build + process restart) | an image rebuild |
| Federation / peers | no | yes |
| HTTPS / CA | no (plain HTTP on loopback) | yes |
| Use it for | day-to-day Rust and Leptos work | images, Caddy, peers, federation, e2e |

`scripts/e2e.sh` still runs against the full stack. Nothing in the host loop
replaces it.

## Host loop

Start the infrastructure once:

```sh
integration/scripts/dev.sh infra
```

That publishes Postgres on `127.0.0.1:55432` and Valkey on
`127.0.0.1:56379`. It does not start Caddy, the peers, or any `nodus` role.
`dev.sh infra down` stops the two containers and keeps the volumes.

Then, in separate terminals:

```sh
integration/scripts/dev.sh api           # http://localhost:3300
integration/scripts/dev.sh feed          # http://localhost:3303, optional
integration/scripts/dev.sh worker media  # media, scan, prune or calc
integration/scripts/dev.sh web           # trunk serve on http://localhost:3301
```

`dev.sh api` builds `nodus-api` in debug mode into
`integration/state/target-dev`, runs `--migrate-only`, then replaces itself with
the server. `dev.sh web` runs `trunk serve`, which serves the client at
`http://localhost:3301` and proxies `/api` to `http://127.0.0.1:3300` (the API
has no CORS layer, so same-origin proxy is required). Media goes to
`integration/state/dev/media`.

Sign in at `http://localhost:3301` with the bootstrap account from
`integration/.env` (`admin@nodus.test` by default). The API's public URL is
`http://localhost:3300`, even though the federation identity stays `nodus.test`.

Every mode checks its port before building or starting. If infra is down, a
port is taken, or Postgres rejects the `.env` password, it exits with the
command that fixes it instead of a sqlx stack trace.

### Full-stack fallback for a dirty tree

When you need Caddy, HTTPS, peers, or an image that contains uncommitted code:

```sh
LAB_BUILD_FROM_WORKTREE=1 integration/scripts/build.sh
integration/scripts/up.sh --skip-build
```

`build.sh` then uses the repository root as the build context and
`integration/Dockerfile.{server,web}` instead of `git archive` of the pinned
commits. Both images are rebuilt; this is not a dev-loop tool.

Proven on 2026-11-21: with `healthz` temporarily changed in the working tree to
return `ok-worktree-proof`, a `LAB_BUILD_FROM_WORKTREE=1` build finished with
both images tagged, `up -d --no-deps nodus-api` recreated only the API
container, and `curl` inside that container (and through Caddy on `:18080`)
returned `ok-worktree-proof`. The source change was then reverted. A warm
BuildKit cache makes this a few minutes, not a pinned build from scratch.

## Measured timings

Host: 32 vCPU, 60 GB RAM, Rust 1.99.1, Docker 29.9.3, no `sccache`, warm cargo
registry. Debug profile for the backend; Trunk's configured release profile for
the web client. Measured 2026-11-21.

| Step | Command | Time |
|---|---|---|
| Cold `api` build, empty `integration/state/target-dev` | `dev.sh api` | 44 s (cargo 44.24 s) |
| Incremental after touching `nodus-backend/crates/api/src/lib.rs` | same | 2.5 s cargo / 3 s wall |
| Edit a `.rs` file to the new binary serving a request | edit, restart `dev.sh api`, poll `/healthz` | 9.1 s |
| Trunk rebuild after touching `web/crates/ui/src/lib.rs` | `trunk build` (release) | 244 s (cargo 127 s + wasm-opt download 30 s) |
| Same rebuild in debug | `trunk build --release=false` | 90 s (cargo 78 s) |

The edit-to-served number covers compiling the changed `api` crate, restarting
the process, re-running migrations, and binding the port. The 9.1 s is the
real loop: save, wait about ten seconds, reload.

The web number is bad and the cause is deliberate: `web/Cargo.toml` sets the
release profile to `opt-level = "z"`, `lto = true`, `codegen-units = 1`, and
Trunk runs `wasm-opt -Oz`. A first build additionally downloads `wasm-opt`
(about 30 s). Debug is 90 s, still dominated by the size of the Leptos graph.
There is no `sccache` on this host. Treat web rebuilds as a minutes-scale
operation, not a save-and-reload one.

## What the host loop cannot do

- **No Rust hot reload.** There is no file watcher. Cargo builds when you run a
  mode, and the running process keeps the binary it started with. After an edit:
  stop the mode, run it again. `trunk serve` does reload the browser, but its
  rebuild still costs the release-profile time above.
- **No federation or peers.** The peers and their DNS only exist in the full
  stack. Outbox delivery logs `error sending request for url
  (https://mastodon.test/inbox)` and similar warnings; they are expected.
- **No HTTPS and no lab CA.** Loopback is plain HTTP.
- **The SSR host cannot sign in against the loopback API.** `dev.sh web --ssr`
  builds the bundle and runs `nodus-web-server`, but
  `web/crates/web-server/src/validate.rs` only accepts an `https` public
  instance URL and rejects `localhost`/`127.0.0.1`. The shell renders; use
  `trunk serve` for actual client work.
- **The database is shared with the containers.** The host API applies
  migrations to the lab database, so a schema change is visible to the full
  stack (and vice versa). `integration/scripts/reset.sh` drops the volume for
  both loops.

## Traps

**Postgres keeps the password it was initialised with.** `initdb/00-nodus.sh`
sets the `nodus` role password once, when the named volume is empty. The
volume (`nodus-lab_postgres-data`, owned by uid 999) survives `down`, `reset.sh`
does not remove `integration/.env`, and an `.env` regenerated or restored from
elsewhere will not match. The symptom is
`password authentication failed for user "nodus"`. `dev.sh` now probes the
credentials and prints the in-place fix:

```sh
docker exec nodus-lab-postgres psql -U postgres \
  -c "ALTER ROLE nodus PASSWORD '<value from integration/.env>'"
```

Do not bind-mount a host directory over `/var/lib/postgresql/data` unless it is
owned by `999:999`; Postgres refuses to start otherwise.

**`.env` secrets persist across runs.** `ensure_env` fills only missing values.
Resetting containers does not rotate secrets, and copying an `.env` between
checkouts carries the old database password with it.

**`integration/.env` may be rewritten to CI ports.** The workflow/act step sets
`NODUS_HTTP_PORT=18090` and `NODUS_HTTPS_PORT=18453`; the tracked README uses
`18080`/`18443`. Containers created before the rewrite keep the old mappings, so
`docker ps` and `.env` can disagree. Check both before debugging a connection.

**Root-owned files after an `act` run.** act runs as root and writes through the
host mounts, so `integration/volumes/build-context`, `web/dist`, `target/`, and
similar paths can become root-owned. The host loop avoids the shared backend
`target/` by using `integration/state/target-dev`. Fix ownership with
`sudo chown -R "$USER":"$USER" integration/volumes web/dist target` before
blaming cargo.

**Port 5432 is not free.** An unrelated `nodus-postgres-1` runs on the host.
The dev database deliberately uses `55432`; change it with
`NODUS_DEV_DB_PORT` if that collides too. The same applies to the API and web
ports (`NODUS_DEV_API_PORT`, `NODUS_DEV_WEB_PORT`).
