// k6 load test — drives the queue hard enough to make the autoscaler act.
//
//   k6 run -e BASE_URL=http://localhost:18080 scripts/loadtest/submit.js
//   k6 run -e BASE_URL=... -e RATE=60 -e DURATION=5m scripts/loadtest/submit.js
//
// Submits `slow_task`, not `add`. That matters: `add` completes instantly, so
// workers drain the queue as fast as it fills and no backlog ever forms — the
// autoscaler would have nothing to react to and the test would "pass" while
// proving nothing. `slow_task` occupies a worker thread for a known duration,
// so offered load above the pool's capacity builds a real backlog.
//
// Capacity arithmetic, so the rate is chosen rather than guessed:
//   WORKER_COUNT = 4 threads per pod, task duration 2s
//   => one pod drains ~2 jobs/sec
//   => at 12 pods (the KEDA ceiling) the pool drains ~24 jobs/sec
// A rate of 40/s therefore exceeds even a fully scaled pool, which is what
// forces the queue up past the 120-job backlog the ScaledObject needs to reach
// its ceiling.

import http from "k6/http";
import { check } from "k6";
import { Counter, Trend } from "k6/metrics";

const submitted = new Counter("orion_submitted");
const rejected = new Counter("orion_rejected");
const submitLatency = new Trend("orion_submit_latency", true);

const BASE_URL = __ENV.BASE_URL || "http://localhost:18080";
const RATE = parseInt(__ENV.RATE || "40", 10);
const DURATION = __ENV.DURATION || "3m";
const TASK_SECONDS = parseInt(__ENV.TASK_SECONDS || "2", 10);

export const options = {
  scenarios: {
    burst: {
      // Arrival-rate, not VU-based. A fixed number of virtual users would
      // slow down as the service slows down, hiding exactly the backlog this
      // test is trying to create. Open-model load keeps arriving regardless.
      executor: "constant-arrival-rate",
      rate: RATE,
      timeUnit: "1s",
      duration: DURATION,
      preAllocatedVUs: 50,
      maxVUs: 300,
    },
  },
  thresholds: {
    // The submit path should stay fast even while the queue is deep. Waiting
    // to be dispatched is expected; waiting to be accepted is not.
    "http_req_failed": ["rate<0.01"],
    "orion_submit_latency": ["p(95)<300"],
  },
  // The point is queue behaviour, not a pretty summary.
  summaryTrendStats: ["avg", "p(50)", "p(95)", "p(99)", "max"],
};

export default function () {
  const payload = JSON.stringify({
    task_name: "slow_task",
    payload: { duration: TASK_SECONDS },
    priority: 5,
    max_retries: 2,
  });

  const res = http.post(`${BASE_URL}/submit`, payload, {
    headers: { "Content-Type": "application/json" },
    tags: { endpoint: "submit" },
  });

  submitLatency.add(res.timings.duration);

  const ok = check(res, {
    "submit accepted": (r) => r.status === 200,
    "job id returned": (r) => {
      try {
        return typeof r.json("job_id") === "string";
      } catch (e) {
        return false;
      }
    },
  });

  if (ok) {
    submitted.add(1);
  } else {
    rejected.add(1);
  }
}

export function handleSummary(data) {
  const m = data.metrics;
  const val = (name, stat) =>
    m[name] && m[name].values ? m[name].values[stat] : undefined;

  const lines = [
    "",
    "Orion load test",
    "===============",
    `  target        ${BASE_URL}`,
    `  offered rate  ${RATE}/s for ${DURATION} (task ${TASK_SECONDS}s)`,
    `  submitted     ${val("orion_submitted", "count") || 0}`,
    `  rejected      ${val("orion_rejected", "count") || 0}`,
    `  submit p95    ${(val("orion_submit_latency", "p(95)") || 0).toFixed(1)} ms`,
    `  submit p99    ${(val("orion_submit_latency", "p(99)") || 0).toFixed(1)} ms`,
    `  http failures ${((val("http_req_failed", "rate") || 0) * 100).toFixed(2)}%`,
    "",
    "Record alongside: pod count, node count, and queue depth at peak.",
    "Those are the numbers the autoscaling claim rests on; this tool only",
    "measures the submit side.",
    "",
  ];

  // The summary path is relative to k6's working directory, not to this file.
  // Override with -e SUMMARY=... ; the Makefile target sets the working
  // directory so the default lands next to the script.
  const out = { stdout: lines.join("\n") };
  out[__ENV.SUMMARY || "results/summary.json"] = JSON.stringify(data, null, 2);
  return out;
}
