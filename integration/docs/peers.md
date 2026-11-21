# Federation peers

`compose.peers.yml` adds two real fediverse servers next to the lab so
federation can be exercised against software that is not ours:

| service    | image                              | host (UI, inspect-only)  | canonical origin (peers)   |
| ---------- | ---------------------------------- | ------------------------ | -------------------------- |
| `mastodon` | `ghcr.io/mastodon/mastodon:v4.3.6` | `http://127.0.0.1:18081` | `https://mastodon.local`   |
| `misskey`  | `misskey/misskey:2024.11.0`        | `http://127.0.0.1:18082` | `https://misskey.local`    |

Every peer speaks to the origin, and is spoken to, at the address it advertises:
`https://<peer domain>` on **443**, terminated by the lab Caddy. The published
`127.0.0.1` ports are the container's own listener, kept for the browser and for
API tokens; nothing federates over them.

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
Misskey's is `https://misskey.local/` (its `url`). Those strings are what peers
see in handles, actor ids and ActivityPub ids; changing either after the first
follow orphans everything already federated.

A peer builds every remote address as `<scheme>://<host>`, with no port, and
ActivityPub ids in both peers are `https` even in development. So the address
they advertise has to be an https origin on 443 — which is what the Caddyfile's
two peer site blocks serve:

    Caddy  https://mastodon.local (443)  ──►  mastodon:80     (web process)
    Caddy  https://misskey.local  (443)  ──►  misskey:18082  (container port)
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
https://mastodon.local {
	tls internal
	encode zstd gzip
	reverse_proxy mastodon:80
}

https://misskey.local {
	tls internal
	encode zstd gzip
	reverse_proxy misskey:18082
}
```

Caddy is the only container holding the `mastodon.local` / `misskey.local`
aliases (they were removed from the peer services), because the name has to
resolve to one address and that address must be the one terminating TLS. The
certificates come from the same internal authority, so the peers' existing
`/certs/nodus-lab-ca.crt` copy is enough to trust them; nothing is published on
host 443.

### The origin trusts the same CA

The origin now fetches `https://mastodon.local/...` and `https://misskey.local/...`,
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
  --cacert /tmp/nodus-lab-ca-bundle.crt https://mastodon.local/health
# 200
docker exec nodus-lab-api curl -s -o /dev/null -w '%{http_code}\n' \
  --cacert /tmp/nodus-lab-ca-bundle.crt https://misskey.local/healthz
# 200

curl -sS -H "authorization: Bearer $TOKEN" \
  'http://127.0.0.1:18080/api/v2/search?q=https%3A%2F%2Fmastodon.local%2Fusers%2Falice&resolve=true'
# 200 {"accounts":[{"id":"01m7y4hf4w9ph9smharrkm6acf","acct":"alice@mastodon.local",
#                   "url":"https://mastodon.local/@alice"}],"statuses":[],"hashtags":[]}

docker exec nodus-lab-api curl -s -o /dev/null -w '%{http_code}\n' -k \
  -H 'accept: application/activity+json' https://misskey.local/users/attcaex9uoqp0002
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
  signer is still `401` — see "Why inbound still fails".

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

- **Both UIs are inspect-only now.** Each peer emits absolute URLs for
  `https://<domain>`, which the host reaches only if `mastodon.local` /
  `misskey.local` resolve to `127.0.0.1` *and* something answers 443 there —
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
`NODUS_ALLOW_PRIVATE_HOSTS=mastodon.local,misskey.local,mastodon,misskey` on
`nodus-api`, which is the half that still matters: the resolver refuses private
addresses unless the host is named, and the peers live on the bridge.

Two consequences are worth knowing before reading the results below:

- **A handle carries no port.** `alice@mastodon.local` makes the origin fetch
  `https://mastodon.local/.well-known/webfinger`, i.e. 443, which is Caddy.
- **Mastodon advertises itself without a port.** It builds actor and inbox URLs
  from `WEB_DOMAIN`, which cannot carry one, so the origin is told to deliver to
  `https://mastodon.local/inbox` — 443, Caddy, `reverse_proxy mastodon:80`. The
  web process stays on 80 inside the network for exactly that reason.

## What this run proves

