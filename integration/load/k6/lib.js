// Shared measurement plumbing: one k6 run per scenario, one load-level tag per
// request so the knee is visible per VU step instead of averaged over the ramp.
//
// The level is derived from elapsed wall time and the stage boundaries below,
// not from k6's VU count, because a request that starts while the ramp is
// climbing 10 -> 50 belongs to the 50 step for reporting purposes.
//
// Errors are counted per endpoint and also printed as a single machine-readable
// line (`LOADERR\t<elapsed_ms>\t<endpoint>\t<status>\t<transport error>`); the
// log is what `report.py` reads to say where errors began.

/* global __ENV */

import http from 'k6/http';
import { Trend, Counter } from 'k6/metrics';

export const BASE = __ENV.BASE_URL || 'http://127.0.0.1:18100';
export const START = Number(__ENV.START_MS || Date.now());
const DEFAULT_LEVELS = ['10', '50', '100', '200', 'rampdown'];
const DEFAULT_STAGE_ENDS = [20, 60, 100, 140];

// A scenario whose VU targets are not 10/50/100/200 (the write mix) passes its
// own labels and stage boundaries, so the bucket name is the VU count that
// actually held during that phase rather than the read ramp's label.
export const LEVELS = __ENV.LEVEL_NAMES
    ? __ENV.LEVEL_NAMES.split(',')
    : DEFAULT_LEVELS;
const STAGE_ENDS = __ENV.STAGE_ENDS
    ? __ENV.STAGE_ENDS.split(',').map(Number)
    : DEFAULT_STAGE_ENDS;

export function levelFor(elapsedMs) {
    const seconds = elapsedMs / 1000;
    for (let i = 0; i < STAGE_ENDS.length; i += 1) {
        if (seconds < STAGE_ENDS[i]) {
            return LEVELS[i];
        }
    }
    return 'rampdown';
}

export class Recorder {
    constructor(endpoints) {
        this.durations = {};
        this.counts = {};
        for (const endpoint of endpoints) {
            for (const level of LEVELS) {
                this.durations[`${endpoint}|${level}`] =
                    new Trend(`${endpoint}_${level}`, false);
                this.counts[`${endpoint}|${level}`] =
                    new Counter(`${endpoint}_${level}_count`, false);
            }
        }
        this.errors = new Counter('load_errors', false);
        this.requests = new Counter('load_requests', false);
    }

    send(endpoint, method, path, body, params, expected) {
        const level = levelFor(Date.now() - START);
        const options = Object.assign({}, params || {});
        options.tags = Object.assign({ endpoint: endpoint }, options.tags || {});
        const response = http.request(method, BASE + path, body, options);
        const ok = (expected || [200]).indexOf(response.status) >= 0;
        this.durations[`${endpoint}|${level}`].add(response.timings.duration);
        this.counts[`${endpoint}|${level}`].add(1);
        this.requests.add(1);
        if (!ok) {
            this.errors.add(1, { endpoint: endpoint });
            console.log(
                `LOADERR\t${Date.now() - START}\t${endpoint}\t` +
                `${response.status}\t${String(response.error || '').slice(0, 120)}`
            );
        }
        return response;
    }

    get(endpoint, path, params, expected) {
        return this.send(endpoint, 'GET', path, null, params, expected);
    }
}
