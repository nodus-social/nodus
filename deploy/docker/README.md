# One container, one origin

`Dockerfile.aio` builds an image that runs a whole Nodus instance: Postgres, the five services,
the server-rendered shell and the client bundle, behind one Caddy listener on port 8080. It is
the smallest thing that behaves like an instance — the same routing the reference deployment
puts in front of the boxes, folded into one process tree that talks to itself over Unix
sockets instead of the network.

```sh
docker build -f deploy/docker/Dockerfile.aio -t nodus-aio:0.1.0 .
docker run -d -p 8080:8080 \
  -e NODUS_DOMAIN=nodus.example \
  -e NODUS_BASE_URL=https://nodus.example \
  -v nodus-data:/var/lib/nodus \
  -v nodus-postgres:/var/lib/postgresql/data \
  nodus-aio:0.1.0
```

## What it starts

`entrypoint.sh` initialises the cluster on first boot (password generated once into
`/var/lib/nodus/db-password`), creates the `nodus` role and database with the `citext` and
`pg_trgm` extensions the migrations expect, then starts one process per service:

| Process | Socket | Does |
| --- | --- | --- |
| `nodus-api` | `/var/run/app/api.sock` | API, ActivityPub documents, auth pages, uploads |
| `nodus-media` | `/var/run/app/media.sock` | uploaded bytes and their variants |
| `nodus-feed` | `/var/run/app/feed.sock` | recommendations, browsing, sync, unfurling |
| `nodus-scan` | — | turns scanner answers into moderation decisions |
| `nodus-prune` | — | deletes what has expired |
| `nodus-calc` | — | the recommendation engine's heavy half |
| `nodus-web-server` | `/var/run/app/shell.sock` | server-rendered pages |

The workers have no socket of their own: they answer telemetry and on-demand triggers over
`/var/run/app/<name>.sock` gRPC. Caddy owns port 8080 and is the only listener; `tini` reaps and
forwards the stop signal, and the first child to exit ends the container, so a crashed service
is not hidden behind a live ingress.

## One container, several roles

The container runs one process per service and Caddy in front of them. `NODUS_ROLES` trims
that list:

```console
docker run -e NODUS_ROLES=scan nodus-aio:0.1.0
```

A list without `api` starts no shell and no ingress, because a container that serves nothing
has nothing to publish; it still starts Postgres, which is what makes the image an
all-in-one box rather than a worker image. The default is `api,media,feed,scan,prune,calc`. For a worker on a machine of its own, run the
binary against the shared database instead — see `deploy/distributed/README.md`.

## Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `NODUS_DOMAIN` | `localhost` | The domain accounts and URLs are built from |
| `NODUS_BASE_URL` | `http://localhost:8080` | Public origin |
| `NODUS_TITLE`, `NODUS_DESCRIPTION`, `NODUS_CONTACT_EMAIL` | empty | Instance metadata |
| `NODUS_AUTH_SECURE_COOKIES` | unset | Set to `true` behind TLS |
| `NODUS_BOOTSTRAP_EMAIL`, `NODUS_BOOTSTRAP_USERNAME`, `NODUS_BOOTSTRAP_PASSWORD` | unset | First administrator, created once |
| `NODUS_DB_PASSWORD` | generated | Overrides the generated database password |
| `NODUS_ROLES` | `api,media,feed,scan,prune,calc` | Which services this container runs |
| `NODUS_TELEMETRY` | the four worker sockets | Where the API looks for its siblings |
| `NODUS_TELEMETRY_FULL` | unset | Set to `true` to show socket paths instead of `unix socket` |
| `NODUS_TOKEN_ENC_KEY` | generated into `/var/lib/nodus/token-enc-key` | Plus token sealing key |
| `RUST_LOG` | `info` | Backend log filter |

## Notes

- `Caddyfile` routes in the same order the reference Caddy site does: the shell owns `/api/session*`,
  `/oauth/callback` and `/public-api/*`; the engine owns `/api/v1/meta`, `/api/v1/feed/*`,
  `/api/v1/browse`, `/api/v1/events`, `/api/v1/feedback/*`, `/api/v1/me`, `/api/v1/sync/*` and
  `/s/*`; the API owns `/oauth`, `/auth`, `/users`, `/inbox`, `/statuses`, `/media`,
  `/.well-known`, the rest of `/api` and the instance's own icon paths; the hashed bundle is
  served from `/srv/nodus`. The icon locations have to come before the asset rule, which would
  otherwise look for `/icon.svg` inside the bundle.
- `--include=optional` is not enough for `@tailwindcss/oxide` on bookworm: npm 9 drops the
  platform binary the lockfile names, so the image installs `@tailwindcss/oxide-linux-x64-gnu`
  at the version npm resolved.
- The bundle build does not need the Rust toolchain's host target, but the two binary stages do:
  the backend reaches into `sdk/` and `server-sdk/` by path, so all three trees are copied.
