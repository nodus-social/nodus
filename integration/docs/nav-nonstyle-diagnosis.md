# Navigation on instances without session style — diagnosis

**Verdict.** On a Mastodon session, at HEAD `8183d91`, the rail renders **nine destinations**
(eight category rows plus the Notifications bell), and **zero** of them land in
`UnservedPage`: Home, Messages, Notifications, Search, People, Saved, Scheduled, Lists and
Settings each paint a real screen, and in-app clicks route without a reload or a page error
(measured against the e2e Mastodon stub, `web/e2e/tests/rail-mastodon.spec.mjs`'s own
routes). So "navigation broken" is **not** a routing failure on Mastodon — nothing is
unserved there, because the SDK's Mastodon baseline marks every surface the nine doors map
to. The two honest defects the report is actually about are narrower: (a) the
**Notifications door is deleted, not replaced**, the moment the notifications probe answers
"this server has none" (`NoticeDoor::Absent`), so a server that 404s
`/api/v1/notifications` loses that door from the rail entirely and cannot be reached from
the navigation at all; the three baselines freeze exactly that state, and (b) a **Misskey**
session loses **Messages and Scheduled** to `served_entries` because the SDK baseline says
`Conversations` and `ScheduledStatuses` are absent, even though both screens exist and
render — the rail and the router disagree. The baseline pictures themselves are **stale**:
all three show eight rows and no bell, while HEAD draws a bell for `Unread(0)`, which the
live client does draw (both against the stub and against the lab, whose
`/api/v1/notifications` answers `200 []`).

## Evidence

### 1. What a Mastodon session's rail contains

- Default catalogue: `web/crates/ui/src/session_style.rs:824-851` — Home `/home`, Messages
  `/messages`, Notifications `/notifications`, Search `/search`, People `/directory`, Saved
  `/saved/favourites`, Scheduled `/scheduled`, Lists `/lists`, Settings `/settings/account`.
- The only filter that removes an item is `served_entries`
  (`web/crates/ui/src/components/rail/mod.rs:714-732`): keep iff
  `Surface::of_path(&item.path).is_none_or(|s| admits(at.as_ref(), s))`, and
  `admits(None) == true` (`web/crates/ui/src/capabilities.rs:56`). Path→surface:
  `web/crates/route/src/route/mod.rs:775-790`.
- Which answer `at` is: `crates/web-client/src/app.rs:74` `serves()` →
  `web/crates/web-client/src/state/bridge/capabilities.rs:95-110`, which prefers the
  server's island answer (`read_island`/`seed_from` at `:39-56`, `prefer` at `:58-60`) and
  otherwise takes the store's negotiated answer, mapping protocol Misskey→
  `Capabilities::misskey()` and Mastodon/Nodus→negotiated (itself falling back to the
  Mastodon baseline when `/api/v1/meta` does not answer).
- `sdk/crates/nodus/src/baseline.rs` (`EXPECTED`, mastodon/misskey columns) is what decides
  each door: Favourites T/T, Conversations T/F, Lists T/T, ScheduledStatuses T/F,
  Notifications T/T, Search T/T, Directory T/T, Admin T/T, Moderation T/T. **Mastodon keeps
  all nine; Misskey loses Messages (`Conversations`) and Scheduled
  (`ScheduledStatuses`).** `Saved` survives on Misskey because it maps to `Favourites`,
  not `Bookmarks`.
- Live measurement (Playwright, `web/dist` as built at HEAD, static server
  `web/e2e/serve.mjs` on `127.0.0.1:4173`, session host `mastodon.luxuride.eu`, with
  `/api/v1/meta`, `/api/v1/nodus/**` and `/api/v1/feed/**` answering 404 — the stub's own
  routing, see `web/e2e/tests/rail-mastodon.spec.mjs`): rail present, three category rails
  `read`/`find`/`library`, staff cards **0**, one bell, and the anchors
  `Home /home`, `Messages /messages`, `Notifications /notifications` (bell),
  `Search /search`, `People /directory`, `Saved /saved/favourites`,
  `Scheduled /scheduled`, `Lists /lists`, `Settings /settings/account`, plus the profile
  card. **Nine doors, nothing filtered.** The staff card is the only rail difference from a
  Nodus session (12 links including Moderation and Administration): `staff_door` is
  `extensions && served && eligible` (`web/crates/ui/src/capabilities.rs:85`), and
  `extensions` (`web/crates/web-client/src/app.rs:65`) is false for every non-Nodus
  protocol, so the staff card closes even though the Mastodon baseline serves Admin and
  Moderation. That closure is correct for this app: those screens call the Nodus API.

### 2. What each of the nine does on a Mastodon session

