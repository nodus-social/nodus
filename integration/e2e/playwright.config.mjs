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

// The browser must resolve `nodus` to the host's published port: NODUS_BASE_URL
// is http://nodus:8080, so absolute media and profile URLs in API payloads name
// that host. The rule rewrites host *and* port — a bare `MAP nodus 127.0.0.1`
// would keep 8080 and reach whatever else listens there.
const resolverRule = `MAP nodus:8080 ${originHost}:${origin.port || '80'}`;

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
      maxDiffPixelRatio: 0.02,
    },
  },
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL,
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    launchOptions: {
      args: [`--host-resolver-rules=${resolverRule}`],
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
