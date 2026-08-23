-- ═══════════════════════════════════════════════════════════════
--  ContractIQ — complete database setup
--  ONE script. Replaces schema_FIXED.sql and migration_002.
-- ═══════════════════════════════════════════════════════════════
--
--  WHAT THIS DOES
--    Creates every table, security policy, function and view the app
--    needs: contracts and documents, per-field confidence scoring,
--    the credit ledger, real user accounts with roles, invitations,
--    the transcript-consent evidence trail, and the background job
--    queue.
--
--  HOW TO RUN IT
--    Supabase Dashboard → SQL Editor → paste all of this → Run.
--    It takes a few seconds.
--
--  IS IT SAFE TO RUN OVER WHAT I ALREADY HAVE?
--    Yes. Every statement is IF NOT EXISTS, CREATE OR REPLACE, or
--    preceded by a DROP ... IF EXISTS. Running it twice changes
--    nothing and destroys nothing. Your existing contract data is
--    left alone.
--
--    (If a previous attempt failed partway, don't worry about
--    cleaning up first. The Supabase SQL editor runs a script in a
--    single transaction, so a failure rolls the whole thing back —
--    a half-built state almost never exists.)
--
--  WHAT IT DOESN'T DO
--    It does not store your Anthropic API key. That belongs in
--    Edge Functions → Secrets, entered by you, and nowhere else.
--
--  AFTER RUNNING, THERE ARE THREE MANUAL STEPS
--    They're listed at the bottom of this file, and in the setup
--    guide with pictures.
-- ═══════════════════════════════════════════════════════════════



-- ═══════════════════════════════════════════════════════════════
--  PART 1 of 2 · CORE SCHEMA
--  Contracts, documents, analyses, confidence scoring, credits,
--  policy packs, transcript consent, obligations, search.
-- ═══════════════════════════════════════════════════════════════

-- FIXED 12 Aug 2026. The previous version failed in the SQL editor with:
--   ERROR 42804: foreign key constraint "data_points_contract_id_fkey"
--   cannot be implemented — key columns "contract_id" and "id" are of
--   incompatible types: uuid and text.
--
-- Cause: the app generates its own string contract IDs ("c1", "CTR-1001"),
-- so contracts.id and documents.id are TEXT, and analyses.id is BIGINT.
-- Five later columns had been declared UUID. Postgres will not create a
-- foreign key between columns of different types.
--
-- Eight corrections were made:
--   data_points.contract_id              uuid   -> text
--   data_points.analysis_id              uuid   -> bigint
--   jobs.contract_id                     uuid   -> text
--   analysis_policy_snapshot.analysis_id uuid   -> bigint
--   obligation_tracking.contract_id      uuid   -> text
--   documents_search_refresh()   new.text -> new.extracted_text
--   the trigger's watched column list    text   -> extracted_text
--   search_documents()  return types uuid -> text, d.text -> d.extracted_text
--
-- The last three would not have surfaced until search was used, so they
-- are fixed here too rather than waiting to bite later.
--
-- Safe to re-run: every statement uses IF NOT EXISTS or CREATE OR REPLACE.
-- If you already ran the broken version, see RUN_ME_FIRST.sql.
-- ===============================================================

-- ContractIQ · Supabase schema (v2 — tenant-isolated)
-- Run in the Supabase SQL editor before first sync.
--
-- SECURITY MODEL — account isolation:
-- Every row belongs to exactly one business account (account_id).
-- Row Level Security (RLS) enforces that a signed-in user can ONLY
-- read/write rows for their own account — the database refuses
-- everything else. This is what guarantees Cedric can never recall
-- another account's contracts: his context is built from queries
-- that RLS has already filtered. Client-side checks are convenience,
-- never the security boundary.

-- Business accounts (tenants) + billing state
create table if not exists accounts (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  created_at timestamptz default now(),

  -- ── Billing (written ONLY by the Stripe webhook, never by the app) ──
  plan                   text default 'sandbox'
                         check (plan in ('sandbox','growth','scale','enterprise')),
  credits_included       int  default 150,     -- allowance for the current period
  credits_used           int  default 0,       -- reset when the period rolls
  credits_banked         int  default 0,       -- rolled-over credits, capped by plan
  period_started_at      timestamptz default now(),
  billing_email          text,
  billing_country        text,
  vat_number             text,
  billing_status         text default 'active',
  stripe_customer_id     text unique,
  stripe_subscription_id text,
  last_failed_invoice    text,
  marketing_opt_in       boolean default false,
  signup_source          text
);

-- Every AI action that spends credits. This is the billing audit trail:
-- it must be written server-side by the Edge Function, not the client.
create table if not exists credit_ledger (
  id          bigint generated always as identity primary key,
  account_id  uuid not null references accounts(id) on delete cascade,
  user_id     uuid references auth.users(id) on delete set null,
  contract_id text,
  kind        text not null check (kind in ('analysis','cedric','revision','topup')),
  credits     int  not null,          -- negative for top-up purchases
  created_at  timestamptz default now()
);
create index if not exists credit_ledger_account_time
  on credit_ledger (account_id, created_at desc);

-- Credits remaining right now, for the current billing period.
create or replace function credits_remaining(acct uuid) returns int
language sql stable as $$
  select greatest(0,
    (select coalesce(credits_included,0) + coalesce(credits_banked,0)
       from accounts where id = acct)
  - (select coalesce(sum(credits),0) from credit_ledger l
       join accounts a on a.id = l.account_id
      where l.account_id = acct and l.created_at >= a.period_started_at)
  )
$$;

