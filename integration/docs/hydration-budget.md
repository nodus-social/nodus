# Hydration budget: what the wasm costs, and what islands would buy

Status: measured 2026-11-23. This pass ran in the dockerised lab (`nodus-lab-web`
0.1.0 behind Caddy) with a real Chromium and Playwright, so the runtime table below is
measurement, not arithmetic. Cells still marked *not tested* are holes.

What this pass confirmed, refuted, and could not test:

| Claim | Verdict | Evidence |
| --- | --- | --- |
| There is no hydration: the client throws the server paint away | **confirmed** | `boot.rs:62-77` mounts into a detached div and calls `replace_children_with_node_1`; in 5/5 browser runs the recorded server node was detached and `isConnected === false` when `window.__nodus` became true |
| The SSR head carries no `modulepreload`/`preload` | **confirmed (before the fix below)** | the served `/home` document had neither link; `document.rs::page_with_style` emitted only the inline module |
| The wasm fetch waits for the module script | **confirmed** | median wasm request start was **219.6 ms** after the JS request start, and 5.1 ms after the JS response ended: `HTML → JS fetch+execute → wasm` |
| Preloading both assets removes that wait | **confirmed** | median waterfall gap fell to **0.5 ms**; wasm download completed 307 ms earlier under 4G throttling |
| Twiggy composition shares (29.3 % framework etc.) | *not tested* | no `twiggy` run this pass |
| Island byte floors and the 81 KB gz `admin` saving | *not tested at runtime* | arithmetic from `web/docs/05-quality.md`; not re-measured |
| Production network behaviour | *not tested* | lab only, loopback origin with CDP throttling |

## 1. What exists, on the record

Measured from the lab's own `/home` response and its `PerformanceResourceTiming` entries
(Chromium 158, 4G emulation: 1.6 Mbps down, 150 ms RTT, 4× CPU; 5 runs, medians):

| Artifact | Raw / decoded | Wire transfer | Source |
| --- | --- | --- | --- |
| `*_bg.wasm` (lab build) | 6 321 282 B | 1 803 638 B (`encodedBodySize` 1 803 338) | resource timing + `curl -I` |
| `*.js` module | 79 237 B | 11 379 B | resource timing |
| document (`/home`, inline CSS) | 185 706 B uncompressed | — | `curl` |
| response headers | `Content-Type: application/wasm`, immutable | — | `curl -I` |

The lab serves the wasm as `application/wasm`, so streaming compilation is available to the
browser. The 6.2 MB figure from the brief is the same artifact class; the 2 003 335 B /
727 775 gz figure in `web/docs/05-quality.md` does **not** describe this build (see §5).

Composition by `twiggy` (framework 29.3 %, `nodus_web` 12.7 %, …) was **not re-run** this
pass and the earlier split summed to 91.2 %, so treat its shares as unverified.

## 2. The critical path in the served document (read, then measured)

Before this pass, `web/crates/web-server/src/document.rs::page_with_style` built the head by
hand and emitted no preload hints:

```html
<script type="module">
  import init, * as bindings from '{script}';
  await init({ module_or_path: '{wasm}' });
  window.wasmBindings = bindings;
</script>
```

The served document confirmed this: no `<link rel="modulepreload">` and no
`<link rel="preload" as="fetch" crossorigin>` for the hashed `*_bg.js` / `*_bg.wasm`.
The waterfall shows what that costs. Baseline, medians of 5 runs on `/home`:

| Metric | Baseline |
| --- | --- |
| TTFB | 152.9 ms |
| FCP (server paint) | 412 ms |
| JS request start → wasm request start (**the waterfall gap**) | **219.6 ms** |
| JS request start / wasm request start | 354.4 ms / 574.6 ms |
| wasm `transferSize` / `decodedBodySize` | 1 803 638 B / 6 321 282 B |
| wasm `duration` (request start → response end) | 9 168 ms |
| wasm response end → `window.__nodus === true` | 175.4 ms |
| wasm response end → rail link hit-testable | 516 ms |
| long tasks > 50 ms, navigation → `__nodus` | median 1 task, 212 ms total (max 212 ms); one run also had a 52 ms parse task |
| server-painted node still in the DOM at `__nodus` | **0 of 5** |

So the wasm request starts only after the module has arrived and executed: the gap is the JS
fetch (≈216 ms at this throttle) plus ≈4 ms of parse/execute. It is one serialized round
trip in front of a 1.8 MB transfer, exactly as the draft claimed — now measured.

## 3. What must load before the page is useful

Confirmed by the same runs:

- The server markup paints at FCP (median 412 ms) and its links are real `<a>` elements.
  Reading a timeline, following a link or using the rail is possible before the wasm
  arrives; clicking one is a full document load until `mark_hydrated()` runs.
- Interactivity is gated by the whole module: on throttled 4G the wasm finished at
  ≈9.75 s and the rail was hit-testable at ≈10.25 s. The 6.3 MB is entirely enhancement
  latency; it does not move FCP.
- The client then rebuilds the same markup (see §4), so the `#nodus-page` island still saves
  a re-fetch, not a render.

## 4. What selective hydration would buy

The premise needs correcting: **there is no hydration on this build**, so "selective
hydration" is not a tuning knob here. `web/crates/web-client/Cargo.toml:23` maps
`hydrate = ["leptos/csr", …]`; `leptos/hydrate` and `islands` appear nowhere. `boot.rs`
mounts a fresh `App` into a detached `<div>` and replaces `#app`'s children in one step
(deliberately, to avoid the server paint blinking out). The browser measurement agrees:
the server node was detached in 5/5 runs and `window.__nodus` was already true when the
removal was observed.

Consequences:

