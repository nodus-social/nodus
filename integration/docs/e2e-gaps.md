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

## The federated timeline serves local posts only

`integration/e2e/tests/federation*.spec.mjs` shows peer-authored statuses
through search, not through `/home/federated`. The reason is in the client
request: `sdk/crates/mastodon/src/rest/api/mod.rs` sends
`StreamKind::Federated` to `/api/v1/timelines/public` without `local=false`,
and the API's default is `local=true` (`/api/v1/timelines/public?limit=20`
returns the five seeded local posts, while `...&local=false` returns the
three `alice@mastodon.test` posts first). Owner: `sdk` (Mastodon client).

## A remote profile renders no posts

`/accounts/mastodon.test/alice` finds the account (header, follow verbs) but
the Posts tab says `0 posts`, although
`/api/v1/accounts/01m7y59g50akmfqj1x3x14wch8/statuses` returns the three
delivered peer statuses. The account row's `statuses_count` is 0 too, so the
screen trusts a number that was never updated for a remote account. Owner:
`web-client` account screen / SDK store.

## A remote status permalink cannot be read by the host browser

`/status/mastodon.test/{id}` parses and calls the public read proxy, which
fetches `https://mastodon.test` from the web server; inside the lab that host
is only reachable through the lab CA, so the screen reports
`The instance could not be reached: HTTP 502`. Owner: `web-server`
public-api proxy (or the lab network, if the proxy should trust the CA).

## Re-authenticating after a reload stops on the consent page

`tests/statuses.spec.mjs` (`a favourite survives a reload`) reloads with a
valid session, clears the stored record, and drives the OAuth helper again.
The login form accepts the credentials, the consent page appears, but the
callback never returns to `/home`; the same helper works from a fresh
context. Owner: `web-client` OAuth handoff.

## The Local timeline renders no caption

`tests/timelines.spec.mjs` keeps its Local/Federated row in `test.fixme`
because the Local tab paints neither the "Posts from this instance." caption
that `web/crates/route/src/route/mod.rs` defines nor the federated copy the
row checks. The posts themselves render. Owner: `web-client` feed page.

## Unfollow returns non-2xx

`POST /api/v1/accounts/:id/unfollow` answers non-success for Ada and the
admin, so the follow edge cannot be removed through the API and the
unfollow-visibility row has no state to arrange. Owner: `server` accounts
API.
