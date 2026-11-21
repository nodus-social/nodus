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
  await expect(page.locator('main')).toHaveScreenshot('drive.png', {
    mask: volatileMasks(page),
  });

  await clearDrive(page.request, session);
});
