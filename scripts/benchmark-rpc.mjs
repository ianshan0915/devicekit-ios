#!/usr/bin/env node

import http from "node:http";
import { performance } from "node:perf_hooks";

function usage(message) {
  if (message) console.error(message);
  console.error(`Usage: scripts/benchmark-rpc.mjs [options]

Options:
  --base-url URL       Forwarded DeviceKit URL (default: http://127.0.0.1:12004)
  --samples N          Measured sequential requests per action (default: 30)
  --warmup N           Warm-up requests per action (default: 5)
  --tap X,Y            Safe tap point in visible stream points (default: 10,10)
  --tap-duration-ms N  Experimental touch duration sent with each tap
  --tap-backend NAME   Experimental daemonFresh, daemonCached, or deviceSynthesizer
  --swipe X1,Y1,X2,Y2  Safe swipe coordinates (default: 10,10,10,10)
  --actions LIST       Comma-separated health,info,tap,home,swipe (default: all)
  --output PATH        Also write the complete JSON result to PATH
  --settle-ms N        Delay between requests (default: 50)
`);
  process.exit(message ? 2 : 0);
}

function parseInteger(value, name, minimum = 0) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < minimum) {
    usage(`${name} must be an integer >= ${minimum}`);
  }
  return parsed;
}

function parsePoint(value, count, name) {
  const parts = value.split(",").map(Number);
  if (parts.length !== count || parts.some((part) => !Number.isFinite(part))) {
    usage(`${name} must contain ${count} comma-separated numbers`);
  }
  return parts;
}

const options = {
  baseUrl: "http://127.0.0.1:12004",
  samples: 30,
  warmup: 5,
  tap: [10, 10],
  tapDurationMs: undefined,
  tapBackend: undefined,
  swipe: [10, 10, 10, 10],
  actions: ["health", "info", "tap", "home", "swipe"],
  output: undefined,
  settleMs: 50,
};

for (let index = 2; index < process.argv.length; index += 1) {
  const key = process.argv[index];
  if (key === "--help" || key === "-h") usage();
  const value = process.argv[++index];
  if (value === undefined) usage(`missing value for ${key}`);
  switch (key) {
    case "--base-url": options.baseUrl = value; break;
    case "--samples": options.samples = parseInteger(value, key, 1); break;
    case "--warmup": options.warmup = parseInteger(value, key); break;
    case "--tap": options.tap = parsePoint(value, 2, key); break;
    case "--tap-duration-ms": options.tapDurationMs = parseInteger(value, key, 1); break;
    case "--tap-backend": options.tapBackend = value; break;
    case "--swipe": options.swipe = parsePoint(value, 4, key); break;
    case "--actions": options.actions = value.split(",").filter(Boolean); break;
    case "--output": options.output = value; break;
    case "--settle-ms": options.settleMs = parseInteger(value, key); break;
    default: usage(`unknown option: ${key}`);
  }
}

const definitions = {
  health: { path: "/health", method: "GET" },
  info: { rpc: "device.info", params: {} },
  tap: {
    rpc: "device.io.tap",
    params: {
      x: options.tap[0],
      y: options.tap[1],
      ...(options.tapDurationMs === undefined ? {} : {
        experimentalDurationMilliseconds: options.tapDurationMs,
      }),
      ...(options.tapBackend === undefined ? {} : {
        experimentalBackend: options.tapBackend,
      }),
    },
  },
  home: { rpc: "device.io.button", params: { button: "home" } },
  swipe: {
    rpc: "device.io.swipe",
    params: {
      x1: options.swipe[0], y1: options.swipe[1],
      x2: options.swipe[2], y2: options.swipe[3],
    },
  },
};

for (const action of options.actions) {
  if (!definitions[action]) usage(`unknown action: ${action}`);
}

const baseUrl = new URL(options.baseUrl);
if (baseUrl.protocol !== "http:") usage("--base-url currently requires http://");

const agent = new http.Agent({ keepAlive: true, maxSockets: 1 });
let rpcId = 0;

