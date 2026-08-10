-- =============================================================================
-- LOAD — don't leave orphaned calendar slots behind
--
-- bootstrap_user_program archives the previous active program but left its
-- scheduled_workouts rows in place, so every re-generation added six more
-- pending slots pointing at a program nobody trains any more. The client
-- filters on the active program_id so nothing rendered wrong, but the rows
-- accumulate and any future "what's coming up" query across programs would
-- read them as real.
--
-- Pending slots for a superseded program are cancelled, not deleted:
-- completed ones are history and must survive.
-- =============================================================================

create or replace function archive_program_schedule() returns trigger
language plpgsql as $$
begin
  if new.status = 'archived' and old.status <> 'archived' then
    update scheduled_workouts
       set status = 'skipped'
     where program_id = new.id
       and status = 'pending';
  end if;
  return new;
end $$;

drop trigger if exists programs_archive_schedule on programs;
create trigger programs_archive_schedule
  after update of status on programs
  for each row execute function archive_program_schedule();

-- Clear the backlog this already created.
update scheduled_workouts sw
   set status = 'skipped'
  from programs p
 where p.id = sw.program_id
   and p.status = 'archived'
   and sw.status = 'pending';
