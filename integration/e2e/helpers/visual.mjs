// Shared preparation for screenshot specs. Stability is the whole job here:
// the same DOM must produce the same pixels on a rerun and after a reset.

import { expect } from '@playwright/test';

/// Waits until the page can be screenshotted deterministically: the reduced
/// motion branch is active (playwright.config.mjs sets reducedMotion: 'reduce'),
/// webfonts have resolved, and every image in `scope` has decoded. A screenshot
/// taken before an avatar decodes captures a blank box on one run and the image
/// on the next.
export async function prepareVisualPage(page, scope) {
  await expect
    .poll(
      () =>
        page.evaluate(
          () => window.matchMedia('(prefers-reduced-motion: reduce)').matches,
        ),
      { message: 'the browser reports prefers-reduced-motion: reduce', timeout: 15_000 },
    )
    .toBe(true);
  await page.evaluate(() => document.fonts.ready);
  await expect
    .poll(
      () =>
        scope
          .locator('img')
          .evaluateAll((images) => images.every((img) => img.complete && img.naturalWidth > 0)),
      { message: 'every image in the screenshot scope has decoded', timeout: 15_000 },
    )
    .toBe(true);
}

/// Nodes whose pixels are time-dependent, not code-dependent. Relative ages
/// ("26m", "now") and the unread badge count change without a deploy, so mask
/// them rather than hiding them in CSS. Masks are painted in the baseline too,
/// so a layout shift around a masked node is still visible.
export function volatileMasks(page) {
  return [
    page.locator('time'),
    page.locator('[datetime]'),
    page.locator('header a[href*="/status/"]'),
    page.locator('[data-notice-count]'),
  ];
}