- The hydration/instantiation split is **0 % / 100 %**. After the wasm arrives, all
  ~200 ms of long-task work (4× CPU throttle) is decode/instantiate, `boot` installs, and a
  full CSR render of markup the server already produced. The duplicate render is real, but
  it is what keeps the paint stable, not an accidental extra.
- Selective hydration would be a **framework restructure** to `leptos/hydrate` + islands
  (`cargo-leptos`, `HydrationScripts { islands: true }`, a different document head), not a
  change to the existing mount. It also cannot make the 41 % framework/allocator floor
  disappear: any hydrated island still ships the Leptos runtime.
- The byte-floor table from the draft (≈0.73 MB zstd framework floor; best-case
  ≈0.95–1.07 MB) is **arithmetic, not measurement**, and rests on the unverified twiggy
  split. The direction is plausible; the percentages are not evidence.
- The honest statement of the remaining lever: on this build the lever is **payload and
  critical-path latency**, not hydrating less. The preload fix removes ~0.3 s of the
  serialized front on throttled 4G; it does not touch the ~9 s the 1.8 MB takes to arrive.
  Only a smaller wasm (or a genuinely static-first restructure) changes that.

## 5. Contradictions and gaps

- **6.2 MB vs 2.0 MB.** This pass measured 6 321 282 B raw / 1 803 638 B wire in the lab.
  `web/docs/05-quality.md`'s 2 003 335 B / 727 775 gz therefore describes an older artifact
  (the local `web/dist` build is also ≈6.3 MB: 6 304 919 B raw, 2 381 665 gzip,
  1 668 950 brotli, 2 206 150 zstd). The 6.2 MB figure is the one to use.
- **Composition sums to 91.2 %**, and was not re-run; shares are unverified.
- **FCP in the preload arm is not comparable.** The arm rewrote the document response with
  the two links (matching the Rust change byte-for-byte) and fulfilled it locally after a
  150 ms delay, so its TTFB matches, but the 185 KB body arrives at once instead of
  streaming. Its FCP (268 ms) is therefore a delivery artifact, not a preload win; the
  baseline FCP is the only honest FCP number here. Waterfall, wasm completion and hydration
  time are comparable.
- **Lab, not production.** Loopback origin, synthetic 4G and 4× CPU. Immutable assets were
  re-downloaded per run (fresh context), so repeat-visit cache behaviour is not measured.
- **One browser.** Chromium only; no Firefox/Safari modulepreload/priority differences.

## 6. Harness (as run)

`integration/e2e`'s Playwright install, a standalone script, 5 runs per arm, medians:

- Chromium headless with the lab's `--host-resolver-rules` (`nodus.test:443 → 127.0.0.1:18443`);
  a real signed-in `localStorage` session was saved once and reused as `storageState`.
- CDP `Network.emulateNetworkConditions`: 1.6 Mbps down, 750 kbps up, 150 ms RTT;
  `Emulation.setCPUThrottlingRate { rate: 4 }`.
- `addInitScript` installed a buffered `PerformanceObserver('longtask')`, a
  `MutationObserver` on `document` recording the server-painted `#app` child and whether it
  was later removed, and a setter on `window.__nodus` recording `performance.now()`.
- After `page.goto('/home', { waitUntil: 'commit' })`, wait for `window.__nodus === true`,
  then read `performance.getEntriesByType('resource')` for the `.js` and `.wasm` entries and
  `navigation`/`paint` for TTFB and FCP.
- Clickability was measured as the first moment a rail `a[href="/notifications"]` was
  visible **and** `document.elementFromPoint` at its centre returned it or a descendant.
- Arms: (A) document as served; (D) the same document with
  `<link rel="modulepreload" href="{script}">` and
  `<link rel="preload" as="fetch" crossorigin href="{wasm}">` inserted immediately before
  the module script, fulfilled after a 150 ms delay to match the baseline document RTT.
  The rewrite is the exact HTML the Rust change now emits; the Rust emitter was verified
  separately against a running host build.

## 7. Recommendation

**Landed:** the two preload tags in `document.rs::page_with_style`, reading the hashed names
from `Assets` (the same source as the module script), plus a test asserting both links are
present in the head before the module. Measured effect, same harness, medians of 5:

| Metric | Baseline | With preload | Delta |
| --- | --- | --- | --- |
| JS start → wasm start (waterfall gap) | 219.6 ms | 0.5 ms | **−219.1 ms** |
| wasm request start | 574.6 ms | 165.7 ms | −408.9 ms |
| wasm response end | 9 749.4 ms | 9 442.3 ms | −307.1 ms |
| `__nodus` (client live) | 9 917.6 ms | 9 612.5 ms | −305.1 ms |
| rail link hit-testable | 10 251.1 ms | 9 940.3 ms | −310.8 ms |
| wasm response end → `__nodus` | 175.4 ms | 168.3 ms | −7.1 ms (unchanged within noise) |
| long tasks → `__nodus` | 1 task / 212 ms | 1 task / 202 ms | unchanged |

The wasm fetch now starts with the module instead of after it, and under 4G throttling that
buys ≈0.3 s to interactivity. It buys **nothing** in bytes and almost nothing in post-arrival
work; FCP is unaffected. Keep it: two links and a test for a measured 0.3 s.

**Not adopted:** islands / `wasm_split`. The 41 % framework floor is unverified arithmetic,
but the structural objection is now stronger, not weaker: there is no hydration to make
selective, so this would be a new rendering architecture whose payoff (a fraction of the
6.3 MB, and the duplicate render) has not been measured. Revisit only with a real
`leptos/hydrate` + islands build and the same harness.

**Free next step, untested here:** build the public image without the default `admin`
feature (`web/docs/05-quality.md` records −81 KB gz). Re-run this harness to confirm the
byte and time saving before shipping it.
