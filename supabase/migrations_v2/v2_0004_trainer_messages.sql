-- =============================================================================
-- LOAD v2 — trainer messages: receipts, acknowledgement, pinning, search
--
-- The v2 Trainer tab is not a plain chat log. Three things it needs that
-- coach_messages does not have:
--
--   1. RECEIPTS — the "what I read" chips under a note ("Read last Wednesday",
--      "Shoulder flagged", "2-day streak"). These cite point-in-time facts that
--      DRIFT: a streak count changes daily, a flagged injury gets resolved.
--      They are therefore snapshotted at write time, never recomputed at
--      display time, or a note from three weeks ago will silently start citing
--      today's numbers and the whole "showing its inputs" trust mechanic
--      becomes a lie.
--
--   2. ACKNOWLEDGEMENT, distinct from having read it. Opening the tab is not
--      the same as tapping "Got it" — the design treats the second as an
--      explicit commitment, and the Train tab's unread dot keys off it.
--
--   3. A category and a warn flag, driving the eyebrow label and whether the
--      card renders amber. Never derived from the text.
-- =============================================================================

do $$ begin
  create type coach_message_category as enum (
    'morning_note',      -- "Before you train"
    'session_debrief',   -- after a session
    'decision',          -- "This needs a decision" — stalled lift, injury triage
    'missed_session',
    'weekly_review',
    'plan_updated',
    'reply'              -- ordinary conversational turn, no eyebrow
  );
exception when duplicate_object then null;
end $$;

alter table coach_messages
  add column if not exists category coach_message_category not null default 'reply',
  add column if not exists needs_attention boolean not null default false,
  add column if not exists read_at timestamptz,
  add column if not exists acknowledged_at timestamptz,
  add column if not exists pinned_until date;

comment on column coach_messages.needs_attention is
  'Renders the card amber and the eyebrow in warn colour. Set by the coach when '
  'the note reports a stall, an injury, or a missed session — not inferred from text.';

comment on column coach_messages.acknowledged_at is
  'Set only by an explicit user action ("Got it" / replying). Distinct from '
  'read_at: the Train tab unread dot clears on acknowledgement, not on view.';

comment on column coach_messages.pinned_until is
  'The pinned note above the thread. Date rather than boolean so today''s note '
  'stops being pinned on its own without a cleanup job.';

-- Some notes carry structured card content beyond text: the weekly review has
-- stat tiles ("Three sessions, 6,140 kg"), the stalled-lift note an inline
-- load sparkline. Snapshotted at write time for the same reason receipts are —
-- a review of THAT week must keep showing that week's numbers forever.
-- jsonb rather than tables: rendered as an opaque block, never queried by field.
--   { "stats": [{"value":"3","label":"sessions"}, ...],
--     "chart": {"points":[40,40,40,40,40], "caption_start":"5 weeks ago · 40 kg",
--               "caption_end":"today · 40 kg"} }
alter table coach_messages
  add column if not exists card jsonb;

-- Only assistant messages carry these; a user's own turn is never pinned,
-- categorised or acknowledged.
alter table coach_messages
  drop constraint if exists coach_messages_meta_assistant_only;
alter table coach_messages
  add constraint coach_messages_meta_assistant_only
  check (
    role = 'assistant'
    or (category = 'reply'
        and not needs_attention
        and acknowledged_at is null
        and pinned_until is null)
  );

create index if not exists coach_messages_unacked_idx
  on coach_messages (user_id, created_at desc)
  where role = 'assistant' and acknowledged_at is null;

create index if not exists coach_messages_pinned_idx
  on coach_messages (user_id, pinned_until)
  where pinned_until is not null;


-- ── receipts ────────────────────────────────────────────────────────────
-- A separate table rather than jsonb on the message: they are a short ordered
-- list rendered as discrete chips, and keeping them relational means a future
-- "show me every note that cited my shoulder" is a query rather than a scan.
create table if not exists coach_message_receipts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null,
  message_id  uuid not null,
  position    int  not null check (position >= 0),
  -- Material icon name, chosen by the coach when it writes the note.
  icon        text not null,
  -- The chip text, already rendered: "Read last Wednesday", "2-day streak".
  label       text not null,
  -- Optional machine-readable provenance, so a receipt can later become a
  -- tappable link back to the thing it cites.
  source_kind text check (source_kind in
                ('session', 'set', 'constraint', 'streak', 'measurement', 'plan')),
  source_id   uuid,
  unique (message_id, position),
  foreign key (message_id, user_id)
    references coach_messages(id, user_id) on delete cascade
);

create index if not exists coach_message_receipts_msg_idx
  on coach_message_receipts (message_id, position);

alter table coach_message_receipts enable row level security;

create policy coach_message_receipts_own on coach_message_receipts
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));


-- ── archive search ──────────────────────────────────────────────────────
-- The design's search covers the full archive. Trigram rather than tsvector:
-- the corpus is one user's own messages (hundreds, not millions), and trigram
-- handles the partial-word typing a search-as-you-type field actually receives.
create extension if not exists pg_trgm;

create index if not exists coach_messages_content_trgm_idx
  on coach_messages using gin (content gin_trgm_ops);