None of the nine reaches `UnservedPage`. `UnservedPage`
(`web/crates/ui/src/capabilities.rs:150`) is used in exactly two places,
`web/crates/web-client/src/routes/admin/mod.rs:223` and
`web/crates/web-client/src/routes/moderation/mod.rs:183` — both behind the staff card that
a Mastodon session does not draw. The `unavailable(title, note)` arm
(`web/crates/web-client/src/app.rs:466`) covers Feed, StyleEditor, Drive, Admin and
Moderation only; of those, only Feed, StyleEditor and Drive are reachable as extra doors,
and they are gated on their own surfaces. Everything else falls through to the generic
`RouteView` (`web/crates/route/src/route/mod.rs:536`), which has a screen for all nine:

| door | route arm | what actually paints on Mastodon |
| --- | --- | --- |
| Home `/home` | own screen, `app.rs` | timeline + composer; **plus a raw `role="alert"`: `discovery request failed: Status { status: 404, message: "request failed" }Switch account or sign in again`** because the Nodus discovery read 404s |
| Messages `/messages` | `RouteView` → `MessagesScreen` | "No conversations yet." |
| Notifications `/notifications` | `RouteView` → notifications screen | "This instance has nothing for you yet." |
| Search `/search` | `RouteView` → search screen | the search screen |
| People `/directory` | `RouteView` → directory screen | "This instance has not published a directory of accounts." |
| Saved `/saved/favourites` | `RouteView` → `SavedScreen` | Favourites/Bookmarks tabs, "Nothing is favourited yet." |
| Scheduled `/scheduled` | `RouteView` → `ScheduledScreen` | "Nothing is waiting." |
| Lists `/lists` | `RouteView` → `ListsScreen` | "No lists yet. A list keeps a timeline of its own." |
| Settings `/settings/account` | settings screen | Account/Profile/Appearance/Filters/Instance/Session; the Appearance card is correctly replaced by "This instance does not store a per-account appearance…" (`web/crates/web-client/src/routes/settings/mod.rs:97-107`) |

Each of those nine was loaded twice — once by full navigation, once by clicking its rail row
on the same Mastodon-shaped session (SPA route interception,
`web/crates/web-client/src/router/mod.rs` `install_links`): same heading each time, a rail
of 10 anchors (profile + bell + eight rows) on every page, no sign-in form, no
`UnservedPage`, and `pageerror` count 0 across all nine clicks.

The one door that *is* lost on a Mastodon-shaped server is Notifications, and it is lost by
a different mechanism than `served_entries`:
`web/crates/web-client/src/app.rs:179-185` maps `notifications::available()` to
`Unknown`/`Absent`/`Unread(n)`; `rail/mod.rs:1155-1168` drops the catalogue row as soon as
the door is **known** (`!(known && item.path == "/notifications")`), and the replacement
bell at `rail/mod.rs:1115-1138` paints only for `Unread(_)`. `Absent` therefore removes the
door and paints nothing in its place. `available()` goes to `Some(false)` when the page read
is `Ok(None)` (a 404), so **any instance whose `/api/v1/notifications` is missing loses the
Notifications door with no trace**.

### 3. Server vs client for the same session

- `web/crates/web-server/src/runtime.rs:179` `session_style()` returns
  `self.style.clone()` from `StaticRuntime` (`:17`, `:141`) — a *page* runtime baked per
  render, not the session's style. Its only reader is the settings screen
  (`web/crates/route/src/route/screens/settings.rs:79`), **not the rail**, so it cannot make
  the rail differ.
- The rail's style on the server comes from `resolve_style`
  (`web/crates/web-server/src/main.rs:712-729`): the session's stored style, else
  `Client::client_metadata_style()`, else `SessionStyle::default()`. A Mastodon or Misskey
  host has no `/api/v1/nodus/style`, so the `unwrap_or_default()` branch is what runs:
  default style, default rail.
- The capability answer used for the server paint is `answer_for(host)`
  (`web/crates/web-server/src/document.rs:322`, inside `chrome_with_style` `:300-360`),
  filled by `capabilities::resolve(&session)` which the shell calls **before** painting
  (`main.rs:763`; also `:80`, `:806`). For `Protocol::Mastodon` that is
  `Some(Capabilities::mastodon())`, remembered per host
  (`web/crates/web-server/src/capabilities.rs:78-101`).
- The island then carries that answer (`document.rs:140-160`, `with_capabilities`), and the
  client prefers it over its own probe
  (`web/crates/web-client/src/state/bridge/capabilities.rs:58-60`). So server and client
  agree, and both draw nine doors for a Mastodon session. No SSR/CSR rail difference exists
  for Mastodon in this code; the `answer_for == None` case (Nodus host whose meta read
  failed) is permissive on both sides by construction (`admits(None) == true`), and the
  Misskey case is only a hazard if the island is absent — the client then negotiates
  `Capabilities::misskey()` and drops Messages/Scheduled *after hydration*, which would be a
  visible post-hydration change of the rail. I could not construct that state with the
  static client build, and the lab cannot stand up a real Mastodon session for SSR (the web
  container has no `mastodon.test` name; `integration/compose.peers.yml:180-190` documents
  that the name belongs to Caddy, so server-side reads of a `mastodon.test` session fail at
  DNS and fall back to `document::shell`).

