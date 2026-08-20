#!/usr/bin/env node

import { spawn } from "node:child_process";
import { writeFile } from "node:fs/promises";
import http from "node:http";
import { performance } from "node:perf_hooks";

function usage(message) {
  if (message) console.error(message);
  console.error(`Usage: scripts/benchmark-visible-frame.mjs [options]

Measures command start -> RPC completion and command start -> first materially
changed decoded /h264 frame. Requests remain sequential.

  --base-url URL    DeviceKit URL (default: http://127.0.0.1:12004)
  --action NAME     home, tap, or swipe (default: home)
  --tap X,Y         Required target for --action tap
  --swipe X1,Y1,X2,Y2  Swipe endpoints (default: 187,600,187,200)
  --samples N       Measured samples (default: 30)
  --warmup N        Warm-up samples (default: 3)
  --fps N           /h264 capture rate (default: 60)
  --threshold N     Mean grayscale delta marking a changed frame (default: 8)
  --settle-ms N     State-settle delay (default: 800)
  --timeout-ms N    Per-sample changed-frame timeout (default: 3000)
  --m06-timing 0|1  Diagnostic scheduling path; default 0 uses production RPC
  --ffmpeg PATH     ffmpeg executable (default: ffmpeg)
  --output PATH     Also write full JSON report
`);
  process.exit(message ? 2 : 0);
}

function integer(value, name, minimum = 0) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < minimum) {
    usage(`${name} must be an integer >= ${minimum}`);
  }
  return parsed;
}

function point(value) {
  const values = value.split(",").map(Number);
  if (values.length !== 2 || values.some((item) => !Number.isFinite(item))) {
    usage("--tap must be X,Y");
  }
  return values;
}

function coordinates(value, count, name) {
  const values = value.split(",").map(Number);
  if (values.length !== count || values.some((item) => !Number.isFinite(item))) {
    usage(`${name} must contain ${count} comma-separated numbers`);
  }
  return values;
}

const options = {
  baseUrl: "http://127.0.0.1:12004",
  action: "home",
  tap: undefined,
  swipe: [187, 600, 187, 200],
  samples: 30,
  warmup: 3,
  fps: 60,
  threshold: 8,
  settleMs: 800,
  timeoutMs: 3000,
  m06Timing: 0,
  ffmpeg: "ffmpeg",
  output: undefined,
};

for (let index = 2; index < process.argv.length; index += 1) {
  const key = process.argv[index];
  if (key === "--help" || key === "-h") usage();
  const value = process.argv[++index];
  if (value === undefined) usage(`missing value for ${key}`);
  switch (key) {
    case "--base-url": options.baseUrl = value; break;
    case "--action": options.action = value; break;
    case "--tap": options.tap = point(value); break;
    case "--swipe": options.swipe = coordinates(value, 4, key); break;
    case "--samples": options.samples = integer(value, key, 1); break;
    case "--warmup": options.warmup = integer(value, key); break;
    case "--fps": options.fps = integer(value, key, 1); break;
    case "--threshold": options.threshold = Number(value); break;
    case "--settle-ms": options.settleMs = integer(value, key); break;
    case "--timeout-ms": options.timeoutMs = integer(value, key, 1); break;
    case "--m06-timing": options.m06Timing = integer(value, key); break;
    case "--ffmpeg": options.ffmpeg = value; break;
    case "--output": options.output = value; break;
    default: usage(`unknown option: ${key}`);
  }
}

if (options.m06Timing > 1) usage("--m06-timing must be 0 or 1");

if (!["home", "tap", "swipe"].includes(options.action)) usage("--action must be home, tap, or swipe");
if (options.action === "tap" && !options.tap) usage("--action tap requires --tap X,Y");
if (!Number.isFinite(options.threshold) || options.threshold <= 0) {
  usage("--threshold must be positive");
}

const baseUrl = new URL(options.baseUrl);
if (baseUrl.protocol !== "http:") usage("--base-url must use http://");
const agent = new http.Agent({ keepAlive: true, maxSockets: 1 });
let requestId = 0;

