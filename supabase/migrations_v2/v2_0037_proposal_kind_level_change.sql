-- =============================================================================
-- v2_0037 — proposal_kind gains 'level_change'
--
-- Alone in its own migration on purpose: Postgres refuses to let a newly added
-- enum value be used by DML in the transaction that added it, so bundling this
-- with v2_0038's functions would make every test that creates a proposal fail.
-- =============================================================================

alter type proposal_kind add value if not exists 'level_change';