-- Members: maps Supabase Auth users to an account with a role
create table if not exists account_members (
  user_id    uuid references auth.users(id) on delete cascade,
  account_id uuid references accounts(id) on delete cascade,
  role       text default 'member' check (role in ('admin','member','viewer')),
  primary key (user_id, account_id)
);

-- Helper: the account(s) the current authenticated user belongs to
create or replace function my_account_ids() returns setof uuid
language sql security definer stable as $$
  select account_id from account_members where user_id = auth.uid()
$$;

create table if not exists contracts (
  id                 text primary key,
  account_id         uuid not null references accounts(id) on delete cascade,
  ref                text,
  name               text,
  supplier           text not null,
  category           text,
  annual_value       numeric default 0,
  currency           text default 'GBP',
  start_date         date,
  end_date           date,
  notice_period_days int default 90,
  auto_renew         boolean default false,
  owner              text,
  users_count        int default 0,
  notes              text,
  analysis           jsonb,
  documents_meta     jsonb,
  created_at         timestamptz default now(),
  updated_at         timestamptz default now()
);

create table if not exists documents (
  id             text primary key,
  account_id     uuid not null references accounts(id) on delete cascade,
  contract_id    text references contracts(id) on delete cascade,
  name           text not null,
  doc_type       text,
  size_bytes     bigint,
  extracted_text text,
  storage_path   text,
  created_at     timestamptz default now()
);

create table if not exists contract_users (
  id           bigint generated always as identity primary key,
  account_id   uuid not null references accounts(id) on delete cascade,
  contract_id  text references contracts(id) on delete cascade,
  full_name    text,
  email        text,
  team         text,
  last_active  date,
  licence_type text
);

create table if not exists analyses (
  id           bigint generated always as identity primary key,
  account_id   uuid not null references accounts(id) on delete cascade,
  contract_id  text references contracts(id) on delete cascade,
  analysis     jsonb not null,
  created_at   timestamptz default now()
);

-- ── ROW LEVEL SECURITY: the isolation boundary ──────────────────
alter table accounts        enable row level security;
alter table account_members enable row level security;
alter table contracts       enable row level security;
alter table documents       enable row level security;
alter table contract_users  enable row level security;
alter table analyses        enable row level security;

-- Users can see their own account and membership
drop policy if exists "read own account" on accounts;
create policy "read own account" on accounts
  for select using (id in (select my_account_ids()));
drop policy if exists "read own membership" on account_members;
create policy "read own membership" on account_members
  for select using (user_id = auth.uid());

-- Per-account access on all data tables: a user touches ONLY rows
-- whose account_id matches an account they belong to.
drop policy if exists "own account rows" on contracts;
create policy "own account rows" on contracts
  for all using (account_id in (select my_account_ids()))
  with check (account_id in (select my_account_ids()));
drop policy if exists "own account rows" on documents;
create policy "own account rows" on documents
  for all using (account_id in (select my_account_ids()))
  with check (account_id in (select my_account_ids()));
drop policy if exists "own account rows" on contract_users;
create policy "own account rows" on contract_users
  for all using (account_id in (select my_account_ids()))
  with check (account_id in (select my_account_ids()));
drop policy if exists "own account rows" on credit_ledger;
create policy "own account rows" on credit_ledger
  for all using (account_id in (select my_account_ids()))
  with check (account_id in (select my_account_ids()));
drop policy if exists "own account rows" on analyses;
create policy "own account rows" on analyses
  for all using (account_id in (select my_account_ids()))
  with check (account_id in (select my_account_ids()));

-- ── PRODUCTION RULES (read before go-live) ─────────────────────
-- 1. Sign-in must use Supabase Auth. The app then queries with the
--    user's JWT and RLS does the filtering automatically.
-- 2. The AI Edge Function (Cedric / analysis proxy) must fetch
--    contract context using the CALLER'S JWT — never the service_role
--    key — so it can only ever read what that user is allowed to see.
-- 3. Never expose the service_role key to any client.
-- 4. The anon key alone (no signed-in user) can read NOTHING under
--    these policies — which is the correct default.


-- ── BILLING RULES (read before go-live) ────────────────────────
-- 1. accounts.plan and accounts.credits_included are set ONLY by the
--    Stripe webhook. If the app can write them, a user can grant
--    themselves Enterprise for free.
-- 2. The Edge Function must check credits_remaining() BEFORE calling the
--    AI, and insert into credit_ledger AFTER a successful call. The
--    client-side balance in the app is a display, not a control.
-- 3. Reset the period monthly: set credits_used = 0, roll unused credits
--    into credits_banked (capped per plan), and move period_started_at.


-- ═══════════════════════════════════════════════════════════════
--  ACTUARIAL ACCURACY LAYER
--  Every extracted value is a row with its own confidence score,
--  reasoning and traceable source. This is what makes an accuracy
--  claim measurable rather than aspirational.
-- ═══════════════════════════════════════════════════════════════

create table if not exists data_points (
  id           bigint generated always as identity primary key,
  account_id   uuid not null references accounts(id) on delete cascade,
  contract_id  text not null references contracts(id) on delete cascade,
  analysis_id  bigint references analyses(id) on delete cascade,

  field        text not null,                     -- 'annualValue', 'Limitation of liability', ...
  kind         text not null check (kind in ('extraction','clause','risk','obligation')),
  value        text,
  confidence   int  not null check (confidence between 0 and 100),
  reasoning    text,
  source_ref   text,                              -- document + quoted phrase, or basis of inference

  -- H-I-L routing tier, derived from confidence. Stored (not just computed)
  -- so historic routing decisions remain auditable if thresholds change.
  tier         text generated always as (
                 case when confidence <= 50 then 'deep'
                      when confidence <= 80 then 'light'
                      else 'auto' end) stored,

  status       text default 'pending' check (status in ('pending','accepted','corrected','rejected')),
  verified_by  uuid references auth.users(id) on delete set null,
  verified_at  timestamptz,
  corrected_value text,

  -- Calibration: filled in later when ground truth is known. This column is
  -- what turns self-reported confidence into a MEASURED accuracy rate.
  ground_truth text,
  was_correct  boolean,

  created_at   timestamptz default now()
);
create index if not exists data_points_queue
  on data_points (account_id, status, tier) where status = 'pending';
