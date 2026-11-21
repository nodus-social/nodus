// Arrangement and cleanup for specs, through the lab's own REST surface with a
// real session token. The seed script stays the only writer of seed data; specs
// that need extra statuses create them here and delete them again, so a rerun
// starts from the same graph and the visual baselines stay valid.

import { API_BASE } from './session.mjs';

export function authHeaders(session) {
  return { Authorization: `Bearer ${session.token}` };
}

async function expectOk(response, what) {
  if (!response.ok()) {
    throw new Error(`${what} failed with HTTP ${response.status()}`);
  }
  return response;
}

/// POST /api/v1/statuses. `inReplyTo` makes the new status a reply.
export async function createStatus(request, session, text, inReplyTo = null) {
  const body = { status: text };
  if (inReplyTo) body.in_reply_to_id = inReplyTo;
  const response = await request.post(`${API_BASE}/api/v1/statuses`, {
    headers: authHeaders(session),
    data: body,
  });
  await expectOk(response, 'POST /api/v1/statuses');
  return response.json();
}

/// DELETE /api/v1/statuses/{id}. 404 is accepted for cleanup so a partly
/// failed spec does not turn its own cleanup into a second failure.
export async function deleteStatus(request, session, id) {
  const response = await request.delete(`${API_BASE}/api/v1/statuses/${id}`, {
    headers: authHeaders(session),
  });
  if (response.status() !== 200 && response.status() !== 404) {
    throw new Error(`DELETE /api/v1/statuses/${id} failed with HTTP ${response.status()}`);
  }
}

export async function favouriteStatus(request, session, id) {
  const response = await request.post(
    `${API_BASE}/api/v1/statuses/${id}/favourite`,
    { headers: authHeaders(session) },
  );
  await expectOk(response, `POST /api/v1/statuses/${id}/favourite`);
}

export async function unfavouriteStatus(request, session, id) {
  const response = await request.post(
    `${API_BASE}/api/v1/statuses/${id}/unfavourite`,
    { headers: authHeaders(session) },
  );
  if (response.status() !== 200 && response.status() !== 404) {
    throw new Error(
      `POST /api/v1/statuses/${id}/unfavourite failed with HTTP ${response.status()}`,
    );
  }
}

export async function lookupAccount(request, session, acct) {
  const response = await request.get(
    `${API_BASE}/api/v1/accounts/lookup?acct=${acct}`,
    { headers: authHeaders(session) },
  );
  await expectOk(response, `GET /api/v1/accounts/lookup?acct=${acct}`);
  return response.json();
}

export async function clearNotifications(request, session) {
  const response = await request.post(`${API_BASE}/api/v1/notifications/clear`, {
    headers: authHeaders(session),
  });
  await expectOk(response, 'POST /api/v1/notifications/clear');
  // The inbox is shared and fan-out is asynchronous: a notice from an earlier
  // spec can land after the clear. Wait until the API agrees the inbox is
  // empty, otherwise the next count assertion races that delivery.
  for (let attempt = 0; attempt < 20; attempt += 1) {
    const list = await request.get(`${API_BASE}/api/v1/notifications?limit=40`, {
      headers: authHeaders(session),
    });
    await expectOk(list, 'GET /api/v1/notifications');
    if ((await list.json()).length === 0) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('notifications did not clear');
}

/// Deletes every file in the session's drive. The drive is the one surface with
/// no seed, so screenshots start from an empty list before uploading.
export async function clearDrive(request, session) {
  const response = await request.get(`${API_BASE}/api/v1/drive/files`, {
    headers: authHeaders(session),
  });
  await expectOk(response, 'GET /api/v1/drive/files');
  for (const file of await response.json()) {
    const deleted = await request.delete(`${API_BASE}/api/v1/drive/files/${file.id}`, {
      headers: authHeaders(session),
    });
    if (deleted.status() !== 204 && deleted.status() !== 404) {
      throw new Error(
        `DELETE /api/v1/drive/files/${file.id} failed with HTTP ${deleted.status()}`,
      );
    }
  }
}

/// The seeded statuses are the only ones the visual baselines may contain.
/// This finds a status by its exact body text through the account timeline.
export async function findStatusByText(request, session, accountId, text, limit = 40) {
  const response = await request.get(
    `${API_BASE}/api/v1/accounts/${accountId}/statuses?limit=${limit}`,
    { headers: authHeaders(session) },
  );
  await expectOk(response, `GET /api/v1/accounts/${accountId}/statuses`);
  return (await response.json()).find((status) => status.content.includes(text));
}
