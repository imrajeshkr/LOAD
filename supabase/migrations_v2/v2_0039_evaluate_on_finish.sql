-- =============================================================================
-- v2_0039 — evaluate the promotion signal when a session is finished
--
-- §13.6: "Evaluate on session finish. The data just changed, the check is
-- cheap, and it needs no cron." A trigger does this without any client change,
-- so it works for app builds already in the wild.
--
-- Evaluating is not notifying. propose_level_change() only writes a coach
-- message, which surfaces in the morning note or at the next session start —
-- nothing interrupts the session that triggered it.
--
-- The whole thing is wrapped so that it can NEVER prevent someone finishing a
-- workout. A bug in the detector costing a lifter their logged session would
-- be far worse than a missed promotion, so any failure is swallowed and the
-- proposal is simply reconsidered after the next session.
-- =============================================================================

create or replace function _on_session_completed() returns trigger
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
begin
  begin
    perform propose_level_change(new.user_id);
  exception when others then
    raise warning 'level check failed for % after session %: %',
      new.user_id, new.id, sqlerrm;
  end;
  return new;
end $$;

drop trigger if exists trg_session_completed_level on workout_sessions;
create trigger trg_session_completed_level
  after update of status on workout_sessions
  for each row
  when (new.status = 'completed' and old.status is distinct from 'completed')
  execute function _on_session_completed();
