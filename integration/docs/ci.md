# Running CI locally

The checks live in `.github/workflows/ci.yml`. Pushes do not run it: runner
minutes are expensive, so the workflow is `workflow_dispatch` only. A normal
check runs the same file locally through [nektos/act], with the same runner
image and the same job containers:

```sh
integration/scripts/ci.sh all                  # every job
integration/scripts/ci.sh run --job preflight  # one job
integration/scripts/ci.sh run --job rust-tests
integration/scripts/ci.sh run --job lab
integration/scripts/ci.sh run --job gate
integration/scripts/ci.sh down                 # stop Docker-in-Docker
```

`preflight`, `rust-tests`, `lab` and `gate` are accepted as shorthands, so
`integration/scripts/ci.sh preflight` is the same as
`run --job preflight`. Extra arguments after `--job` are passed to `act`.

## What act actually runs

`ci.sh` starts a privileged `docker:dind` container on
`127.0.0.1:2375` with `--network host`, then executes
`.github/workflows/ci.yml` as a `workflow_dispatch` event with:

- `-P ubuntu-24.04=catthehacker/ubuntu:act-24.04` — the runner image closest to
  GitHub's `ubuntu-24.04`;
- `--bind` — the workspace is bind-mounted into the job container, not copied
  into it. act's default `docker cp` of this checkout copies the build output
  too (`nodus-backend/target` is 128 GB, `web/target` 136 GB), which is where
  the first `rust-tests` attempt died before its first step; the bind also
  means the container's cargo compiles into the same `target/` a local
  `cargo test` uses, so the two share a compile instead of each paying for one.
  The price is that the container runs as root and leaves root-owned files in
  `target/`; `ci.sh` reclaims them at the end of every run instead of leaving it to
  `sudo chown -R`;
- `DOCKER_HOST=tcp://127.0.0.1:2375` — so the `lab` job's `docker build` and
  `docker compose` use the dind daemon instead of the host's socket;
- `CARGO_HOME=integration/.act/cargo-home` — cargo would otherwise keep its
  registry and git checkouts in the image's `/usr/local/cargo`, which dies with
  the job container. The path is on the `--bind` mount, so the next `rust-tests`
  run reuses the crates the first one downloaded (466 of them on this
  checkout) instead of fetching them again. `target/` needs no help: the bind
  puts the checkout at its own host path, so the container compiles into the
  same 174 GB `nodus-backend/target` a host `cargo test` uses. This is a local
  stand-in for `Swatinem/rust-cache`, not the same mechanism: `ci.yml` skips
  that action under act (`if: ${{ !env.ACT }}`, because `rust:1-bookworm` ships
  no node), and act's cache server only serves JavaScript actions, so there is
  no GitHub cache to restore or key to share. It also replaces the named-volume
  idea: this act build ignores `--container-options` for a job that sets
  `container:`, which is every `rust-tests` container.
- the dind container itself is started with `-v "$REPO_DIR:$REPO_DIR"` — the
  repository at its own absolute path, writable. `--bind` gives the *client*
  the checkout at that path, but the *daemon* is a separate filesystem, so a
  compose bind source like `./Caddyfile` is passed to dind as
  `/var/home/lux/Projects/MastodonReccom/integration/Caddyfile`, which does not
  exist there. The first `docker compose up` of a service with a bind mount
  therefore failed in runc with
  `error mounting "/var/home/lux/Projects/MastodonReccom/integration/Caddyfile" to rootfs at "/etc/caddy/Caddyfile": not a directory`
  (the daemon had auto-created an empty directory for the unseen path). The
  mount is not `:ro`: `integration/scripts/e2e.sh` runs the Playwright image
  with `-v "$REPO_DIR:/work"` against this daemon, and the suite writes
  `test-results/` and `playwright-report/` into the tree through it;
  `ci.sh up` replaces a running dind that lacks the mount, so an old container
  does not keep failing;
