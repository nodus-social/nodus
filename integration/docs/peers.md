# Federation peers

`compose.peers.yml` adds two real fediverse servers next to the lab so
federation can be exercised against software that is not ours:

| service                     | image                                  | answers at              |
| --------------------------- | -------------------------------------- | ----------------------- |
| `mastodon`                  | `ghcr.io/mastodon/mastodon:v4.3.6`     | `http://127.0.0.1:18081` |
| `misskey`                   | `misskey/misskey:2024.11.0`            | `http://127.0.0.1:18082` |

Each peer owns its database and cache (`mastodon-db`/`mastodon-redis`,
`misskey-db`/`misskey-redis`). Neither reuses the lab's Postgres or Valkey: a
peer reset must not be able to damage the origin, and Mastodon's schema needs
extensions the lab database does not carry. All of them join the existing
`nodus-lab` network, so `nodus`, `mastodon.local`, `misskey.local` and the peer
databases resolve by name.

`scripts/peers.sh` is the only supported entry point:

```sh
integration/scripts/peers.sh up      # start peers, wait for health
integration/scripts/peers.sh seed    # create alice@mastodon.local and alice@misskey.local
integration/scripts/peers.sh status   # containers, endpoint probes, seeded accounts
integration/scripts/peers.sh follow   # attempt the four federation directions
integration/scripts/peers.sh down    # remove peer containers, keep peer volumes
```

`up` generates the peer secrets in `integration/.env` (database passwords, the
three `ACTIVE_RECORD_ENCRYPTION_*` keys Rails needs before it will boot) and
never overwrites one that is already there, so `down` + `up` keeps the seeded
accounts and their tokens valid.

## Topology and identity

Mastodon's identity is `mastodon.local` (`LOCAL_DOMAIN` and `WEB_DOMAIN`), and
Misskey's is `http://misskey.local:18082/` (its `url`). Those strings are what
peers see in handles, actor ids and ActivityPub ids; changing either after the
first follow orphans everything already federated.