Run state: the backend was **not** rebuilt for this run (no backend commit is
involved); the superproject changes are the Caddyfile peer sites, the origin's CA
wrapper, `NODUS_BASE_URL`, the two peer identities and `scripts/peers.sh`. Every
nodus service was recreated with `--force-recreate`, because a new mount or
entrypoint does not reach an existing container.

Reachability first, from inside the origin's own container:

```sh
docker exec nodus-lab-api getent hosts mastodon.local misskey.local
# 172.20.0.16     mastodon.local
# 172.20.0.16     misskey.local          (Caddy, the only container with these aliases)
```

Both names resolve to Caddy and Caddy answers `200` on both (commands in "The
origin trusts the same CA"). The four proofs below are reported as they came out.

### (a) nodus → Mastodon: resolve, follow, delivery — **proven; ingest still 401**

    GET /api/v2/search?q=https%3A%2F%2Fmastodon.local%2Fusers%2Falice&resolve=true
    HTTP 200
    {"accounts":[{"id":"01m7y4hf4w9ph9smharrkm6acf","username":"alice",
                  "acct":"alice@mastodon.local","url":"https://mastodon.local/@alice"},...]}

    POST /api/v1/accounts/01m7y4hf4w9ph9smharrkm6acf/follow
    {"id":"01m7y4hf4w9ph9smharrkm6acf","following":true,"requested":false,...}
    HTTP 200

The origin delivers to the shared inbox Mastodon advertised, over the lab CA:

    nodus_server_api::outbox: activity delivered inbox=https://mastodon.local/inbox status=202
    # 202 at 04:07:20 (Follow) and 04:08:40 (a note)

Mastodon records the follow from the peer:

    F ada@nodus -> alice@

What is still missing is the other half: alice's posts are delivered *to* the
origin, and that delivery is the 401 in (b). So no Mastodon post is ingested:

    GET /api/v1/accounts/01m7y4hf4w9ph9smharrkm6acf/statuses?limit=10
    []

### (b) Mastodon → nodus: resolve, follow, delivery — **addressing proven, delivery still 401**

The cached `http` remote account from the previous run was destroyed and the
domain's cache cleared (`tootctl cache clear` → `OK`; `tootctl domains` exposes
only `crawl`/`purge` and had no `nodus` row), so this is a fresh resolution:

    GET /api/v2/search?q=https%3A%2F%2Fnodus%2Fusers%2Fada&resolve=true&type=accounts
    HTTP 200
    {"accounts":[{"id":"117652462960056716","acct":"ada@nodus",
                  "uri":"https://nodus/users/ada","url":"https://nodus/@ada",
                  "inbox_url":"https://nodus/users/ada/inbox",...}]}

    POST /api/v1/accounts/117652462960056716/follow
    {"id":"117652462960056716","following":true,"requested":false,...}
    HTTP 200

The fresh `Follow` job — not a retried old row — reaches the origin on 443 and
is refused:

    # sidekiq, retry_count 0
    args: [... {"type":"Follow","actor":"https://mastodon.local/users/alice",
                "object":"https://nodus/users/ada"}, ...,
           "https://nodus/users/ada/inbox"]
    [httplog] POST https://nodus/users/ada/inbox completed with status code 401
    Mastodon::UnexpectedResponseError: https://nodus/users/ada/inbox returned code 401

TLS, DNS, certificate trust and the advertised addresses are therefore all
correct; what refuses the delivery is the origin's signature check — see "Why
inbound still fails". The wall is symmetric: the `Accept` Mastodon sends for
*ada's* follow of alice takes the same route and the same answer —

    {"type":"Accept","actor":"https://mastodon.local/users/alice",
     "object":{"type":"Follow","actor":"https://nodus/users/ada",
               "object":"https://mastodon.local/users/alice"}} -> https://nodus/users/ada/inbox
    401, retry_count 3

— so the origin never learns the follow was accepted, and Mastodon keeps a
pending `FollowRequest` for `alice → ada@nodus` because it never receives an
`Accept` of its own.

