// Scenario 3: write mix.
//
// The write path is the expensive one -- media upload, status insert with
// timeline fan-out, favourite, delete -- so it runs as its own low-VU scenario
// rather than as a slice of the read mixes. Combined request volume is roughly
// 5% of the anonymous run: 4 requests per iteration here against ~1 request per
// iteration at 10x the VUs there.
//
// Every iteration creates and then deletes its own status; the uploaded media
// row is left behind on purpose (deleting a status detaches its attachment, it
// does not delete the object), and the seed's own clearing step removes bulk
// accounts but not these. A long-running write campaign should be run against
// a freshly created `nodusload` database.

/* global __ENV, open */

import http from 'k6/http';
import { check } from 'k6';
import { Recorder } from './lib.js';

const recorder = new Recorder(['media_upload', 'status_create', 'favourite', 'status_delete']);

const TOKEN = __ENV.AUTH_TOKEN;
const STATUS_ID = __ENV.STATUS_ID;
// Written by `load.sh seed` (the media worker's own default avatar), then
// mounted at /load/out; it is the same bytes the seeded media rows point at.
const FIXTURE = open('../out/fixture.png', 'b');

export const options = {
    scenarios: {
        write_mix: {
            executor: 'ramping-vus',
            startVUs: 0,
            stages: [
                { duration: '15s', target: 5 },
                { duration: '30s', target: 10 },
                { duration: '30s', target: 20 },
                { duration: '30s', target: 30 },
                { duration: '15s', target: 0 },
            ],
            gracefulRampDown: '5s',
        },
    },
    summaryTrendStats: ['avg', 'min', 'med', 'p(50)', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

const authorized = { headers: { Authorization: `Bearer ${TOKEN}` } };

export default function () {
    const upload = recorder.send(
        'media_upload',
        'POST',
        '/api/v1/media',
        { file: http.file(FIXTURE, 'load-fixture.png', 'image/png') },
        authorized
    );
    if (upload.status !== 200 || !upload.json('id')) {
        return;
    }
    const mediaId = upload.json('id');

    const created = recorder.send(
        'status_create',
        'POST',
        '/api/v1/statuses',
        JSON.stringify({
            status: `load write ${Date.now()}`,
            media_ids: [mediaId],
            visibility: 'public',
        }),
        Object.assign({}, authorized, {
            headers: Object.assign(
                { 'content-type': 'application/json' },
                authorized.headers
            ),
        })
    );
    if (created.status !== 200 || !created.json('id')) {
        return;
    }
    const createdId = created.json('id');

    recorder.send(
        'favourite',
        'POST',
        `/api/v1/statuses/${STATUS_ID}/favourite`,
        null,
        authorized
    );

    const deleted = recorder.send(
        'status_delete',
        'DELETE',
        `/api/v1/statuses/${createdId}`,
        null,
        authorized
    );
    check(deleted, { 'status deleted': (r) => r.status === 200 });
}
