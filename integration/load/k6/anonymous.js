// Scenario 1: anonymous read mix.
//
// Weights, chosen to look like a public instance where most traffic is the
// public timeline and the rest is people clicking through:
//   public timeline      45%  (/api/v1/timelines/public)
//   profile account      15%  (/api/v1/accounts/{id})
//   profile statuses     15%  (/api/v1/accounts/{id}/statuses)
//   status permalink     15%  (/api/v1/statuses/{id})
//   media bytes          10%  (/media/{id}/compressed)
//
// Thresholds are deliberately absent: this run reports a knee, it does not
// fail a build.

/* global __ENV */

import { Recorder } from './lib.js';

const recorder = new Recorder([
    'public_timeline',
    'profile',
    'profile_statuses',
    'permalink',
    'media',
]);

const PROFILE_ID = __ENV.PROFILE_ID;
const STATUS_ID = __ENV.STATUS_ID;
const MEDIA_ID = __ENV.MEDIA_ID;

export const options = {
    scenarios: {
        anonymous_read: {
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

export default function () {
    const roll = Math.random();
    if (roll < 0.45) {
        recorder.get('public_timeline', '/api/v1/timelines/public?limit=20');
    } else if (roll < 0.6) {
        recorder.get('profile', `/api/v1/accounts/${PROFILE_ID}`);
    } else if (roll < 0.75) {
        recorder.get(
            'profile_statuses',
            `/api/v1/accounts/${PROFILE_ID}/statuses?limit=20`
        );
    } else if (roll < 0.9) {
        recorder.get('permalink', `/api/v1/statuses/${STATUS_ID}`);
    } else {
        recorder.get('media', `/media/${MEDIA_ID}/compressed`);
    }
}
