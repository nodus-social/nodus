# Running the parts apart

One binary per service. An instance that fits on one machine runs them all in one container
next to one database; an instance that does not gives each binary its own container or its own
machine, and they meet at the database and at the addresses they are told about — never at a
registry, a broker or a discovery service.

```text
nodus-api     serves HTTP and ActivityPub, and owns media and auth pages
nodus-feed    serves recommendations, browsing, sync and unfurling
nodus-scan    claims scans, calls the scanner services, raises what they find
nodus-prune   deletes expired media, sessions and codes
nodus-calc    the recommendation engine's heavy half: crawling, recomputing, retention
```

Shared code lives in `nodus-backend/crates/*`; the binaries live in `nodus-backend/services/*`.
A worker binds no port at all: it answers telemetry and on-demand triggers over a gRPC socket
of its own, and says so in its log. The only service that speaks HTTP is `nodus-api`
(and `nodus-feed`); everything else talks gRPC.

Inside one container the services reach each other over Unix sockets, which is both faster and
the reason the AIO image publishes exactly one port.

## What they share

The database, and nothing else. Every role connects with `NODUS_DATABASE_URL` and every
role applies the migrations it finds, so a fresh volume can be brought up by any of them;
the winner is decided by the database's own advisory lock, not by start order. The
recommendation engine keeps its tables in a schema of its own (`feeds`), so the engine's
`account`/`status`/`instance` never collide with the core ones.

Queues are tables, so a scan raised by one process is claimed by another without a broker.

## What an operator has to say

| Variable | Meaning |
| --- | --- |
| `NODUS_BIND` | where this service listens: `0.0.0.0:3001`, `127.0.0.1:3001` or `unix:/var/run/app/api.sock` |
| `NODUS_TELEMETRY_SOCKET` / `NODUS_TELEMETRY_BIND` | where this process answers about itself (gRPC); set one, not both |
| `NODUS_NODE_NAME` | the name this process uses in every other process's view (`api`, `scan`, `prune`) |
| `NODUS_TELEMETRY` | the peers to ask, as `name=address` pairs; `unix:` or `tcp://` |
| `NODUS_TELEMETRY_FULL` | `true` publishes socket paths and internal addresses in that view |
| `NODUS_ROLES` | AIO image only: which of the five services its container starts |

An address is a TCP address or a socket path everywhere it appears, and one spelling per
listener is enough: `unix:/run/nodus/api.sock` and `unix:///run/nodus/api.sock` both mean
the same socket, and `127.0.0.1:9091` means a port.

## A two-process instance, verified

The API serves requests; the scanner worker has no address anyone can dial for HTTP.

```console
# scanner worker, machine B
NODUS_DATABASE_URL=postgres://nodus@10.0.1.8/nodus \
NODUS_NODE_NAME=scan \
NODUS_TELEMETRY_SOCKET=tcp://0.0.0.0:9091 \
nodus-scan

# API, machine A: it asks B, and does not care that B is elsewhere
NODUS_DATABASE_URL=postgres://nodus@10.0.1.8/nodus \
NODUS_DOMAIN=nodus.example NODUS_BASE_URL=https://nodus.example \
NODUS_NODE_NAME=api \
NODUS_BIND=unix:/var/run/app/api.sock \
NODUS_TELEMETRY_SOCKET=unix:/var/run/app/api-telemetry.sock \
NODUS_TELEMETRY=scan=tcp://10.0.1.19:9091 \
nodus-api
```

On one host the sockets are enough and nothing is published:

```console
nodus-api    &   # /var/run/app/api.sock, telemetry beside it
nodus-feed   &   # /var/run/app/feed.sock
nodus-scan   &   # /var/run/app/scan.sock
nodus-prune  &   # /var/run/app/prune.sock
nodus-calc   &   # /var/run/app/calc.sock
```

`GET /api/v1/admin/topology` then answers with each service's own numbers, and a worker that
stops answering is reported dead with the reason and the time it was last heard from:

```console
api    unix  healthy  2ms
feed   unix  healthy  2ms
scan   unix  healthy  3ms
prune  unix  healthy  3ms
calc   unix  healthy  2ms
```

`POST /api/v1/admin/topology/{name}/trigger` asks one of them to do its pass now instead of
waiting for the next tick — the durable path is still the queues, this is the impatient one.
The System screen offers the same thing as "Do it now" on each worker card, and shows the
worker's answer as a notice: the pass has been queued, not completed.
The API itself is always in the list, because a console that hides the process it is talking
to cannot show that process failing.

The sockets above are removed when the process stops, and a socket left behind by a killed
process is unlinked by its replacement, so a restart never fails on "address already in use".

## Ingress

Only the ingress publishes a port. It proxies the API's paths to `NODUS_BIND` and, behind a
socket, adds the caller's address (`x-forwarded-for`) because a socket cannot report it.
The paths that are not the shell's own are the ones the backend answers — the AIO image's
`deploy/docker/Caddyfile` and the production Caddy site are both examples of that split, and neither
needs to know whether the API is behind a socket or a port.

The shell (`nodus-web-server`) serves the first page and `/api/session`; the bundle it
paints is served by the ingress from `/srv/nodus`.

## Checking a split deployment

```console
curl -fsS http://127.0.0.1:3001/readyz          # the API is up and migrated
curl -fsS --unix-socket /var/run/app/api.sock http://localhost/healthz
ss -tulpn                                        # a worker shows no listener at all
```

The admin console's *System* section lists every node that was configured, its uptime, CPU
and memory, its latency and its last error, and can follow any node's log while the drawer
is open.