function rpc(method, params = {}) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ jsonrpc: "2.0", id: ++requestId, method, params });
    const request = http.request({
      protocol: baseUrl.protocol,
      hostname: baseUrl.hostname,
      port: baseUrl.port,
      path: options.m06Timing ? "/rpc?m06_timing=1" : "/rpc",
      method: "POST",
      agent,
      headers: {
        "content-type": "application/json",
        "content-length": Buffer.byteLength(body),
      },
    }, (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => {
        let payload;
        try {
          payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        } catch (error) {
          reject(new Error(`invalid RPC JSON: ${error.message}`));
          return;
        }
        if (payload.error) reject(new Error(payload.error.message));
        else resolve({ result: payload.result, m06Timing: payload.m06Timing });
      });
    });
    request.on("error", reject);
    request.end(body);
  });
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

class FrameReader {
  static width = 64;
  static height = 64;
  static bytes = FrameReader.width * FrameReader.height;

  buffer = Buffer.alloc(0);
  latest;
  sequence = 0;
  listeners = new Set();

  push(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length >= FrameReader.bytes) {
      this.latest = Buffer.from(this.buffer.subarray(0, FrameReader.bytes));
      this.buffer = this.buffer.subarray(FrameReader.bytes);
      this.sequence += 1;
      const event = { frame: this.latest, sequence: this.sequence, at: performance.now() };
      for (const listener of this.listeners) listener(event);
    }
  }

  waitForFrame(timeoutMs) {
    if (this.latest) return Promise.resolve(this.latest);
    return this.waitFor(() => true, timeoutMs).then((event) => event.frame);
  }

  waitForChange(reference, afterSequence, threshold, timeoutMs) {
    let observedFrames = 0;
    let maximumDelta = 0;
    return this.waitFor((event) => {
      if (event.sequence <= afterSequence) return false;
      observedFrames += 1;
      const delta = meanAbsoluteDifference(reference, event.frame);
      maximumDelta = Math.max(maximumDelta, delta);
      return delta >= threshold;
    }, timeoutMs, () => (
      `no changed frame within ${timeoutMs} ms; `
      + `observed=${observedFrames}, maxMeanDelta=${maximumDelta.toFixed(2)}`
    ));
  }

  waitFor(predicate, timeoutMs, timeoutMessage = () => `no frame within ${timeoutMs} ms`) {
    return new Promise((resolve, reject) => {
      const listener = (event) => {
        if (!predicate(event)) return;
        clearTimeout(timer);
        this.listeners.delete(listener);
        resolve(event);
      };
      const timer = setTimeout(() => {
        this.listeners.delete(listener);
        reject(new Error(timeoutMessage()));
      }, timeoutMs);
      this.listeners.add(listener);
    });
  }
}

function meanAbsoluteDifference(left, right) {
  let total = 0;
  for (let index = 0; index < left.length; index += 1) {
    total += Math.abs(left[index] - right[index]);
  }
  return total / left.length;
}

function percentile(sorted, quantile) {
  const index = Math.ceil(quantile * sorted.length) - 1;
  return sorted[Math.max(0, Math.min(index, sorted.length - 1))];
}

function summary(values) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return {
    count: sorted.length,
    p50Ms: percentile(sorted, 0.5),
    p95Ms: percentile(sorted, 0.95),
    maxMs: sorted.at(-1),
  };
}

const h264Url = new URL("/h264", baseUrl);
h264Url.searchParams.set("fps", String(options.fps));
h264Url.searchParams.set("scale", "75");
h264Url.searchParams.set("bitrate", "8000000");
h264Url.searchParams.set("quality", "80");
if (options.m06Timing) h264Url.searchParams.set("m06_timing", "1");

const ffmpeg = spawn(options.ffmpeg, [
  "-hide_banner", "-loglevel", "warning",
  // FFmpeg's raw-H264 `nobuffer` mode emitted the first decoded frame but then
  // stalled on DeviceKit's stream in live canary testing. Normal buffering is
  // deterministic enough for before/after comparison and keeps frames flowing.
  "-f", "h264", "-i", h264Url.toString(),
  "-vf", `scale=${FrameReader.width}:${FrameReader.height},format=gray`,
  "-f", "rawvideo", "-pix_fmt", "gray", "pipe:1",
], { stdio: ["ignore", "pipe", "pipe"] });

