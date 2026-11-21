# The Nodus integration lab

A disposable, single-origin Nodus instance in Docker: the API, its worker
processes, the trunk-built web client, the SSR shell and Caddy, on top of real
Postgres and Valkey. Everything runs over plain HTTP, the database lives in a
named volume, and `scripts/reset.sh` throws the whole thing away.

The point is a deployed artifact to test against — the same binaries and the
same `dist/` the images carry, built from the commits the superproject records —
not a `cargo run` on the host.

```text
integration/
  compose.yml            the single-origin stack (project name `nodus-lab`)
  compose.peers.yml      federation peers, added by the peers task
  Dockerfile.server      the six nodus binaries
  Dockerfile.web         the trunk bundle + the SSR host (+ Caddy binary)
  Caddyfile              route ownership for the whole origin
  initdb/00-nodus.sh     the `nodus` role, database and extensions
  .env.example           every knob, no secrets
  scripts/               build, up, down, reset, seed
  e2e/                   Playwright on the host, against the Caddy origin
```

## Quick start

```sh
integration/scripts/build.sh      # build both images from the pinned commits
integration/scripts/up.sh         # build if needed, start, wait for health
integration/scripts/seed.sh       # admin + ada + grace, their posts and follows
cd integration/e2e && npm install && npx playwright test
```

Stop and start again without losing the database:

```sh
integration/scripts/down.sh       # containers and network go, volumes stay
integration/scripts/up.sh --skip-build
```

Start over from an empty database:

```sh
integration/scripts/reset.sh      # drops containers, network and the volumes
integration/scripts/up.sh --skip-build && integration/scripts/seed.sh
```

`reset.sh` refuses to run when a `nodus-lab` container was not created by this
checkout's `compose.yml` (it inspects
`com.docker.compose.project.config_files`), and every script pins
`--project-name nodus-lab`. There is no `docker compose down -v` in the scripts:
the only destructive command is `compose down --volumes` behind that guard.

## Ports, URLs, credentials

| what | value |
| --- | --- |
| origin (host) | `http://localhost:8080` — this checkout uses **18080**, see below |
| origin (in the `nodus-lab` network) | `http://nodus:8080` |
| admin | `admin@nodus.test` / `nodus-lab-admin` (from `.env`) |
| ordinary account | `ada@nodus.test` / `lab-password-ada` |
| ordinary account | `grace@nodus.test` / `lab-password-grace` |
| Postgres | `postgres:5432` inside the network only, role `nodus`, database `nodus` |
| Valkey | `valkey:6379`, `requirepass` from `.env` |

`NODUS_HTTP_PORT` is the only host-port knob (default `8080`).
`http://nodus:8080` is Caddy's network alias, so the origin is stable for peers
and for federation identity even when the host port changes.

This checkout sets `NODUS_HTTP_PORT=18080` in the untracked `integration/.env`
because a root-owned podman Caddy on this machine already holds host port 8080.
That container is not ours and is never touched. Everything below works
unchanged; the e2e suite reads the same value from `LAB_BASE_URL`:

```sh
cd integration/e2e
LAB_BASE_URL=http://127.0.0.1:18080 npx playwright test
```

## Containers

All containers are named `nodus-lab-*`; nothing publishes 5432.

| service | container | image | port | health |
| --- | --- | --- | --- | --- |
| `postgres` | `nodus-lab-postgres` | `pgvector/pgvector:pg17` | 5432 (internal) | `pg_isready` |
| `valkey` | `nodus-lab-valkey` | `valkey/valkey:8.1-bookworm` | 6379 (internal) | `valkey-cli ping` |
| `nodus-api` | `nodus-lab-api` | `nodus-lab/server:0.1.0` (role `api`) | 3000 | `/healthz` |
| `nodus-media-worker` | `nodus-lab-media-worker` | same image, role `media-worker` | 3003 | `GET /media/default-avatar.png` |
| `nodus-feed` | `nodus-lab-feed` | same image, role `feed` | 3000 | `GET /api/v1/meta` |
| `nodus-scan` | `nodus-lab-scan` | same image, role `scan` | 3000 | none: gRPC worker, no HTTP surface |
| `nodus-prune` | `nodus-lab-prune` | same image, role `prune` | 3000 | none: gRPC worker |
| `nodus-calc` | `nodus-lab-calc` | same image, role `calc` | 3000 | none: gRPC worker |
| `nodus-web` | `nodus-lab-web` | `nodus-lab/web:0.1.0` | 3000 | `/healthz` |
| `caddy` | `nodus-lab-caddy` | `nodus-lab/web:0.1.0` | **8080 → host**, 443 in-network | `/healthz` through the proxy |

