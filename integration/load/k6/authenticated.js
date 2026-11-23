// Scenario 2: authenticated read mix, run twice by load.sh.
//
//   MODE=warm  home timeline served from the Valkey ZSET that `load.sh seed`
//              populated and verified (60%)
//   MODE=cold  the same request with the ZSET deleted (FLUSHDB before the run,
//              and nothing in this mix writes a status, so it stays cold) (60%)
//
// The other 40% does not depend on the cache state:
//   notifications        20%  (/api/v1/notifications)
//   profile               10%
//   profile statuses      10%
//
// Measuring both matters because the warm path is a bounded ZRANGE + hydrate,
// while the cold path is the UNION of timeline_entry and recent statuses of
// followed accounts -- two very different ceilings behind one identical URL.
// The two runs write separate summary files, so the metric name stays
// `home_timeline` in both.

/* global __ENV */

import { Recorder } from './lib.js';

const recorder = new Recorder([
    'home_timeline',
    'notifications',
    'profile',
    'profile_statuses',
]);

const PROFILE_ID = __ENV.PROFILE_ID;
const TOKEN = __ENV.AUTH_TOKEN;
const MODE = __ENV.MODE || 'warm';

export const options = {
    scenarios: {
        authenticated_read: {
            executor: 'ramping-vus',
            startVUs: 0,
            stages: [
                { duration: '20s', target: 10 },
                { duration: '40s', target: 50 },
                { duration: '40s', target: 100 },
                { duration: '40s', target: 200 },
                { duration: '20s', target: 0 },
            ],
            gracefulRampDown: '5s',
        },
    },
    summaryTrendStats: ['avg', 'min', 'med', 'p(50)', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

const authorized = {
    headers: { Authorization: `Bearer ${TOKEN}` },
    tags: { mode: MODE },
};

export default function () {
    const roll = Math.random();
    if (roll < 0.6) {
        recorder.get('home_timeline', '/api/v1/timelines/home?limit=20', authorized);
    } else if (roll < 0.8) {
        recorder.get('notifications', '/api/v1/notifications?limit=20', authorized);
    } else if (roll < 0.9) {
        recorder.get('profile', `/api/v1/accounts/${PROFILE_ID}`, authorized);
    } else {
        recorder.get(
            'profile_statuses',
            `/api/v1/accounts/${PROFILE_ID}/statuses?limit=20`,
            authorized
        );
    }
}
