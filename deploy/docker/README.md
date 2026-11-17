# One container, one origin

`Dockerfile.aio` builds an image that runs a whole Nodus instance: Postgres, the server, the
server-rendered shell and the client bundle, behind one nginx listener on port 8080. It is the
smallest thing that behaves like an instance — the same routing the reference deployment puts
in front of the boxes, folded into one process tree.

```
docker build -f deploy/docker/Dockerfile.aio -t nodus:aio .
docker run -d -p 8080:8080 \
  -e NODUS_DOMAIN=nodus.example \
  -e NODUS_BASE_URL=https://nodus.example \
  -v nodus-data:/var/lib/nodus \
  -v nodus-postgres:/var/lib/postgresql/data \
  nodus:aio
```

## What it starts

`entrypoint.sh` initialises the cluster on first boot (password generated once into
`/var/lib/nodus/db-password`), creates the `nodus` role and database with the `citext` and
`pg_trgm` extensions the migrations expect, then runs the backend with `--roles=api,scan,prune`,
the SSR shell, and nginx. `tini` reaps and forwards the stop signal; the first child to exit
ends the container, so a crashed backend is not hidden behind a live nginx.

## One container, several roles

The container runs the API, the scanner worker, the pruner and the recommendation engine in
one process, the shell beside it and nginx in front of both. `NODUS_ROLES` trims that list:

```console
docker run -e NODUS_ROLES=scan nodus:aio
```

A list without `api` starts no shell and no ingress, because a container that serves nothing
has nothing to publish; it still starts Postgres, which is what makes the image an
all-in-one box rather than a worker image. For a worker on a machine of its own, run the
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
| `RUST_LOG` | `info` | Backend log filter |

## Notes

- nginx routes in the same order the reference Caddyfile does: the shell owns `/api/session*`
  and `/oauth/callback`, the backend owns `/oauth`, `/auth`, `/users`, `/inbox`, `/statuses`,
  `/media`, `/.well-known`, `/api` and the instance's own icon paths, and the hashed bundle is
  served from `/srv/nodus`. The icon locations have to come before the asset rule, which would
  otherwise look for `/icon.svg` inside the bundle.
- `--include=optional` is not enough for `@tailwindcss/oxide` on bookworm: npm 9 drops the
  platform binary the lockfile names, so the image installs `@tailwindcss/oxide-linux-x64-gnu`
  at the version npm resolved.
- The bundle build does not need the Rust toolchain's host target, but the two binary stages do:
  the backend reaches into `sdk/` and `server-sdk/` by path, so all three trees are copied.