One image per role rather than one all-in-one container: a test can restart a
single process (`docker restart nodus-lab-feed`) without losing the others. The
entrypoint logic is the reference one from
`nodus-backend/deploy/docker/Dockerfile.aio` (tini, one process per container),
and `initdb/00-nodus.sh` mirrors its Postgres bootstrap: role `nodus`, database
`nodus`, `citext` and `pg_trgm`.

Every role runs migrations at boot. The bootstrap admin is passed **only** to
`nodus-api`, because several roles provisioning the same account at once trips
the unique index on `account.local_username`.

## Route ownership (Caddy)

One origin, one route table (`integration/Caddyfile`), copied from
`nodus-backend/deploy/docker/Caddyfile`:

- the web shell owns `/api/session*`, `/oauth/callback*`, `/public-api/*`;
- `nodus-feed` owns `/api/v1/meta`, `/api/v1/feed/*`, `/api/v1/browse`,
  `/api/v1/events`, `/api/v1/feedback/*`, `/api/v1/me`, `/api/v1/sync/*`, `/s/*`;
- the API owns `/healthz`, `/readyz`, the icons, `/media/*` and everything else
  under `/api`, plus `/oauth`, `/auth`, `/users`, `/inbox`, `/statuses`,
  `/media` and `/.well-known`;
- hashed bundles under `/s/` are cached immutably; everything else falling
  through is the SSR shell, `no-store`.

Lab-only addition: `/api/v1/healthz` is rewritten to the API's `/healthz`. The
server has no `/api/v1/healthz` route; the alias exists so `scripts/up.sh` and
CI can wait on one stable readiness URL.

`NODUS_DRIVE_SHARE_SECRET` is set, so `/api/v1/meta` publishes `drive_share` and
`POST /api/v1/drive/files/{id}/share` works.

## How the images are built

`scripts/build.sh` does not build the working trees. It runs
`git ls-tree HEAD` in the superproject for every submodule and materialises a
temporary context with `git archive <pin>` for each one, plus `deploy/` from the
superproject, and prints what it resolved:

```text
resolving pinned commits ...
  nodus-backend  16a5ce20097e1129cc4e10e51ff5f168fd00481e
  recommender    352cf507aebc3e23a8ef1d0329d8c91af638cb1d
  sdk            b32b53275fe754498dcf4f97584412ff4bf77eb8
  server-sdk     8baa97d61a10971ab8d609410c9bb226aef4a9bb (lab override; the gitlink records dba7629…)
  web            2428dfe86dbf6cd5ee5bf39f06a1815a9683f5c3
```

That output is part of a green run: a dirty submodule prints a warning and a
HEAD/pin mismatch note, so nobody can mistake a passing lab for coverage of
uncommitted work.

The `server-sdk` override exists because the recorded pins disagree:
`nodus-backend` 16a5ce2 imports `HttpSigner`, which only exists from
`server-sdk` 8baa97d. The override is one variable at the top of
`scripts/build.sh`; delete it once `git ls-tree HEAD server-sdk` reports 8baa97d
which the CI preflight already requires.

Two escape hatches:

- `LAB_BUILD_FROM_WORKTREE=1 integration/scripts/build.sh` builds the
  superproject root as it stands, for testing uncommitted work.
- `LAB_DOCKER_BUILD_ARGS="--build-arg NAME=value ..."` appends arguments to the
  `docker compose build` invocation (word-split). Empty by default, so the
  command stays exactly `docker compose build`.

Cargo builds **without `--locked`**: `nodus-backend/Cargo.lock` predates the
`sdk`/`server-sdk` pins and `--locked` fails before compiling. Resolution
happens inside the image layer and the lock file is not committed back.