- `--network host` for the `lab` job (and a whole-workflow run), because its
  published ports (the workflow's `LAB_HTTP_PORT` and `LAB_HTTPS_PORT`, 18090
  and 18453) and the nested e2e container need the host network. Jobs that only
  need a service container (`rust-tests` and its `postgres` service) run on
  act's bridge network, where the service hostname resolves.

  The pair is deliberately not the developer defaults (8080/18443, or this
  checkout's 18080): dind shares the host network namespace, so a lab started
  with `integration/scripts/up.sh` holds the same ports and the run died with
  `failed to bind host port 0.0.0.0:18443/tcp: address already in use`. With a
  pair of its own, a local stack can stay up during a CI run. `ci.sh` reads the
  pair out of the workflow and checks both with `ss` before starting act, so a
  collision is named up front instead of surfacing from inside dind.

Act is installed into `~/.local/bin` on first use (`ACT_VERSION`, default
0.2.98). Logs land in `integration/.act/` (git-ignored).

`act` runs the job container as root, and `--bind` (plus dind's copy of the
same path) means its writes land in this checkout owned by root —
`nodus-backend/target`, `web/target`, `integration/state`, the e2e
`test-results`/`playwright-report` directories, and `web/dist`. A host-side
`cargo test` during the first local runs then failed with `Permission denied`,
which is why `ci.sh` ends every `run` with a reclaim:

```sh
docker run --rm -v "<path>:/t" alpine:latest chown -R "$(id -u):$(id -g)" /t
```

for each existing path in `RECLAIM_PATHS`, followed by one line naming what was
handed back. The named volumes (`nodus-act-dind-data`, e2e `node_modules`) are
out of scope: they never appear in the checkout.

The dind daemon's `/var/lib/docker` is the named volume
`nodus-act-dind-data`, and `ci.sh down` removes the container without `-v`, so
the volume survives: a second `lab` run reuses the cached Postgres, Playwright
and lab base images instead of pulling them again. `CI_KEEP_DIND=1` goes
further and leaves the daemon itself up between invocations. Note the split:
act starts the *job* and *service* containers (the `catthehacker` runner,
`rust:1-bookworm`, `pgvector/pgvector:pg17`) on the host daemon, so those layers
are cached by docker there; only the images the `lab` job builds and pulls
through `DOCKER_HOST` live in the dind volume.

## Prerequisites

| what | why |
| --- | --- |
| docker daemon | act, dind and the lab's images |
| ~10 GB free disk | `catthehacker/ubuntu:act-24.04`, `rust:1-bookworm`, `pgvector/pgvector:pg17`, the lab images, dind's layer cache |
| network (first run) | act binary, runner image, node toolchain, Playwright/Chromium, crates |
| `LAB_HTTP_PORT`, `LAB_HTTPS_PORT` | not environment knobs: the workflow's own `env:` (18090/18453), so the CI lab does not collide with a developer stack. Every consumer derives from them — the `point the lab at the CI port` step writes `NODUS_HTTP_PORT`/`NODUS_HTTPS_PORT` into `integration/.env`, `integration/scripts/e2e.sh` reads that file back, and `LAB_BASE_URL` is built from `LAB_HTTP_PORT`. Change them in `ci.yml`. The step rewrites those two lines only: a local run keeps the `.env` its dind volumes were initialised from, because `up.sh`'s `ensure_env` generates the passwords on first use and the postgres volume outlives a run |

## Stages, what they need, rough duration

Durations below are from a warm local run on this host; a cold run pays image
pulls and a full cargo compile.

| job | what it does | needs | warm duration |
| --- | --- | --- | --- |
| `preflight` | asserts the `server-sdk` gitlink is `8baa97d…`; advisory skip-policy source scan; advisory `cargo metadata --locked --offline` | runner image, node 22 download | ~40 s (first run ~3.5 min: image + node download) |
| `rust-tests` | `citext`/`pg_trgm` in the service database, ffmpeg, `cargo test --workspace`, then `cargo check` of `sdk/`, `web/` (minus the wasm crate) and the wasm crate | `rust:1-bookworm`, `pgvector/pgvector:pg17`, a compile | 10–20 min cold, several minutes warm |
| `lab` | builds the images from the pinned gitlinks, starts the stack, seeds, runs `integration/e2e`, extracts `web/dist` from the web image, runs `web/e2e`, enforces the skip allowlist | dind, all lab images, Chromium cache | 15–30 min cold, ~5–10 min warm |
| `gate` | fails unless `rust-tests` and `lab` succeeded | the two jobs' results | seconds |

## What a local run does NOT prove

- **The runner image is not GitHub's.** `catthehacker/ubuntu:act-24.04`
  approximates `ubuntu-24.04`; preinstalled tools, versions and apt state can
  differ. A green local run is not evidence that the dispatched run is green.
- **`actions/*` are fetched at run time**, not pinned by SHA in the workflow;
  act may resolve a newer release than the runner would, or vice versa.
- **Caches are not GitHub's.** `actions/cache`, `Swatinem/rust-cache` and
  `actions/setup-node` caches either miss or are per-run. The `rust-tests` job
  skips `rust-cache` entirely under act (`!env.ACT`), so a local run restores
  nothing from GitHub; it reuses `CARGO_HOME=integration/.act/cargo-home` and
  the bind-mounted `target/` from the previous local run instead. Those are
  local, not keyed like GitHub's cache: a local warm run says nothing about
  whether the dispatched run's restore key hits. A cold local run is still the
  closer analogue of a GitHub miss.
- **A JavaScript action runs in a different place.** GitHub executes a JS
  action on the runner host, which has node; act executes it inside the job
  container with `docker exec node …`. The runner-image jobs (`preflight`,
  `lab`) are fine, because `catthehacker/ubuntu:act-24.04` ships node.
  `rust-tests` runs in `rust:1-bookworm`, which ships none, so its
  `Swatinem/rust-cache@v2` step died with `exec: "node": executable file not
  found in $PATH` before the first `cargo` command. That step now carries
  `if: ${{ !env.ACT }}` — act exports `ACT=true`, GitHub leaves it unset — so
  the dispatched run still restores and saves the cache while a local run skips
  it. The trade-off is that the dispatched run becomes the only place the cache
  key and the restore path are exercised, so a broken key or a broken restore
  would not be caught locally. The same split stopped the job at its later
  `actions/setup-node@v4` step, which that image cannot run either. That step is
  now guarded the same way, with an act-only `curl`-and-`apt` step after it
  installing node 22 from NodeSource inside the container (bookworm's own
  `nodejs` is 18, below `@tailwindcss/oxide` 4.x's `>= 20`), so local runs get
  the npm that `web-client/build.rs` panics without. The consequence: node
  comes from NodeSource under act and from the tool cache on GitHub, so a
  problem with the tool-cache key or a pinned version on GitHub is still only
  caught by a dispatched run. This was the second JS-action escape, so the rule
  is now explicit: **any JavaScript action in a job whose `container:` ships no
  node must carry an `if: ${{ env.ACT }}` branch that provides it**, or the job
  needs an image with node in it.
- **Service containers** are act's implementation, not GitHub's; health checks
  and DNS can behave differently.
- **The `cargo metadata --locked --offline` advisory step fails under act**,
  because the act runner image has no cargo. It is `continue-on-error` in the
  workflow, so it does not gate, but its signal is absent locally (the workflow
  comment says the same about a cold GitHub registry).
- **Disk and CPU** are this host's, not the runner's. The `lab` job's free-disk
  step deletes paths that may not exist; that is harmless but does not recreate
  GitHub's disk budget.
- **Artifacts cannot be uploaded.** `actions/upload-artifact@v4` needs the
  `ACTIONS_RUNTIME_TOKEN` and the artifact service that only GitHub runs; under
  act the step fails with
  `❗ ::error::Unable to get the ACTIONS_RUNTIME_TOKEN env variable`. It runs
  `if: always()`, so that failure used to flip an otherwise green `lab` red on
  every local run, which made the job's colour useless as a signal. The step is
  now `if: ${{ !env.ACT && always() }}`: act exports `ACT=true`, GitHub leaves
  it unset, so a dispatched run still uploads `lab-reports` (on failure too)
  and a local run skips the step. `lab` can therefore be fully green locally,
  and the only difference from a dispatched run is that nothing was uploaded:
  `ci.sh` prints, at the end of a run that included `lab`, that the reports
  stayed on disk at `integration/e2e/playwright-report` and
  `web/e2e/playwright-report`. `ci/gate` remains GitHub-only for the same
  reason: it aggregates the `needs` results, and locally the `lab` result now
  depends on a step (the upload) that only GitHub executes, so a local gate
  green would be certifying a workflow shape the runner never runs.
- **Secrets and variables** are whatever is exported in the shell. The workflow
  currently reads none.

[nektos/act]: https://github.com/nektos/act
