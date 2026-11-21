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
- `DOCKER_HOST=tcp://127.0.0.1:2375` — so the `lab` job's `docker build` and
  `docker compose` use the dind daemon instead of the host's socket;
- `--network host` for the `lab` job (and a whole-workflow run), because its
  published ports (18080, 18443) and the nested e2e container need the host
  network. Jobs that only need a service container (`rust-tests` and its
  `postgres` service) run on act's bridge network, where the service hostname
  resolves.

Act is installed into `~/.local/bin` on first use (`ACT_VERSION`, default
0.2.98). Logs land in `integration/.act/` (git-ignored). The dind image layer
cache lives in a named volume, so repeated runs rebuild less; `CI_KEEP_DIND=1`
leaves the daemon up between invocations.

## Prerequisites

| what | why |
| --- | --- |
| docker daemon | act, dind and the lab's images |
| ~10 GB free disk | `catthehacker/ubuntu:act-24.04`, `rust:1-bookworm`, `pgvector/pgvector:pg17`, the lab images, dind's layer cache |
| network (first run) | act binary, runner image, node toolchain, Playwright/Chromium, crates |
| `LAB_HTTP_PORT` | optional; forwarded to the lab job. This checkout uses 18080 so it does not collide with the root-owned Caddy on 8080 |
| `NODUS_HTTPS_PORT` | optional; forwarded for Caddy's 443 (default 18443) |

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
  `actions/setup-node` caches either miss or are per-run. Timings and cold-path
  failures differ; a cold local run is the closer analogue.
- **Service containers** are act's implementation, not GitHub's; health checks
  and DNS can behave differently.
- **The `cargo metadata --locked --offline` advisory step fails under act**,
  because the act runner image has no cargo. It is `continue-on-error` in the
  workflow, so it does not gate, but its signal is absent locally (the workflow
  comment says the same about a cold GitHub registry).
- **Disk and CPU** are this host's, not the runner's. The `lab` job's free-disk
  step deletes paths that may not exist; that is harmless but does not recreate
  GitHub's disk budget.
- **Secrets and variables** are whatever is exported in the shell. The workflow
  currently reads none, but `ci.sh` forwards `LAB_HTTP_PORT` and
  `NODUS_HTTPS_PORT` only.

[nektos/act]: https://github.com/nektos/act
