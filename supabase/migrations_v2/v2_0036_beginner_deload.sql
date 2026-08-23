-- =============================================================================
-- v2_0036 — the reactive deload also applies to beginners
--
-- Resolves a contradiction between two spec sections that only shows up once
-- both are implemented.
--
--   §7   gives the deload branch to ADVANCED only.
--   §8.1 requires, for beginner → intermediate promotion, that "the stall
--        survived one deload — proving it's adaptation, not fatigue."
--
-- Under §7 as written, a beginner never receives a deload, so that condition
-- can never be satisfied and no one is ever promoted. The detector in v2_0037
-- would be dead code.
--
-- §8.1 is the section to follow, because it matches how novice programming
-- actually works: the classic linear-progression protocol is stall three
-- times, reset ~10%, build back, and if you stall again you have stopped being
-- a novice. That reset IS the deload, and it is the evidence the promotion
-- test depends on.
--
-- Intermediate still holds — §7 is explicit that it should ("Hold, then
-- Progress flags it"), and double progression has more room to keep working
-- before a reset is warranted.
-- =============================================================================

create or replace function _v2_0036_patch() returns void language plpgsql as $patch$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where proname = 'train_screen';

  if position('v_exp = ''advanced'' and coalesce(st.stalled, false)' in v_src) = 0 then
    raise exception 'v2_0036: train_screen does not contain the expected '
                    'advanced-only deload guard — refusing to patch blind';
  end if;

  execute 'create or replace function public.train_screen(p_user_id uuid) '
       || 'returns jsonb language plpgsql stable as $body$'
       || replace(v_src,
            'v_exp = ''advanced'' and coalesce(st.stalled, false)',
            'v_exp in (''beginner'', ''advanced'') and coalesce(st.stalled, false)')
       || '$body$';
end $patch$;

select _v2_0036_patch();
drop function _v2_0036_patch();

-- `is_deload` in the payload follows the same rule, since it is written from
-- the same expression.
do $$
begin
  if (select prosrc from pg_proc where proname='train_screen')
       like '%v_exp = ''advanced'' and coalesce(st.stalled, false)%' then
    raise exception 'v2_0036: advanced-only guard still present after patch';
  end if;
end $$;
