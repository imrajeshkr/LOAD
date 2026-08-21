-- =============================================================================
-- v2_0013 — one session-debrief per session
--
-- finishSession() writes the coach's debrief note, but nothing tied a debrief
-- to the session it summarised, so a finish that fired twice (laggy taps, a
-- retried write) produced duplicate identical notes. Anchor each debrief to
-- its session and make that anchor unique, so a second write is a no-op.
-- =============================================================================

alter table coach_messages
  add column if not exists source_session_id uuid;

comment on column coach_messages.source_session_id is
  'The workout_sessions row a note was generated from (session debriefs). '
  'Null for everything else. Uniqueness below keeps one debrief per session.';

-- One debrief per (user, session). Partial + null-guarded so it only ever
-- constrains session debriefs and never the many notes with no source session.
drop index if exists coach_messages_one_debrief_per_session;
create unique index coach_messages_one_debrief_per_session
  on coach_messages (user_id, source_session_id)
  where category = 'session_debrief' and source_session_id is not null;
