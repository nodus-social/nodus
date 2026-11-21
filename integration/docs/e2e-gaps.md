# E2E gaps found by the browser suite

Surfaces the lab shell does not render at this build, recorded per the
skip policy: a spec that cannot pass without a product change is marked
`test.fixme` with one of the reasons below. Each row names the owning crate.

## Closed: the lab's origin was a single-label host (was: `discovery request failed`)

The shell showed `discovery request failed: Status { status: 400, message:
"X-Instance-Host must be a bare host name such as mastodon.social" }` on every
signed-in page, because the lab called itself `nodus` and the browser signed in
at `127.0.0.1:<port>`. Both are refused by the API on purpose
(`crates/api/src/activitypub.rs`, `is_disallowed_domain`), so the lab — not the
guard — was wrong. Closed without a product change: the canonical origin is now
`nodus.test` and the suite signs in there, so `X-Instance-Host` is a host name.

## Closed: the federated timeline serves local posts only

`/home/federated` now carries peer-authored statuses. The client still sends no
`local` parameter (`sdk/crates/mastodon/src/rest/api/mod.rs`, `StreamKind::Federated`),
which used to fall through to the API's `local=true` default; `server` `b02cb4b`
("serve the federated timeline the federation it stores") made the absent
parameter mean the federated view, so the gap closed on the API side and the
pinned client needed no change. Covered by `tests/federation.spec.mjs`
(`the federated timeline shows a peer-authored post`) and
`tests/timelines.spec.mjs`.

## Closed: a remote profile renders no posts

`/accounts/mastodon.test/alice` lists the delivered peer statuses (owner:
`server`, same `b02cb4b` window). Covered by
`tests/federation.spec.mjs` (`a remote profile lists the account's posts`).

## Closed: `statuses_count` was 0 in the API row for a remote account

The stored counter is maintained now (owner: `server` store, `a4e0281`).
`statuses::upsert_remote` takes the same `UPDATE account SET statuses_count =
statuses_count + 1` that `statuses::create` makes for a local author, and only
when the uri was not already in the transaction, so a re-delivery or an edit is
not a second post; `delete_remote` and `delete_remote_actor` take the rows back
out, mirroring `delete_owned`. Measured in the lab at
`/api/v1/accounts/01m7yznagw96czhm7tzaqyk8w6` (`alice@mastodon.test`), the
account row against the length of `/api/v1/accounts/{id}/statuses`, before one
more delivery, after it, and after the peer deleted that status again:

```
before          count=0  list=1
after delivery  count=1  list=2   (01m7zvcx6aess9p66cv3enaqmf)
after delete    count=0  list=1
```

The pair moves together in both directions. The residual `0` against `1` is the
row this lab stored before the fix (12:01 that day; `a4e0281` landed 20:43):
the counter moves with the insert that follows it, and nothing backfills rows
already stored, so an instance upgraded with peer rows keeps the old number
until each of those rows is re-inserted. A fresh database — what the CI lab
starts from — counts from the first delivery.

Known limitation, deliberate: a stored counter counts a status from a paused
domain while the profile list hides it. `account_page`
(`crates/store/src/statuses.rs`) filters the live rows on `domain_pause`,
`quarantined_at` and remote moderation, and `statuses_count` does not, because
the counter is the stored fact of what this instance holds for the author, not
the answer to "what may this reader see". It is the same split as a local
private post: it counts toward its author's `statuses_count` while the outbox
does not list it.

## Closed: a remote post's permalink answered only a signed-out reader

`/status/mastodon.test/{id}` is the form the shell paints (`rows.rs`
`status_path(Some(&host), &inner.id)`) and it carries the id THIS origin minted,
so no peer can answer for it. Both halves read the stored row now (owner:
`web-server` public-api proxy, `63a3777` for the anonymous read, `ff8afbb` for
the signed-in one). `public_api::status` asks `local_read` before
`status_target` for every reader; the token no longer decides whether this
origin's own copy may answer, and the relay is reached only for an id this
origin never stored. `answers_for` still decides which host a row may answer
under, so a local row cannot answer under a peer's name. A profile keeps the
sign-in gate (`Read::Profile`, `8fbabee`) on purpose: a signed-in reader's home
instance resolves a profile by url and holds their relationship state.

