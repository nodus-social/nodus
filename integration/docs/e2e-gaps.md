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

## `statuses_count` is 0 in the API row for a remote account

Still open, and narrower than the entry this replaces: the profile's Posts tab
renders the statuses, but the account row `statuses_count` is 0 for a remote
account (`/api/v1/accounts/01m7yznagw96czhm7tzaqyk8w6`), so any screen that
trusts the number shows `0 posts`. Owner: `server` accounts API — the counter is
never recomputed on delivery.

## A remote post's permalink is readable only without a session

`/status/mastodon.test/{id}` is the form the shell paints (`rows.rs`
`status_path(Some(&host), &inner.id)`) and it carries the id THIS origin minted.
Two halves, two states:

- Anonymous: `web-server` `63a3777` reads the origin's own stored row before the
  peer (`public_api.rs` `local_read`, guarded by `token.is_none()`), so the
  painted link renders. Covered by `tests/federation.spec.mjs`
  (`an anonymous reader opens a remote post by the id this origin minted`).
  It needs the lab wiring in `integration/compose.yml` (`nodus-web` gets
  `NODUS_INSTANCE_HOST` and the lab CA), otherwise the self-read is refused as a
  non-public host.
- Signed in: the browser sends a token, `local_read` is skipped, and the proxy
  relays the peer's own id to `https://mastodon.test`, which inside the lab is a
  private address the SSRF guard refuses — `The instance could not be reached:
  HTTP 502`. Owner: `web-server` public-api proxy (whether a signed-in read of a
  peer's own id should also consult the stored row, or the lab should front the
  peers on a name the guard trusts).

## Re-authenticating after a reload stops on the consent page

`tests/statuses.spec.mjs` (`a favourite survives a reload`) reloads with a
valid session, clears the stored record, and drives the OAuth helper again.
The login form accepts the credentials, the consent page appears, but the
callback never returns to `/home`; the same helper works from a fresh
context. Owner: `web-client` OAuth handoff.

## The Local timeline renders no caption

`tests/timelines.spec.mjs` keeps its Local row in `test.fixme` because the Local
tab paints neither the "Posts from this instance." caption that
`web/crates/route/src/route/mod.rs` defines nor the post copy the row checks.
The posts themselves render, and the Federated half of that row now passes, so
the fixme names the caption only. Owner: `web-client` feed page.

## Unfollow returns non-2xx

`POST /api/v1/accounts/:id/unfollow` answers non-success for Ada and the
admin, so the follow edge cannot be removed through the API and the
unfollow-visibility row has no state to arrange. Owner: `server` accounts
API.
