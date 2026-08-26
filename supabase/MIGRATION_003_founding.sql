-- ═══════════════════════════════════════════════════════════════
--  ContractIQ — Migration 003 · Founding member seats
-- ═══════════════════════════════════════════════════════════════
--  Ten places. 200 credits a month for six months, then the
--  account converts to Growth / Professional.
--
--  Run this AFTER contractiq_supabase_setup.sql, in the SQL Editor.
--  Safe to re-run: nothing here destroys data.
-- ═══════════════════════════════════════════════════════════════


-- ── 1 · How many places exist ─────────────────────────────────
-- Kept as a settable row rather than a hard-coded 10, so you can
-- open two more places without a deployment.
create table if not exists founding_offer (
  id              int primary key default 1 check (id = 1),
  total_places    int  not null default 10,
  offer_open      boolean not null default true,
  free_months     int  not null default 6,
  monthly_credits int  not null default 200,
  converts_to     text not null default 'growth',
  updated_at      timestamptz default now()
);
insert into founding_offer (id) values (1) on conflict (id) do nothing;


-- ── 2 · The seats themselves ──────────────────────────────────
create table if not exists founding_members (
  account_id      uuid primary key references accounts(id) on delete cascade,
  seat_no         int  not null,
  claimed_at      timestamptz not null default now(),
  -- The two dates that answer "when did they start" and "when do
  -- they finish", which is the whole point of this table.
  free_from       timestamptz not null default now(),
  free_until      timestamptz not null,
  monthly_credits int  not null default 200,
  status          text not null default 'active'
                  check (status in ('active','converted','cancelled')),
  converted_at    timestamptz,
  converted_to    text,
  cancelled_at    timestamptz,
  -- A seat number can only be held once. This is what makes two
  -- simultaneous sign-ups for the last place safe: one wins the
  -- unique index, the other retries and finds the offer closed.
  constraint founding_seat_unique unique (seat_no)
);
create index if not exists founding_due on founding_members (free_until)
  where status = 'active';

alter table founding_members enable row level security;
drop policy if exists "read own founding seat" on founding_members;
create policy "read own founding seat" on founding_members
  for select using (account_id in (select my_account_ids()));


-- ── 3 · Places remaining — readable by anyone ─────────────────
-- The website calls this to decide whether to show the button.
-- It returns a count and nothing else: no emails, no names, no
-- account ids. Safe to expose to an anonymous visitor.
create or replace function founding_places_remaining()
returns int
language sql
stable
security definer
set search_path = public
as $$
  select greatest(0,
    (select case when offer_open then total_places else 0 end from founding_offer where id = 1)
    - (select count(*)::int from founding_members where status <> 'cancelled')
  )
$$;

grant execute on function founding_places_remaining() to anon, authenticated;