Covered by `tests/federation.spec.mjs` (`an anonymous reader opens a remote post
by the id this origin minted` and `a signed-in reader opens a remote post by the
id this origin minted`, the second one green in all three projects). The
anonymous read needs the lab wiring in `integration/compose.yml` (`nodus-web`
gets `NODUS_INSTANCE_HOST` and the lab CA), otherwise the self-read is refused
as a non-public host.

An id this origin does not hold still fails honestly: measured against the lab
at `https://nodus.test/public-api/status/mastodon.test/01m8zzzzzzzzzzzzzzzzzzzzzb`,
signed in and signed out alike, `HTTP 404 {"error":"Not Found"}` — the peer's
own answer, reached through the relay. No manufactured 200.

## Re-authenticating after a reload stops on the consent page

`tests/statuses.spec.mjs` (`a favourite survives a reload`) reloads with a
valid session, clears the stored record, and drives the OAuth helper again.
The login form accepts the credentials, the consent page appears, but the
callback never returns to `/home`; the same helper works from a fresh
context. Owner: `web-client` OAuth handoff.

## Closed: the Local timeline lost its header, not its caption

The caption was never the missing half. `copy` in
`web/crates/route/src/route/mod.rs` hands `TimelineScreen` a sentence per
`TimelineKind`, and `FeedPage` paints it through `PageHeader`; Local reached the
dom with "Posts from this instance." all along. What Local did lose was the
block above it: `web/crates/web-client/src/app.rs` had an arm for `Route::Home`
only, so `/home/local` and `/home/federated` fell through to the generic
`route if signed_in` arm and `RouteView` was built with no `header` slot — no
inline composer, and no tab strip, so a reader who clicked Local had no tab to
leave by (the old spec said as much: "the tab strip only exists on /home").
`LocalTimeline` and `FederatedTimeline` existed in
`web/crates/web-client/src/routes/home/mod.rs` and were never dispatched to.
Closed by giving both routes their own arm in `app.rs`; covered by
`tests/timelines.spec.mjs` (`the Local tab paints its caption, the local posts
and the switch back`), which is red at the previous build on the tab it asks
for after Local and green with the arm.

## Unfollow returns non-2xx

`POST /api/v1/accounts/:id/unfollow` answers `404 {"error":"no route for
POST /api/v1/accounts/01m7yzkjfwhazsjs93hhxpdsax/unfollow"}` for Ada and the
admin, so the follow edge cannot be removed through the API and the
unfollow-visibility row has no state to arrange. Owner: `server` accounts API;
not patched here because `nodus-backend` is owned elsewhere at this build.

Measured against the lab with Ada's token (the edge exists: `GET
/api/v1/accounts/relationships?id[]=<admin>` answers `"following": true`):

```
$ curl -i -X POST -H "Authorization: Bearer <ada token>" \
    http://127.0.0.1:18080/api/v1/accounts/01m7yzkjfwhazsjs93hhxpdsax/unfollow
HTTP/1.1 404 Not Found
{"error":"no route for POST /api/v1/accounts/01m7yzkjfwhazsjs93hhxpdsax/unfollow"}
```

That body is axum's own fallback (`nodus-backend/crates/api/src/error.rs:114-121`,
`not_found_fallback`), so the request reached the API router and the router has
no such route: Caddy forwards `/api/*` straight to `nodus-api`
(`integration/Caddyfile`, `@api` handle) and the shell never rewrites it, so
this is not a `web` proxy defect.

The handler exists; only the method and the path differ. `nodus-backend`
`crates/api/src/lib.rs:99-102` mounts it as

```rust
.route(
    "/api/v1/accounts/{id}/follow",
    post(accounts::follow).delete(accounts::unfollow),
)
```

while the pinned client posts to `/api/v1/accounts/{id}/unfollow`
(`sdk/crates/mastodon/src/rest/api/mod.rs:118-120`, `unfollow`), which is the
Mastodon spelling of the same call. The handler itself is fine
(`nodus-backend/crates/api/src/accounts.rs:379-391`).

One-line fix (in `nodus-backend`, with `post` already imported there):

```rust
.route("/api/v1/accounts/{id}/unfollow", post(accounts::unfollow))
```

`tests/timelines.spec.mjs` keeps its row in `test.fixme` with that cause in the
comment: the row ends by re-following through `POST .../follow`, which works,
so the only thing that stops it is the missing route.