create index if not exists data_points_contract
  on data_points (contract_id, created_at desc);

-- Immutable record of every human verification decision.
create table if not exists verification_audit (
  id            bigint generated always as identity primary key,
  account_id    uuid not null references accounts(id) on delete cascade,
  data_point_id bigint not null references data_points(id) on delete cascade,
  user_id       uuid references auth.users(id) on delete set null,
  action        text not null check (action in ('accepted','corrected','rejected','reopened')),
  value_before  text,
  value_after   text,
  note          text,
  created_at    timestamptz default now()
);
create index if not exists verification_audit_point on verification_audit (data_point_id, created_at);

-- Measured accuracy by tier. Run against rows where ground_truth is known.
-- THIS is the query that substantiates an accuracy claim — nothing else does.
create or replace view accuracy_by_tier as
  select tier,
         count(*)                                        as sampled,
         round(100.0 * count(*) filter (where was_correct) / nullif(count(*),0), 1) as measured_accuracy_pct,
         round(avg(confidence), 1)                       as mean_self_reported_confidence
  from data_points
  where was_correct is not null
  group by tier;


-- ═══════════════════════════════════════════════════════════════
--  ASYNC JOB QUEUE  (decouples ingestion / inference / writes)
--  Heavy work never runs in the request path. The API enqueues and
--  returns immediately; workers claim jobs transactionally.
-- ═══════════════════════════════════════════════════════════════

create table if not exists jobs (
  id            uuid primary key default gen_random_uuid(),
  account_id    uuid not null references accounts(id) on delete cascade,
  contract_id   text references contracts(id) on delete cascade,
  kind          text not null check (kind in ('ingest','ocr','analysis','reanalysis','export','embed')),
  payload       jsonb not null default '{}'::jsonb,

  status        text not null default 'queued'
                check (status in ('queued','running','succeeded','failed','dead')),
  priority      int  not null default 100,          -- lower = sooner; paid tiers get a lower number
  attempts      int  not null default 0,
  max_attempts  int  not null default 5,

  -- Exponential backoff: a failed job becomes visible again at run_after.
  run_after     timestamptz not null default now(),
  locked_by     text,                                -- worker id
  locked_at     timestamptz,
  heartbeat_at  timestamptz,                         -- stale lock reaper uses this

  error         text,
  result        jsonb,
  enqueued_at   timestamptz default now(),
  started_at    timestamptz,
  finished_at   timestamptz
);
create index if not exists jobs_claimable
  on jobs (status, priority, run_after) where status = 'queued';
create index if not exists jobs_account on jobs (account_id, enqueued_at desc);

-- Transactional claim: SKIP LOCKED lets many workers pull concurrently
-- without blocking each other or double-processing a job.
create or replace function claim_job(worker text, kinds text[] default null)
returns jobs language plpgsql as $$
declare j jobs;
begin
  select * into j from jobs
   where status = 'queued'
     and run_after <= now()
     and (kinds is null or kind = any(kinds))
   order by priority, run_after
   for update skip locked
   limit 1;
  if not found then return null; end if;
  update jobs set status='running', locked_by=worker, locked_at=now(),
         heartbeat_at=now(), attempts=attempts+1, started_at=coalesce(started_at, now())
   where id = j.id returning * into j;
  return j;
end $$;

-- Reap jobs whose worker died mid-flight (no heartbeat), with backoff.
create or replace function reap_stale_jobs(stale_after interval default '5 minutes')
returns int language plpgsql as $$
declare n int;
begin
  with reaped as (
    update jobs
       set status = case when attempts >= max_attempts then 'dead' else 'queued' end,
           run_after = now() + (interval '10 seconds' * power(2, least(attempts, 6))),
           locked_by = null, locked_at = null,
           error = coalesce(error, 'worker heartbeat lost')
     where status = 'running' and heartbeat_at < now() - stale_after
     returning 1)
  select count(*) into n from reaped;
  return n;
end $$;

-- Queue depth by kind — the primary autoscaling signal.
create or replace view queue_depth as
  select kind, status, count(*) as n,
         extract(epoch from (now() - min(enqueued_at))) as oldest_seconds
  from jobs where status in ('queued','running') group by kind, status;


-- ═══════════════════════════════════════════════════════════════
--  HOT-SWAPPABLE REGULATORY POLICY PACKS
--  Compliance rules are DATA. Changing the law is an UPDATE, not a
--  redeploy. Versioned so an old analysis can be explained against
--  the ruleset that was actually in force when it ran.
-- ═══════════════════════════════════════════════════════════════

create table if not exists policy_packs (
  id            uuid primary key default gen_random_uuid(),
  account_id    uuid references accounts(id) on delete cascade,  -- null = global/system pack
  key           text not null,                    -- 'uk-core', 'eu-gdpr', ...
  name          text not null,
  jurisdiction  text not null,                    -- 'GB','EU','US','ANY'
  version       text not null,
  rules         jsonb not null,                   -- array of rule strings
  active        boolean not null default true,
  effective_from timestamptz default now(),
  effective_to   timestamptz,                     -- null = current
  updated_by    uuid references auth.users(id) on delete set null,
  updated_at    timestamptz default now(),
  unique (account_id, key, version)
);
create index if not exists policy_packs_active
  on policy_packs (jurisdiction, active) where active;

