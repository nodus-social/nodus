// Functional: upload a real image through the composer, publish it, find the
// file in the drive, and prove the media blob is actually served. The drive is
// cleared through the API before and after, so this spec owns the only file in
// it and the drive screenshot has a deterministic list.

import { fileURLToPath } from 'node:url';

import { expect, test } from '@playwright/test';

import { ACCOUNTS, BASE_URL } from '../fixtures.mjs';
import { clearDrive, deleteStatus, findStatusByText } from '../helpers/api.mjs';
import { navigate } from '../helpers/navigation.mjs';
import { signIn } from '../helpers/session.mjs';

const FIXTURE = fileURLToPath(new URL('../fixtures/status-image.png', import.meta.url));

test('an uploaded image is published, listed in the drive and served', async ({ page }) => {
  const session = await signIn(page, ACCOUNTS.ada);
  await clearDrive(page.request, session);

  const text = `drive probe ${Date.now()}`;
  const composer = page.locator('main .card').filter({ has: page.locator('.ProseMirror') }).first();
  await composer.locator('.ProseMirror').click();
  await page.keyboard.type(text);

  const chooser = page.waitForEvent('filechooser');
  await composer.getByRole('button', { name: 'Add images, video or audio' }).click();
  await (await chooser).setFiles(FIXTURE);

  // The composer renders the decoded preview, not a filename chip.
  const preview = composer.locator('img').first();
  await expect(preview).toBeVisible();
  await expect
    .poll(() => preview.evaluate((img) => img.complete && img.naturalWidth > 0))
    .toBe(true);

  await page.getByRole('button', { name: 'Post', exact: true }).click();
  await expect(page.getByText(text)).toBeVisible();

  await navigate(page, '/drive');
  const row = page.locator('[data-testid="drive-file"]').filter({ hasText: 'upload' }).first();
  await expect(row).toBeVisible();
  await expect(row).toContainText('4.1 KB');
  await expect(row).toContainText('image/png');

  const status = await findStatusByText(page.request, session, session.accountId, text);
  expect(status, 'the published status is readable through the API').toBeTruthy();
  expect(status.media_attachments.length, 'the status carries one attachment').toBe(1);

  // preview_url is absolute with the container host (nodus:8080); the browser
  // rewrites that host, but request.get must target the lab origin instead.
  const media = status.media_attachments[0];
  const mediaUrl = new URL(media.preview_url ?? media.url);
  const blob = await page.request.get(`${BASE_URL}${mediaUrl.pathname}`);
  expect(blob.status(), 'the media blob is served').toBe(200);
  // The media pipeline re-encodes derivatives to WebP (nodus-backend/crates/media/
  // src/process.rs: `content_type: "image/webp"`), so the served bytes are WebP
  // even though the upload was a PNG. Assert what is served, and that the drive
  // row still names the type the author uploaded.
  expect(blob.headers()['content-type']).toContain('image/webp');
  expect((await blob.body()).byteLength, 'the derivative carries bytes').toBeGreaterThan(0);

  await deleteStatus(page.request, session, status.id);
  await clearDrive(page.request, session);
});
