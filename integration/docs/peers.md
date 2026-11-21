# Federation peers

`compose.peers.yml` adds two real fediverse servers next to the lab so
federation can be exercised against software that is not ours:

| service    | image                              | host (UI, inspect-only)  | canonical origin (peers)   |
| ---------- | ---------------------------------- | ------------------------ | -------------------------- |
| `mastodon` | `ghcr.io/mastodon/mastodon:v4.3.6` | `http://127.0.0.1:18081` | `https://mastodon.test`   |
| `misskey`  | `misskey/misskey:2024.11.0`        | `http://127.0.0.1:18082` | `https://misskey.test`    |

Every peer speaks to the origin, and is spoken to, at the address it advertises:
`https://<peer domain>` on **443**, terminated by the lab Caddy. The published
`127.0.0.1` ports are the container's own listener, kept for the browser and for
API tokens; nothing federates over them.

Each peer owns its database and cache (`mastodon-db`/`mastodon-redis`,
`misskey-db`/`misskey-redis`). Neither reuses the lab's Postgres or Valkey: a
peer reset must not be able to damage the origin, and Mastodon's schema needs
extensions the lab database does not carry. All of them join the existing
`nodus-lab` network, so `nodus`, `mastodon.test`, `misskey.test` and the peer
databases resolve by name.

`scripts/peers.sh` is the only supported entry point:

```sh
integration/scripts/peers.sh up      # start peers, wait for health
integration/scripts/peers.sh seed    # create alice@mastodon.test and alice@misskey.test
integration/scripts/peers.sh status   # containers, endpoint probes, seeded accounts
integration/scripts/peers.sh follow   # attempt the four federation directions
integration/scripts/peers.sh down    # remove peer containers, keep peer volumes
```

`up` generates the peer secrets in `integration/.env` (database passwords, the
three `ACTIVE_RECORD_ENCRYPTION_*` keys Rails needs before it will boot) and
never overwrites one that is already there, so `down` + `up` keeps the seeded
accounts and their tokens valid.

## Topology and identity

Mastodon's identity is `mastodon.test` (`LOCAL_DOMAIN` and `WEB_DOMAIN`), and
Misskey's is `https://misskey.test/` (its `url`). Those strings are what peers
see in handles, actor ids and ActivityPub ids; changing either after the first
follow orphans everything already federated.

A peer builds every remote address as `<scheme>://<host>`, with no port, and
ActivityPub ids in both peers are `https` even in development. So the address
they advertise has to be an https origin on 443 — which is what the Caddyfile's
two peer site blocks serve:

    Caddy  https://mastodon.test (443)  ──►  mastodon:80     (web process)
    Caddy  https://misskey.test  (443)  ──►  misskey:18082  (container port)
    Caddy  https://nodus          (443)  ──►  web + api      (the origin itself)
    Caddy  http://nodus:8080             ──►  the same routes (host browser)

Mastodon's web process is on 80 rather than its default 3000 for the same
reason it always was: `WEB_DOMAIN` cannot carry a port, so the app has to be
reachable at the container port Caddy proxies to. Misskey keeps its own 18082,
which is also the published host port.

`LOCAL_HTTPS=true` makes Mastodon's WebFinger and HTML links agree with the
`https` ids it already emits; without it the peer advertises `http://` aliases
next to `https` ids and a peer that follows the aliases dead-ends on port 80.

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
- **Address guard, not scheme guard.** `compose.peers.yml` sets
  `NODUS_ALLOW_PRIVATE_HOSTS` on `nodus-api`, which lifts the private-address
  half of the resolver guard for the peer names. `NODUS_ALLOW_INSECURE_PEERS` is
  empty in this lab: both peers now answer https, so nothing needs the
  plain-http escape hatch. What is left is the origin's **inbound** host
  classification, which no environment variable reaches — see "Why inbound
  still fails".

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
# {"aliases":["https://nodus/users/ada"],"links":[
#   {"href":"https://nodus/users/ada","rel":"self","type":"application/activity+json"},
#   {"href":"https://nodus/@ada","rel":"http://webfinger.net/rel/profile-page","type":"text/html"}],
#  "subject":"acct:ada@nodus"}
```

The third is the exact call that used to fail with
`Connection refused - connect(2) for 172.20.0.11:443 on https://nodus/.well-known/webfinger`.

