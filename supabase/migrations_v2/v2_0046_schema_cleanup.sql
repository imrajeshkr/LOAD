-- =============================================================================
-- v2_0046 — drop schema that is provably dead
--
-- "Provably" is doing real work in that sentence. Three things were on the
-- candidate list and were NOT dropped, because checking beat guessing:
--
--   coach_memories      unreferenced in lib/, but read by the coach Edge
--   v_nutrition_daily   Function (supabase/functions/coach/context.ts). A
--                       Dart-only grep would have removed working infrastructure.
--
--   all-NULL columns    notes, rpe, superset_group, video_url, session_rpe,
--                       bodyweight_kg and friends are empty because the feature
--                       is unbuilt, not because the column is dead. Dropping
--                       them removes capacity, it does not remove redundancy.
--                       exercises.owner_id is NULL in all 530 rows and appears
--                       in literally every catalog query (`owner_id is null`);
--                       programs.ends_on and volume_ramp_until are NULL only
--                       because v2_0045's migration has not run yet.
--
-- What IS dropped below is either orphaned or superseded.
-- =============================================================================

-- ── The v1 backups ──────────────────────────────────────────────────────────
-- 455 rows across six tables, and NOT ONE of them belongs to an account that
-- still exists. They are the residue of the v1 -> v2 migration, left behind
-- when those users later deleted their accounts: delete-account cascades
-- through profiles(id), and these tables were never wired to it.
--
-- So this is not only cleanup. Someone asked for their account to be deleted
-- and their training history and chat messages are still sitting here.
drop table if exists v1_backup_session_sets;
drop table if exists v1_backup_sessions;
drop table if exists v1_backup_protein_logs;
drop table if exists v1_backup_weight_logs;
drop table if exists v1_backup_chat_messages;
drop table if exists v1_backup_profiles;

-- ── Superseded by how blocks were actually built ─────────────────────────────
-- program_blocks was scaffolding for §8.4. The implementation went a different
-- way — v2_0042 puts the block on programs.ends_on, which needs no second
-- table and no join. Never written to: 0 rows.
alter table program_days drop column if exists block_id;
drop table if exists program_blocks;

-- ── Views nothing reads ─────────────────────────────────────────────────────
-- Checked against lib/, every function body in the database, the Edge
-- Functions, and pg_depend. Safe to drop precisely because a view is pure
-- derivation — no data is lost and recreating one is a migration away.
drop view if exists v_adherence;
drop view if exists v_flagged_exercises;

do $$
declare v_left int;
begin
  select count(*) into v_left from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relname like 'v1_backup_%';
  if v_left > 0 then raise exception 'v2_0046: % v1 backup table(s) survived', v_left; end if;
end $$;