Both listen on the same port inside the network that the published port
forwards to, and both are reached by container name from the origin:

    nodus (Caddy alias, http://nodus:8080)  ──►  mastodon.local (port 80)
                                            ──►  misskey.local:18082

Mastodon is on 80 rather than 3000 because it builds the URLs it advertises
from `WEB_DOMAIN`, which carries no port: peers are told
`http://mastodon.local/inbox`, so something has to answer there (see "The
origin's plain-http escape hatch" below).

## Trust decisions

- **Development mode on purpose.** Mastodon derives its URL scheme from
  `RAILS_ENV` (`config/initializers/1_hosts.rb` forces https in production) and
  only development bypasses the private-address guard in `app/lib/request.rb`.
  Production Mastodon cannot speak plain HTTP to a private bridge address, so
  http plus a private network is a development-mode configuration, not a patch.
- **Authorized fetch off.** `AUTHORIZED_FETCH=false`: the lab origin has no
  signed-key discovery story for peers yet, and secure mode would make every
  unauthenticated fetch a 401 instead of a federation bug we can read.
- **No streaming server.** `STREAMING_API_BASE_URL` is left on the canonical
  host; the API and federation do not need a streaming process, only the web UI
  live updates do.
- **Private networks on the Misskey side.** `allowedPrivateNetworks` lists the
  docker bridge ranges, otherwise Misskey refuses to dereference actors and
  notes that live on private addresses. `disableHsts` and
  `signToActivityPubGet: false` do the same job for HSTS and inbox reachability
  probing.
- **The origin side is the loose end.** `compose.peers.yml` sets
  `NODUS_ALLOW_PRIVATE_HOSTS=mastodon.local,misskey.local,mastodon,misskey` on
  `nodus-api`, which lifts the private-address half of the resolver guard. It
  does **not** make these peers resolvable: the API still requires `https`
  (`crates/api/src/remote.rs`, `parse_target` and `outbound_client`) and always
  probes port 443 (`client_for_with`). See "What is proven" below.

## TLS in the lab

Both peers address a remote origin as `https://<domain>` and will not look anywhere else
for a domain that is not `.onion`: Mastodon builds that URL in
`app/lib/webfinger.rb:113-121` (`Webfinger#standard_url`), Misskey does the same when it
delivers. A handle carries no port, so the name they dial is `nodus` on **443**. The lab
origin therefore answers there as well as on `8080`:

```text
http://nodus:8080   host browsing (Playwright, up.sh) and the origin-to-peer direction
https://nodus       what a peer dials when it resolves or verifies ada@nodus
```

`integration/Caddyfile` serves one route table on both entry points (`import routes`), so
a federation request sees exactly the routes a browser sees. 443 is **not published on the
host**: `compose.yml` only `expose`s it, because peers reach Caddy by container name on the
`nodus-lab` bridge and host port 443 already belongs to something else.

### The internal CA

`tls internal` makes Caddy sign with its own CA — the lab has no internet-facing name and
cannot use ACME. The root lives on the `nodus-data` volume:

```sh
docker exec nodus-lab-caddy cat /var/lib/nodus/caddy/pki/authorities/local/root.crt
```

`peers/ca/nodus-lab-ca.crt` in this repo is a copy of that root (subject
`CN=Caddy Local Authority - 2026 ECC Root`). It is a **throwaway lab CA**: generated per
lab, not a secret, of no value to anyone. It survives `docker compose restart caddy`, but
`reset.sh` drops `nodus-data` and the authority is regenerated on the next start — after
that the committed copy no longer verifies, so re-take it with the command above and
recreate the peers.

### How each peer trusts it

The system bundle is never replaced; the lab root is added to what the image already
trusts. Both read the same file, mounted read-only at `/certs/nodus-lab-ca.crt`.

| peer | env var | mechanism |
| --- | --- | --- |
| Mastodon (web, sidekiq) | `SSL_CERT_FILE` | `peers/mastodon/ca-entrypoint.sh` copies `/etc/ssl/certs/ca-certificates.crt` and appends the lab root to it |
| Misskey | `NODE_EXTRA_CA_CERTS` | Node appends the file to its built-in store |

`SSL_CERT_FILE` names a *file*, so pointing it at the lab root alone would drop the public
bundle — hence the concatenated copy, written to the container's tmpdir because
`/etc/ssl/certs/ca-certificates.crt` is root-owned and the app runs as uid 991. The
variable is declared in `compose.peers.yml` rather than exported by the entrypoint
wrapper, because `docker exec` inherits the container's configured environment and not a
shell's exports — which is what makes the checks below work.

Verification is from inside the containers, on the same code paths the peers' own clients
use:

```sh
docker exec nodus-lab-mastodon ruby -e \
  'require "net/http"; puts Net::HTTP.get(URI("https://nodus/api/v1/meta"))'
docker exec nodus-lab-misskey node -e \
  'fetch("https://nodus/api/v1/meta").then(r=>r.text()).then(console.log)'
# both print:
# {"api":"1","contract":"0.1.0","min_contract":"0.1.0",
#  "features":["feed_accounts","events","sync_token"]}

docker exec nodus-lab-mastodon ruby -e \
  'require "net/http"; r = Net::HTTP.get_response(URI("https://nodus/.well-known/webfinger?resource=acct:ada@nodus")); puts r.code; puts r.body'
# 200
# {"aliases":["http://nodus:8080/users/ada"],"links":[
#   {"href":"http://nodus:8080/users/ada","rel":"self","type":"application/activity+json"},
#   {"href":"http://nodus:8080/@ada","rel":"http://webfinger.net/rel/profile-page","type":"text/html"}],
#  "subject":"acct:ada@nodus"}
```

The third is the exact call that used to fail with
`Connection refused - connect(2) for 172.20.0.11:443 on https://nodus/.well-known/webfinger`.

### What this leg does not change

- **The origin still advertises `http://nodus:8080`.** `NODUS_BASE_URL` is untouched, so
  the WebFinger above answers with `http` aliases and the actor's `id` stays `http://`.
  Whether a peer then dereferences that actor is the next proof, not this plumbing.
- **`NODUS_ALLOW_INSECURE_PEERS` is the other direction.** It names
  `mastodon.local,misskey.local` for the origin's *outbound* calls, where the origin is the
  client and the peer has no certificate. The TLS leg covers the opposite case: a peer as
  the client, dialling the origin. Both hold at the same time.
- **The inbound signature check is untouched.** A peer that signs with an `http` `keyId`
  is still answered `401`; this leg only makes the origin's https name reachable and
  verifiable.

## Mutable peer code is mounted, never edited in place

Nothing in a running container is patched. The one peer file the lab has to
inject is `peers/mastodon/letter_opener_web_shim.rb`, bind-mounted as
`config/initializers/0_letter_opener_web_shim.rb`. It exists because the
official image is built `--without development test`, while this lab boots
`RAILS_ENV=development` (see above), and two development-only files reference
the excluded gem:

    config/initializers/content_security_policy.rb:68
    config/routes.rb:52  (mount LetterOpenerWeb::Engine)

The shim defines the two constants those files touch and nothing else. No mail
is delivered and no `/letter_opener` route is served.

### Why sidekiq needed it too

Mastodon queues every outbound ActivityPub delivery in Sidekiq, so the peer is
not usable for federation while `mastodon-sidekiq` is crash-looping:

    INFO: Booting Sidekiq 6.5.12 with Sidekiq::RedisConnection::RedisAdapter options {:url=>"redis://mastodon-redis:6379/0", ...}
    WARN: NameError: uninitialized constant LetterOpenerWeb
    WARN: /opt/mastodon/config/initializers/content_security_policy.rb:68:in `block in <main>'

The web process boots because it loads the shim; the Sidekiq container was
created before the shim volume was added to its service definition, so it ran
with only the `mastodon-system` volume and no `0_letter_opener_web_shim.rb`
initializer. Docker only applies volume changes when the container is
recreated, and `restart: unless-stopped` keeps the old container's mounts
across restarts. The fix is a recreate, not a code change:

    docker compose --project-name nodus-lab --env-file integration/.env \
      -f integration/compose.yml -f integration/compose.peers.yml \
      up -d --no-deps mastodon-sidekiq

After that Sidekiq boots and drains the federation queues. The `mailers` queue
still fails each job with `RuntimeError: Invalid delivery method :letter_opener`
(the gem is not installed and there is no SMTP host) — expected in the lab,
unrelated to federation, and it retries without blocking the other queues.

## Seeded accounts

`peers.sh seed` is idempotent and writes three files under
`integration/state/` (git-ignored, mode 600):

| file                   | contents                                              |
| ---------------------- | ----------------------------------------------------- |
| `mastodon-account.json` | `{host, username, password, token, acct}`             |
| `misskey-account.json`  | `{host, username, password, token, acct, adminToken}` |
| `nodus-account.json`    | the lab's own `ada@nodus.test` OAuth token            |

- **Mastodon:** created with `tootctl accounts create --confirmed --approve`,
  password set through the model (`tootctl accounts modify` has no
  `--password`), then a `password`-grant token. Doorkeeper resolves the resource
  owner with `User.find_by(email: request.params[:username])`
  (`config/initializers/doorkeeper.rb`), so the grant must be fed
  `alice@mastodon.local`, not `alice`.
- **Misskey:** the root account is created with `setupPassword` from
  `peers/misskey/default.yml`, and that root token creates or deletes
  `alice@misskey.local` by idempotent lookup. The account token is a real
  Misskey access token — `POST /api/i` with it returns the account — and it is
  stored in the named volume's database, so it survives `down.sh` + `up.sh`
  (`down.sh`/`reset.sh` remove the volumes and therefore the accounts; run
  `seed` again afterwards).

## What a browser needs

The peer UIs bind to `127.0.0.1` on published ports. Both peers emit absolute
URLs for their canonical origin, so the hostname has to match what the peer
believes it is:

    # /etc/hosts
    127.0.0.1 mastodon.local misskey.local

- **Misskey** — `http://misskey.local:18082` works. Its `url` includes the port
  and the container listens on the same port, so assets, API calls and the UI
  all agree.
- **Mastodon** — `http://mastodon.local:18081` loads, but `WEB_DOMAIN` cannot
  carry a port, so canonical links, asset URLs and the OAuth flow point at
  `http://mastodon.local` (port 80), which nothing serves. Treat the Mastodon UI
  as inspect-only; use the API token from `state/mastodon-account.json` for
  scripted checks.
- Both peers must not publish 8080 or 5432.

## The origin's plain-http escape hatch

`NODUS_ALLOW_INSECURE_PEERS` (lab value in `.env.example`:
`mastodon.local,misskey.local`) names the hosts the API may reach over plain
`http`; TLS is skipped for exactly those names and production leaves it empty.
`compose.yml` forwards it to `nodus-api`, `compose.peers.yml` still sets
`NODUS_ALLOW_PRIVATE_HOSTS` for the same service, and together they lift both
halves of the resolver guard: scheme and private address.

Two consequences are worth knowing before reading the results below:

- **A handle carries no port.** `alice@mastodon.local` makes the origin probe
  `http://mastodon.local:80/.well-known/webfinger`. Only an actor URL can carry
  a port, so every step that must name a non-80 port has to pass an actor URL.
- **Mastodon advertises itself without a port.** It builds actor and inbox URLs
  from `WEB_DOMAIN`, which cannot carry one, so the origin is told to deliver a
  `Follow` to `http://mastodon.local/inbox` — port 80. `compose.peers.yml`
  therefore runs Mastodon's web process on **80** inside the network
  (`-p 80`, published to the host as `127.0.0.1:18081:80`). The image runs as
  uid 991 and docker sets `net.ipv4.ip_unprivileged_port_start=0`, so no
  capability is needed. Without that, outbound delivery fails with
  `error sending request for url (http://mastodon.local/inbox)`.

## What this run proves

Run state: `integration/scripts/build.sh` built `nodus-api` from the backend
**working tree** (`LAB_BUILD_FROM_WORKTREE=1`, `NODUS_BUILD_CONTEXT=$PWD`,
`NODUS_DOCKERFILE=integration/Dockerfile.server`), because the superproject
gitlink still records the older commit. Backend HEAD was `883185b`, which
contains both federation fixes — `79d9711` (dial a named host over plain http)
and `b503bed` (accept a signed delivery from a named plain-http host) — and
`git status` in `nodus-backend` was clean. The built image was
`nodus-lab/server:0.1.0` (`a38e6afd3af7`); the API was recreated with the
two-file compose set and `/healthz` answered `200`.

The lab origin answers **https on 443** inside `nodus-lab` (Caddy
`https://nodus:443 { tls internal }`), and both peers trust the lab CA. That leg
is proven from inside the peer containers:

```sh
docker exec nodus-lab-mastodon curl -sS -o /dev/null -w '%{http_code}\n' \
  https://nodus/api/v1/meta
# 200
docker exec nodus-lab-mastodon curl -sS -o /dev/null -w '%{http_code}\n' \
  'https://nodus/.well-known/webfinger?resource=acct:ada@nodus'
# 200
```

What that did **not** do is get a peer delivery into the origin. The four
proofs below are reported as they came out, not as intended.

### (a) nodus → Mastodon: resolve, follow, ingest — **resolve and follow only, no ingest**

Resolution works through the actor URL:

    GET /api/v2/search?q=http://mastodon.local/users/alice&resolve=true
    HTTP 200
    {"accounts":[{"id":"01m7y0ajbp2ctfq9w8j2d8st91","username":"alice",
                  "acct":"alice@mastodon.local","url":"https://mastodon.local/@alice"},
                 ...],"statuses":[],"hashtags":[]}

The follow is accepted locally:

    POST /api/v1/accounts/01m7y0ajbp2ctfq9w8j2d8st91/follow
    {"id":"01m7y0ajbp2ctfq9w8j2d8st91","following":true,"requested":false,...}
    HTTP 200

But nothing is ingested:

    GET /api/v1/accounts/01m7y0ajbp2ctfq9w8j2d8st91/statuses?limit=10
    []            # length 0, before and after the follow

The reason is still the inbound signature check (see "Why inbound still
fails"), and the delivery ledger tells the same story — one old `Follow` row
from the previous run, never re-attempted because the origin already had the
follow recorded locally:

    select activity->>'type', created_at, attempts, last_status_code, last_error
      from federation_delivery order by created_at desc limit 2;
    Undo   | 2026-11-21 03:52:22 | 0 | 202 | ok
    Undo   | 2026-11-21 02:56:03 | 1 | 401 | Failed to fetch remote data:
             failed to connect: Connection refused ... 172.20.0.11:443
             on https://nodus/.well-known/webfinger?resource=acct:ada@nodus
    Follow | 2026-11-21 02:52:53 | 3 | 401 | Fetching attempt skipped because
             of recent connection failure

Unfollowing (`DELETE /api/v1/accounts/<id>/follow`, `200`) and following again
(`POST .../follow`, `200`) created a fresh local follow row but no new `Follow`
delivery row — only the `Undo` was sent, and Mastodon accepted it with `202`
(see "What the TLS leg did prove"). The peer was therefore never told about the
new follow. That is a delivery-queue observation, separate from the 401 wall.

### (b) Mastodon → nodus: follow and timeline — **blocked by the origin's 401**

Mastodon resolves the origin by actor URL (`/api/v2/search?q=http://nodus:8080/users/ada&resolve=true`
→ `200`), and the follow endpoint answers `200`, but Mastodon never records the
follow:

    docker exec nodus-lab-mastodon bundle exec rails runner \
      'a=Account.find_local("alice"); puts Follow.where(target_account: a).count'
    # 0
    # followers_of_alice=[]  (nodus presence on Alice's home timeline: absent)

The cause is Mastodon's `Follow` delivery to the origin:

    Mastodon::UnexpectedResponseError: http://nodus:8080/users/ada/inbox
      returned code 401
    # Sidekiq retries; the origin's log has no ingest line for it

Clearing Mastodon's cached view did not help because the failure is not cached
domain state: `tootctl cache clear` printed `OK`, web and Sidekiq were restarted,
and there was no `Instance` row for `nodus` to purge (`tootctl domains` exposes
only crawl/purge and showed nothing for the lab). The stale `172.20.0.11:443`
message in the ledger predates the Caddy restart; `getent hosts nodus` inside
Mastodon now resolves `172.20.0.16`, and the direct `https://nodus/...` curls
above answer `200`. The 401 comes from the request body, not from reaching us.

### (c) Misskey reaction on a nodus post — **created on Misskey, delivery still 401**

`ap/show` dereferences a nodus note (`200`) and the reaction is accepted:

    POST /api/notes/reactions/create {"noteId":"...","reaction":"👍"}
    HTTP 204
    GET /api/v1/statuses/<id>/reactions   -> []   # before and after
    select count(*) from status_reaction where status_id='<id>';
    # 0

Misskey's delivery queue shows why:

    VERB [queue deliver] active id=10 to=http://nodus:8080/users/ada/inbox
    ERR  [queue deliver] failed(UnrecoverableError: 401 Unauthorized)
         id=10 attempts=1/12 to=http://nodus:8080/users/ada/inbox
    VERB [queue deliver] active id=11 to=http://nodus:8080/users/ada/inbox
    ERR  [queue deliver] failed(UnrecoverableError: 401 Unauthorized)

So the honest answer is still **nodus does not ingest the reaction, and the
activity never reaches the ingest handler**: it is refused at signature
verification. This run cannot say whether a `Like` would be recorded once it
gets past that gate.

The code-level caveats from the previous run still stand and are the next
things to fix after the 401:

- Misskey renders `Like` with `content` (`ApRendererService#renderLike`), not
  `EmojiReact`; nodus handles `Like` (`activitypub.rs:468` → `like_local`,
  `:1112`).
- `EmojiReact` is not an `ActivityKind` (`server-sdk/crates/activitypub-core/src/activity.rs:71-89`)
  and is rejected with `422 unsupported activity type: EmojiReact`.
- Even an accepted `Like` would not show on a local post: `like_local` resolves
  the target via `statuses::by_uri` (`crates/store/src/statuses.rs:191`), local
  rows have a null `uri`, and `status_for_uri`
  (`crates/api/src/poll_votes.rs:125-139`) — which handles both spellings — is
  not used by `like_local`/`boost_local`. There is no table or handler for a
  remote emoji reaction as such; a `Like` becomes a favourite, and an
  `EmojiReact` would need a new `ActivityKind` plus a reaction table.

### (d) A peer post in the lab web shell — **not observed**

With nothing ingested from either peer there is no peer-authored post to show at
`http://127.0.0.1:18080`; the shell serves only ada's own posts. No screenshot
can evidence a state that does not exist. This is blocked by (b) and (c), not by
the shell.

## Why inbound still fails: `.local` is reserved

`b503bed` fixed the scheme half of the inbound guard, but not the host half.
`validate_remote_url` (`crates/api/src/activitypub.rs:947-965`) now delegates the
scheme decision to `remote::scheme_allowed`, which passes for a host named in
`NODUS_ALLOW_INSECURE_PEERS`; it then calls `check_url_host`, and
`is_disallowed_domain` (`crates/api/src/activitypub.rs:981-993`) treats every
name under `.local` as reserved:

```rust
["localhost", "local", "internal", "localdomain", "home.arpa"]
    .iter()
    .any(|reserved| {
        d == *reserved
            || d.strip_suffix(reserved)
                .is_some_and(|prefix| prefix.ends_with('.'))
    })
```

`mastodon.local` and `misskey.local` both match, so `validate_remote_url`
returns `URL host is not a publicly routable destination`, which
`verify_signature` turns into
`ApiError::unauthorized("signing key actor URL is invalid")`
(`crates/api/src/activitypub.rs:377`). `NODUS_ALLOW_INSECURE_PEERS` and
`NODUS_ALLOW_PRIVATE_HOSTS` do not bypass this predicate.

Reproduce without any peer key — the signature need not be valid, because the
actor URL is rejected before the key is fetched:

```sh
body='{"type":"Like","actor":"http://mastodon.local/users/alice",
       "object":"http://nodus:8080/statuses/x"}'
digest="SHA-256=$(printf '%s' "$body" | openssl dgst -sha256 -binary | openssl base64 -A)"
date=$(date -u '+%a, %d %b %Y %H:%M:%S GMT')
# Signature keyId="http://mastodon.local/users/alice#main-key", algorithm="rsa-sha256",
#   headers="(request-target) host date digest"
curl -sS -i -X POST http://127.0.0.1:18080/users/ada/inbox \
  -H 'content-type: application/activity+json' \
  -H "Date: $date" -H "Digest: $digest" -H "Signature: $sig" -d "$body"
# HTTP/1.1 401 Unauthorized
# {"error":"signing key actor URL is invalid"}
```

## What the TLS leg did prove

The `Undo` delivery at `03:52:22` was accepted by Mastodon with `202`:

    nodus_server_api::outbox: activity delivered inbox=http://mastodon.local/inbox status=202

Mastodon verifies a signature by fetching the signing actor, so a `202` means it
reached `https://nodus/...` through the lab CA and verified a nodus-signed
activity. Caddy's internal-CA leg and nodus's outbound signing both work. What
is left is the origin's inbound host classification.

## Two node URLs, and which one is ActivityPub

Unchanged from the previous run, and still worth knowing:

    status.uri / status.url  ->  http://nodus:8080/@ada/<id>      (HTML page)
    AP object id (outbox)    ->  http://nodus:8080/statuses/<id>  (activity+json)

`/@ada/<id>` answers `text/html` even for `Accept: application/activity+json`,
so a peer that dereferences `status.uri` sees a web page and reports
`Content type is not application/activity+json or application/ld+json`. Use the
outbox id; `scripts/peers.sh` does.

## Recreating the origin changes its address, and Misskey caches it

Each `up -d --no-deps nodus-api caddy` can hand the name a new address on
`nodus-lab`. Misskey keeps the old one and answers `ap/show` with
`connect ECONNREFUSED <old-ip>:8080` while `curl http://nodus:8080/healthz`
inside the same container is `200`. `docker compose ... restart misskey`
clears it. The stale `172.20.0.11:443` in Mastodon's old ledger row is the same
kind of artifact, not a live failure.

## What would close the remaining gap

1. Exempt a host named in `NODUS_ALLOW_INSECURE_PEERS` from
   `is_disallowed_domain` (or check the allowlist before the reserved-name
   rule), while still rejecting address literals and private IPs. That is the
   one change that opens (a), (b), (c) and (d); `b503bed` deliberately left the
   private-name rule untouched.
2. Make `like_local`/`boost_local` resolve local targets with `status_for_uri`
   so an accepted `Like` lands on a local post.
3. Decide whether `EmojiReact` should be a first-class `ActivityKind` with a
   reaction table, or whether Misskey's `Like`+`content` is enough.

## Commands used

```sh
# build the API from the worktree (pin bump is separate)
export NODUS_BUILD_CONTEXT=$PWD NODUS_DOCKERFILE=integration/Dockerfile.server
export CARGO_BUILD_JOBS=8
docker compose --project-name nodus-lab --env-file integration/.env \
  -f integration/compose.yml build nodus-api

# recreate only the API, keeping the peers overlay's private-host allowance
docker compose --project-name nodus-lab --env-file integration/.env \
  -f integration/compose.yml -f integration/compose.peers.yml \
  up -d --force-recreate --no-deps nodus-api

# peers: TLS leg and account setup
docker exec nodus-lab-mastodon curl -sS -o /dev/null -w '%{http_code}\n' \
  https://nodus/api/v1/meta
docker exec nodus-lab-mastodon bundle exec bin/tootctl cache clear

# the four checks
integration/scripts/peers.sh follow

# ledger, follow state and reaction state
docker exec -e PGPASSWORD="$(sed -n 's|^NODUS_DB_PASSWORD=||p' integration/.env)" \
  nodus-lab-postgres psql -U nodus -d nodus -c \
  "select activity->>'type', created_at, attempts, last_status_code, last_error
     from federation_delivery order by created_at desc limit 5;"
docker exec nodus-lab-mastodon bundle exec rails runner \
  'a=Account.find_local("alice"); puts Follow.where(target_account: a).count'
docker exec -e PGPASSWORD="$(sed -n 's|^NODUS_DB_PASSWORD=||p' integration/.env)" \
  nodus-lab-postgres psql -U nodus -d nodus -c \
  "select count(*) from status_reaction where status_id='<id>';"

# peer-side delivery failures
docker logs --since 30m nodus-lab-misskey | grep -E 'queue deliver'
```
