// Client-side navigation for signed-in specs.
//
// A full page.goto() after sign-in breaks the stored session: the client
// re-reads the host without a scheme and assumes https, so the lab origin
// answers as unreachable (integration/README.md, limitations). The SPA router
// listens for document-level clicks on internal anchors, so clicking a
// synthetic anchor exercises the same route without reloading the document.
// Use this only after signIn(); signed-out specs should page.goto() freely.

import { BASE_URL } from '../fixtures.mjs';

export async function navigate(page, path) {
  const expected = new URL(path, BASE_URL).pathname;
  await page.evaluate((target) => {
    const anchor = document.createElement('a');
    anchor.href = target;
    document.body.append(anchor);
    anchor.click();
    anchor.remove();
  }, path);
  await page.waitForURL((url) => url.pathname === expected, { timeout: 30_000 });
}