### 4. The three baselines

`integration/e2e/tests/capabilities-visual.spec.mjs-snapshots/`, all 176×640:

- `navigator-nodus-full-desktop-linux.png` (22567 B): profile card `admin@nodus.test`, masked
  avatar strip, then READ `Home` (active) `Messages`; FIND `Search` `People` `Saved`;
  LIBRARY `Scheduled` `Lists` `Settings`; STAFF `Moderation` `Administration`. 11 rows.
- `navigator-absent-caps-grant-held-desktop-linux.png` (18090 B) and
  `navigator-mastodon-grant-ignored-desktop-linux.png` (18090 B, byte-identical): the same
  picture minus the STAFF card. 9 rows.
- **All three lack the Notifications door and the bell.** The difference between the three
  is only the STAFF card, which is what the spec says it is testing — `staff_door` closing
  on `extensions`. The two degraded pictures are identical *by design*: the spec's own
  comment says the Mastodon baseline serves lists, favourites, scheduled, search, directory,
  conversations and notifications, so no rail door could honestly differ.
- No baseline is "broken" as a picture of its own scenario; the **Mastodon baseline is
  redundant** (it proves nothing the absent-caps baseline doesn't) and **all three are
  stale**: HEAD paints the bell for `Unread(0)` (`rail/mod.rs:1115`), and the live client
  draws it for both the stub and the real lab origin (lab `/api/v1/notifications` →
  `200 []`). The missing Notifications row in every picture is the `Absent`/`Unread` row
  filter at `rail/mod.rs:1159` recorded before the bell existed or with a lab answer that
  has since changed.

### 5. Live reproduction

Cheap and done, with the stub route the task allowed:
`web/e2e/tests/rail-mastodon.spec.mjs`'s own stubs (verify_credentials 200,
`/api/v1/timelines/home`, `/api/v1/notifications` → `[]`, `/api/v1/meta` 404,
`/api/v1/nodus/**` 404, `/api/v1/feed/**` 404), seeding the same `localStorage` keys
`web/e2e/fixtures.mjs:390` writes, against the HEAD `web/dist` on the e2e static server.
Rail labels and hrefs are in §1; each href's page rendered (no `UnservedPage`, no sign-in
form) and every click navigated. Peer sign-in was **not** attempted: the lab's Mastodon is
only reachable as `https://mastodon.test:18443` through Caddy and the SSR container cannot
resolve that name, so an SSR comparison with a real Mastodon session is not available in
this lab. The account-card link `/accounts/mastodon.luxuride.eu/ada` showed
`The instance could not be reached: expected value at line 1 column 1` — a raw decode error,
not a nav failure.

Caveat: `web` was being edited by other agents while this ran (`git status` changed twice
during the session). All line numbers are as of the working tree at the time of reading.

## Candidate fixes, smallest first

1. **Never lose the Notifications door** (tiny). Paint the bell for `Absent` too, with a
   zero-count, or stop removing the row when the door is `Absent` — one `matches!` arm at
   `rail/mod.rs:1115` and one clause at `:1159`. Turns the only *vanishing* door into a
   door that opens the page and says "nothing here", which is what the screen already does.
2. **Stop the home screen from painting a transport error as navigation** (small). The
   `role="alert"` `discovery request failed: Status { status: 404 … }` on `/home` for a
   non-Nodus session (`app.rs`, the Home arm) is a raw `Status` debug string; route it
   through `capabilities::explain` (or suppress the discovery read when the session does
   not serve feed accounts).
3. **Make Misskey's rail and router agree** (small). Either keep Messages/Scheduled in the
   rail when the corresponding `Screen` exists and let the screen explain the empty state,
   or make `from_path`/`RouteView` answer the same refusal — today `served_entries` hides
   two doors whose pages work when typed.
4. **Re-record the three baselines at HEAD** (medium, mechanical). They no longer contain
   the bell, and the Mastodon one is a duplicate of the absent-caps one; giving it a
   session whose notifications answer `404` would make it prove the notification-door
   behaviour the operator is reporting.
5. **Give `StaticRuntime::session_style` the session's style** (medium, only if the
   settings card is expected to show a per-account style on first paint). It currently
   returns a baked default (`runtime.rs:179`) while the rail and chrome use
   `resolve_style`; one value per concept would remove the discrepancy.

## Addendum after implementation (2026-11-23)

### 1. The Notifications door

