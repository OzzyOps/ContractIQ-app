// ContractIQ · Supabase Edge Function · job-worker
// ---------------------------------------------------------------
// The background worker. pg_cron wakes it every few seconds when
// there is work waiting; it claims jobs one at a time, calls the AI,
// and writes the result back.
//
// The four properties that make this safe under load:
//
//   1. TRANSACTIONAL CLAIM — claim_job() uses SELECT ... FOR UPDATE
//      SKIP LOCKED, so many workers can run at once and no job is
//      ever processed twice.
//   2. IDEMPOTENCY — enqueue_job() collapses duplicate requests onto
//      one row, so a double-click or a network retry cannot cause
//      two analyses (or two charges).
//   3. RETRY WITH BACKOFF — a transient failure requeues with an
//      exponentially growing delay rather than hammering a struggling
//      upstream.
//   4. DEAD-LETTER — after max_attempts the job is parked, not lost,
//      so a human can look at why.
//
// DEPLOY
//   Supabase Dashboard → Edge Functions → Deploy a new function
//   → Via Editor → name it exactly:  job-worker
//   Paste this file. Deploy.
//
//   It is called by the database, not the browser, so leave JWT
//   verification ON — the dispatcher sends the service role key.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
// Sonnet 5 is the right default for contract analysis: it handles long
// documents and structured JSON well, and it is the cheapest tier that
// does so reliably. Override with the ANTHROPIC_MODEL secret if you want
// to route a premium tier to Opus 5. See the setup guide for the numbers.
const MODEL = Deno.env.get("ANTHROPIC_MODEL") ?? "claude-sonnet-5";

// How many jobs one invocation will take. Edge Functions have a wall
// clock limit (150s on the free plan), and one analysis takes roughly
// 20-40s, so three is a safe ceiling. The cron tick picks up the rest.
const MAX_JOBS_PER_RUN = Number(Deno.env.get("MAX_JOBS_PER_RUN") ?? "3");
const WORKER_ID = `worker-${crypto.randomUUID().slice(0, 8)}`;

const db = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false },
});

// ── Circuit breaker ───────────────────────────────────────────
// If the model API is failing, stop hammering it. Kept in module
// scope so it survives between invocations on a warm instance.
let consecutiveFailures = 0;
let breakerOpenUntil = 0;
const BREAKER_THRESHOLD = 4;
const BREAKER_COOLDOWN_MS = 60_000;

function breakerOpen(): boolean {
  return Date.now() < breakerOpenUntil;
}
function recordSuccess() {
  consecutiveFailures = 0;
  breakerOpenUntil = 0;
}
function recordFailure() {
  consecutiveFailures++;
  if (consecutiveFailures >= BREAKER_THRESHOLD) {
    breakerOpenUntil = Date.now() + BREAKER_COOLDOWN_MS;
    console.warn(`circuit breaker OPEN for ${BREAKER_COOLDOWN_MS / 1000}s`);
  }
}

// ── Is this error worth retrying? ─────────────────────────────
// A 400 (malformed request) will fail identically forever — retrying
// wastes credit. A 429 or 5xx is transient and should be retried.
function isRetryable(status: number, message: string): boolean {
  if (status === 429) return true;              // rate limited
  if (status >= 500) return true;               // upstream trouble
  if (status === 408) return true;              // timeout
  if (/network|fetch failed|timeout|ECONN/i.test(message)) return true;
  return false;
}

async function callAnthropic(system: string | undefined, messages: unknown[], maxTokens: number) {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": ANTHROPIC_KEY,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: maxTokens,
      ...(system ? { system } : {}),
      messages,
    }),
  });
  const data = await res.json();
  if (!res.ok) {
    const msg = data?.error?.message ?? `HTTP ${res.status}`;
    const err = new Error(msg) as Error & { status?: number };
    err.status = res.status;
    throw err;
  }
  return data;
}

// The model is asked for JSON. It occasionally wraps it in a code
// fence or adds a sentence either side, so parse defensively rather
// than letting a stray backtick fail the whole job.
function extractJson(text: string) {
  let t = (text ?? "").trim();
  t = t.replace(/^```(?:json)?/i, "").replace(/```$/, "").trim();
  const first = t.indexOf("{");
  const last = t.lastIndexOf("}");
  if (first >= 0 && last > first) t = t.slice(first, last + 1);
  return JSON.parse(t);
}

