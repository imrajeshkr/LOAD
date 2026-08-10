-- =============================================================================
-- LOAD — a target set and changed on the same day
--
-- nutrition_targets carries `check (valid_to is null or valid_to > valid_from)`,
-- which is the right rule for a dated slowly-changing row: a version should
-- span at least a day. But sync_protein_target closed the current row with
-- `valid_to = current_date`, so any target created today and recalculated
-- today violated it — which is exactly what happens the first time a lifter
-- logs a weigh-in after onboarding.
--
-- Fixed by amending in place when the row started today, rather than
-- relaxing the constraint and littering the table with zero-length versions.
-- =============================================================================

create or replace function sync_protein_target(p_user_id uuid)
returns int
language plpgsql security invoker as $$
declare
  v_g    int;
  v_cur  int;
  v_from date;
begin
  select grams into v_g from protein_target_for(p_user_id);
  if v_g is null then return null; end if;

  select protein_g, valid_from into v_cur, v_from
    from nutrition_targets
   where user_id = p_user_id and valid_to is null;

  if v_cur is null then
    insert into nutrition_targets (user_id, protein_g) values (p_user_id, v_g);

  elsif v_cur <> v_g then
    if v_from >= current_date then
      -- Same-day correction: this version was never in force for a whole day,
      -- so there is no history worth preserving. Amend it.
      update nutrition_targets set protein_g = v_g
       where user_id = p_user_id and valid_to is null;
    else
      update nutrition_targets set valid_to = current_date
       where user_id = p_user_id and valid_to is null;
      insert into nutrition_targets (user_id, protein_g) values (p_user_id, v_g);
    end if;
  end if;

  return v_g;
end $$;

grant execute on function sync_protein_target(uuid) to authenticated;
