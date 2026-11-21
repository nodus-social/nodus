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

## What is proven, and what is not

Run state at the time of writing: `integration/scripts/build.sh` built the API
from the backend **working tree** (`LAB_BUILD_FROM_WORKTREE=1`, backend HEAD
`79d9711`, tree clean — the superproject gitlink still records the older
commit), `nodus-api` was recreated with the two-file compose set, both peers are
healthy, and Sidekiq drains its queues.

### (a) nodus → Mastodon: resolve, follow, ingest — **resolve and follow only**

Resolution works, and only through an actor URL:

    GET /api/v2/search?q=http://mastodon.local/users/alice&resolve=true
    {"accounts":[{"id":"01m7y0ajbp2ctfq9w8j2d8st91","username":"alice",
                  "acct":"alice@mastodon.local","url":"https://mastodon.local/@alice",
                  ...}],"statuses":[],"hashtags":[]}
    HTTP 200
    # API log: WARN nodus_server_api::remote: reaching this peer over plain http
    #   because NODUS_ALLOW_INSECURE_PEERS names it; TLS is not used host=mastodon.local

The port-less form is the one that answers: Mastodon now serves port 80 inside
the network (see "Topology and identity"), so `http://mastodon.local:3000/...`
is a refusal while `http://mastodon.local/users/alice` is the actor. The follow
is accepted locally:

    POST /api/v1/accounts/01m7y0ajbp2ctfq9w8j2d8st91/follow
    {"id":"...","following":true,"requested":false,...}   HTTP 200

