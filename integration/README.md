# The Nodus integration lab

A disposable, single-origin Nodus instance in Docker: the API, its worker
processes, the trunk-built web client, the SSR shell and Caddy, on top of real
Postgres and Valkey. Everything runs over plain HTTP, the database lives in a
named volume, and `scripts/reset.sh` throws the whole thing away.

The point is a deployed artifact to test against — the same binaries and the
same `dist/` the images carry, built from the commits the superproject records.
For day-to-day work, `scripts/dev.sh` runs the code on the host against the
lab's Postgres and Valkey while the infrastructure stays in containers; see
`docs/dev-loop.md`. The two loops share one database volume.

```text
integration/
  compose.yml            the single-origin stack (project name `nodus-lab`)
  compose.dev.yml        publishes Postgres/Valkey on loopback for the host loop
  compose.peers.yml      federation peers, added by the peers task
  Dockerfile.server      the six nodus binaries
  Dockerfile.web         the trunk bundle + the SSR host (+ Caddy binary)
  Caddyfile              route ownership for the whole origin
  initdb/00-nodus.sh     the `nodus` role, database and extensions
  .env.example           every knob, no secrets
  scripts/               build, up, down, reset, seed, e2e, ci, dev
  docs/dev-loop.md       host loop vs full stack, timings, traps
  e2e/                   Playwright specs and baselines; run via scripts/e2e.sh
```

## Quick start

```sh
integration/scripts/build.sh      # build both images from the pinned commits
integration/scripts/up.sh         # build if needed, start, wait for health
integration/scripts/seed.sh       # admin + ada + grace, their posts and follows
integration/scripts/e2e.sh        # Playwright in the pinned container image
```

CI runs those same checks locally, through nektos/act, because GitHub runner
minutes are expensive: `integration/scripts/ci.sh all`. The workflow is
`workflow_dispatch` only; see `docs/ci.md` for stages, prerequisites and what a
local green run does not prove.

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

## The lab CA

Caddy terminates TLS for `nodus.test`, `mastodon.test` and `misskey.test` with its own
internal authority. The authority lives on the `nodus-data` volume, which
`reset.sh` drops, so every reset mints a **new** root: same subject
(`CN=Caddy Local Authority - 2026 ECC Root`), different key. The root is
therefore generated, never committed, at `integration/state/ca/nodus-lab-ca.crt`
(git-ignored), and the only thing that writes it is:

```sh
integration/scripts/ca.sh export    # reads /var/lib/nodus/caddy/pki/authorities/local/root.crt
integration/scripts/ca.sh require   # fails unless the file is caddy's current root
```

`up.sh` starts caddy alone first, exports the root, and only then creates the API,
the workers and (through `peers.sh up`) the two peers, because all of them build
their trust bundle from that file at start. No manual copying is part of any
workflow.

When trust breaks — `BadSignature` in `nodus-api` fetching `https://mastodon.test`,
or a peer that cannot deliver to the origin — re-run `up.sh` (and `peers.sh up`),
or with the core lab already running, `ca.sh export` and restart `nodus-lab-api`
and the peers. A restart is needed because the bundles are built once at start;
this is also why a `reset.sh` right after a CA change needs the peers restarted.
`docs/peers.md` ("The internal CA", "When trust breaks") has the full chain.

## Ports, URLs, credentials

| what | value |
| --- | --- |
| origin (host, Node-side requests) | `http://localhost:8080` — this checkout uses **18080**, see below |
| origin (browser) | `https://nodus.test` — resolved to `NODUS_HTTPS_PORT` by Playwright |
| origin (in the `nodus-lab` network) | `http://nodus.test:8080` |
| admin | `admin@nodus.test` / `nodus-lab-admin` (from `.env`) |
| ordinary account | `ada@nodus.test` / `lab-password-ada` |
| ordinary account | `grace@nodus.test` / `lab-password-grace` |
| Postgres | `postgres:5432` inside the network only, role `nodus`, database `nodus` |
| Valkey | `valkey:6379`, `requirepass` from `.env` |

`NODUS_HTTP_PORT` is the only host-port knob (default `8080`).
`http://nodus.test:8080` is Caddy's network alias, so the origin is stable for peers
and for federation identity even when the host port changes.

This checkout sets `NODUS_HTTP_PORT=18080` in the untracked `integration/.env`
because a root-owned podman Caddy on this machine already holds host port 8080.
That container is not ours and is never touched. Everything below works
unchanged; the e2e script reads the same value from
`integration/.env` (`scripts/e2e.sh` derives `LAB_BASE_URL` from it):

```sh
integration/scripts/e2e.sh
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

Playwright runs **inside the official Playwright image against the Caddy
origin**, through `scripts/e2e.sh`. The image tag is derived from the
`@playwright/test` pin in `e2e/package.json` — currently 1.65.0, so
`mcr.microsoft.com/playwright:v1.65.0-noble` — which makes the browser build a
pinned artifact instead of "whatever chromium the machine has".

```sh
integration/scripts/e2e.sh                      # the whole suite
integration/scripts/e2e.sh --project=desktop    # one project
integration/scripts/e2e.sh --grep home          # one test
integration/scripts/e2e.sh --update-snapshots   # rewrite every baseline
```

Every argument is forwarded to `playwright test` (a leading `--` is dropped, so
`e2e.sh -- --project=desktop` is the same as above). The script creates a
`nodus-lab-e2e-node-modules` volume for the container's `node_modules`, runs
`npm ci` into it on every invocation, and mounts the checkout at `/work` with
`--network host`, so the lab is reached at `http://127.0.0.1:$NODUS_HTTP_PORT`
exactly as a host run reaches it. The host `e2e/node_modules` is never touched.
`LAB_BASE_URL`, `LAB_HTTP_PORT` and `LAB_HTTPS_PORT` override the ports; CI
passes `LAB_BASE_URL=http://127.0.0.1:$LAB_HTTP_PORT`.