function request(definition) {
  return new Promise((resolve, reject) => {
    let body;
    let path = definition.path;
    let method = definition.method;
    if (definition.rpc) {
      path = "/rpc";
      method = "POST";
      body = JSON.stringify({
        jsonrpc: "2.0",
        id: ++rpcId,
        method: definition.rpc,
        params: definition.params,
      });
    }

    const started = performance.now();
    const req = http.request({
      protocol: baseUrl.protocol,
      hostname: baseUrl.hostname,
      port: baseUrl.port,
      path,
      method,
      agent,
      headers: body ? {
        "content-type": "application/json",
        "content-length": Buffer.byteLength(body),
      } : undefined,
    }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => {
        const elapsedMs = performance.now() - started;
        const text = Buffer.concat(chunks).toString("utf8");
        if (res.statusCode < 200 || res.statusCode >= 300) {
          reject(new Error(`HTTP ${res.statusCode}: ${text.slice(0, 200)}`));
          return;
        }
        if (!definition.rpc) {
          resolve({ elapsedMs, result: text });
          return;
        }
        let payload;
        try {
          payload = JSON.parse(text);
        } catch (error) {
          reject(new Error(`invalid JSON response: ${error.message}`));
          return;
        }
        if (payload.error) {
          reject(new Error(`RPC ${payload.error.code}: ${payload.error.message}`));
          return;
        }
        resolve({ elapsedMs, result: payload.result });
      });
    });
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function percentile(sorted, quantile) {
  if (sorted.length === 0) return null;
  const index = Math.ceil(quantile * sorted.length) - 1;
  return sorted[Math.max(0, Math.min(index, sorted.length - 1))];
}

function summarize(values) {
  const sorted = [...values].sort((a, b) => a - b);
  return {
    count: sorted.length,
    p50Ms: percentile(sorted, 0.50),
    p95Ms: percentile(sorted, 0.95),
    maxMs: sorted.at(-1) ?? null,
    minMs: sorted[0] ?? null,
  };
}

async function runAction(name, definition) {
  for (let index = 0; index < options.warmup; index += 1) {
    await request(definition);
    if (options.settleMs) await sleep(options.settleMs);
  }

  const elapsed = [];
  const synthesis = [];
  const handler = [];
  const rttOutsideHandler = [];
  const runnerTimingValues = new Map();
  const samples = [];
  const failures = [];
  for (let index = 0; index < options.samples; index += 1) {
    try {
      const sample = await request(definition);
      elapsed.push(sample.elapsedMs);
      const durationSeconds = sample.result?.durationSeconds;
      const timings = sample.result?.timings;
      const synthesisSeconds = timings?.synthesisSeconds;
      if (Number.isFinite(synthesisSeconds)) synthesis.push(synthesisSeconds * 1000);
      else if (Number.isFinite(durationSeconds)) synthesis.push(durationSeconds * 1000);

      if (timings && typeof timings === "object") {
        for (const [key, seconds] of Object.entries(timings)) {
          if (!Number.isFinite(seconds)) continue;
          const values = runnerTimingValues.get(key) ?? [];
          values.push(seconds * 1000);
          runnerTimingValues.set(key, values);
        }
        if (Number.isFinite(timings.handlerSeconds)) {
          const handlerMs = timings.handlerSeconds * 1000;
          handler.push(handlerMs);
          rttOutsideHandler.push(sample.elapsedMs - handlerMs);
        }
      }
      samples.push({
        rttMs: sample.elapsedMs,
        result: sample.result,
      });
    } catch (error) {
      failures.push({ sample: index + 1, message: error.message });
    }
    if (options.settleMs) await sleep(options.settleMs);
  }

  const result = {
    rtt: summarize(elapsed),
    runnerSynthesis: synthesis.length ? summarize(synthesis) : null,
    runnerHandler: handler.length ? summarize(handler) : null,
    // This is deliberately labelled as a combined remainder: it includes
    // request parsing/dispatch plus response encoding, HTTP/USB transport, and
    // client overhead. It must not be presented as any one of those stages.
    rttOutsideRunnerHandler: rttOutsideHandler.length
      ? summarize(rttOutsideHandler)
      : null,
    runnerTimings: Object.fromEntries(
      [...runnerTimingValues.entries()].map(([key, values]) => [key, summarize(values)])
    ),
    failures,
    samples,
  };
  console.log(`${name.padEnd(7)} p50=${result.rtt.p50Ms?.toFixed(1)} ms  p95=${result.rtt.p95Ms?.toFixed(1)} ms  max=${result.rtt.maxMs?.toFixed(1)} ms  failures=${failures.length}`);
  return result;
}

const report = {
  schemaVersion: 1,
  timestamp: new Date().toISOString(),
  configuration: options,
  node: process.version,
  results: {},
};

try {
  // This loop is deliberately serial. One runner action must complete before the
  // next begins so the benchmark measures real XCTest completion latency.
  for (const name of options.actions) {
    report.results[name] = await runAction(name, definitions[name]);
  }
} finally {
  agent.destroy();
}

const json = `${JSON.stringify(report, null, 2)}\n`;
if (options.output) {
  const { writeFile } = await import("node:fs/promises");
  await writeFile(options.output, json);
}
console.log(json);
