-- =============================================================================
-- v2_0053 — let a lifter attach details to an exercise they own
--
-- exercises already reads `owner_id is null or owner_id = auth.uid()` and
-- writes own rows. But exercise_muscles and exercise_equipment carry ONLY a
-- read policy, so creating a custom exercise would succeed and then fail to
-- describe it — leaving a row the picker cannot filter by muscle and the
-- equipment filter cannot place.
--
-- Scoped to exercises the caller OWNS, not merely to authenticated. Anything
-- looser would let one lifter attach a muscle to a CATALOGUE exercise and
-- change what every other lifter is prescribed.
-- =============================================================================

drop policy if exists exercise_muscles_write_own on exercise_muscles;
create policy exercise_muscles_write_own on exercise_muscles
  for all
  using (exists (select 1 from exercises e
                  where e.id = exercise_muscles.exercise_id
                    and e.owner_id = (select auth.uid())))
  with check (exists (select 1 from exercises e
                       where e.id = exercise_muscles.exercise_id
                         and e.owner_id = (select auth.uid())));

drop policy if exists exercise_equipment_write_own on exercise_equipment;
create policy exercise_equipment_write_own on exercise_equipment
  for all
  using (exists (select 1 from exercises e
                  where e.id = exercise_equipment.exercise_id
                    and e.owner_id = (select auth.uid())))
  with check (exists (select 1 from exercises e
                       where e.id = exercise_equipment.exercise_id
                         and e.owner_id = (select auth.uid())));
