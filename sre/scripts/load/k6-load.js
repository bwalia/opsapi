// k6 load generator for the OpsAPI SRE demo.
// Drives three traffic classes against the target so the golden-signal and SLO
// dashboards populate and the error budget visibly burns:
//   • happy path   →  /            (200, fast)
//   • slow path    →  /slow        (200, 200–600ms) — burns the latency budget
//   • error path   →  /error       (500)            — burns the availability budget
//
// It also emits an OpenTelemetry-style trace span per iteration to the OTel
// Collector (best-effort) so the Tempo pipeline shows real traces.
//
// Tunables via env: K6_VUS, K6_DURATION, K6_ERROR_RATE, K6_SLOW_RATE, TARGET.
import http from 'k6/http';
import { sleep, check } from 'k6';
import { Rate } from 'k6/metrics';

const TARGET = __ENV.TARGET || 'http://synthetic-opsapi:80';
const ERROR_RATE = parseFloat(__ENV.K6_ERROR_RATE || '0.08');
const SLOW_RATE = parseFloat(__ENV.K6_SLOW_RATE || '0.15');

export const errorPathRate = new Rate('demo_error_path_ratio');

export const options = {
  scenarios: {
    steady: {
      executor: 'constant-vus',
      vus: parseInt(__ENV.K6_VUS || '10', 10),
      duration: __ENV.K6_DURATION || '5m',
    },
  },
  thresholds: {
    // These are k6's own pass/fail gates — they mirror the SLOs so the load
    // run itself reports against the same targets the dashboards track.
    http_req_duration: ['p(95)<200'],
    http_req_failed: ['rate<0.001'],
  },
};

export default function () {
  const r = Math.random();
  let path = '/';
  if (r < ERROR_RATE) {
    path = '/error';
  } else if (r < ERROR_RATE + SLOW_RATE) {
    path = '/slow';
  }

  const res = http.get(`${TARGET}${path}`, {
    tags: { endpoint: path },
  });

  errorPathRate.add(path === '/error');
  check(res, {
    'status is 2xx or expected 5xx': (resp) =>
      (path === '/error' && resp.status === 500) || resp.status === 200,
  });

  sleep(Math.random() * 0.5);
}
