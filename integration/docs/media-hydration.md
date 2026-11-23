# Media hydration

How the shell paints a picture without swapping it after hydration.

## The rule

The document decides which file a reader gets, not a script. A profile layer is emitted as
one `<picture>`:

```html
<picture>
  <source media="(prefers-reduced-motion: reduce)" srcset="https://social.example/media/1/avatar_static">
  <img src="https://social.example/media/1/avatar" width="40" height="40" class="h-10 w-10 rounded-full object-cover" alt="" loading="lazy" fetchpriority="auto" decoding="async" referrerpolicy="no-referrer">
</picture>
```

The browser evaluates the media query while it parses the markup, before any script runs.
A reader who asked for reduced motion gets `avatar_static`; everybody else gets `avatar`.
There is no server-side "paint the still, swap the animation in" step, so:

- no media query is read in Rust (`window.match_media` is gone from the shell's picture path),
- no effect, signal or resource runs at hydration for a picture,
- the server's HTML and the client's first paint are byte-identical, so the browser fetches
  one file and decodes it once.

The pair is named by the backend: `/media/{id}/avatar` ↔ `/media/{id}/avatar_static`, and
`/media/{id}/header` ↔ `/media/{id}/header_static`. A URL that is not on that path (a remote
account's avatar, say) has no still twin; it is drawn as the single layer the instance
reported, with no `<source>` element.

`crates/ui/src/picture.rs` owns this: `avatar()`/`banner()` return the animated layer,
`avatar_still()`/`banner_still()` return the twin when there is one, and the `Picture`
component emits the markup above.

## Proof it does not move

`crates/ui/src/picture.rs` tests assert, for the rendered markup:

- the `<source>` precedes the `<img>`, and is gated on `(prefers-reduced-motion: reduce)`;
- `src`, `srcset`, `width`, `height`, `loading` and `decoding` are identical across two
  paints of the same component (the "byte-identical through hydration" test);
- the paint carries no `data-hk` hydration marker;
- a URL without a twin produces exactly one `<img>` and no `<source>`.

## Intrinsic size

Every picture declares its box, so the page never shifts when the bytes land:

| surface | width/height | source |
| --- | --- | --- |
| avatar in a row, notification, status header | 40 × 40 | the record has no dimensions; the layout's square box is the documented fallback ratio (1:1) |
| profile avatar | 64 × 64 | same, 1:1 |
| profile banner | box only | profile records carry no banner dimensions; the header keeps its 3:1 CSS box |
| attachment tile | `meta.width` / `meta.height` | the instance's media metadata, via `components/media/rules::extent` |
| attachment without metadata | 16:9 aspect-ratio box | documented fallback in `components/media/rules.rs` |

## Loading policy

- The first picture on a page (the reader's own avatar, a profile header) is
  `loading="eager"` and `fetchpriority="high"`.
- Everything else is `loading="lazy"`, `decoding="async"`.
- Attachments and video: `poster` is the instance's preview layer, `preload="metadata"`,
  no `autoplay`. Video only gets a player after the reader presses play.

## Origins

Every painted URL is absolute on the instance origin, as the API returns it. Media is never
proxied through the SSR host: Caddy routes `/media/*` to the media socket
(`deploy/docker/Caddyfile`), so the shell origin only serves HTML, JS and CSS.
