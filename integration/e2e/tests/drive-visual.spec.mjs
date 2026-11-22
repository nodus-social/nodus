// Visual: the drive after one upload. The drive has no seed, so the spec
// empties it through the API first and uploads the committed fixture; the row
// is the same filename, size, type and visibility on every run.

import { fileURLToPath } from 'node:url';

import { expect, test } from '@playwright/test';

import { ACCOUNTS } from '../fixtures.mjs';
import { clearDrive } from '../helpers/api.mjs';
import { navigate } from '../helpers/navigation.mjs';
import { signIn } from '../helpers/session.mjs';
import { prepareVisualPage, volatileMasks } from '../helpers/visual.mjs';

const FIXTURE = fileURLToPath(new URL('../fixtures/status-image.png', import.meta.url));

test('drive with an uploaded file', async ({ page }) => {
  const session = await signIn(page, ACCOUNTS.ada);
  await clearDrive(page.request, session);

  await navigate(page, '/drive');
  await page.locator('input[aria-label="Upload files"]').setInputFiles(FIXTURE);

  const row = page.locator('[data-testid="drive-file"]').first();
  await expect(row).toBeVisible();
  await expect(row).toContainText('status-image.png');
  await expect(page.locator('main')).toContainText('4.1 KB used · 1 files');

  await prepareVisualPage(page, page.locator('main'));
  // The reading column is a flex item in the page's row and has no height of
  // its own, so it is stretched to the rail's height: the same drive measured
  // 557px while the rail drew an empty staff card and 517px after web 17f66d6
  // stopped drawing it, with the drive's own pixels identical and the whole
  // difference trailing background. Pin the crop to the column's own content,
  // as capabilities-visual.spec.mjs does for the rail itself.
  await page.locator('main').evaluate((element) => {
    const parent = getComputedStyle(element.parentElement);
    if (parent.flexDirection.startsWith('row')) {
      element.style.alignSelf = 'flex-start';
    }
    element.style.height = 'auto';
    const { height } = element.getBoundingClientRect();
    element.style.height = `${Math.ceil(height)}px`;
  });
  await expect(page.locator('main')).toHaveScreenshot('drive.png', {
    mask: volatileMasks(page),
  });

  await clearDrive(page.request, session);
});