Requirements: Docker with BuildKit, ~6 GB of free disk for the two images, and
network access on the first build (crates.io, trunk and wasm-opt release
archives). The builder stages are `rust:1-bookworm`; the web bundle stage adds
node 22 and trunk 0.21.14, and pins wasm-opt to `version_123` (the tool trunk
downloads by default is newer than bookworm's glibc allows).

## The e2e harness

Playwright runs on the host against the Caddy origin. Browsers are the ones
already in `~/.cache/ms-playwright`: `@playwright/test` is pinned to 1.65.0 so
`npm install` never pulls a different chromium.

```sh
cd integration/e2e
npm ci
LAB_BASE_URL=http://127.0.0.1:18080 npx playwright test
```

Projects: `desktop` (1400×900), `tablet` (900×900), `phone` (Pixel 7). Animations
are disabled and the caret hidden for screenshots; diffs are allowed up to 2% of
pixels.

- `tests/home.spec.mjs` — signs in as ada through the real OAuth dance, asserts
  Grace's post in the home timeline, then fetches the same timeline over REST
  with the token the browser stored.
- `tests/profile.spec.mjs` — resolves `grace` by handle, lists her posts and
  checks the follow edge ada→grace, all with ada's token.
- `tests/login-visual.spec.mjs` — the sign-in screen.
- `tests/home-visual.spec.mjs` — the home timeline, with relative timestamps
  masked.

Two specs depend on the federation peers: `tests/federation.spec.mjs` and
`tests/federation-visual.spec.mjs` assert a status the Mastodon peer delivered.
A run that starts only the origin (CI's default `up.sh` + `seed.sh`) stores no
remote account, so both skip themselves with that reason and the suite runs 6
rows fewer; after `integration/scripts/peers.sh up` they run. CI's
`workflow_dispatch` input `peers: true` brings the peers up first.

Baselines live next to the specs (`tests/*-snapshots/*-linux.png`) and are
committed. Regenerate them deliberately, with the stack up and seeded:

```sh
LAB_BASE_URL=http://127.0.0.1:18080 npx playwright test --update-snapshots
```

`helpers/session.mjs` drives sign-in (instance → `/auth/login` → consent →
`/home`) and parses the `nodus.session` record from `localStorage`;
`fixtures.mjs` holds the seeded account constants and post texts. Reuse both in
new specs.

## Configuration

`integration/.env` is generated from `.env.example` on the first `up.sh`,
`build.sh` or `seed.sh`. Every `__GENERATE__` marker is replaced with
`openssl rand -hex 32` (`TOKEN_ENC_KEY` with `openssl rand -base64 32`), and a
key added to `.env.example` later is filled into an existing `.env` without
touching values that are already set. `.env` is git-ignored; secrets are never
committed.

Notable knobs (all documented inline in `.env.example`):

- `NODUS_HTTP_PORT` — the only host port.
- `NODUS_AUTH_SECURE_COOKIES=false` and `NODUS_BASE_URL=http://nodus:8080` —
  the lab is HTTP end to end.
- `NODUS_REGISTRATIONS_OPEN=true` — `seed.sh` registers over `/auth/register`.
  The binary parses this as a bool: `1` is rejected at boot.
- `NODUS_DOMAIN=nodus` — the identity federation sees.
- `NODUS_ALLOW_PRIVATE_HOSTS` — comma-separated hosts the API may dial on
  private addresses; the peers task fills this with `mastodon` and `misskey`.
- `NODUS_DRIVE_SHARE_SECRET`, `TOKEN_ENC_KEY` — capability and worker secret.
- `LAB_BASE_URL` (e2e only) — the origin Playwright drives.

## Federation peers

`compose.peers.yml` adds two real fediverse servers to the lab — Mastodon
4.3.6 on `http://127.0.0.1:18081` and Misskey 2024.11 on
`http://127.0.0.1:18082` — each with its own database and cache. It joins the
existing `nodus-lab` network (declared `external: true`), keeps container names
prefixed `nodus-lab-`, and relies on the origin being reachable as
`http://nodus:8080` inside that network. Peers must not publish 8080 or 5432.

Use the script, not raw compose: it fills the peer secrets in `.env` and runs
the setup and seeding steps in order.

```sh
integration/scripts/peers.sh up      # start, generate secrets, wait for health
integration/scripts/peers.sh seed    # alice@mastodon.test, alice@misskey.test
integration/scripts/peers.sh status
integration/scripts/peers.sh follow  # the federation directions
integration/scripts/peers.sh down    # stop, keep peer data
```

Seeded credentials and API tokens land in `integration/state/*-account.json`
(git-ignored) and survive `down.sh` + `up.sh`; `reset.sh` drops the peer
volumes and the accounts with them. `docs/peers.md` covers the topology, the
trust decisions, what a browser needs for the peer UIs, the Sidekiq
`letter_opener` initializer, and the origin-side blocker that keeps the
follow-direction proofs from running today.

## What works today

- The deployed bundle from the pinned `web` commit boots and hydrates: the wasm
  and the stylesheet are served from `/s/`, the SPA loads, and hydration errors
  are gone.
- Sign-in through the real OAuth + PKCE flow (SPA registers a client, the API's
  `/auth/login` form, consent, token exchange) with a browser session that
  survives client-side navigation.
- Home, Local and Federated timelines; follow graph; posting; the account's own
  profile; `/api/v1/meta` capability handshake; drive share links.
- All ten containers healthy, the seed script idempotent, and 12 Playwright
  tests green: two functional specs and two visual specs across desktop, tablet
  and phone, with committed baselines.

## Honest limitations

1. **Profile and status pages need https.** The web shell renders
   `/@handle` through `/public-api/*`, which only talks to public https
   instances (`web/crates/web-server/src/validate.rs` rejects any other scheme
   and any loopback host, and `public_api.rs` hardcodes `https://{host}`). On an
   http loopback origin those requests answer 400 and the screen says
   *"The instance could not be reached: HTTP 400"*. The profile spec therefore
   covers the profile *data* over the API, not the profile screen. No env knob
   changes this; it needs a web change.
2. **A full reload while signed in fails.** The client stores the bare host and
   the SDK defaults a bare host to `https://`, so after a reload the session
   restore calls `https://127.0.0.1:18080/...` and shows *"could not confirm the
   saved session"*. Specs navigate client-side (links, tabs) after signing in.
3. **The recommended feed cannot reach the origin.** The engine validates
   `X-Instance-Host` and rejects IPs and single-label names
   (`recommender/crates/feeds/src/host.rs`), while the client sends the bare
   host (`127.0.0.1`). `/api/v1/feed/*` answers 400 and the home screen shows an
   orange *"discovery request failed"* banner. The home visual baseline includes
   that banner; it is what the lab really renders.
4. **The SSR sign-in path is unused.** The SSR host sets its session cookie
   `Secure`, so a cookie set over http never comes back; the SPA's
   `localStorage` OAuth session is the working path. `/api/session` also rejects
   loopback hosts.
5. **`scan`, `prune` and `calc` have no healthcheck.** They expose gRPC only.
   `docker compose ps` shows them running, and `up.sh` waits on the API, the
   origin and Postgres instead.
6. **Port 8080 is not free on this machine**, hence 18080 here. On a clean host
   the default is 8080 and `LAB_BASE_URL` is unnecessary.
7. **`cargo build --locked` is unavailable** and the `server-sdk` pin is
   overridden until the superproject gitlink catches up; both are visible in
   the build output rather than hidden.

## Troubleshooting

```sh
docker compose -p nodus-lab --env-file integration/.env -f integration/compose.yml ps
docker compose -p nodus-lab --env-file integration/.env -f integration/compose.yml logs -f nodus-api
curl -s http://localhost:18080/api/v1/healthz
docker restart nodus-lab-feed        # one role at a time, by design
```

If `up.sh` times out, the usual causes are the port being taken (change
`NODUS_HTTP_PORT`), `nodus-calc` missing `TOKEN_ENC_KEY` (the script fills it),
or a bootstrap race from stale volumes (run `reset.sh`).