-- ── 4 · Claim a seat ──────────────────────────────────────────
-- Called automatically when a new account is created. Returns the
-- seat number, or null when the offer is closed or full.
create or replace function claim_founding_seat(p_account_id uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg   founding_offer%rowtype;
  taken int;
  seat  int;
begin
  -- Lock the config row for the duration of this transaction. Two
  -- sign-ups landing at the same moment queue here rather than both
  -- reading "1 place left" and both claiming it.
  select * into cfg from founding_offer where id = 1 for update;
  if not found or not cfg.offer_open then
    return null;
  end if;

  -- Already has a seat? Return it rather than issuing a second.
  select seat_no into seat from founding_members where account_id = p_account_id;
  if found then return seat; end if;

  select count(*)::int into taken from founding_members where status <> 'cancelled';
  if taken >= cfg.total_places then
    return null;
  end if;

  seat := taken + 1;

  insert into founding_members
    (account_id, seat_no, free_from, free_until, monthly_credits)
  values
    (p_account_id, seat, now(), now() + (cfg.free_months || ' months')::interval,
     cfg.monthly_credits);

  -- Give them the founding allowance straight away.
  update accounts
     set plan              = 'growth',   -- feature set they get during the offer
         credits_included  = cfg.monthly_credits,
         credits_used      = 0,
         period_started_at = now(),
         signup_source     = coalesce(signup_source, 'founding')
   where id = p_account_id;

  -- Close the offer automatically on the last seat.
  if seat >= cfg.total_places then
    update founding_offer set offer_open = false, updated_at = now() where id = 1;
  end if;

  return seat;
end $$;


-- ── 5 · Hook it into sign-up ──────────────────────────────────
-- handle_new_user() already creates the account. This wraps it so a
-- founding seat is claimed in the same breath, without touching the
-- original function's logic.
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

  org_name := coalesce(new.raw_user_meta_data->>'company',
                       initcap(split_part(split_part(new.email,'@',2), '.', 1)));

  insert into public.accounts (name, plan, credits_included, billing_email)
  values (org_name, 'sandbox', 150, new.email)
  returning id into new_account_id;

  insert into public.account_members (account_id, user_id, role)
  values (new_account_id, new.id, 'owner')
  on conflict do nothing;

  -- Founding seat, if any remain. Returns null and changes nothing
  -- once the ten are gone, so ordinary sign-up carries on working.
  perform claim_founding_seat(new_account_id);

  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();


-- ── 6 · Monthly credit top-up during the free period ──────────
-- 200 credits a MONTH, not 200 in total. This rolls the allowance
-- on each monthly anniversary while the seat is still active.
create or replace function refresh_founding_credits()
returns int
language plpgsql
security definer set search_path = public
as $$
declare n int := 0;
begin
  update accounts a
     set credits_included  = f.monthly_credits,
         credits_used      = 0,
         period_started_at = now()
    from founding_members f
   where f.account_id = a.id
     and f.status = 'active'
     and f.free_until > now()
     and a.period_started_at < now() - interval '1 month';
  get diagnostics n = row_count;
  return n;
end $$;


-- ── 7 · Convert when the six months are up ────────────────────
-- Moves the account onto the paid plan and records exactly when.
-- Nothing is deleted: the founding row stays as the audit trail of
-- who joined, when, and when they converted.
create or replace function convert_expired_founding()
returns int
language plpgsql
security definer set search_path = public
as $$
declare
  cfg founding_offer%rowtype;
  n int := 0;
begin
  select * into cfg from founding_offer where id = 1;

  update founding_members f
     set status       = 'converted',
         converted_at = now(),
         converted_to = cfg.converts_to
   where f.status = 'active'
     and f.free_until <= now();
  get diagnostics n = row_count;

  update accounts a
     set plan              = cfg.converts_to,
         credits_included  = case cfg.converts_to
                               when 'growth'     then 500
                               when 'scale'      then 1800
                               when 'enterprise' then 5000
                               else 150 end,
         credits_used      = 0,
         period_started_at = now()
    from founding_members f
   where f.account_id = a.id
     and f.status = 'converted'
     and f.converted_at >= now() - interval '5 minutes';

  return n;
end $$;


-- ── 8 · What the account holder sees ──────────────────────────
create or replace view my_founding_status as
  select f.seat_no,
         f.claimed_at,
         f.free_from,
         f.free_until,
         f.monthly_credits,
         f.status,
         f.converted_at,
         f.converted_to,
         greatest(0, extract(day from (f.free_until - now()))::int) as days_remaining,
         -- Cancellation is permitted from the six-month anniversary,
         -- which is the same date the free period ends.
         (now() >= f.free_until) as can_cancel_now
    from founding_members f
   where f.account_id in (select my_account_ids());


-- ── 9 · Your own view of the ten ──────────────────────────────
-- Run this in the SQL Editor any time to see where the offer stands.
create or replace view founding_roster as
  select f.seat_no,
         a.name        as organisation,
         a.billing_email,
         f.claimed_at,
         f.free_until,
         f.status,
         f.converted_at,
         f.converted_to,
         greatest(0, extract(day from (f.free_until - now()))::int) as days_remaining
    from founding_members f
    join accounts a on a.id = f.account_id
   order by f.seat_no;


-- ═══════════════════════════════════════════════════════════════
--  SCHEDULE THE TWO MAINTENANCE JOBS
--  (Integrations → enable Cron first, if you have not already)
-- ═══════════════════════════════════════════════════════════════
--
--   select cron.schedule('founding-credits', '0 3 * * *',
--                        $$select refresh_founding_credits()$$);
--   select cron.schedule('founding-convert', '0 4 * * *',
--                        $$select convert_expired_founding()$$);
--
--  Both are safe to run daily; they only touch rows that are due.
--
--  USEFUL QUERIES
--   select founding_places_remaining();     -- how many places left
--   select * from founding_roster;          -- who has them
--
--  TO CLOSE THE OFFER EARLY
--   update founding_offer set offer_open = false where id = 1;
--
--  TO OPEN MORE PLACES
--   update founding_offer set total_places = 15, offer_open = true where id = 1;
-- ═══════════════════════════════════════════════════════════════