const frames = new FrameReader();
ffmpeg.stdout.on("data", (chunk) => frames.push(chunk));
let ffmpegError = "";
ffmpeg.stderr.on("data", (chunk) => {
  ffmpegError = `${ffmpegError}${chunk}`.slice(-4000);
});

async function setInitialState() {
  if (options.action === "home" || options.action === "swipe") {
    await rpc("device.apps.launch", { bundleId: "com.apple.Preferences" });
  } else {
    await rpc("device.io.button", { button: "home" });
  }
  await sleep(options.settleMs);
}

async function issueAction(sampleIndex) {
  if (options.action === "home") {
    return rpc("device.io.button", { button: "home" });
  }
  if (options.action === "tap") {
    return rpc("device.io.tap", { x: options.tap[0], y: options.tap[1] });
  }
  const points = sampleIndex % 2 === 0
    ? options.swipe
    : [options.swipe[2], options.swipe[3], options.swipe[0], options.swipe[1]];
  return rpc("device.io.swipe", {
    x1: points[0], y1: points[1], x2: points[2], y2: points[3],
  });
}

async function sample(sampleIndex) {
  await setInitialState();
  const reference = Buffer.from(frames.latest);
  const sequence = frames.sequence;
  const started = performance.now();
  const changed = frames.waitForChange(
    reference,
    sequence,
    options.threshold,
    options.timeoutMs
  );
  const rpcCompletion = issueAction(sampleIndex).then((payload) => ({
    payload,
    completedAt: performance.now(),
  }));
  const [changedFrame, rpcCompleted] = await Promise.all([
    changed,
    rpcCompletion,
  ]);
  return {
    rpcMs: rpcCompleted.completedAt - started,
    firstVisibleFrameMs: changedFrame.at - started,
    frameSequence: changedFrame.sequence,
    meanDelta: meanAbsoluteDifference(reference, changedFrame.frame),
    m06Timing: rpcCompleted.payload.m06Timing,
  };
}

const measured = [];
const failures = [];
try {
  await Promise.race([
    frames.waitForFrame(10_000),
    new Promise((_, reject) => ffmpeg.once("exit", (code) => {
      reject(new Error(`ffmpeg exited ${code}: ${ffmpegError}`));
    })),
  ]);

  for (let index = 0; index < options.warmup; index += 1) await sample(index);
  for (let index = 0; index < options.samples; index += 1) {
    try {
      const result = await sample(options.warmup + index);
      measured.push(result);
      console.log(`${index + 1}/${options.samples} rpc=${result.rpcMs.toFixed(1)} ms visible=${result.firstVisibleFrameMs.toFixed(1)} ms delta=${result.meanDelta.toFixed(1)}`);
    } catch (error) {
      failures.push({ sample: index + 1, message: error.message });
    }
  }
} finally {
  ffmpeg.kill("SIGTERM");
  agent.destroy();
}

const report = {
  schemaVersion: 1,
  timestamp: new Date().toISOString(),
  configuration: options,
  rpc: summary(measured.map((item) => item.rpcMs)),
  firstVisibleFrame: summary(measured.map((item) => item.firstVisibleFrameMs)),
  m06Scheduling: Object.fromEntries(
    [...new Set(measured.flatMap((item) => Object.keys(item.m06Timing ?? {})))]
      .filter((key) => key !== "schemaVersion" && key !== "screenshotActiveAtArrival")
      .map((key) => [
        key,
        summary(measured.map((item) => item.m06Timing?.[key]).filter(Number.isFinite)),
      ])
  ),
  screenshotActiveAtArrival: {
    count: measured.filter((item) => item.m06Timing?.screenshotActiveAtArrival === true).length,
    total: measured.filter((item) => item.m06Timing !== undefined).length,
  },
  failures,
  samples: measured,
};
const json = `${JSON.stringify(report, null, 2)}\n`;
console.log(json);
if (options.output) await writeFile(options.output, json);