### (c) Misskey → nodus: resolve, follow, note deref, reaction — **addressing proven, delivery still 401**

    POST /api/ap/show {"uri":"https://nodus/users/ada"}
    HTTP 200 {"type":"User","object":{"id":"attgcsezzuny0001","host":"nodus",
              "url":"https://nodus/@ada","uri":"https://nodus/users/ada",...}}

    POST /api/following/create {"userId":"attgcsezzuny0001"}   -> 200
    POST /api/ap/show {"uri":"https://nodus/statuses/01m7y4nex1g9v3nze79hwjf4t3"}
    HTTP 200 {"type":"Note","object":{...,"uri":"https://nodus/statuses/01m7y4nex1g9v3nze79hwjf4t3"}}

    POST /api/notes/reactions/create {"noteId":"attgcs4wzuny0004","reaction":"👍"}
    HTTP 204
    nodus reactions before: []
    nodus reactions after:  []

Its delivery lands on the same wall as Mastodon's (`to=https://nodus/users/ada/inbox`,
`UnrecoverableError: 401 Unauthorized`), so nothing reaches an ingest handler and
the code-level caveats below are still untested by this run:

- Misskey renders `Like` with `content` (`ApRendererService#renderLike`), not
  `EmojiReact`; nodus handles `Like` (`crates/api/src/activitypub.rs:468` →
  `like_local`, `:1112`).
- `EmojiReact` is not an `ActivityKind`
  (`crates/activitypub-core/src/activity.rs:71-89`) and is rejected with
  `422 unsupported activity type: EmojiReact`.
- Even an accepted `Like` would not show on a local post: `like_local` resolves
  the target via `statuses::by_uri` (`crates/store/src/statuses.rs:191`), local
  rows have a null `uri`, and `status_for_uri`
  (`crates/api/src/poll_votes.rs:125-139`) — which handles both spellings — is
  not used by `like_local`/`boost_local`. There is no table or handler for a
  remote emoji reaction as such; a `Like` becomes a favourite, and an
  `EmojiReact` would need a new `ActivityKind` plus a reaction table.

### (d) A peer post in the lab web shell — **not observed, and cannot be yet**

    select count(*) from status s join account a on a.id = s.account_id
      where a.domain is not null;
    # 0

    select count(*) from status_reaction;
    # 0

There is no peer-authored row to render at `http://127.0.0.1:18080`; the shell
serves only ada's own posts. This is blocked by the same inbound 401 as (b) and
(c), not by the shell.

## Why inbound still fails: `.local` is reserved

The TLS leg is done, and it was never the blocker: `verify_signature` classifies
the signer's actor URL *before* it fetches anything. `validate_remote_url`
(`crates/api/src/activitypub.rs:947-964`) accepts the scheme via
`remote::scheme_allowed` and then calls `check_url_host` →
`is_disallowed_domain` (`:981-993`), which treats every name under a reserved
suffix as unroutable:

```rust
["localhost", "local", "internal", "localdomain", "home.arpa"]
    .iter()
    .any(|reserved| {
        d == *reserved
            || d.strip_suffix(reserved)
                .is_some_and(|prefix| prefix.ends_with('.'))
    })
```

`mastodon.local` and `misskey.local` both match, so `validate_remote_url` returns
`URL host is not a publicly routable destination`, which `verify_signature` turns
into `ApiError::unauthorized("signing key actor URL is invalid")`
(`crates/api/src/activitypub.rs:377`). Neither `NODUS_ALLOW_INSECURE_PEERS` nor
`NODUS_ALLOW_PRIVATE_HOSTS` reaches this predicate — the first only widens the
scheme, the second only the private-address rule in the *outbound* resolver.

Reproduced with a throwaway RSA key, so the signature's validity is irrelevant —
the actor URL is rejected before the key is fetched. The header value must
**not** carry a leading `Signature ` (the parser reads `name="value"` pairs,
`crates/federation/src/lib.rs:62-96`; the HTTP header name carries the word):

```sh
# keyId https://mastodon.local/users/alice#main-key
POST https://nodus/users/ada/inbox
# HTTP 401
# {"error":"signing key actor URL is invalid"}

# same request, keyId https://mastodon.example/users/alice#main-key
# HTTP 401
# {"error":"signing key does not match activity actor"}
```

The second answer is the proof that the predicate — not TLS, not the address —
is the wall: a `.example` name passes host classification and fails later, on the
signature/actor comparison. A `.local` name never gets that far.

