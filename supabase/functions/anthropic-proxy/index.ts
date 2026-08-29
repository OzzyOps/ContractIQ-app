// ContractIQ · Supabase Edge Function · anthropic-proxy
// ---------------------------------------------------------------
// The ONLY place the Anthropic API key exists. The browser never sees it.
//
// DEPLOY (free tier):
//   supabase functions new anthropic-proxy      # paste this file in
//   supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
//   supabase secrets set ALLOWED_ORIGIN=https://YOURNAME.github.io
//   supabase functions deploy anthropic-proxy --no-verify-jwt
//
// The --no-verify-jwt flag is for TESTING ONLY. It lets the app call this
// without a signed-in Supabase user, which is what you want while you are
// evaluating the product yourself. "BEFORE REAL USERS" at the bottom
// explains exactly what to turn on before anyone else touches it.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const ANTHROPIC_KEY  = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
const ALLOWED_ORIGIN = Deno.env.get("ALLOWED_ORIGIN") ?? "";   // e.g. https://you.github.io
// Sonnet 5 is the right default for contract analysis: it handles long
// documents and structured JSON well, and it is the cheapest tier that
// does so reliably. Override with the ANTHROPIC_MODEL secret if you want
// to route a premium tier to Opus 5. See the setup guide for the numbers.
const MODEL          = Deno.env.get("ANTHROPIC_MODEL") ?? "claude-sonnet-5";

// Crude but effective spend guard while testing: caps how many calls this
// function will make in a rolling hour, so a mistake (or someone finding
// the URL) cannot quietly run up a bill.
const MAX_CALLS_PER_HOUR = Number(Deno.env.get("MAX_CALLS_PER_HOUR") ?? "60");
let windowStart = Date.now();
let callsThisWindow = 0;

const corsHeaders = (origin: string) => ({
  "Access-Control-Allow-Origin": ALLOWED_ORIGIN || origin || "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  // Cache the preflight for 24 hours. Without this the browser asks
  // permission before EVERY call — five times per analysis — and each
  // OPTIONS is another chance to hit a worker that is still booting or
  // shutting down after a long request, which returns 502 and makes the
  // browser report "Failed to fetch" without ever sending the POST.
  // One preflight per day instead of five per analysis.
  "Access-Control-Max-Age": "86400",
  "Vary": "Origin",
});

serve(async (req) => {
  const origin = req.headers.get("origin") ?? "";
  const cors = corsHeaders(origin);

  // Answer the preflight FIRST and as cheaply as possible: 204, no body,
  // before any key check, rate-limit check or JSON parsing. A preflight
  // that fails blocks the real request entirely, so it must never depend
  // on anything that could error.
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }),
      { status: 405, headers: { ...cors, "Content-Type": "application/json" } });
  }

  // Only serve the origin you deployed to. Without this, anyone who finds
  // the URL can spend your Anthropic credit.
  if (ALLOWED_ORIGIN && origin && origin !== ALLOWED_ORIGIN) {
    return new Response(JSON.stringify({ error: "Origin not allowed" }),
      { status: 403, headers: { ...cors, "Content-Type": "application/json" } });
  }

  if (!ANTHROPIC_KEY) {
    return new Response(JSON.stringify({ error: "Server is missing ANTHROPIC_API_KEY" }),
      { status: 500, headers: { ...cors, "Content-Type": "application/json" } });
  }

  // ── Spend guard ──
  if (Date.now() - windowStart > 3_600_000) { windowStart = Date.now(); callsThisWindow = 0; }
  if (callsThisWindow >= MAX_CALLS_PER_HOUR) {
    return new Response(JSON.stringify({
      error: `Rate limit reached (${MAX_CALLS_PER_HOUR}/hour). This is a safety cap you set, not an Anthropic limit.`,
    }), { status: 429, headers: { ...cors, "Content-Type": "application/json" } });
  }
  callsThisWindow++;

  try {
    const body = await req.json();

    // Only forward the fields we expect. Never let the client choose the
    // model or pass arbitrary parameters through to a paid API.
    const messages = Array.isArray(body.messages) ? body.messages : [];
    if (!messages.length) {
      return new Response(JSON.stringify({ error: "No messages supplied" }),
        { status: 400, headers: { ...cors, "Content-Type": "application/json" } });
    }
    const payload = {
      model: MODEL,
      // Ceiling raised from 4,000. A full contract analysis routinely needs
      // 5-7k output tokens; capping at 4,000 truncated the JSON mid-object
      // after ~45 seconds of generation, which surfaced as an opaque failure.
      max_tokens: Math.min(Number(body.max_tokens) || 2000, 16000),
      ...(body.system ? { system: String(body.system) } : {}),
      messages,
    };

    const upstream = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": ANTHROPIC_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify(payload),
    });

    const data = await upstream.json();

    // Log usage so you can see what testing actually costs.
    if (data?.usage) {
      const inTok = data.usage.input_tokens ?? 0;
      const outTok = data.usage.output_tokens ?? 0;
      const usd = (inTok * 3) / 1e6 + (outTok * 15) / 1e6;
      console.log(`in:${inTok} out:${outTok} ~$${usd.toFixed(4)} (call ${callsThisWindow}/${MAX_CALLS_PER_HOUR} this hour)`);
    }

    return new Response(JSON.stringify(data), {
      status: upstream.status,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error("proxy error", e);
    return new Response(JSON.stringify({ error: "Proxy failure", detail: String(e) }),
      { status: 502, headers: { ...cors, "Content-Type": "application/json" } });
  }
});

/* ===============================================================
   BEFORE REAL USERS - what this test build deliberately skips
   ===============================================================
   This version is safe enough to evaluate the product yourself. It is
   NOT safe in front of paying customers, because it does not:

   1. VERIFY WHO IS CALLING.
      Deploy without --no-verify-jwt, then read the caller's Supabase Auth
      JWT and build a Supabase client with it, so Row Level Security
      filters every query to that user's own account:

        const supabase = createClient(
          Deno.env.get("SUPABASE_URL")!,
          Deno.env.get("SUPABASE_ANON_KEY")!,
          { global: { headers: { Authorization: req.headers.get("Authorization")! } } },
        );
        const { data: { user } } = await supabase.auth.getUser();
        if (!user) return new Response("Unauthorized", { status: 401 });

   2. ENFORCE CREDITS SERVER-SIDE.
      The credit balance in the app is a display, not a control - a
      modified client can spend without limit. Check before, record after:

        const { data: left } = await supabase.rpc("credits_remaining", { acct: accountId });
        if (left < 10) return new Response("Out of credits", { status: 402 });
        // ... call Anthropic ...
        await supabase.from("credit_ledger").insert({
          account_id: accountId, kind: "analysis", credits: 10,
        });

   3. USE PROMPT CACHING.
      Cedric re-sends the whole document context every question. Caching
      cuts that to roughly a third of the cost.

   credits_remaining() and credit_ledger already exist in
   contractiq_supabase_schema.sql - they are just not wired up here.
   =============================================================== */
