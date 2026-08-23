-- =============================================================================
-- v2_0040 — ease into a volume increase instead of doubling it overnight
--
-- §8.3: "Going 3 -> 6 days roughly doubles weekly sets, which is how people get
-- hurt." The same applies to a level change, which is what makes this urgent
-- now rather than later: accepting a promotion moves the weekly budget from 9
-- sets per muscle to 14 (+55%), well past §8.3's 30% threshold, and until this
-- migration that jump landed in full on the first session.
--
-- §8.3 hoped to derive the ramp from days since the program started with no
-- schema change. That is not derivable: train_screen has no way to know what
-- the PREVIOUS program's weekly volume was, since the rebuild archived it and
-- the two differ by level, split and day count all at once. One nullable date
-- on `programs` states the intent directly, and expires on its own.
-- =============================================================================

alter table programs
  add column if not exists volume_ramp_until date;

comment on column programs.volume_ramp_until is
  'While this date is in the future, train_screen scales sets_target down so a '
  'volume increase arrives over two weeks rather than in one session. Set when '
  'a change raises weekly volume; needs no cleanup, it simply passes.';

-- resolve_level_change is the one thing that raises volume today, so it sets
-- the ramp. Shape changes (§8.3) should set it too when they land.
create or replace function _v2_0040_patch() returns void language plpgsql as $patch$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where proname = 'resolve_level_change';
  if position('perform bootstrap_user_program(v_uid);' in v_src) = 0 then
    raise exception 'v2_0040: resolve_level_change shape changed — refusing to patch blind';
  end if;
  execute 'create or replace function public.resolve_level_change('
       || 'p_proposal_id uuid, p_accept boolean) returns void '
       || 'language plpgsql security definer set search_path to ''public'', ''pg_temp'' '
       || 'as $body$'
       || replace(v_src, 'perform bootstrap_user_program(v_uid);',
            'perform bootstrap_user_program(v_uid);' || chr(10) ||
            '  -- Promotion raises the weekly budget by roughly half again;' || chr(10) ||
            '  -- give the lifter a week to meet it.' || chr(10) ||
            '  update programs set volume_ramp_until = current_date + 7' || chr(10) ||
            '   where user_id = v_uid and status = ''active'';')
       || '$body$';
end $patch$;
select _v2_0040_patch();
drop function _v2_0040_patch();

-- train_screen honours it.
create or replace function _v2_0040_patch2() returns void language plpgsql as $patch$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where proname = 'train_screen';
  if position('''sets_target'',  p.sets_target,' in v_src) = 0 then
    raise exception 'v2_0040: train_screen sets_target shape changed — refusing to patch blind';
  end if;
  execute 'create or replace function public.train_screen(p_user_id uuid) '
       || 'returns jsonb language plpgsql stable as $body$'
       || replace(v_src, '''sets_target'',  p.sets_target,',
            '''sets_target'',  case when exists (select 1 from programs pr '
            || 'where pr.user_id = p_user_id and pr.status = ''active'' '
            || 'and pr.volume_ramp_until > v_today) '
            || 'then greatest(2, ceil(p.sets_target * 0.7)::int) '
            || 'else p.sets_target end,')
       || '$body$';
end $patch$;
select _v2_0040_patch2();
drop function _v2_0040_patch2();