-- Which rules were in force at a moment in time — needed to defend a
-- historic analysis ("why didn't it flag X?" → X wasn't in force yet).
create or replace function policy_packs_at(ts timestamptz, jur text default null)
returns setof policy_packs language sql stable as $$
  select * from policy_packs
   where active
     and effective_from <= ts
     and (effective_to is null or effective_to > ts)
     and (jur is null or jurisdiction in (jur, 'ANY'))
$$;

-- Record which pack versions an analysis was graded against.
create table if not exists analysis_policy_snapshot (
  analysis_id bigint not null references analyses(id) on delete cascade,
  pack_id     uuid not null references policy_packs(id),
  primary key (analysis_id, pack_id)
);


-- ═══════════════════════════════════════════════════════════════
--  TELEMETRY
-- ═══════════════════════════════════════════════════════════════

create table if not exists telemetry_events (
  id           bigint generated always as identity primary key,
  account_id   uuid references accounts(id) on delete cascade,
  op           text not null,                    -- 'analysis','ingest','cedric','export'
  duration_ms  int,
  tokens_in    int,
  tokens_out   int,
  cached_tokens int,
  queue_wait_ms int,
  ok           boolean,
  error_class  text,
  worker       text,
  created_at   timestamptz default now()
);
create index if not exists telemetry_recent on telemetry_events (created_at desc);

-- Rolling operational picture for dashboards and alerting.
create or replace view ops_health as
  select date_trunc('minute', created_at) as minute,
         op,
         count(*)                                     as ops,
         round(avg(duration_ms))                      as avg_ms,
         percentile_disc(0.95) within group (order by duration_ms) as p95_ms,
         round(100.0 * count(*) filter (where ok) / nullif(count(*),0), 1) as success_pct,
         sum(tokens_in + tokens_out)                  as tokens
  from telemetry_events
  where created_at > now() - interval '24 hours'
  group by 1, 2;


-- ── RLS for the new tables (tenant isolation is not optional) ──
alter table data_points        enable row level security;
alter table verification_audit enable row level security;
alter table jobs               enable row level security;
alter table policy_packs       enable row level security;
alter table telemetry_events   enable row level security;

drop policy if exists "own account rows" on data_points;
create policy "own account rows" on data_points
  for all using (account_id in (select my_account_ids()))
  with check (account_id in (select my_account_ids()));
drop policy if exists "own account rows" on verification_audit;
create policy "own account rows" on verification_audit
  for all using (account_id in (select my_account_ids()))
  with check (account_id in (select my_account_ids()));
drop policy if exists "own account rows" on jobs;
create policy "own account rows" on jobs
  for all using (account_id in (select my_account_ids()))
  with check (account_id in (select my_account_ids()));
drop policy if exists "own or global packs" on policy_packs;
create policy "own or global packs" on policy_packs
  for select using (account_id is null or account_id in (select my_account_ids()));
drop policy if exists "own account rows" on telemetry_events;
create policy "own account rows" on telemetry_events
  for all using (account_id in (select my_account_ids()))
  with check (account_id in (select my_account_ids()));


-- ── OPERATIONAL NOTES ──────────────────────────────────────────
-- 1. An accuracy CLAIM requires the accuracy_by_tier view to be populated
--    from a labelled sample. Self-reported confidence is a routing signal,
--    not evidence. Do not publish a percentage until this view has data.
-- 2. Workers must heartbeat (update heartbeat_at) or reap_stale_jobs will
--    requeue their work. Run the reaper on a schedule (pg_cron, 1 min).
-- 3. Autoscale on queue_depth.oldest_seconds, not CPU — a queue that is
--    deep but moving is healthy; a shallow queue that is not draining is not.


-- ═══════════════════════════════════════════════════════════════
--  TRANSCRIPT RECORDING CONSENT
--  Clause 7 of the Terms puts the recording-notice obligation on the
--  customer. This table is the evidence that they accepted it, and
--  every transcript references the acceptance it came in under.
-- ═══════════════════════════════════════════════════════════════

create table if not exists transcript_consents (
  id           uuid primary key default gen_random_uuid(),
  account_id   uuid not null references accounts(id) on delete cascade,
  accepted_by  uuid references auth.users(id) on delete set null,
  accepted_name text not null,                  -- denormalised: survives user deletion
  version      text not null,                   -- consent wording version, e.g. '2026.1'
  ip_address   inet,
  user_agent   text,
  accepted_at  timestamptz default now()
);
create index if not exists transcript_consents_account
  on transcript_consents (account_id, accepted_at desc);

-- Link each ingested transcript to the acceptance in force at the time.
alter table documents add column if not exists consent_id uuid references transcript_consents(id);
alter table documents add column if not exists is_transcript boolean default false;

-- OCR provenance: a value read by OCR is less reliable than one read from a
-- text layer, and the analysis should be able to say so.
alter table documents add column if not exists ocr_applied boolean default false;
alter table documents add column if not exists ocr_at timestamptz;
alter table documents add column if not exists ocr_chars int;
alter table documents add column if not exists scanned boolean default false;
alter table documents add column if not exists page_count int;

-- Refuse to store a transcript with no consent on file. Belt and braces
-- alongside the UI gate — the database is the last line, not the first.
create or replace function assert_transcript_consent() returns trigger
language plpgsql as $$
begin
  if new.is_transcript and new.consent_id is null then
    raise exception 'transcript upload requires a recorded consent (see transcript_consents)';
  end if;
  return new;
end $$;
drop trigger if exists documents_require_consent on documents;
create trigger documents_require_consent
  before insert or update on documents
  for each row execute function assert_transcript_consent();


-- ═══════════════════════════════════════════════════════════════
--  OBLIGATION TRACKING
--  Extraction finds obligations; tracking is what makes them get done.
-- ═══════════════════════════════════════════════════════════════

create table if not exists obligation_tracking (
  id            uuid primary key default gen_random_uuid(),
  account_id    uuid not null references accounts(id) on delete cascade,
  contract_id   text not null references contracts(id) on delete cascade,
  obligation_ix int not null,                   -- index within the analysis register
  obligation    text not null,                  -- denormalised so it survives re-analysis
  party         text check (party in ('us','supplier')),
  assignee_id   uuid references auth.users(id) on delete set null,
  assignee_name text,
  due_date      date,
  status        text not null default 'open' check (status in ('open','done','waived')),
  completed_at  timestamptz,
  completed_by  uuid references auth.users(id) on delete set null,
  updated_at    timestamptz default now(),
  unique (contract_id, obligation_ix)
);
create index if not exists obligation_due
  on obligation_tracking (account_id, status, due_date) where status = 'open';

-- What is overdue or unowned right now — drives the reminder job.
create or replace view obligations_due as
  select t.*, c.ref, c.supplier,
         (t.due_date < current_date) as overdue,
         (t.assignee_id is null)     as unassigned
  from obligation_tracking t
  join contracts c on c.id = t.contract_id
  where t.status = 'open';


-- ═══════════════════════════════════════════════════════════════
--  PORTFOLIO SEARCH
--  Repository-wide search is one of the top-three ROI capabilities in
--  this category. Postgres full-text search is more than sufficient at
--  mid-market scale and avoids standing up a separate search cluster.
-- ═══════════════════════════════════════════════════════════════

alter table documents add column if not exists search_tsv tsvector;
create index if not exists documents_search on documents using gin (search_tsv);

create or replace function documents_search_refresh() returns trigger
language plpgsql as $$
begin
  new.search_tsv :=
    setweight(to_tsvector('english', coalesce(new.name, '')), 'A') ||
    setweight(to_tsvector('english', left(coalesce(new.extracted_text, ''), 900000)), 'B');
  return new;
end $$;
drop trigger if exists documents_search_tsv on documents;
create trigger documents_search_tsv
  before insert or update of name, extracted_text on documents
  for each row execute function documents_search_refresh();

-- Ranked search across a tenant's documents, with a highlighted snippet.
create or replace function search_documents(acct uuid, q text, lim int default 40)
returns table (contract_id text, document_id text, name text, snippet text, rank real)
language sql stable as $$
  select d.contract_id, d.id, d.name,
         ts_headline('english', coalesce(d.extracted_text, ''), websearch_to_tsquery('english', q),
                     'MaxFragments=2,MinWords=8,MaxWords=26'),
         ts_rank(d.search_tsv, websearch_to_tsquery('english', q))
  from documents d
  join contracts c on c.id = d.contract_id
  where c.account_id = acct
    and d.search_tsv @@ websearch_to_tsquery('english', q)
  order by 5 desc
  limit lim
$$;


-- ── RLS for the new tables ─────────────────────────────────────
alter table transcript_consents   enable row level security;
alter table obligation_tracking   enable row level security;
drop policy if exists "own account rows" on transcript_consents;
create policy "own account rows" on transcript_consents
  for all using (account_id in (select my_account_ids()))
  with check (account_id in (select my_account_ids()));
drop policy if exists "own account rows" on obligation_tracking;
create policy "own account rows" on obligation_tracking
  for all using (account_id in (select my_account_ids()))
  with check (account_id in (select my_account_ids()));


-- ── NOTES ──────────────────────────────────────────────────────
-- 1. OCR runs client-side (tesseract.js) so scanned documents never leave
--    the user's machine. Set ocr_applied so the analysis can weight an
--    OCR-derived value lower than one read from a real text layer.
-- 2. obligations_due drives a scheduled reminder — the feature that turns
--    an obligations register into something people actually act on.
-- 3. search_documents covers document text. Record fields and analysis
--    findings are searched in-app; move them here if the estate grows
--    beyond what the client can hold comfortably.


-- ═══════════════════════════════════════════════════════════════
--  PART 2 of 2 · ACCOUNTS AND BACKGROUND PROCESSING
--  Real user accounts, roles, invitations, and the job queue that
--  lets analysis survive the browser tab being closed.
-- ═══════════════════════════════════════════════════════════════

-- Adds two things to the schema you already ran:
--
--   PART A  Real user accounts
--           Supabase Auth, email verification, organisations,
--           roles, invitations, and RLS wired to the signed-in user.
--
--   PART B  Async AI processing
--           Jobs are queued and processed by a background worker
--           instead of blocking the browser. Survives closing the
--           tab, retries on failure, and cannot time out.
--
-- Run this AFTER schema_FIXED.sql, in the Supabase SQL Editor.
-- Safe to re-run: every statement uses IF NOT EXISTS / OR REPLACE.
-- ===============================================================


-- ═══════════════════════════════════════════════════════════════
--  PART A · REAL USER ACCOUNTS
-- ═══════════════════════════════════════════════════════════════

-- ── A1 · Profiles ──────────────────────────────────────────────
-- auth.users is managed by Supabase and should not be altered.
-- This mirrors the bits the application needs, and is safe to read.
create table if not exists profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  email         text not null,
  full_name     text,
  avatar_url    text,
  job_title     text,
  -- The Terms/Privacy/DPA acceptance now belongs to a real person,
  -- not a browser session. This is the evidence trail.
  terms_accepted_at      timestamptz,
  terms_version          text,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);

