# Running the parts apart

One binary, several roles. An instance that fits on one machine runs every role in the
process that serves requests; an instance that does not gives each role its own process,
its own container or its own machine, and they meet at the database and at the addresses
they are told about — never at a registry, a broker or a discovery service.

```text
--roles=api      serves HTTP and ActivityPub, mounts the recommendation engine
--roles=scan     claims scans, calls the scanner services, raises what they find
--roles=prune    deletes expired media on an hourly tick
--roles=feed     mounts the recommendation engine without serving anything else
```

The default is `api,feed,scan,prune`, which is what the AIO image and the single-host
deployment use. A role that is named does not appear in another process's table: a
`--roles=scan` process binds no port at all and says so in its log
(`no listener in this process`).

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
| `NODUS_BIND` | where the API listens: `0.0.0.0:3001`, `127.0.0.1:3001` or `unix:/var/run/app/api.sock` |
| `NODUS_TELEMETRY_SOCKET` / `NODUS_TELEMETRY_BIND` | where this process answers about itself (gRPC); set one, not both |
| `NODUS_NODE_NAME` | the name this process uses in every other process's view (`api`, `scan`, `prune`) |
| `NODUS_TELEMETRY` | the peers to ask, as `name=address` pairs; `unix:` or `tcp://` |
| `NODUS_TELEMETRY_FULL` | `true` publishes socket paths and internal addresses in that view |
| `NODUS_ROLES` | AIO image only: which roles its single container runs |

An address is a TCP address or a socket path everywhere it appears, and one spelling per
listener is enough: `unix:/run/nodus/api.sock` and `unix:///run/nodus/api.sock` both mean
the same socket, and `127.0.0.1:9091` means a port.

## A two-process instance, verified

The API serves requests; the scanner worker has no address anyone can dial.

```console
# scanner worker, machine B
NODUS_DATABASE_URL=postgres://nodus@10.0.1.8/nodus \
NODUS_NODE_NAME=scan \
NODUS_TELEMETRY_SOCKET=unix:/var/run/app/scan.sock \
nodus-server --roles=scan

# API, machine A: it asks B, and does not care that B is elsewhere
NODUS_DATABASE_URL=postgres://nodus@10.0.1.8/nodus \
NODUS_DOMAIN=nodus.example NODUS_BASE_URL=https://nodus.example \
NODUS_NODE_NAME=api \
NODUS_BIND=unix:/var/run/app/api.sock \
NODUS_TELEMETRY_SOCKET=unix:/var/run/app/api.sock.telemetry \
NODUS_TELEMETRY=scan=tcp://10.0.1.19:9091 \
nodus-server --roles=api
```

`GET /api/v1/admin/topology` then answers with the worker's own numbers, and a worker that
stops answering is reported dead with the reason and the time it was last heard from:

```console
scan  unix  healthy  4ms
```

The sockets above are removed when the process stops, and a socket left behind by a killed
process is unlinked by its replacement, so a restart never fails on "address already in use".

## Ingress

Only the ingress publishes a port. It proxies the API's paths to `NODUS_BIND` and, behind a
socket, adds the caller's address (`x-forwarded-for`) because a socket cannot report it.
The paths that are not the shell's own are the ones the backend answers — the AIO image's
`nginx.conf` and the production Caddy file are both examples of that split, and neither
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
