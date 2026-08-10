-- LOAD — store everything in metric, track the user's display preference.
--
-- Weights are canonically kilograms in the database so that history stays
-- comparable if the user later switches between metric and imperial. The
-- app converts only at the display/input boundary.

-- ── profiles: units preference + metric weight columns ──────────────────
alter table public.profiles
  add column if not exists units text not null default 'metric'
    check (units in ('metric', 'imperial')),
  add column if not exists current_weight_kg numeric,
  add column if not exists target_weight_kg numeric;

-- Migrate any existing lb values written by the first build.
update public.profiles
   set current_weight_kg = round((current_weight / 2.2046226218)::numeric, 2)
 where current_weight_kg is null
   and current_weight is not null;

update public.profiles
   set target_weight_kg = round((target_weight / 2.2046226218)::numeric, 2)
 where target_weight_kg is null
   and target_weight is not null;

alter table public.profiles drop column if exists current_weight;
alter table public.profiles drop column if exists target_weight;

-- ── weight_logs ─────────────────────────────────────────────────────────
alter table public.weight_logs
  add column if not exists weight_kg numeric;

update public.weight_logs
   set weight_kg = round((weight / 2.2046226218)::numeric, 2)
 where weight_kg is null
   and weight is not null;

alter table public.weight_logs alter column weight_kg set not null;
alter table public.weight_logs drop column if exists weight;

-- ── session_sets ────────────────────────────────────────────────────────
alter table public.session_sets
  add column if not exists weight_kg numeric;

update public.session_sets
   set weight_kg = round((weight / 2.2046226218)::numeric, 2)
 where weight_kg is null
   and weight is not null;

alter table public.session_sets alter column weight_kg set not null;
alter table public.session_sets drop column if exists weight;