The suite has two origins on purpose. The browser browses the canonical origin,
`https://nodus.test` (`LAB_ORIGIN`), which `playwright.config.mjs` resolves to
`LAB_HTTPS_PORT` with `--host-resolver-rules`; signing in there is what makes a
handle read `@ada@nodus.test` and a discovery request carry an
`X-Instance-Host` the API accepts. Requests that Playwright issues from node
(`page.request`, `helpers/api.mjs`) cannot use a resolver rule, so they target
`LAB_BASE_URL` instead.

### Visual baselines are container-rendered

The committed PNGs under `e2e/tests/*-snapshots/` are the source of truth for
what the product looks like, and they are **rasterised by the browser in that
image**. Fonts, hinting and antialiasing differ between two Linux hosts: CI run
44871012849 showed `composer-desktop-linux.png` differing by 2427 pixels (ratio
0.02) and `drive-desktop-linux.png` by 7427 pixels (ratio 0.02) between this
machine and the ubuntu-24.04 runner on identical same-platform snapshots. The
`-linux` suffix cannot express that, because both hosts are Linux.

Therefore:

- a host `cd integration/e2e && npx playwright test` is **not authoritative for
the `*-visual.spec.mjs` specs**. A diff there means the host renderer differs;
it says nothing about the product.
- the functional specs may be run either way (the container is still the
reference, because CI uses it).
- a diff inside the pinned image **is** a product difference. Do not paper over
it by raising `maxDiffPixels` or the per-pixel `threshold`.

To refresh a baseline, bring the lab up and seed it first — the baselines
include the seeded graph, so a half-seeded database produces a wrong baseline —
then rewrite from the image and commit the result:

```sh
integration/scripts/up.sh
integration/scripts/seed.sh                 # ada, grace, admin, posts, follows
integration/scripts/e2e.sh --update-snapshots
```

Take the federation baselines with the peers up and delivered
(`scripts/peers.sh up && scripts/peers.sh follow`); the two federation specs
skip without that data and would leave `peer-status-*.png` untouched. Before
committing, run the suite once more **without** `--update-snapshots` and confirm
zero failures: `--update-snapshots` overwrites whatever it renders, so only the
following plain run proves the committed pair is self-consistent.

Projects: `desktop` (1400×900), `tablet` (900×900), `phone` (Pixel 7). Animations
are disabled and the caret hidden for screenshots; a screenshot may differ by at
most 40 pixels, each channel compared with a 0.2 tolerance.

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
rows fewer; after `integration/scripts/peers.sh up` they run. Bring the peers up
before the suite in any run that is meant to cover federation.

Baselines live next to the specs (`tests/*-snapshots/*-linux.png`) and are
committed; they are container-rendered, see above. `scripts/e2e.sh
--update-snapshots` is the only supported way to rewrite them.
`docs/visual-baselines.md` is the short version of this policy for reviewers.

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
- `NODUS_AUTH_SECURE_COOKIES=false` and `NODUS_BASE_URL=http://nodus.test:8080` —
  the lab is HTTP end to end.
- `NODUS_REGISTRATIONS_OPEN=true` — `seed.sh` registers over `/auth/register`.
  The binary parses this as a bool: `1` is rejected at boot.
- `NODUS_DOMAIN=nodus.test` — the identity federation sees. It has to be a
  dotted host name: an ActivityPub origin is a host name, and the API refuses a
  single-label one as `X-Instance-Host` (`crates/api/src/activitypub.rs`,
  `is_disallowed_domain`).
- `NODUS_ALLOW_PRIVATE_HOSTS` — comma-separated hosts the API may dial on
  private addresses; the peers task fills this with `mastodon` and `misskey`.
- `NODUS_DRIVE_SHARE_SECRET`, `TOKEN_ENC_KEY` — capability and worker secret.
- `LAB_BASE_URL` (e2e only) — the host origin node-side requests use.
- `LAB_ORIGIN` (e2e only) — the canonical origin the browser drives, `https://nodus.test`.

## Federation peers

`compose.peers.yml` adds two real fediverse servers to the lab — Mastodon
4.6.3 on `http://127.0.0.1:18081` and Misskey 2026.11.0 on
`http://127.0.0.1:18082` — each with its own database and cache. It joins the
existing `nodus-lab` network (declared `external: true`), keeps container names
prefixed `nodus-lab-`, and relies on the origin being reachable as
`http://nodus.test:8080` inside that network. Peers must not publish 8080 or 5432.

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
- All ten containers healthy, the seed script idempotent, and the Playwright
  suite green with committed, container-rendered baselines.

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
