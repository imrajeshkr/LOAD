-- =============================================================================
-- LOAD — tell historical sessions which program day they were
--
-- Comparing a session against "the last time you trained this day" needs
-- workout_sessions.program_day_id, which nothing populated before
-- open_session_for_today existed. Every seeded and chat-logged session has it
-- null, so the comparison silently returned nothing rather than being wrong —
-- which is the failure mode that hides longest.
--
-- Matched on title, which is how those rows were named ('Push Day' etc.).
-- Sessions with no matching day stay null: ad-hoc training genuinely has no
-- prescription to compare against, and inventing one would be worse.
-- =============================================================================

update workout_sessions ws
   set program_day_id = d.id
  from program_days d
  join programs p on p.id = d.program_id
 where ws.program_day_id is null
   and p.user_id = ws.user_id
   and lower(d.label) = lower(ws.title);
