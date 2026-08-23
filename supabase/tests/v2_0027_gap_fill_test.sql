savepoint gap_fill;
DO $$
declare v_bw int; v_bwlegs int; v_hg_rho int; v_hg_rear int; v_hg_calf int; v_orphan int;
begin
  -- no Core row may lack joint data (that is what makes injury routing work)
  select count(*) into v_orphan from exercises e
   where e.owner_id is null and e.is_core
     and not exists (select 1 from exercise_joints ej where ej.exercise_id=e.id);

  select count(*) into v_bw from exercises e
   where e.owner_id is null and e.is_core
     and e.load_type in ('weight_reps','bodyweight_reps')
     and not exists (select 1 from exercise_equipment ee where ee.exercise_id=e.id and ee.is_required
                      and not exists (select 1 from environment_equipment ev
                                       where ev.equipment_id=ee.equipment_id and ev.environment='bodyweight_only'));

  select count(*) into v_bwlegs from exercises e
   where e.owner_id is null and e.is_core and e.pattern='legs'
     and not exists (select 1 from exercise_equipment ee where ee.exercise_id=e.id and ee.is_required
                      and not exists (select 1 from environment_equipment ev
                                       where ev.equipment_id=ee.equipment_id and ev.environment='bodyweight_only'));

  for v_hg_rho, v_hg_rear, v_hg_calf in
    select
      count(*) filter (where m.name='Rhomboids'),
      count(*) filter (where m.name='Rear Delt'),
      count(*) filter (where m.name='Calves')
    from exercises e
    join exercise_muscles em on em.exercise_id=e.id and em.role='primary'
    join muscles m on m.id=em.muscle_id
   where e.owner_id is null and e.is_core
     and not exists (select 1 from exercise_equipment ee where ee.exercise_id=e.id and ee.is_required
                      and not exists (select 1 from environment_equipment ev
                                       where ev.equipment_id=ee.equipment_id and ev.environment='home_gym'))
  loop end loop;

  raise notice 'core w/o joint data=%  bodyweight-core=%  bodyweight-LEGS=%', v_orphan, v_bw, v_bwlegs;
  raise notice 'home_gym core: rhomboids=% rear-delt=% calves=%', v_hg_rho, v_hg_rear, v_hg_calf;

  if v_orphan  > 1 then raise exception 'CORE ROWS WITHOUT JOINT DATA: %', v_orphan; end if;
  if v_bwlegs  < 3 then raise exception 'BODYWEIGHT STILL HAS NO LEG WORK: %', v_bwlegs; end if;
  if v_hg_rho  < 1 then raise exception 'HOME GYM STILL HAS NO RHOMBOID WORK'; end if;
  if v_hg_rear < 1 then raise exception 'HOME GYM STILL HAS NO REAR DELT WORK'; end if;
  if v_hg_calf < 1 then raise exception 'HOME GYM STILL HAS NO CALF WORK'; end if;
  raise notice 'GAPS CLOSED';
end $$;
rollback to savepoint gap_fill;