### The peers at their advertised origin

Two more sites in `integration/Caddyfile`, in the same `(routes)`-snippet style as
the `:8080` and `https://nodus:443` ones — except that each imports nothing,
because it terminates a *peer's* origin and must proxy, not route:

```caddyfile
https://mastodon.test {
	tls internal
	encode zstd gzip
	reverse_proxy mastodon:80
}

https://misskey.test {
	tls internal
	encode zstd gzip
	reverse_proxy misskey:18082
}
```

Caddy is the only container holding the `mastodon.test` / `misskey.test`
aliases (they were removed from the peer services), because the name has to
resolve to one address and that address must be the one terminating TLS. The
certificates come from the same internal authority, so the peers' existing
`/certs/nodus-lab-ca.crt` copy is enough to trust them; nothing is published on
host 443.

### The origin trusts the same CA

The origin now fetches `https://mastodon.test/...` and `https://misskey.test/...`,
so it is a client of that authority too. Rust reads `SSL_CERT_FILE`
(`rustls-platform-verifier`, pulled in by reqwest's `rustls` feature), so the
same concatenated-bundle trick the Mastodon services use applies unchanged:

| service | how |
| --- | --- |
| `nodus-api`, `nodus-media-worker`, `nodus-feed`, `nodus-scan`, `nodus-prune`, `nodus-calc` | `entrypoint: [tini, --, /opt/nodus/bin/lab-ca-entrypoint.sh]` from the `x-nodus-service` anchor; the script appends `/certs/nodus-lab-ca.crt` to the image bundle and writes `/tmp/nodus-lab-ca-bundle.crt`, which `SSL_CERT_FILE` names |

Verified from the API's own process, not by assumption — the container's
`curl` proves the CA and the route, and a resolve through the API proves the
Rust client:

```sh
docker exec nodus-lab-api curl -s -o /dev/null -w '%{http_code}\n' \
  --cacert /tmp/nodus-lab-ca-bundle.crt https://mastodon.test/health
# 200
docker exec nodus-lab-api curl -s -o /dev/null -w '%{http_code}\n' \
  --cacert /tmp/nodus-lab-ca-bundle.crt https://misskey.test/healthz
# 200

curl -sS -H "authorization: Bearer $TOKEN" \
  'http://127.0.0.1:18080/api/v2/search?q=https%3A%2F%2Fmastodon.test%2Fusers%2Falice&resolve=true'
# 200 {"accounts":[{"id":"01m7y4hf4w9ph9smharrkm6acf","acct":"alice@mastodon.test",
#                   "url":"https://mastodon.test/@alice"}],"statuses":[],"hashtags":[]}

docker exec nodus-lab-api curl -s -o /dev/null -w '%{http_code}\n' -k \
  -H 'accept: application/activity+json' https://misskey.test/users/attcaex9uoqp0002
# 200
```

A resolve that fails at TLS leaves exactly one trace — `discovery: could not
store a resolved account … error=…` in the API log — while a resolve that fails
at the *host* rule leaves none, because it never gets that far. That is the
distinction the two runs below turn on.

### What this leg does not change

- **The origin's identity is `https://nodus`.** `compose.yml` defaults
  `NODUS_BASE_URL` to `https://nodus`, and the actor document's `id`, `inbox`,
  `outbox`, `followers` and `publicKey.id` are all under it. `http://nodus:8080`
  stays served (Playwright, `up.sh`, the host browser) but is no longer the
  canonical address. See "Changing the base URL does not rewrite identity".
- **The peers address the origin over TLS.** With `NODUS_ALLOW_INSECURE_PEERS`
  empty, nothing in the lab needs the plain-http escape hatch any more.
- **The inbound signature check is untouched.** A delivery from a `.local`
  signer is still `401` by design (`.local` is mDNS), which is why the lab names
  the peers under `.test` — see "Why `.local` is refused by design".

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
| `nodus-account.json`    | the lab's own `ada@nodus` OAuth token            |

- **Mastodon:** created with `tootctl accounts create --confirmed --approve`,
  password set through the model (`tootctl accounts modify` has no
  `--password`), then a `password`-grant token. Doorkeeper resolves the resource
  owner with `User.find_by(email: request.params[:username])`
  (`config/initializers/doorkeeper.rb`), so the grant must be fed
  `alice@mastodon.test`, not `alice`.
- **Misskey:** the root account is created with `setupPassword` from
  `peers/misskey/default.yml`, and that root token creates or deletes
  `alice@misskey.test` by idempotent lookup. The account token is a real
  Misskey access token — `POST /api/i` with it returns the account — and it is
  stored in the named volume's database, so it survives `down.sh` + `up.sh`
  (`down.sh`/`reset.sh` remove the volumes and therefore the accounts; run
  `seed` again afterwards).

## What a browser needs

The peer UIs bind to `127.0.0.1` on published ports. Both peers emit absolute
URLs for their canonical origin, so the hostname has to match what the peer
believes it is:

    # /etc/hosts
    127.0.0.1 mastodon.test misskey.test

- **Both UIs are inspect-only now.** Each peer emits absolute URLs for
  `https://<domain>`, which the host reaches only if `mastodon.test` /
  `misskey.test` resolve to `127.0.0.1` *and* something answers 443 there —
  nothing does, by design (host 443 is not ours). Use the API tokens in
  `integration/state/*.json` for scripted checks; the UI is useful for looking,
  not for flows that redirect through the canonical origin.
- **Nothing federates over the published ports.** They exist for those tokens
  and for a human eye.
- Both peers must not publish 8080 or 5432.

## The origin's outbound guard

`NODUS_ALLOW_INSECURE_PEERS` names the hosts the API may reach over plain `http`;
it is **empty** in this lab, because both peers answer https through Caddy.
`compose.yml` forwards it to every nodus service and `compose.peers.yml` sets
`NODUS_ALLOW_PRIVATE_HOSTS=mastodon.test,misskey.test,mastodon,misskey` on
`nodus-api`, which is the half that still matters: the resolver refuses private
addresses unless the host is named, and the peers live on the bridge.

Two consequences are worth knowing before reading the results below:

- **A handle carries no port.** `alice@mastodon.test` makes the origin fetch
  `https://mastodon.test/.well-known/webfinger`, i.e. 443, which is Caddy.
- **Mastodon advertises itself without a port.** It builds actor and inbox URLs
  from `WEB_DOMAIN`, which cannot carry one, so the origin is told to deliver to
  `https://mastodon.test/inbox` — 443, Caddy, `reverse_proxy mastodon:80`. The
  web process stays on 80 inside the network for exactly that reason.

## What this run proves

This is the `.test` run. The peers advertise `https://mastodon.test` and
`https://misskey.test` (RFC 6761 sets `.test` aside for testing, and the
origin's reserved-suffix list does not include it). The rename is a lab change
only: `LOCAL_DOMAIN`/`WEB_DOMAIN`, Misskey's `url`, both Caddy site blocks,
`NODUS_ALLOW_PRIVATE_HOSTS`, `scripts/peers.sh` and this document. The peer
databases were recreated rather than migrated (Mastodon persists `LOCAL_DOMAIN`
in account rows and Redis): the four peer volumes were removed and
`peers.sh seed` re-created `alice@mastodon.test` and `alice@misskey.test`. No
backend code changed for this run.

`integration/scripts/peers.sh follow` exits 0; the results below are the literal
output of that run plus the follow-up queries.

These proofs need the peer stack. A run that starts only the origin —
`scripts/up.sh` then `scripts/seed.sh`, which is CI's default push/PR path — has
no remote account stored, so `integration/e2e/tests/federation.spec.mjs` and
`federation-visual.spec.mjs` skip themselves with that reason instead of
passing or failing, and their rows are missing from a peer-free run. The guard
probes the origin's store rather than an environment variable, so `peers.sh up`
restores them without anyone flipping a flag. Any run meant to cover federation
must bring the peers up before the suite; the default CI job does not.

Reachability, from the origin's own container:

```sh
docker exec nodus-lab-api getent hosts mastodon.test misskey.test nodus
# 172.20.0.15     mastodon.test
# 172.20.0.15     misskey.test
# 172.20.0.15     nodus
docker exec nodus-lab-api printenv SSL_CERT_FILE
# /tmp/nodus-lab-ca-bundle.crt
docker exec nodus-lab-api printenv NODUS_ALLOW_PRIVATE_HOSTS
# mastodon.test,misskey.test,mastodon,misskey
docker exec nodus-lab-api curl -s -o /dev/null -w '%{http_code}\n' \
  --cacert /tmp/nodus-lab-ca-bundle.crt https://mastodon.test/health
# 200
docker exec nodus-lab-api curl -s -o /dev/null -w '%{http_code}\n' \
  --cacert /tmp/nodus-lab-ca-bundle.crt https://misskey.test/healthz
# 200
```

### (a) nodus → Mastodon: resolve, follow, delivery — **proven**

```sh
GET /api/v2/search?q=https%3A%2F%2Fmastodon.test%2Fusers%2Falice&resolve=true
# HTTP 200 {"accounts":[{"id":"01m7y59g50akmfqj1x3x14wch8","acct":"alice@mastodon.test",
#                       "url":"https://mastodon.test/@alice","followers_count":1},...]}

POST /api/v1/accounts/01m7y59g50akmfqj1x3x14wch8/follow
# HTTP 200 {"following":true,"requested":false,"followed_by":true,...}
```

The origin delivers over the lab CA, to both peers:

```sh
docker logs nodus-lab-api | grep 'activity delivered'
# activity delivered inbox=https://mastodon.test/inbox status=202
# activity delivered inbox=https://misskey.test/inbox status=202
```

Mastodon's home timeline for alice then carries ada's posts:

```sh
GET http://127.0.0.1:18081/api/v1/timelines/home?limit=10   # with alice's token
# [{"id":"117652507445367982","uri":"https://nodus/statuses/01m7y59q9gft4th2zdz8b2r3y4",
#   "url":"https://nodus/@ada/01m7y59q9gft4th2zdz8b2r3y4",
#   "content":"<p>hello from nodus, misskey reaction check</p>",
#   "account":{"acct":"ada@nodus","uri":"https://nodus/users/ada"}},...]
```

### (b) Mastodon → nodus: follow, Accept and Create — **proven**

The follow is a fresh resolution — the peer database was recreated for this run,
so no cached `ada@nodus` row survived:

```sh
GET /api/v2/search?q=https%3A%2F%2Fnodus%2Fusers%2Fada&resolve=true&type=accounts
# HTTP 200 {"accounts":[{"id":"117652506454551665","acct":"ada@nodus",
#                       "uri":"https://nodus/users/ada",
#                       "inbox_url":"https://nodus/users/ada/inbox"},...]}

POST /api/v1/accounts/117652506454551665/follow
# HTTP 200 {"following":true,"requested":false,"followed_by":true,...}
```

The origin now accepts the signed activity instead of answering `401`:

```sh
docker logs nodus-lab-api --since 30m | grep 'accepted inbound'
# accepted inbound activity kind=Follow actor=https://mastodon.test/users/alice
# accepted inbound activity kind=Accept actor=https://mastodon.test/users/alice
# accepted inbound activity kind=Create actor=https://mastodon.test/users/alice
```

A peer-authored row is stored, and it is served back through the API the shell
reads:

```sh
docker exec nodus-lab-postgres psql -U nodus -d nodus -c \
  "select s.id, a.username, a.domain, s.uri
     from status s join account a on a.id = s.account_id
    where a.domain is not null;"
#              id             | username |    domain     |                              uri
# ----------------------------+----------+---------------+-----------------------------------------------------------------
#  01m7y5avpp44m68wpwb3tfsdct | alice    | mastodon.test | https://mastodon.test/users/alice/statuses/117652509134446676
#  01m7y5hp965sv3798bvdcxw8e7 | alice    | mastodon.test | https://mastodon.test/users/alice/statuses/117652523807697779
#  01m7y5txkt209fp97tkry2jsps | alice    | mastodon.test | https://mastodon.test/users/alice/statuses/117652543626743910

curl -sS -H "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:18080/api/v1/accounts/$ALICE_ID/statuses?limit=5"
# [{"id":"01m7y5txkt209fp97tkry2jsps","content":"<p>hello from mastodon, follows are live</p>"},
#  {"id":"01m7y5hp965sv3798bvdcxw8e7","content":"<p>hello from mastodon, follows are live</p>"},
#  {"id":"01m7y5avpp44m68wpwb3tfsdct","content":"<p>hello from mastodon.test, inbound create check</p>"}]
```

### (c) Misskey → nodus: follow and Like accepted; reaction not stored — **partial, with a residual**

Addressing, note dereference and the follow all work; the delivery from Misskey
first came back `401` for a reason that is *not* the host rule:

```text
# nodus-lab-misskey, delivery queue
[queue deliver] failed(UnrecoverableError: 401 Unauthorized) ... to=https://nodus/users/ada/inbox
# nodus-lab-api, the 401 body (a signed probe with alice's own key)
401 {"error":"activitypub read failed: error sending request for url
(https://misskey.test/users/attgqpslu33y0002)"}
```

Verifying a signature fetches the signer's key through the ActivityPub client
(`server-sdk/crates/activitypub-client/src/client.rs`), whose `SafeDnsResolver`
refuses private addresses and is **not** widened by `NODUS_ALLOW_PRIVATE_HOSTS`;
Caddy answers on `172.20.0.15`. The origin's own outbound resolver does honour
the allowlist, so resolving the Misskey actor through nodus first caches the key
and the next delivery verifies:

```sh
curl -sS -H "authorization: Bearer $TOKEN" \
  'http://127.0.0.1:18080/api/v2/search?q=%40alice%40misskey.test&resolve=true'
# 200 {"accounts":[{"id":"01m7y5hhsq76ew840cfhmkbj8m","acct":"alice@misskey.test",
#                   "url":"https://misskey.test/users/attgqpslu33y0002"}],...}
```

After that, the same `peers.sh follow` run:

```sh
POST /api/ap/show {"uri":"https://nodus/users/ada"}
# HTTP 200 {"type":"User","object":{"id":"attgr0q8u33y0003","host":"nodus",
#            "uri":"https://nodus/users/ada"}}
POST /api/following/create {"userId":"attgr0q8u33y0003"}
# HTTP 200
POST /api/ap/show {"uri":"https://nodus/statuses/01m7y5hwj9dy41dn99nya8tmjw"}
# HTTP 200 {"type":"Note","object":{...,"uri":"https://nodus/statuses/01m7y5hwj9dy41dn99nya8tmjw"}}
POST /api/notes/reactions/create {"noteId":"attgwr9su33y0009","reaction":"👍"}
# HTTP 204
nodus reactions before: []
nodus reactions after:  []

docker logs nodus-lab-api --since 30m | grep 'accepted inbound'
# accepted inbound activity kind=Follow actor=https://misskey.test/users/attgqpslu33y0002
# accepted inbound activity kind=Like   actor=https://misskey.test/users/attgqpslu33y0002
```

The `Follow` is stored (the account is a follower), but the `Like` produces no
favourite and `status_reaction` stays empty:

- ActivityPub `Like` is mapped to a favourite (`crates/api/src/activitypub.rs:468`
  → `like_local`, `:1129`), not to `status_reaction`; `status_reaction` is
  written only by the Misskey-compatible reactions API.
- `like_local` resolves its target with `statuses::by_uri`
  (`crates/store/src/statuses.rs:191-198`), which matches `status.uri`; local
  rows have a null `uri`, so a `Like` aimed at `https://nodus/statuses/<id>`
  finds nothing and returns `Ok`. `status_for_uri`/`local_status_id`
  (`crates/api/src/poll_votes.rs:125-139`) already handle both spellings, but
  `like_local`/`boost_local` do not use them. Mastodon has the same result: it
  reports `{"favourited":true}` for a nodus post while nodus stores no
  peer-authored favourite.
- Misskey renders `Like` with `content` (its emoji) rather than `EmojiReact`,
  and `EmojiReact` is not an `ActivityKind`
  (`crates/activitypub-core/src/activity.rs:71-89`), so there is no inbound path
  that would create an emoji reaction row either.

### (d) A peer post in the lab shell — **the data is served; the HTML is a SPA**

```sh
docker exec nodus-lab-postgres psql -U nodus -d nodus -c \
  "select count(*) from status s join account a on a.id = s.account_id
    where a.domain is not null;"
#  3
docker exec nodus-lab-postgres psql -U nodus -d nodus -c \
  "select count(*) from status_reaction;"
#  0
```

Both peer-authored statuses are returned by the endpoint the profile route reads
(`/api/v1/accounts/<id>/statuses`, output in (b)). The unauthenticated HTML is
the client-side boot shell:

```sh
curl -sS http://127.0.0.1:18080/@alice@mastodon.test | grep '<title>'
# <title>Sign in · Nodus
```

The web client is a WASM app that authenticates in the browser (OAuth/PKCE,
IndexedDB), so its HTML does not embed the timeline and a server-side cookie
cannot stand in for that session. The account page renders the peer's posts once
a browser is signed in; the API above is the data it renders.

## Why `.local` is refused by design

The inbound host check is a reserved-suffix rule: `is_disallowed_domain`
(`crates/api/src/activitypub.rs:981-993`) matches exactly

```rust
["localhost", "local", "internal", "localdomain", "home.arpa"]
```

`.local` is the mDNS suffix (RFC 6762). A key fetched from an actor under it is
not trustworthy, so the refusal is correct product behaviour and the guard was
left untouched. The old lab names hit it before the key was fetched:

```text
POST https://nodus/users/ada/inbox   (keyId .../users/alice#main-key, mastodon.local)
# 401 {"error":"signing key actor URL is invalid"}
```

The same probe with a `.example` keyId passed host classification and failed
later, on the signature/actor comparison (`signing key does not match activity
actor`) — proof that the address was the only thing in the way. `.test` is not
on the list, which is why the peers now live there.

## What the TLS leg proves

Status `202` from `https://mastodon.test/inbox` and `https://misskey.test/inbox`
means each peer accepted a nodus delivery over the lab CA; the accepted follow
at Mastodon and the posts it serves back (a) show the same bridge used from the
other side. The origin's side of that bridge is (b): the CA bundle, DNS aliases
and host classification all line up.

## Two node URLs, and which one is ActivityPub

    status.uri / status.url  ->  https://nodus/@ada/<id>      (HTML page)
    AP object id (outbox)    ->  https://nodus/statuses/<id>  (activity+json)

`/@ada/<id>` answers `text/html` even for `Accept: application/activity+json`,
so a peer that dereferences `status.uri` sees a web page and reports
`Content type is not application/activity+json or application/ld+json`. Use the
outbox id; `scripts/peers.sh` does.

## Changing the base URL does not rewrite identity

The actor URI is assigned once, on the first request that needs a key, and then
persisted (`ensure_identity` → `accounts::set_actor_identity`,
`crates/api/src/activitypub.rs:1735-1760`). Changing `NODUS_BASE_URL` therefore
leaves whichever accounts already had an identity pointing at the old URL, while
`url` and the rest of the document follow the new one — an actor whose `id` and
`inbox` are `http://nodus:8080/...` and whose `url` is `https://nodus/@ada`.
Misskey refused exactly that in the first attempt of this run:

    bad Activity: neither id(http://nodus:8080/users/ada) nor
    url(https://nodus/@ada) match location(https://nodus/users/ada)

That is the lab's migration step, not a backend change — reset the identity
columns of the local accounts that predate the new base URL and let the next
request mint them:

```sh
docker exec -e PGPASSWORD="$(sed -n 's|^NODUS_DB_PASSWORD=||p' integration/.env)" \
  nodus-lab-postgres psql -U nodus -d nodus -c \
  "update account set uri = null, inbox_url = null, shared_inbox_url = null,
     public_key_pem = null, private_key_pem = null
   where domain is null and uri is not null;"
# UPDATE 1
```

After that the actor document is consistent:

```sh
docker exec nodus-lab-api curl -s -k -H 'accept: application/activity+json' \
  https://nodus/users/ada | jq -r '.id, .url, .inbox, .publicKey.id'
# https://nodus/users/ada
# https://nodus/@ada
# https://nodus/users/ada/inbox
# https://nodus/users/ada#main-key
```

The peers cache the old identity, so they need the same treatment on their side:
destroy the remote `ada@nodus` account in Mastodon
(`Account.find_by(domain: "nodus", username: "ada").destroy`) and
`delete from "user" where host is not null` in Misskey's database. Both were
re-resolved fresh for this run, which is what makes (b)'s `uri` value evidence.

## Recreating the origin changes its address, and Misskey caches it

## What would close the remaining gap

The domain-name blocker is closed by this run (the peers are `.test`). What is
left is backend work, listed in the order it shows up:

1. **Let `NODUS_ALLOW_PRIVATE_HOSTS` reach the inbound key fetch too.** The
   ActivityPub client's `SafeDnsResolver`
   (`server-sdk/crates/activitypub-client/src/client.rs`) rejects private
   addresses unconditionally, so a cold inbound delivery from a peer on the lab
   bridge is `401` until the origin has resolved that actor outbound. The lab
   works around it by priming the actor (`peers.sh follow` does), but the
   resolver should honour the same allowlist as `crates/api/src/remote.rs`.
2. Make `like_local`/`boost_local` resolve local targets with `status_for_uri`
   (`crates/api/src/poll_votes.rs:125-139`) so an accepted `Like` lands on a
   local post instead of being dropped after a `by_uri` miss.
3. Decide whether `EmojiReact` should be a first-class `ActivityKind` with a
   reaction table, or whether Misskey's `Like`+`content` is enough.

## Commands used

```sh
compose() {
  docker compose --project-name nodus-lab --env-file integration/.env \
    -f integration/compose.yml -f integration/compose.peers.yml "$@"
}

# recreate the peer databases (LOCAL_DOMAIN is persisted in rows and Redis);
# the origin's postgres/valkey and nodus-api data are not touched
compose rm -s -f -v mastodon mastodon-sidekiq mastodon-setup mastodon-db \
  mastodon-redis misskey misskey-db misskey-redis misskey-files-init
docker volume rm nodus-lab-mastodon-db nodus-lab-mastodon-system \
  nodus-lab-misskey-db nodus-lab-misskey-files
integration/scripts/peers.sh up
integration/scripts/peers.sh seed

# reachability and trust from the origin's own container
docker exec nodus-lab-api getent hosts mastodon.test misskey.test nodus
docker exec nodus-lab-api printenv SSL_CERT_FILE NODUS_ALLOW_PRIVATE_HOSTS
docker exec nodus-lab-api curl -s -o /dev/null -w '%{http_code}\n' \
  --cacert /tmp/nodus-lab-ca-bundle.crt https://mastodon.test/health      # 200
docker exec nodus-lab-api curl -s -o /dev/null -w '%{http_code}\n' \
  --cacert /tmp/nodus-lab-ca-bundle.crt https://misskey.test/healthz      # 200

# the four checks
integration/scripts/peers.sh follow

# what came out of them
docker logs --since 30m nodus-lab-api | grep 'accepted inbound'
docker logs --since 30m nodus-lab-api | grep 'activity delivered'
docker logs --since 30m nodus-lab-misskey | grep 'queue deliver'
docker exec nodus-lab-postgres psql -U nodus -d nodus -c \
  "select count(*) from status s join account a on a.id = s.account_id
    where a.domain is not null;"
docker exec nodus-lab-postgres psql -U nodus -d nodus -c \
  "select count(*) from status_reaction;"
```
