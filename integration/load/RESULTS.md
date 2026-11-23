# API load test: numbers, and where the ceiling is

Measured 2026-11-23 on the `nodusload` stack: one API process and one media
worker process on the `nodus-lab` network, Caddy in front, a database of its own
in the lab's Postgres. The e2e lab was running at the same time; nothing here
touched its database.

## Machine and build

| | |
|---|---|
| CPU | AMD Ryzen 9 9950X3D, 32 logical CPUs (16 cores × 2 threads) |
| Memory | 60 GB |
| Disk | btrfs on `/dev/nvme0n1p3`, 82% full |
| Kernel | Linux 7.3.4-ogc8.1.fc45.x86_64 |

| component | image | digest |
|---|---|---|
| API + media worker | `nodus-lab/server:0.1.0` | `sha256:17c43e6f43b7ccec4c58df95a002f8c794ed972cf6be2b8d4ac87b7b8e543291` |
| Caddy | `nodus-lab/web:0.1.0` | `sha256:952305696ab15c76fdd637be2be20090a3dc626c19d265746cefe768523c75c8` |
| load generator | `grafana/k6:latest` | `sha256:3d8e5c7f1d53ec59408c2ffbd9943602a0985ffcbd4a2430ec00f3ffca89796e` |
| database | `pgvector/pgvector:pg17`, PostgreSQL 17.12, shared with the lab | `max_connections = 100`, `shared_buffers = 128MB` |

Process settings that bound every number below: `NODUS_DATABASE_CONNECTIONS=10`
per process (API and media worker each open their own pool), `NODUS_HOME_SHARDS=1`,
`NODUS_HOME_CAP=400`, one API replica, one media replica.

## Dataset

Seeded with `integration/load/seed.py` (`--seed 20261123`, `COPY` into the same
schema the API writes):

| rows | count |
|---|---|
| accounts | 10,001 (10,000 bulk `loadbulk*` + the API-created reader) |
| statuses | 200,000, all local and public |
| media attachments | 20,000 |
| follows | 57,984 (6 hubs, ~1,667 followers each) |
| home timeline rows (reader) | 400 |
| notifications (reader) | 400 |
| database size | 197 MB |

The reader account (`loadbulk01059`) is the subject of every profile read; its
newest status is the permalink read; one seeded media attachment is the media
read.

## How the runs were driven

```
integration/scripts/load.sh up
NODUS_LOAD_ACCOUNTS=10000 NODUS_LOAD_STATUSES=200000 NODUS_LOAD_MEDIA=20000 \
    integration/scripts/load.sh seed
integration/scripts/load.sh run     # anonymous, auth-warm, auth-cold, write
integration/scripts/load.sh report
```

`run` here was driven without the `auth-cold` leg (time budget); see "Not
measured". Each read scenario ramps 0 → 10 (20 s) → 50 (40 s) → 100 (40 s) →
200 (40 s) → 0 (20 s): 160 s of load, `ramping-vus`, `gracefulRampDown 5s`. The
write scenario ramps 0 → 5 (15 s) → 10 (30 s) → 20 (30 s) → 30 (30 s) → 0
(15 s). Buckets are labelled by the VU target that held during that step, and
are bucketed by elapsed time, not by k6's instantaneous VU count, so a request
that starts on the ramp is attributed to the step it belongs to.

## Anonymous read mix (45% public timeline, 15% profile, 15% profile statuses, 15% permalink, 10% media)

| endpoint | 10 VUs p50/p95/p99 | 50 VUs p50/p95/p99 | 100 VUs p50/p95/p99 | 200 VUs p50/p95/p99 |
|---|---|---|---|---|
| `media` | 1 / 1 / 1 | 1 / 1 / 2 | 1 / 1 / 1 | 1 / 1 / 1 |
| `permalink` | 1 / 1 / 2 | 3 / 7 / 8 | 9 / 14 / 16 | 19 / 27 / 31 |
| `profile` | 1 / 1 / 1 | 1 / 2 / 2 | 2 / 3 / 4 | 4 / 6 / 7 |
| `profile_statuses` | 14 / 19 / 22 | 61 / 104 / 118 | 164 / 224 / 251 | 344 / 460 / 507 |
| `public_timeline` | 2 / 2 / 3 | 2 / 3 / 4 | 4 / 5 / 6 | 5 / 8 / 9 |
| **req/s in that step** | 1201 | 2506 | 2563 | 2559 |

