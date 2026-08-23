-- After v2_0033 the injury filter must be able to see the whole catalog:
-- an exercise with no joint rows is invisible to it, not safe.
savepoint jc;
DO $$
declare v_blind int; v_sev int; v_auth int;
begin
  select count(*) into v_blind from exercises e
   where e.owner_id is null
     and not exists (select 1 from exercise_joints x where x.exercise_id = e.id);
  if v_blind > 0 then
    raise exception '% catalog exercise(s) still have no joint data', v_blind;
  end if;

  -- The hand-authored set must be untouched: deadlift stays severe/lumbar.
  select count(*) into v_auth from exercise_joints ej
    join exercises e on e.id=ej.exercise_id join joints j on j.id=ej.joint_id
   where e.slug='deadlift' and j.slug='lumbar' and ej.stress_level='severe';
  if v_auth <> 1 then raise exception 'hand-authored deadlift joints were altered'; end if;

  -- The generator once left every derived exercise with exactly ONE joint
  -- (each guarded insert saw the previous one). Average joints per exercise
  -- catches that shape of failure; a plain "no blind rows" check does not.
  if (select count(*)::numeric / count(distinct exercise_id)
        from exercise_joints) < 1.6 then
    raise exception 'derived joints look truncated: %.2f joints per exercise',
      (select count(*)::numeric / count(distinct exercise_id) from exercise_joints);
  end if;

  select count(distinct e.id) into v_sev from exercises e
    join exercise_joints ej on ej.exercise_id=e.id
   where e.owner_id is null and ej.stress_level='severe';
  raise notice 'catalog fully vetted: 0 blind, % exercises carry a severe flag', v_sev;
  raise notice 'V2_0033 JOINT COVERAGE OK';
end $$;
rollback to savepoint jc;