async function processJob(job: Record<string, any>) {
  const t0 = Date.now();
  const p = job.payload ?? {};

  await db.rpc("report_job_progress", {
    p_job_id: job.id, p_progress: 10, p_note: "Reading documents",
  });

  if (!ANTHROPIC_KEY) {
    throw Object.assign(new Error("Server is missing ANTHROPIC_API_KEY"), { status: 500, fatal: true });
  }
  if (!p.prompt && !Array.isArray(p.messages)) {
    // A malformed payload will never succeed. Do not retry it.
    throw Object.assign(new Error("Job payload has no prompt"), { status: 400, fatal: true });
  }

  await db.rpc("report_job_progress", {
    p_job_id: job.id, p_progress: 35, p_note: "Analysing with AI",
  });

  const messages = p.messages ?? [{ role: "user", content: p.prompt }];
  const data = await callAnthropic(p.system, messages, Math.min(p.max_tokens ?? 3000, 4000));

  await db.rpc("report_job_progress", {
    p_job_id: job.id, p_progress: 80, p_note: "Scoring and checking",
  });

  const text = (data?.content ?? [])
    .filter((b: any) => b?.type === "text")
    .map((b: any) => b.text)
    .join("\n");

  let result: unknown;
  if (job.kind === "analysis" || job.kind === "reanalysis") {
    result = extractJson(text);            // structured analysis
  } else {
    result = { text };                     // Cedric and friends
  }

  await db.rpc("complete_job", { p_job_id: job.id, p_result: result });

  // Telemetry: what this actually cost, recorded server-side.
  const u = data?.usage ?? {};
  await db.from("telemetry_events").insert({
    account_id: job.account_id,
    op: job.kind,
    duration_ms: Date.now() - t0,
    tokens_in: u.input_tokens ?? null,
    tokens_out: u.output_tokens ?? null,
    cached_tokens: u.cache_read_input_tokens ?? null,
    queue_wait_ms: job.started_at
      ? new Date(job.started_at).getTime() - new Date(job.enqueued_at).getTime()
      : null,
    ok: true,
    worker: WORKER_ID,
  });

  const usd = ((u.input_tokens ?? 0) * 3 + (u.output_tokens ?? 0) * 15) / 1e6;
  console.log(`job ${job.id} (${job.kind}) done in ${Date.now() - t0}ms ~$${usd.toFixed(4)}`);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  if (breakerOpen()) {
    const wait = Math.ceil((breakerOpenUntil - Date.now()) / 1000);
    console.warn(`breaker open, skipping this tick (${wait}s remaining)`);
    return Response.json({ skipped: true, reason: "circuit breaker open", retryInSeconds: wait });
  }

  const processed: string[] = [];
  const failed: string[] = [];

  for (let i = 0; i < MAX_JOBS_PER_RUN; i++) {
    // Transactional claim. Two workers racing here get different
    // jobs, or one gets nothing — never the same job twice.
    const { data: job, error: claimErr } = await db.rpc("claim_job", {
      worker: WORKER_ID,
      kinds: ["analysis", "reanalysis", "cedric"],
    });
    if (claimErr) {
      console.error("claim failed", claimErr);
      break;
    }
    if (!job) break;                                  // queue empty

    try {
      await processJob(job);
      processed.push(job.id);
      recordSuccess();
    } catch (e) {
      const err = e as Error & { status?: number; fatal?: boolean };
      const retryable = !err.fatal && isRetryable(err.status ?? 0, err.message ?? "");
      console.error(`job ${job.id} failed (${retryable ? "will retry" : "fatal"}):`, err.message);

      await db.rpc("fail_job", {
        p_job_id: job.id,
        p_error: `${err.status ?? ""} ${err.message}`.trim().slice(0, 500),
        p_retryable: retryable,
      });
      await db.from("telemetry_events").insert({
        account_id: job.account_id, op: job.kind, ok: false,
        error_class: String(err.status ?? "error"), worker: WORKER_ID,
      });

      failed.push(job.id);
      if (retryable) recordFailure();
      // A fatal error is this job's problem, not the system's, so
      // carry on with the next one.
      if (breakerOpen()) break;
    }
  }

  return Response.json({
    worker: WORKER_ID,
    processed: processed.length,
    failed: failed.length,
    breakerOpen: breakerOpen(),
  });
});