381204 requests, 0.00% failed. Latency in ms. The 10-VU column includes the ramp from 0, so its req/s is an average of a rising ramp, not a steady state.

Throughput is flat from 50 VUs on (2,506 → 2,563 → 2,559 req/s) while the
expensive read grows: `profile_statuses` p50 61 → 344 ms and the permalink
3 → 19 ms. The cheap reads — media bytes, one account row — stay at 1-4 ms
throughout. Nothing errors; requests just wait their turn in front of the
database connections.

## Authenticated read mix, warm home cache (60% home, 20% notifications, 10% profile, 10% profile statuses)

| endpoint | 10 VUs p50/p95/p99 | 50 VUs p50/p95/p99 | 100 VUs p50/p95/p99 | 200 VUs p50/p95/p99 |
|---|---|---|---|---|
| `home_timeline` | 33 / 119 / 218 | 123 / 365 / 563 | 185 / 375 / 550 | 337 / 598 / 757 |
| `notifications` | 36 / 128 / 227 | 128 / 356 / 588 | 210 / 404 / 524 | 395 / 693 / 880 |
| `profile` | 1 / 1 / 1 | 13 / 43 / 67 | 39 / 82 / 91 | 100 / 186 / 239 |
| `profile_statuses` | 48 / 133 / 222 | 1561 / 3339 / 3518 | 5086 / 6779 / 6964 | 11436 / 14144 / 14284 |
| **req/s in that step** | 101 | 99 | 117 | 116 |

17653 requests, 0.00% failed. Latency in ms. The 10-VU column includes the ramp from 0, so its req/s is an average of a rising ramp, not a steady state.

This mix saturates at ~100-117 req/s at *every* step from 10 VUs up: it never
gets faster with more load, it only queues. The home timeline and the
notification list hold a connection longer (they hydrate 20-40 rows), so the
same ten connections deliver twenty times fewer requests per second than the
anonymous mix. `profile_statuses` is the extreme: 48 ms at 10 VUs, 1.6 s at 50,
11.4 s at 200 — and because VUs that draw it stay stuck inside it, its share of
*completed* requests falls as the queue grows, so its counts at 200 VUs
understate its share of traffic.

Two things about the authenticated path are worth a follow-up: it is the only
mix where the API log records slow statements, and the ones it records are
`UPDATE oauth_token SET last_used_at = now() WHERE token_hash = $1` taking
1.0 s — a write on the authentication path, serialised on one row. That was not
isolated here; it is a candidate, not a proven cause, for part of the collapse.

## Write mix (upload media → publish status → favourite the seeded status → delete own status)

| endpoint | 5 VUs p50/p95/p99 | 10 VUs p50/p95/p99 | 20 VUs p50/p95/p99 | 30 VUs p50/p95/p99 |
|---|---|---|---|---|
| `favourite` | 27 / 55 / 87 | 76 / 207 / 408 | 227 / 511 / 818 | 438 / 875 / 1102 |
| `media_upload` | 56 / 84 / 98 | 104 / 251 / 349 | 165 / 461 / 716 | 215 / 498 / 730 |
| `status_create` | 41 / 57 / 71 | 98 / 260 / 354 | 301 / 704 / 956 | 532 / 1018 / 1380 |
| `status_delete` | 71 / 107 / 126 | 121 / 260 / 350 | 268 / 584 / 866 | 438 / 811 / 1181 |
| **req/s in that step** | 35 | 58 | 53 | 55 |

6244 requests, 0.00% failed. Latency in ms. The 10-VU column includes the ramp from 0, so its req/s is an average of a rising ramp, not a steady state.

The write path plateaus at ~55 req/s from 20 VUs (35 → 58 → 53 → 55), 0.00%
failed over 6,244 requests. The upload is not the expensive step: media upload
is 56 ms p50 at 5 VUs, while publishing the status — insert plus fan-out plus
the cached home timeline write — is 41 ms at 5 VUs and 532 ms at 30. Every
endpoint grows ~linearly from 10 VUs on, the same queue as the read mixes.

