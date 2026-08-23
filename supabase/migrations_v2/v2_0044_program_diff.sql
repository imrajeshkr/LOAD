-- =============================================================================
-- v2_0044 — say what actually changed when a plan is rebuilt (§8.3 item 4)
--
-- "The rebuild confirm says only 'new sessions and exercises.' It should say
--  what actually happens: kept Bench, Squat, Row · added Incline press, Leg
--  curl · dropped Cable fly. This is the single cheapest trust win in the
--  whole design."
--
-- It could not be written before v2_0042. Until continuity existed, a rebuild
-- reshuffled everything and "kept" was close to meaningless — the diff would
-- have been an alarming wall of dropped/added rather than the reassurance it
-- is meant to be.
--
-- The confirmation sheet cannot show this: it runs BEFORE the rebuild, and the
-- new program does not exist yet. Producing one would mean speculatively
-- running the whole generator. So the diff is shown after the fact instead,
-- which is also when a lifter actually wants it — the question they are asking
-- is "what did you just do to my plan", not "what might you do".
-- =============================================================================

create or replace function program_diff(p_user_id uuid)
returns table (kept text[], added text[], dropped text[])
language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  with cur as (
    select id from programs
     where user_id = p_user_id and status = 'active'
     order by created_at desc limit 1
  ),
  prev as (
    -- The program the active one replaced. Ordered by created_at because a
    -- rebuild on the same day leaves several rows sharing starts_on.
    select id from programs
     where user_id = p_user_id and status = 'archived'
     order by created_at desc limit 1
  ),
  new_ex as (
    select distinct e.name
      from program_day_exercises pde
      join program_days pd on pd.id = pde.program_day_id
      join exercises e on e.id = pde.exercise_id
     where pd.program_id = (select id from cur)
  ),
  old_ex as (
    select distinct e.name
      from program_day_exercises pde
      join program_days pd on pd.id = pde.program_day_id
      join exercises e on e.id = pde.exercise_id
     where pd.program_id = (select id from prev)
  )
  select
    coalesce((select array_agg(name order by name) from new_ex
               where name in (select name from old_ex)), '{}'),
    coalesce((select array_agg(name order by name) from new_ex
               where name not in (select name from old_ex)), '{}'),
    coalesce((select array_agg(name order by name) from old_ex
               where name not in (select name from new_ex)), '{}');
$$;

grant execute on function program_diff(uuid) to authenticated;


-- The block-rollover note promised "same main lifts, with a couple of new
-- accessories" without ever naming them. Now it names them.
create or replace function _v2_0044_patch() returns void language plpgsql as $patch$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where proname = 'roll_block_if_due';
  if position('with a couple of ' in v_src) = 0 then
    raise exception 'v2_0044: roll_block_if_due copy changed — refusing to patch blind';
  end if;

  execute 'create or replace function public.roll_block_if_due(p_user_id uuid) '
       || 'returns text language plpgsql security definer '
       || 'set search_path to ''public'', ''pg_temp'' as $body$'
       || replace(v_src,
            '''new accessories. This first week is deliberately lighter so you ''',
            '''new accessories'' || coalesce((select '' — this time '' || '
            -- At most two names: the sentence promises "a couple", and a
            -- rollover that genuinely changed seven lifts should not read as
            -- though it changed two. Slicing keeps copy and content honest.
            || 'array_to_string(d.added[1:2], '' and '') from program_diff(p_user_id) d '
            || 'where cardinality(d.added) > 0), '''') || ''. This first week is '
            || 'deliberately lighter so you ''')
       || '$body$';
end $patch$;
select _v2_0044_patch();
drop function _v2_0044_patch();
