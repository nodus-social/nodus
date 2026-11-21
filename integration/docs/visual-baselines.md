# Visual baselines: rendered by the pinned container

The `*-linux.png` files under `integration/e2e/tests/*-snapshots/` are
rasterised by the chromium build in the official Playwright image, pinned to the
`@playwright/test` version in `integration/e2e/package.json`
(`mcr.microsoft.com/playwright:v1.65.0-noble` today). The image tag is derived
by `integration/scripts/e2e.sh`, so the runner and the renderer cannot drift
apart.

## What that means

- A **host** `cd integration/e2e && npx playwright test` is *not authoritative
  for the `*-visual.spec.mjs` specs*. Two Linux hosts have different font
  packages and rasterise the same DOM differently. CI run 44871012849 is the
  evidence: `composer-desktop-linux.png` differed by 2427 pixels (ratio 0.02 of
  all pixels) and `drive-desktop-linux.png` by 7427 pixels (ratio 0.02) between
  this machine and the ubuntu-24.04 runner, on identical same-platform
  snapshots. `-linux` cannot name that difference.
- A diff **inside** the pinned image is a real product difference. Never make it
  pass by raising `maxDiffPixels`, `maxDiffPixelRatio` or `threshold`; explain
  the pixels instead.
- The functional specs may run either way. The container is still the reference
  because CI uses it.

## Refreshing a baseline

The seeded graph is part of the screenshot (ada's home shows grace's post,
notifications show a favourite), so a baseline taken against an empty or
half-seeded database is wrong.

```sh
integration/scripts/up.sh
integration/scripts/seed.sh
integration/scripts/peers.sh up && integration/scripts/peers.sh follow   # federation baselines
integration/scripts/e2e.sh --update-snapshots
integration/scripts/e2e.sh                    # must be 0 failed before committing
```

Commit the PNGs with the change that altered them. Delete a baseline rather
than leaving a pair when the spec stops producing it.

## CI

The workflow runs the same entry point after `up.sh` and `seed.sh`:

```sh
integration/scripts/e2e.sh --retries=0
```

`e2e.sh` forwards every argument to `playwright test` and passes
`LAB_BASE_URL=http://127.0.0.1:$NODUS_HTTP_PORT` to the container, which uses
`--network host`. On a runner that starts only the origin, the two federation
specs skip; the federation baselines are then not exercised, and must be taken
with the peers up.
