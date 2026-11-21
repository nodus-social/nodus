import { defineConfig, devices } from '@playwright/test';

// The stack is expected to be up (`integration/scripts/up.sh`); this config
// never starts servers, because the point is to test the dockerised origin.
//
// The public origin defaults to the lab contract, http://127.0.0.1:8080.
// LAB_BASE_URL exists for a host where that port is already taken; the same
// value must be passed to the spec README commands and to up.sh (NODUS_HTTP_PORT).
const baseURL = process.env.LAB_BASE_URL ?? 'http://127.0.0.1:8080';
const origin = new URL(baseURL);
const originHost = origin.hostname === 'localhost' ? '127.0.0.1' : origin.hostname;

// NODUS_BASE_URL is https://nodus, so absolute media, avatar and profile URLs in
// API payloads name that host. The browser cannot resolve it and the host owns
// 443, so compose publishes Caddy's 443 on NODUS_HTTPS_PORT (18443 by default)
// and this rule sends `nodus:443` there. The certificate is Caddy's internal
// CA, which the browser has no reason to trust, hence ignoreHTTPSErrors below.
//
// The http rule stays for any `http://nodus:8080` absolute URL that still
// appears (up.sh probes and older payloads): it rewrites host *and* port so the
// name does not land on whatever else listens on 8080.
const httpsPort = process.env.LAB_HTTPS_PORT ?? '18443';
const resolverRules = [
  `MAP nodus:8080 ${originHost}:${origin.port || '80'}`,
  `MAP nodus:443 ${originHost}:${httpsPort}`,
].join(', ');

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  // OAuth registrations and the login rate limiter are shared state; a single
  // worker keeps the run deterministic and the screenshots identical.
  workers: 1,
  retries: 0,
  timeout: 60_000,
  expect: {
    timeout: 15_000,
    toHaveScreenshot: {
      animations: 'disabled',
      caret: 'hide',
      // 40 pixels is deliberately tiny: the same host, browser build and
      // fonts render the same DOM identically, so this only absorbs the
      // sub-pixel antialiasing jitter of text and rounded avatars. A layout or
      // colour regression changes thousands of pixels and still fails.
      maxDiffPixels: 40,
      // Per-pixel channel tolerance. 0.2 lets antialiased edges differ in
      // shade without letting a visibly different colour through.
      threshold: 0.2,
    },
  },
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL,
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
    // Fixed clock and locale: the UI formats dates and pluralisation from
    // these, and a host-dependent default would change every baseline.
    timezoneId: 'UTC',
    locale: 'en-US',
    // The stylesheet animates a few transitions; the media query makes the
    // reduced-motion branch the one every project screenshots.
    reducedMotion: 'reduce',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    // The https origin is signed by the lab's throwaway internal CA.
    ignoreHTTPSErrors: true,
    launchOptions: {
      args: [`--host-resolver-rules=${resolverRules}`],
    },
  },
  projects: [
    {
      name: 'desktop',
      use: {
        ...devices['Desktop Chrome'],
        viewport: { width: 1400, height: 900 },
      },
    },
    {
      name: 'tablet',
      use: {
        ...devices['Desktop Chrome'],
        viewport: { width: 900, height: 900 },
      },
    },
    {
      name: 'phone',
      use: {
        ...devices['Pixel 7'],
      },
    },
  ],
});
