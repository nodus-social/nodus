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

    nodus (Caddy alias, http://nodus:8080)  ──►  mastodon.local:3000
                                            ──►  misskey.local:18082

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

## What is proven, and what is not

`peers.sh up`, `seed` and the compose config check
(`docker compose ... config -q`) all pass, both peers are healthy, and Sidekiq
processes jobs.

The four federation proofs (`nodus → Mastodon`, `Mastodon → nodus`,
`Misskey → nodus`, peer post through the lab shell) are **not** reachable yet.
`peers.sh follow` stops at the first step:

    === nodus -> Mastodon: ada follows alice@mastodon.local ===
    -- resolve by handle
    {"accounts":[],"statuses":[],"hashtags":[]}
    HTTP 200
    -- resolve by actor URL
    {"accounts":[],"statuses":[],"hashtags":[]}
    HTTP 200
    RESULT: nodus could not resolve the Mastodon account, so no Follow was sent.

The origin refuses the peers by policy, not by configuration:

- `parse_target` (`crates/api/src/remote.rs`) returns `None` for an `http://`
  link, so the actor URL in the failure above is dropped before any request.
- Handle resolution builds `https://<host>` and `client_for_with` only ever
  probes port 443, pinning the connection to the checked address.
- `NODUS_ALLOW_PRIVATE_HOSTS` bypasses the private-address half of that guard
  for the named hosts, but not the scheme or the port.

Making the lab federate requires either an origin change (an explicit,
operator-named allowance for plain-http peers, mirroring the existing
`NODUS_ALLOW_PRIVATE_HOSTS` affordance) or terminating TLS for both peers on
port 443 with a CA the API container trusts. Both are product decisions for the
origin, not peer-side configuration, so they are recorded here rather than
improvised in the peer stack.