alter table profiles enable row level security;

drop policy if exists "read own profile" on profiles;
create policy "read own profile" on profiles
  for select using (id = auth.uid());

drop policy if exists "update own profile" on profiles;
create policy "update own profile" on profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

-- Colleagues in the same organisation can see each other's names.
drop policy if exists "read profiles in my orgs" on profiles;
create policy "read profiles in my orgs" on profiles
  for select using (
    id in (
      select m.user_id from account_members m
      where m.account_id in (select my_account_ids())
    )
  );


-- ── A2 · Create the profile automatically on sign-up ───────────
-- Without this, a verified user exists in auth.users but has no
-- row anywhere the application can see, and every RLS check fails.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  new_account_id uuid;
  org_name text;
begin
  insert into public.profiles (id, email, full_name, avatar_url)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name',
             new.raw_user_meta_data->>'name',
             split_part(new.email, '@', 1)),
    new.raw_user_meta_data->>'avatar_url'
  )
  on conflict (id) do nothing;

  -- Every new user gets their own workspace on the free tier.
  -- If they were invited, the invitation flow moves them instead
  -- (see accept_invitation below) and this one sits unused.
  org_name := coalesce(new.raw_user_meta_data->>'company',
                       initcap(split_part(split_part(new.email,'@',2), '.', 1)));

  insert into public.accounts (name, plan, credits_included, billing_email)
  values (org_name, 'sandbox', 150, new.email)
  returning id into new_account_id;

  insert into public.account_members (account_id, user_id, role)
  values (new_account_id, new.id, 'owner')
  on conflict do nothing;

  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();