`crates/ui/src/components/rail/mod.rs` now derives the bell from **two** facts: the probe has
a count (`Unread(_)`) **and** the capability answer admits `Surface::Notifications`. Every
other probe answer leaves the catalogue row in place, including `Absent` (a 404): a 404 from
one read cannot distinguish a missing endpoint from a proxy that has not been taught the
route, so it is "we do not know yet", not evidence that the destination does not exist. The
capability answer is the only refusal. The rule is stated on `NoticeDoor` and on the `bell`
signal. Three tests pin it: `Absent` keeps the door, a capability refusal removes it,
`Unread(0)` draws the bell without a badge, `Unread(n)` draws the count.

### 2. The three navigator baselines (correction to §4)

The earlier reading of §4 was wrong about *why* the door was missing from the pictures: the
old baselines **did** draw the bell row, but `volatileMasks` masked the whole
`a[href="/notifications"]`, and the mask rectangle was mistaken for the avatar strip. The
pictures could not distinguish the bell from an ordinary catalogue row, so they neither
proved nor disproved the claim.

The spec now waits for `[data-notice-bell]` before the shot (`railPicture`, the probe answers
after first paint and the old shot could race it), and the navigator shots mask only the
count badge (`volatileMasks(page, { notificationDoor: 'badge' })`), so the bell icon and
label are part of the picture while the count stays volatile.

Re-recorded all three in the pinned Playwright container (`v1.65.0-noble`, `--project=desktop`)
against the same lab origin. Measured against the previous files:

| baseline | changed pixels | diff band | rows that moved |
| --- | --- | --- | --- |
| `navigator-nodus-full` | 5268 | y 64–96 only | none; the bell row is now visible, badge still masked |
| `navigator-absent-caps-grant-held` | 5268 | y 64–96 only | none; same bell row |
| `navigator-mastodon-grant-ignored` | 5268 | y 64–96 only | none; same bell row |

No category row moved, which is the point: the bell already occupied that row in the old
pictures; the re-record makes the claim falsifiable instead of hiding the evidence under a
link-sized mask. The full picture now shows bell + READ Home/Messages + FIND
Search/People/Saved + LIBRARY Scheduled/Lists/Settings + STAFF Moderation/Administration
(11 rows); the two degraded pictures show the same minus STAFF (9 rows).

Caveat: the lab image (`nodus-lab/web:0.1.0`, pinned web `1aacf89`) predates the `Absent`
change, because `web` HEAD's `nodus-web-client` is mid-flight against the new SDK trait
(`E0046` in `bridge/misskey/read.rs`, `E0034` in `bridge/actions.rs`) and does not build as
wasm. None of the three scenarios exercises `Absent` (all serve `Notifications` and the probe
answers `200 []`), and the bell predicate is equivalent for `Unread`; the `Absent` rule is
covered by the unit tests in §1.

### 3. Misskey probe: why Messages and Scheduled stay hidden

Probed the running lab Misskey (2026.11.0, `http://127.0.0.1:18082`, token from
`integration/state/misskey-account.json`, account `alice`). `POST`, JSON body, token as `i`.

| endpoint | status | verdict |
| --- | --- | --- |
| `/api/chat/history` | 200 `[]` | a real DM thread-list endpoint exists in 2026.11 |
| `/api/notes/conversation` | 400 (`noteId` required) | per-note thread, not a list of conversations |
| `/api/notes/scheduled` | 404 | no scheduled-notes endpoint |
| `/api/i/scheduled` | 404 | no scheduled-notes endpoint |
| `/api/notes/favorites` | 404 | wrong route |
| `/api/i/favorites` | 200 `[]` | favourites served; baseline `true` correct |
| `/api/notes/bookmarks` | 404 | wrong route |
| `/api/i/bookmarks` | 404 | bookmarks not served; baseline `false` correct |
| `/api/users/lists/list` | 200 `[]` | lists served; baseline `true` correct |
| `/api/i/markers` | 404 | markers not served; baseline `false` correct |
| `/api/i/notifications` | 200 `[]` | notifications served |
| `/api/endpoints` | 200 (438 routes) | `chat/*` family and `notes/drafts/list`; no scheduled-note or bookmark route |

The SDK agrees where it matters: `sdk/crates/misskey/src/lib.rs:346` returns
`Error::Unsupported("the conversations endpoint")` ("Direct messages are not a thread object
in Misskey's API"), bookmarks `:333`, markers `:401`. Flipping Misskey `Conversations` to
`true` would only let the door open onto that `Unsupported` error, not onto a working list;
`ScheduledStatuses` has no endpoint to call at all. **No SDK baseline changed.** A real
Misskey conversation list would require implementing `conversations()` on top of
`/api/chat/history`, which is SDK work, not a baseline flip.

The diagnosis's §2 claim that "both screens work" is therefore not supported: the screens
render an empty/unsupported state, which is not a served read. The rail's hiding matches the
SDK's own stateless audit.
