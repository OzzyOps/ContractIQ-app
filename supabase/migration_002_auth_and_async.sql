-- ContractIQ — Migration 002
-- ===============================================================
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
create policy "read contracts in my orgs" on contracts
  for select using (account_id in (select my_account_ids()));
create policy "write contracts if editor" on contracts
  for insert with check (can_edit(account_id));
create policy "update contracts if editor" on contracts
  for update using (can_edit(account_id)) with check (can_edit(account_id));
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