## What the TLS leg proves

The `202`s in (a) are the peers' side of the same story: Mastodon verifies an
inbound signature by fetching the signing actor, so `status=202` from
`https://mastodon.local/inbox` means it reached `https://nodus/users/ada` through
the lab CA, fetched a nodus key and accepted a nodus-signed activity. Combined
with (b)'s `[httplog] POST https://nodus/users/ada/inbox`, both directions cross
the bridge over verified TLS. The only thing left is the origin's inbound host
classification.

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

1. **Rename the lab peers to a non-reserved suffix.** The probe above shows
   `mastodon.example` passes host classification while everything else about the
   request is identical, so `mastodon.example` / `misskey.example` (with the same
   Caddy sites, `LOCAL_DOMAIN`/`WEB_DOMAIN`, Misskey `url`, `/etc/hosts` entry)
   is a pure lab change that would open (b), (c) and (d). No origin option
   reaches `is_disallowed_domain`; only the name does.
2. **Or exempt a host named in `NODUS_ALLOW_INSECURE_PEERS` from
   `is_disallowed_domain`** (check the allowlist before the reserved-name rule)
   while still rejecting address literals and private IPs. That is the backend
   change; `b503bed` deliberately left the private-name rule untouched.
3. Make `like_local`/`boost_local` resolve local targets with `status_for_uri` so
   an accepted `Like` lands on a local post.
4. Decide whether `EmojiReact` should be a first-class `ActivityKind` with a
   reaction table, or whether Misskey's `Like`+`content` is enough.

## Commands used

```sh
compose() {
  docker compose --project-name nodus-lab --env-file integration/.env \
    -f integration/compose.yml -f integration/compose.peers.yml "$@"
}

# every service that takes a new mount or entrypoint needs --force-recreate
compose up -d --force-recreate nodus-api nodus-media-worker nodus-feed \
  nodus-scan nodus-prune nodus-calc caddy
compose up -d --force-recreate --no-deps mastodon mastodon-sidekiq misskey

# the peers at their advertised origin, and the origin trusting that CA
docker exec nodus-lab-api curl -s -o /dev/null -w '%{http_code}\n' \
  --cacert /tmp/nodus-lab-ca-bundle.crt https://mastodon.local/health      # 200
docker exec nodus-lab-api curl -s -o /dev/null -w '%{http_code}\n' \
  --cacert /tmp/nodus-lab-ca-bundle.crt https://misskey.local/healthz      # 200
docker exec nodus-lab-api getent hosts mastodon.local misskey.local

# the origin's own identity, which is persisted per account
docker exec nodus-lab-api curl -s -k -H 'accept: application/activity+json' \
  https://nodus/users/ada | jq -r '.id, .url, .inbox, .publicKey.id'

# peer-side stale state from the http era
docker exec -e RAILS_ENV=development nodus-lab-mastodon \
  bundle exec bin/tootctl cache clear
docker exec -e RAILS_ENV=development nodus-lab-mastodon \
  bundle exec bin/tootctl domains
docker exec -e RAILS_ENV=development nodus-lab-mastodon rails runner \
  'Account.find_by(domain: "nodus", username: "ada")&.destroy'
docker exec -e PGPASSWORD="$(sed -n 's|^MISSKEY_DB_PASSWORD=||p' integration/.env)" \
  nodus-lab-misskey-db psql -U misskey -d misskey -c \
  'delete from "user" where host is not null;'

# the four checks
integration/scripts/peers.sh follow

# what came out of them
docker logs --since 30m nodus-lab-api | grep -E 'activity delivered|signature'
docker logs --since 30m nodus-lab-mastodon-sidekiq | grep -E 'httplog|UnexpectedResponse'
docker logs --since 30m nodus-lab-misskey | grep -E 'queue deliver'
docker exec -e PGPASSWORD="$(sed -n 's|^NODUS_DB_PASSWORD=||p' integration/.env)" \
  nodus-lab-postgres psql -U nodus -d nodus -c \
  "select count(*) from status s join account a on a.id = s.account_id
    where a.domain is not null;"

# the two-keyId probe that isolates the host predicate (see "Why inbound still fails")
}