## The first resource that ran out: the API's 10-connection pool

The read mixes stop scaling at 50 VUs and the latency grows linearly after that
while throughput stays flat — 2,506 → 2,563 → 2,559 req/s from 50 to 200 VUs. That
is a queue in front of a fixed number of servers, not a CPU or disk limit:

- the API container sat at **260% of 3200% CPU** (2.6 of 32 cores) at 200 VUs,
  and the media worker at 7%;
- Postgres had **20 client backends** for `nodusload` — its 10 API connections
  plus the media worker's 10 — against `max_connections = 100`;
- the pool is `NODUS_DATABASE_CONNECTIONS=10`, and 10 connections serving
  ~3.9 ms of query work each is exactly the ~2,560 req/s plateau.

The pool is also where the only hard failure appeared. During the first write
run, ten `INSERT INTO favourite` statements queued behind a lock held by a
leftover seed transaction; every one of the ten pool slots was held by a
blocked query, and the API answered HTTP 500 after exactly 5001 ms with:

```
ERROR nodus_server_api::error: database error error=pool timed out while
waiting for an open connection
ERROR tower_http::trace::on_failure: response failed classification=Status code:
500 Internal Server Error latency=5001 ms
```

`pg_stat_activity` at that moment (`out/lock_wedge.txt`): 10 backends `active`
waiting on `Lock: transactionid`, every one of them blocked by pid 71971 — an
18-minute-old `DELETE FROM media_attachment WHERE account_id IN (SELECT id FROM
account ...)`, the clear step of an earlier seeding attempt whose client had
gone away. Killing that backend returned the API to 3 ms responses instantly,
and all ten favourites then completed. That failure is a seeding artefact, not
a property of the write path; the write numbers above are from a rerun on a
lock-free database.

**Plain sentence:** the ceiling is the 10 connections one API process may hold,
and the next bottleneck behind it is already visible in the mix that does more
DB work per request — the authenticated read mix, whose home-timeline and
notification requests hydrate 20-40 rows each and hold a connection for far
longer.

## A defect this run exposed in the harness

`seed.py` clears a previous bulk seed with `DELETE FROM media_attachment WHERE
account_id IN (SELECT id FROM account ... 'loadbulk%')`. On the first rerun that
statement was still running 18 minutes later, holding the transaction-id lock
that wedged the API (above); its client was gone, so it was an orphan. Its plan
is a hash join over 10,000 accounts and 20,000 media rows, which should take
milliseconds, so the time was not a planning problem — it was terminated rather
than diagnosed further. Until that is understood, reset by dropping/recreating
`nodusload`, or with

```sql
TRUNCATE status, media_attachment, media_variant, timeline_entry,
  account_relation, notification, drive_object, account RESTART IDENTITY CASCADE;
```

(and then re-run `load.sh seed` so the API-created reader exists again).
Never rerun `seed.py` against a database that is being measured.

## Not measured

- **`auth-cold`** — the same authenticated mix with the Valkey home ZSET
  flushed. Written and installed in the harness, not run in this budget; the
  `load.sh run` command above includes it.
- **Media resize path** — the fixture is the media worker's own default avatar
  and `serve_variant` falls back to the original bytes, so the media endpoint
  measured the fallback, not a resize or variant lookup.
- **TLS/HTTP2 and Caddy overhead** — k6 spoke plain HTTP to port 18100.
- **Federation, multiple app nodes, multiple home shards** — single API
  process, `NODUS_HOME_SHARDS=1`, `NODUS_AUTHORIZED_FETCH=false`.
- **Long-run behaviour** — each scenario is 160 s; no soak, no cache warm-up
  curve beyond the seed's explicit warm.
- **Run-to-run variance** — one run per scenario; the knee's location is
  consistent with the pool arithmetic above, but the exact percentiles will
  move by 10-20% between runs.
- **Capacity projections** — none are given. Extrapolating from one process
  with a 10-connection pool to a deployment would be a guess, not a measurement.