-- ── A3 · Roles ─────────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_name='account_members' and column_name='role') then
    alter table account_members add column role text default 'member';
  end if;
end $$;

alter table account_members
  drop constraint if exists account_members_role_check;
alter table account_members
  add constraint account_members_role_check
  check (role in ('owner','admin','member','viewer'));

-- Role helpers, used by policies below and by the application.
create or replace function my_role(acct uuid) returns text
language sql stable security definer set search_path = public as $$
  select role from account_members where account_id = acct and user_id = auth.uid()
$$;

create or replace function can_edit(acct uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(my_role(acct) in ('owner','admin','member'), false)
$$;

create or replace function can_admin(acct uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(my_role(acct) in ('owner','admin'), false)
$$;

-- Viewers can read but not change contracts.
drop policy if exists "own account rows" on contracts;
drop policy if exists "read contracts in my orgs" on contracts;
create policy "read contracts in my orgs" on contracts
  for select using (account_id in (select my_account_ids()));
drop policy if exists "write contracts if editor" on contracts;
create policy "write contracts if editor" on contracts
  for insert with check (can_edit(account_id));
drop policy if exists "update contracts if editor" on contracts;
create policy "update contracts if editor" on contracts
  for update using (can_edit(account_id)) with check (can_edit(account_id));
drop policy if exists "delete contracts if admin" on contracts;
create policy "delete contracts if admin" on contracts
  for delete using (can_admin(account_id));


-- ── A4 · Invitations ───────────────────────────────────────────
create table if not exists invitations (
  id           uuid primary key default gen_random_uuid(),
  account_id   uuid not null references accounts(id) on delete cascade,
  email        text not null,
  role         text not null default 'member'
               check (role in ('admin','member','viewer')),
  token        text not null unique default encode(gen_random_bytes(24), 'hex'),
  invited_by   uuid references auth.users(id) on delete set null,
  expires_at   timestamptz not null default now() + interval '7 days',
  accepted_at  timestamptz,
  created_at   timestamptz default now(),
  unique (account_id, email)
);
create index if not exists invitations_email on invitations (lower(email))
  where accepted_at is null;

alter table invitations enable row level security;
drop policy if exists "admins manage invitations" on invitations;
create policy "admins manage invitations" on invitations
  for all using (can_admin(account_id)) with check (can_admin(account_id));

-- Called by the app straight after sign-in when an invite token is present.
create or replace function accept_invitation(invite_token text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  inv invitations%rowtype;
  uid uuid := auth.uid();
  uemail text;
begin
  if uid is null then
    return jsonb_build_object('ok', false, 'error', 'not signed in');
  end if;
  select email into uemail from auth.users where id = uid;

  select * into inv from invitations
   where token = invite_token and accepted_at is null and expires_at > now();
  if not found then
    return jsonb_build_object('ok', false, 'error', 'invitation not found or expired');
  end if;

  -- The invitation is for a specific address. Accepting it with a
  -- different account would silently hand access to the wrong person.
  if lower(inv.email) <> lower(uemail) then
    return jsonb_build_object('ok', false, 'error',
      'this invitation was sent to ' || inv.email);
  end if;

  insert into account_members (account_id, user_id, role)
  values (inv.account_id, uid, inv.role)
  on conflict (account_id, user_id) do update set role = excluded.role;

  update invitations set accepted_at = now() where id = inv.id;
  return jsonb_build_object('ok', true, 'account_id', inv.account_id, 'role', inv.role);
end $$;


-- ── A5 · Terms acceptance, recorded against a real person ──────
create or replace function record_terms_acceptance(version text)
returns void
language sql security definer set search_path = public as $$
  update profiles
     set terms_accepted_at = now(), terms_version = version, updated_at = now()
   where id = auth.uid()
$$;


-- ═══════════════════════════════════════════════════════════════
--  PART B · ASYNC AI PROCESSING
-- ═══════════════════════════════════════════════════════════════
-- The browser no longer waits for the AI. It enqueues a job and
-- gets on with life; a background worker does the work and writes
-- the result back. Closing the tab no longer loses the analysis.

-- ── B1 · Extend the jobs table for the worker loop ─────────────
alter table jobs add column if not exists progress      int default 0;
alter table jobs add column if not exists progress_note text;
alter table jobs add column if not exists requested_by  uuid references auth.users(id) on delete set null;
alter table jobs add column if not exists idempotency_key text;

-- Idempotency: the same logical request must never create two jobs.
-- A network retry, a double-click, or a worker re-delivery all
-- collapse onto one row.
create unique index if not exists jobs_idempotency
  on jobs (account_id, idempotency_key)
  where idempotency_key is not null and status <> 'dead';

create index if not exists jobs_by_contract on jobs (contract_id, enqueued_at desc);


-- ── B2 · Enqueue (called by the app) ───────────────────────────
create or replace function enqueue_job(
  p_account_id  uuid,
  p_contract_id text,
  p_kind        text,
  p_payload     jsonb default '{}'::jsonb,
  p_idempotency text default null
) returns jobs
language plpgsql security definer set search_path = public
as $$
declare j jobs;
begin
  if not can_edit(p_account_id) then
    raise exception 'not permitted to queue work for this account';
  end if;

  -- If an identical request is already queued or running, return it
  -- rather than creating a duplicate. This is the idempotency the
  -- async pattern depends on.
  if p_idempotency is not null then
    select * into j from jobs
     where account_id = p_account_id
       and idempotency_key = p_idempotency
       and status in ('queued','running','succeeded')
     limit 1;
    if found then return j; end if;
  end if;

  insert into jobs (account_id, contract_id, kind, payload,
                    priority, requested_by, idempotency_key)
  values (p_account_id, p_contract_id, p_kind, p_payload,
          case (select plan from accounts where id = p_account_id)
            when 'enterprise' then 10
            when 'scale'      then 30
            when 'growth'     then 50
            else 100 end,
          auth.uid(), p_idempotency)
  returning * into j;
  return j;
end $$;


-- ── B3 · Progress reporting (called by the worker) ─────────────
create or replace function report_job_progress(
  p_job_id uuid, p_progress int, p_note text default null
) returns void
language sql security definer set search_path = public as $$
  update jobs
     set progress = greatest(0, least(100, p_progress)),
         progress_note = coalesce(p_note, progress_note),
         heartbeat_at = now()
   where id = p_job_id
$$;


-- ── B4 · Completion (called by the worker) ─────────────────────
create or replace function complete_job(
  p_job_id uuid, p_result jsonb
) returns void
language plpgsql security definer set search_path = public
as $$
declare j jobs;
begin
  select * into j from jobs where id = p_job_id;
  if not found then return; end if;

  update jobs
     set status = 'succeeded', progress = 100, result = p_result,
         finished_at = now(), locked_by = null, error = null
   where id = p_job_id;

  -- Write the analysis onto the contract itself so the UI picks it up.
  if j.kind in ('analysis','reanalysis') and j.contract_id is not null then
    update contracts
       set analysis = p_result, updated_at = now()
     where id = j.contract_id;

    insert into analyses (account_id, contract_id, analysis)
    values (j.account_id, j.contract_id, p_result);

    -- Credits are spent HERE, on the server, after the work
    -- succeeded — not in the browser, and never for a failed job.
    insert into credit_ledger (account_id, contract_id, kind, credits)
    values (j.account_id, j.contract_id, 'analysis', 10);
  end if;
end $$;


-- ── B5 · Failure with exponential backoff ──────────────────────
create or replace function fail_job(
  p_job_id uuid, p_error text, p_retryable boolean default true
) returns void
language plpgsql security definer set search_path = public
as $$
declare j jobs;
begin
  select * into j from jobs where id = p_job_id;
  if not found then return; end if;

  if p_retryable and j.attempts < j.max_attempts then
    -- Back off: 20s, 40s, 80s, 160s, 320s. Gives a struggling
    -- upstream room to recover instead of hammering it.
    update jobs
       set status = 'queued',
           run_after = now() + (interval '10 seconds' * power(2, least(j.attempts, 6))),
           error = p_error, locked_by = null, progress_note = 'Retrying…'
     where id = p_job_id;
  else
    -- Dead-letter. Kept, not deleted — a permanently failed job is
    -- evidence, and somebody needs to be able to look at it.
    update jobs
       set status = 'dead', error = p_error, finished_at = now(),
           locked_by = null, progress_note = 'Failed — needs investigation'
     where id = p_job_id;
  end if;
end $$;


-- ── B6 · What the app polls ────────────────────────────────────
create or replace view my_jobs as
  select j.id, j.contract_id, j.kind, j.status, j.progress, j.progress_note,
         j.attempts, j.max_attempts, j.error, j.enqueued_at, j.started_at,
         j.finished_at, c.ref, c.supplier,
         extract(epoch from (now() - j.enqueued_at))::int as age_seconds
    from jobs j
    left join contracts c on c.id = j.contract_id
   where j.account_id in (select my_account_ids())
     and j.enqueued_at > now() - interval '24 hours';

-- The dead-letter queue, for the admin screen.
create or replace view dead_letter_jobs as
  select j.*, c.ref, c.supplier
    from jobs j
    left join contracts c on c.id = j.contract_id
   where j.status = 'dead'
     and j.account_id in (select my_account_ids());

-- Requeue something from the dead-letter queue after a fix.
create or replace function retry_dead_job(p_job_id uuid) returns void
language plpgsql security definer set search_path = public
as $$
begin
  update jobs
     set status = 'queued', attempts = 0, run_after = now(),
         error = null, progress = 0, progress_note = 'Requeued manually'
   where id = p_job_id
     and status = 'dead'
     and can_admin(account_id);
end $$;


-- ── B7 · The worker tick ───────────────────────────────────────
-- pg_cron calls this on a schedule; it wakes the Edge Function only
-- when there is actually something to do, so an idle project costs
-- nothing.
create or replace function dispatch_jobs()
returns int
language plpgsql security definer set search_path = public
as $$
declare
  waiting int;
  fn_url  text;
  svc_key text;
begin
  select count(*) into waiting
    from jobs where status = 'queued' and run_after <= now();
  if waiting = 0 then return 0; end if;

  -- Read from Vault so no secret is written into this function body.
  select decrypted_secret into fn_url
    from vault.decrypted_secrets where name = 'job_worker_url';
  select decrypted_secret into svc_key
    from vault.decrypted_secrets where name = 'service_role_key';
  if fn_url is null or svc_key is null then
    raise notice 'dispatch_jobs: vault secrets not set; skipping';
    return 0;
  end if;

  perform net.http_post(
    url     := fn_url,
    headers := jsonb_build_object(
                 'Content-Type',  'application/json',
                 'Authorization', 'Bearer ' || svc_key),
    body    := jsonb_build_object('trigger', 'cron', 'waiting', waiting),
    timeout_milliseconds := 5000
  );
  return waiting;
end $$;

-- Reap jobs whose worker died mid-flight.
create or replace function maintenance_tick() returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform reap_stale_jobs('5 minutes'::interval);
end $$;


-- ═══════════════════════════════════════════════════════════════
--  SETUP THAT MUST BE DONE BY HAND (see the guide)
-- ═══════════════════════════════════════════════════════════════
-- 1. Dashboard → Integrations → enable Cron and (optionally) Queues.
--
-- 2. Store the two secrets the dispatcher needs:
--      select vault.create_secret(
--        'https://YOUR-PROJECT.supabase.co/functions/v1/job-worker',
--        'job_worker_url');
--      select vault.create_secret('YOUR_SERVICE_ROLE_KEY', 'service_role_key');
--
-- 3. Schedule the dispatcher and the reaper:
--      select cron.schedule('contractiq-dispatch', '10 seconds',
--                           $$select dispatch_jobs()$$);
--      select cron.schedule('contractiq-maintenance', '* * * * *',
--                           $$select maintenance_tick()$$);
--
-- 4. Deploy the job-worker Edge Function.
--
-- To check it is running:   select * from cron.job;
--                           select * from cron.job_run_details
--                             order by start_time desc limit 20;
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
--  DID IT WORK?
--  Run this on its own afterwards. You should see every row 'yes'.
-- ═══════════════════════════════════════════════════════════════
--
--  select
--    to_regclass('public.contracts')            is not null as contracts,
--    to_regclass('public.documents')            is not null as documents,
--    to_regclass('public.data_points')          is not null as confidence_scoring,
--    to_regclass('public.credit_ledger')        is not null as credits,
--    to_regclass('public.profiles')             is not null as user_accounts,
--    to_regclass('public.jobs')                 is not null as job_queue,
--    to_regclass('public.transcript_consents')  is not null as consent_trail,
--    to_regclass('public.obligation_tracking')  is not null as obligations;
--
--
--  THE THREE THINGS THIS SCRIPT CANNOT DO FOR YOU
--  ───────────────────────────────────────────────────────────────
--  1. YOUR API KEY  (required — nothing analyses without it)
--       Edge Functions → Secrets → add:
--         ANTHROPIC_API_KEY    = your sk-ant-… key
--         ALLOWED_ORIGIN       = https://YOURNAME.github.io
--         MAX_CALLS_PER_HOUR   = 60
--       ALLOWED_ORIGIN is the origin the APP is served from:
--       https:// only, no folder path, no trailing slash.
--       Get it wrong and every call returns 403.
--
--  2. THE TWO EDGE FUNCTIONS  (required)
--       Edge Functions → Deploy a new function → Via Editor
--         name: anthropic-proxy   → paste supabase/functions/anthropic-proxy/index.ts
--         name: job-worker        → paste supabase/functions/job-worker/index.ts
--       Names must match exactly — the app builds its URL from them.
--       Turn Verify JWT OFF for anthropic-proxy (the browser calls it).
--       Leave it ON for job-worker (the database calls it).
--
--  3. BACKGROUND PROCESSING  (optional — analysis works without it,
--     it just runs in the browser tab and stops if you close it)
--       Integrations → enable Cron, then run:
--
--         select vault.create_secret(
--           'https://YOUR-PROJECT.supabase.co/functions/v1/job-worker',
--           'job_worker_url');
--         select vault.create_secret('YOUR_SERVICE_ROLE_KEY', 'service_role_key');
--
--         select cron.schedule('contractiq-dispatch', '10 seconds',
--                              $$select dispatch_jobs()$$);
--         select cron.schedule('contractiq-maintenance', '* * * * *',
--                              $$select maintenance_tick()$$);
--
--       Check it is ticking over:
--         select * from cron.job_run_details order by start_time desc limit 20;
--
--  ALSO WORTH DOING BEFORE ANYONE ELSE SIGNS UP
--  ───────────────────────────────────────────────────────────────
--    Authentication → URL Configuration
--      Site URL and Redirect URLs must include the FULL app address
--      including the folder, e.g. https://you.github.io/repo/app/
--      Skip this and verification links bounce silently with no error.
--
--    Authentication → Providers → Email
--      'Confirm email' must be ON.
--
--    Authentication → Email Templates → Confirm signup
--      Replace {{ .ConfirmationURL }} with {{ .Token }} to send a
--      6-digit code instead of a link. Corporate mail scanners
--      pre-fetch links and consume them before the user clicks,
--      which is why codes are the better choice for business email.
-- ═══════════════════════════════════════════════════════════════