**Ingestion does not happen, because the `Follow` never lands.** The origin
signs it and posts to the shared inbox it was advertised, and Mastodon rejects
the signature:

    WARN nodus_server_api::outbox: activity delivery failed inbox=http://mastodon.local/inbox
      attempts=3 status=Some(401) retry=false
      error=inbox answered 401 Unauthorized: {"error":"Failed to fetch remote data:
      failed to connect: Connection refused - connect(2) for 172.20.0.11:443 on
      https://nodus/.well-known/webfinger?resource=acct:ada@nodus"}

The rejected actor is `ada@nodus`, i.e. the origin's own handle. Mastodon's
`Webfinger#standard_url` (`app/lib/webfinger.rb:113-121`) hardcodes
`https://<domain>` for every domain that is not `.onion`, and the origin's
handle domain carries no port, so verification dials `https://nodus` on **443**
and is refused. `GET /api/v1/accounts/<id>/statuses` answers `[]` afterwards:
nothing was ingested.

Nothing in the origin can fix this from its side: the handle `ada@nodus` is what
nodus advertises, and a peer is entitled to require TLS for it. The existing
`NODUS_ALLOW_INSECURE_PEERS` lifts the origin's *own* guard; it cannot make
Mastodon accept a plain-http signer.

### (b) Mastodon → nodus: resolve and follow — **blocked twice over**

Mastodon cannot resolve the origin at all:

    GET /api/v2/search?q=http://nodus:8080/users/ada&resolve=true&type=accounts
    {"error":"Remote data could not be fetched"}            HTTP 503
    # Mastodon log: Fetching attempt skipped because of recent connection failure
    #   ... 172.20.0.11:443 on https://nodus/...

Mastodon *can* fetch that actor — from inside the peer container,
`curl -H 'Accept: application/activity+json' http://nodus:8080/users/ada` is
`200` — so the address and the scheme are fine and the WebFinger step in (a) is
the failure: `https://nodus` on 443 is refused, and Mastodon then caches the
domain as failing. A handle (`@ada@nodus`) never gets this far; the actor URL at
least fails for a reason that can be read.

The second wall is on the origin's side and it stops *everything inbound*, so it
is worth stating on its own: **the origin answers `401` to every signed peer
delivery.** Misskey's delivery of a reaction is the cleanest evidence, because
its signature can be checked independently:

    # Misskey -> POST http://nodus:8080/users/ada/inbox, recorded by a Caddy access log
    Signature: keyId="http://misskey.local:18082/users/attcaex9uoqp0002#main-key",
               algorithm="rsa-sha256",headers="(request-target) date host digest",...
    Digest: SHA-256=hyL2Uxhc3LB3VwCrcAcgRSRXyNLeFFAXZgnvQ+MivNU=
    # verified by hand against the actor's published publicKeyPem:
    #   signing string "(request-target): post /users/ada/inbox\ndate: ...\n
    #                    host: nodus:8080\ndigest: ..."  ->  Verified OK
    # the origin's answer to that same request:  401

The cause is in the origin, not the peer: `NODUS_ALLOW_INSECURE_PEERS` is
consulted only by the outbound client (`crates/api/src/remote.rs`), while the
inbound verifier still routes every remote URL through
`validate_remote_url` (`crates/api/src/activitypub.rs:936-947`), whose first
check is

```rust
if parsed.scheme() != "https" || !parsed.username().is_empty() || parsed.password().is_some() {
    return Err(ApiError::unprocessable("URL must be a public HTTPS URL"));
}
```

`verify_signature` turns that into a refusal
(`crates/api/src/activitypub.rs:376`,
`ApiError::unauthorized("signing key actor URL is invalid")`), before any key is
fetched. The same predicate filters inbound object ids
(`activitypub.rs:551`, `:576`, `:602`, `:670`, `:1335`), so even a delivery that
got past the signature check would drop its plain-http objects. This is a
backend gap, reported rather than patched here (the pin bump is separate work).

The refusal can be reproduced without holding any peer's key, which is what
pins the cause to the scheme and not to a bad signature:

```sh
body='{"type":"Like","actor":"http://misskey.local:18082/users/probe",
       "object":"http://nodus:8080/statuses/x"}'
digest="SHA-256=$(printf '%s' "$body" | openssl dgst -sha256 -binary | openssl base64 -A)"
sig=$(printf '%s' "(request-target): post /users/ada/inbox\nhost: 127.0.0.1:18080\n
date: $date\ndigest: $digest" | openssl dgst -sha256 -sign k.pem | openssl base64 -A)
# keyId http  -> 401 {"error":"signing key actor URL is invalid"}
# keyId https -> 401 {"error":"signing key does not match activity actor"}
```

The second answer is the control: with an `https` keyId the request gets past
the scheme check and fails later, on the actor/keyId mismatch it really has. The
plain-http request never gets that far.

Consequence: no nodus post reached a Mastodon timeline, and nothing from either
peer reached the origin. Proofs (c) and (d) below inherit exactly this wall.

### (c) Misskey reaction on a nodus post — **peer side proven, delivery refused**

Misskey refuses plain-http ActivityPub ids unless it runs outside production.
`checkHttps` (`packages/backend/src/misc/check-https.ts`, compiled in the image
as `built/misc/check-https.js`) is

```js
export function checkHttps(url) {
    return url.startsWith('https://') ||
        (url.startsWith('http://') && process.env.NODE_ENV !== 'production');
}
```

and `ApNoteService` throws `unexpected schema of note.id: <uri>` otherwise. The
lab peer therefore sets `NODE_ENV: development` in `compose.peers.yml` — the
peer's own escape hatch, lab-only, next to the origin's — and with it Misskey
dereferences a nodus note. Note the URL: it is the ActivityPub id, not the
Mastodon-API `uri` (see the next section). The script posts a fresh note so the
check never depends on a timeline having anything in it:

```sh
POST /api/v1/statuses  {"status":"hello from nodus, misskey reaction check"}
  -> id 01m7y194b716ng6a3h05h195by
POST /api/ap/show  {"uri":"http://nodus:8080/statuses/01m7y194b716ng6a3h05h195by"}
HTTP 200 {"type":"Note","object":{"id":"atte8oxs3wn50002","userId":"attdzubtixas0001",
  "user":{"name":"ada","username":"ada","host":"nodus:8080"},
  "text":"hello from nodus, misskey reaction check","reactionCount":0,
  "uri":"http://nodus:8080/statuses/01m7y194b716ng6a3h05h195by",
  "url":"http://nodus:8080/@ada/01m7y194b716ng6a3h05h195by"}}
# Misskey keeps the port in the remote host it records: host "nodus:8080"
POST /api/notes/reactions/create  {"noteId":"atte8oxs3wn50002","reaction":"👍"}
HTTP 204
GET /api/v1/statuses/01m7y194b716ng6a3h05h195by/reactions  -> []  (before and after)
```

The reaction is created locally and Misskey then tries to tell the origin:

```sh
VERB [queue deliver] active id=9 to=http://nodus:8080/users/ada/inbox
ERR  [queue deliver] failed(UnrecoverableError: 401 Unauthorized)
     id=9 attempts=1/12 age=5ms to=http://nodus:8080/users/ada/inbox
```

So the honest answer to "does nodus ingest `EmojiReact`/`Like`?" is **not
answered by this run**: the activity never reaches the ingest code, it is
refused at signature verification for being plain http (see (b)). Whether the
verb itself is understood stays open; it is not a case of the origin silently
ignoring the verb. Repeated for three reactions (`👍`, `❤️`, `😀`), all `401`,
all `UnrecoverableError` at the first attempt.

What the code says about the verbs, for whoever picks this up next:

- Misskey does **not** emit `EmojiReact`. `ApRendererService#renderLike`
  (`/misskey/packages/backend/built/core/activitypub/ApRendererService.js:231`)
  always renders `type: 'Like'` carrying `content: <the reaction>`, custom emoji
  included, so a working path would present nodus with `Like`.
- nodus handles `Like`: `ActivityKind::Like` dispatches to `like_local`
  (`crates/api/src/activitypub.rs:468`, `:1112`), which records a favourite.
- `EmojiReact` is not an `ActivityKind` at all
  (`server-sdk/crates/activitypub-core/src/activity.rs:71-89`), and
  `Activity::from_json` refuses an unknown verb with `unsupported activity type:
  EmojiReact` → `422`. A peer that does send it is rejected, not ignored.
- Even a `Like` that arrived would not count on a local post: `like_local`
  resolves its target with `statuses::by_uri` (`crates/store/src/statuses.rs:191`),
  and a local status row has a null `uri` — the check below answers `0`.

```sh
# the row for the note Misskey reacted to, looked up by the id Misskey sent
select count(*) from status where uri='http://nodus:8080/statuses/01m7y194b716ng6a3h05h195by';
  -> 0
select count(*) from status where id='01m7y194b716ng6a3h05h195by';
  -> 1
```

`status_for_uri` (`crates/api/src/poll_votes.rs:125-139`) already resolves both
spellings for a local status; `like_local` and `boost_local` do not use it. A
third backend finding, also reported rather than patched.

### (d) A peer post through the lab shell — **not observed**

`http://127.0.0.1:18080` serves the shell and its API (`/healthz` `200`, peers
healthy), but with nothing ingested from either peer there is no peer-authored
post to render. Nothing about the shell's rendering of remote posts was
exercised; it is blocked exactly like (b) and (c).

### Recreating the origin changes its address, and Misskey caches it

Every `up -d --no-deps nodus-api caddy` hands the containers new addresses on
`nodus-lab`. Mastodon re-resolves each time, but Misskey does not: after one
such recreate it kept dialling the previous holder of the name and answered
`ap/show` with

```sh
500 {"error":{"info":{"e":{"message":"request to http://nodus:8080/statuses/<id>
  failed, reason: connect ECONNREFUSED 172.20.0.11:8080"}}}}
```

while `http://nodus:8080/healthz` inside the same container answered `200` —
`getent hosts nodus` had moved to a different address. `docker compose restart
misskey` clears it. Nothing is wrong with the origin when this appears; check
what the peer resolves before chasing it.

### Two node URLs, and which one is ActivityPub

The origin's Mastodon-API status object and its ActivityPub object are not the
same URL:

    status.uri / status.url  ->  http://nodus:8080/@ada/01m7y0tj548yrjk390mx401ngv
    AP object id (outbox)    ->  http://nodus:8080/statuses/01m7y0tj548yrjk390mx401ngv

`/@ada/<id>` answers `Content-Type: text/html` even for
`Accept: application/activity+json` (a full 181 KB shell page), so a peer that
dereferences the `uri` cannot see a note. Misskey says so plainly:

    POST /api/ap/show {"uri":"http://nodus:8080/@ada/01m7y..."}
    {"error":{"message":"Internal error occurred...",
      "info":{"e":{"message":"Validate content type of AP response:
        Content type is not application/activity+json or application/ld+json"}}}}

The AP id is reachable from the actor's outbox
(`/users/ada/outbox?page=true` → `.orderedItems[].object.id`). `scripts/peers.sh`
takes the note id that way. This asymmetry is a second backend finding: a
Mastodon-API client that hands a `status.uri` to a peer hands it a web page.

### What would close (a) and (b)

For (a): TLS on the origin for the name its handles carry — `https://nodus` on
443 with a certificate both peers trust (a lab CA in the Mastodon and Misskey
trust stores) — because Mastodon's WebFinger client will not look at `http://`
for a non-`.onion` domain.

For (b), (c) and (d): consult `NODUS_ALLOW_INSECURE_PEERS` in the inbound
verifier too, i.e. let `validate_remote_url` (and the object-id filters built on
it) accept `http` for a listed host, exactly as `parse_target` already does for
outbound requests. No peer change is needed; the signatures in this run were
valid.

### Commands used

```sh
# build the API from the clean backend working tree (pin bump is separate)
LAB_BUILD_FROM_WORKTREE=1 \
  NODUS_BUILD_CONTEXT=$PWD NODUS_DOCKERFILE=integration/Dockerfile.server \
  docker compose --project-name nodus-lab --env-file integration/.env \
    -f integration/compose.yml build nodus-api

# recreate only the API, keeping the peers overlay's private-host allowance
docker compose --project-name nodus-lab --env-file integration/.env \
  -f integration/compose.yml -f integration/compose.peers.yml \
  up -d --no-deps nodus-api

# Mastodon must serve port 80 for its own advertised inbox URL
docker compose --project-name nodus-lab --env-file integration/.env \
  -f integration/compose.yml -f integration/compose.peers.yml \
  up -d --no-deps mastodon

# the Misskey peer only dereferences http AP ids outside production
docker compose --project-name nodus-lab --env-file integration/.env \
  -f integration/compose.yml -f integration/compose.peers.yml \
  up -d --no-deps misskey
```

Reading the two sides of a refused delivery:

```sh
# the peer's own view: what was posted, and what came back
docker logs --since 5m nodus-lab-misskey | grep -E 'queue deliver'

# the origin's inbox body, for a request that carries no signature
docker exec nodus-lab-misskey curl -sS -X POST \
  -H 'content-type: application/activity+json' -d '{"type":"Like"}' \
  http://nodus:8080/users/ada/inbox -w ' %{http_code}\n'
# {"error":"missing signature"} 401

# the Misskey direction: dereference a nodus note, then react to it
curl -sS -X POST http://127.0.0.1:18082/api/ap/show \
  -H "Authorization: Bearer $(jq -r .token integration/state/misskey-account.json)" \
  -H 'content-type: application/json' \
  -d '{"uri":"http://nodus:8080/statuses/<status-id>"}'
curl -sS -X POST http://127.0.0.1:18082/api/notes/reactions/create \
  -H "Authorization: Bearer $(jq -r .token integration/state/misskey-account.json)" \
  -H 'content-type: application/json' \
  -d '{"noteId":"<note-id from ap/show>","reaction":"👍"}' -w ' %{http_code}\n'
# 204, then the delivery above fails 401

# and the outbound ledger
docker exec -e PGPASSWORD="$(sed -n 's|^NODUS_DB_PASSWORD=||p' \
  integration/.env)" \
  nodus-lab-postgres psql -U nodus -d nodus \
  -c "select activity->>'type', attempts, last_error, delivered_at
        from federation_delivery order by created_at desc limit 5;"
```
