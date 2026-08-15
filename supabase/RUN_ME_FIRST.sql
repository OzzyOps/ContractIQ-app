-- ContractIQ — reset before re-running the schema
-- ===============================================================
-- YOU PROBABLY DO NOT NEED THIS FILE.
--
-- The Supabase SQL editor runs your whole script inside a single
-- transaction. When the previous schema.sql hit the foreign-key error,
-- everything it had already created was rolled back — so your project is
-- almost certainly empty, and you can go straight to schema_FIXED.sql.
--
-- That is exactly what "relation documents does not exist" was telling
-- you: the earlier version of this file tried to drop a trigger on a
-- table that had never survived.
--
-- (That earlier version was my mistake, and this is the fix.
--  DROP TRIGGER IF EXISTS ... ON <table> only guards the TRIGGER — the
--  TABLE must still exist, or Postgres raises 42P01. Everything below is
--  now guarded, so it runs cleanly on an empty project, a partly-built
--  one, or a fully-built one.)
--
-- Run this ONLY if schema_FIXED.sql complains that something already
-- exists with the wrong shape. Otherwise skip straight to that file.
--
-- It preserves accounts, contracts, documents and analyses, so no
-- contract data is lost.
-- ===============================================================

do $$
declare
  t text;
  v text;
  f text;
begin
  -- ── Views first: they depend on the tables below ──
  foreach v in array array[
    'obligations_due', 'accuracy_by_tier', 'queue_depth', 'ops_health'
  ] loop
    execute format('drop view if exists public.%I cascade', v);
  end loop;

  -- ── Triggers: only attempted where the table actually exists ──
  if to_regclass('public.documents') is not null then
    drop trigger if exists documents_search_tsv      on public.documents;
    drop trigger if exists documents_require_consent on public.documents;
  end if;

  -- ── Functions: dropped by full signature ──
  foreach f in array array[
    'public.claim_job(text, text[])',
    'public.reap_stale_jobs(interval)',
    'public.search_documents(uuid, text, int)',
    'public.documents_search_refresh()',
    'public.assert_transcript_consent()',
    'public.credits_remaining(uuid)',
    'public.policy_packs_at(timestamptz, text)'
  ] loop
    execute format('drop function if exists %s cascade', f);
  end loop;

  -- ── Tables that carried the wrong column types ──
  -- Only these five were affected. accounts, contracts, documents,
  -- analyses, credit_ledger, policy_packs and transcript_consents are
  -- deliberately left alone so no contract data is lost.
  foreach t in array array[
    'analysis_policy_snapshot',
    'obligation_tracking',
    'verification_audit',
    'data_points',
    'jobs'
  ] loop
    execute format('drop table if exists public.%I cascade', t);
  end loop;

  -- ── Column added to documents by the search layer ──
  if to_regclass('public.documents') is not null then
    alter table public.documents drop column if exists search_tsv;
  end if;

  raise notice 'ContractIQ reset complete. Now run schema_FIXED.sql.';
end $$;
