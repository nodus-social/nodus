// An ad-hoc browser, for looking at something once.
//
// The suites answer "does this still work". This answers "what is actually on
// screen", which is a different question and the one you ask while diagnosing.
// It exists so nobody has to re-derive the launch arguments again: the HTTPS
// resolver, the academy certificate, the signed-in path and the stale-bundle
// trap are all handled here.
//
//   node ad-hoc.mjs --path /home                 # signed in as admin
//   node ad-hoc.mjs --path /accounts/<id> --shot /tmp/x.png
//   node ad-hoc.mjs --path /home --anon          # signed out
//   node ad-hoc.mjs --path /home --click "Add a left side banner"
//
// Four traps it takes care of, each of which has cost somebody an hour:
//
//   1. The browser browses https://nodus.test through a launch-arg resolver
//      (`playwright.config.mjs` explains why: absolute URLs in payloads name
//      that host, and its port 443 belongs to something else on the host).
//   2. After signing in, `page.goto()` BREAKS the session — the client re-reads
//      the host without a scheme and assumes https — so a signed-in navigation
//      is a document-level click on an anchor (`helpers/navigation.mjs`). Use
//      `--then <path>` for that, never a second `goto`.
//   3. `web/e2e` serves `web/dist`: run `trunk build --release` before believing
//      anything a spec says about the bundle.
//   4. A screenshot path under `/tmp` is the CONTAINER's `/tmp` when the suite
//      runs in the pinned image. From here it is the host's, so pass a real path.
import { chromium } from 'playwright';
import { ACCOUNTS, BROWSER_ORIGIN } from './fixtures.mjs';
import { navigate } from './helpers/navigation.mjs';
import { signIn } from './helpers/session.mjs';

const argv = process.argv.slice(2);
const arg = (name, fallback = undefined) => {
  const at = argv.indexOf(`--${name}`);
  return at === -1 ? fallback : (argv[at + 1] ?? true);
};

const path = arg('path', '/');
const then = arg('then');
const click = arg('click');
const shot = arg('shot');
const wait = Number(arg('wait', 1500));
const anonymous = argv.includes('--anon');

const httpsPort = process.env.LAB_HTTPS_PORT ?? '18443';
const hostOrigin = new URL(process.env.LAB_BASE_URL ?? 'http://127.0.0.1:18080');
const originHost = hostOrigin.hostname === 'localhost' ? '127.0.0.1' : hostOrigin.hostname;
const resolverRules = [
  `MAP nodus.test:8080 ${originHost}:${hostOrigin.port || '80'}`,
  `MAP nodus.test:443 ${originHost}:${httpsPort}`,
].join(', ');

const browser = await chromium.launch({
  args: [`--host-resolver-rules=${resolverRules}`],
});
const context = await browser.newContext({
  baseURL: BROWSER_ORIGIN,
  ignoreHTTPSErrors: true,
  viewport: { width: Number(arg('width', 1400)), height: Number(arg('height', 900)) },
});
const page = await context.newPage();

const noisy = [];
page.on('console', (message) => {
  if (message.type() === 'error' || message.type() === 'warning') {
    noisy.push(`${message.type()}: ${message.text().slice(0, 200)}`);
  }
});
page.on('pageerror', (error) => noisy.push(`pageerror: ${error.message.slice(0, 200)}`));
const requests = [];
page.on('request', (request) => {
  const url = new URL(request.url());
  if (url.origin === new URL(BROWSER_ORIGIN).origin) return;
  if (url.host !== new URL(BROWSER_ORIGIN).host) requests.push(`${request.method()} ${request.url()}`);
});

if (!anonymous) {
  const account = arg('as', 'admin');
  await signIn(page, ACCOUNTS[account] ?? ACCOUNTS.admin);
  console.log(`signed in as ${account}`);
}

// A signed-in first load is a document load only when it is the FIRST one after
// signing in (the client announces the session, then the host knows it).
await page.goto(path, { waitUntil: 'domcontentloaded' });
await page.waitForTimeout(wait);

if (then) {
  await navigate(page, then);
  await page.waitForTimeout(wait);
}

if (typeof click === 'string') {
  await page.getByRole('button', { name: new RegExp(click, 'i') }).first().click();
  await page.waitForTimeout(wait);
}

const report = {
  url: new URL(page.url()).pathname,
  title: await page.title(),
  live: await page.evaluate(() => !!window.__nodus),
  hydrated: await page.evaluate(() => !!document.querySelector('#app[data-hydrate]')),
  shell: await page.evaluate(() => !!document.querySelector('#app[data-shell]')),
  headings: (await page.locator('h1, h2').allInnerTexts()).slice(0, 8),
  tabs: await page.locator('[role="tablist"]').count(),
  buttons: (await page.locator('button').allInnerTexts()).slice(0, 12),
  foreignRequests: requests.slice(0, 8),
  console: noisy.slice(0, 8),
};
console.log(JSON.stringify(report, null, 2));

if (typeof shot === 'string') {
  await page.screenshot({ path: shot, fullPage: true });
  console.log(`shot ${shot}`);
}

await browser.close();
