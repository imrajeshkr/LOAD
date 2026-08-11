-- =============================================================================
-- LOAD — demo media for the exercise catalog
--
-- The Guide screen has always had a "Demo clip coming soon" placeholder. This
-- points each catalog exercise at a real asset in the `exercise-media` bucket.
--
-- Stores the object PATH, not a full URL. The client builds the URL with
-- `storage.from('exercise-media').getPublicUrl(path)`, so the project ref
-- lives in one place (the Supabase client) instead of being baked into 36 rows.
--
-- One file per exercise, named for its slug, under exercise-guide-web/ — that
-- prefix is where `supabase storage cp -r` landed them (it preserves the
-- source directory name rather than flattening it) and is left as-is rather
-- than re-uploaded, since the bucket has no other content to collide with it.
-- Most are static WebP; hip-thrust is an animated WebP. Both decode through
-- the same image widget, so the app needs no kind discriminator — an
-- animation just animates.
--
-- Requires: supabase/storage_setup.sql (creates the bucket) and the files to
-- have been uploaded. Safe to run before the upload — the rows simply point at
-- objects that 404 until they exist.
-- =============================================================================

alter table exercises
  add column if not exists demo_path text;

comment on column exercises.demo_path is
  'Object path within the public `exercise-media` bucket, e.g. '
  '"exercise-guide-web/bench-press.webp". Null means no demo asset yet; '
  'the client falls back to its placeholder.';

-- Every global catalog exercise has an asset named for its slug.
update exercises
   set demo_path = 'exercise-guide-web/' || slug || '.webp'
 where owner_id is null
   and demo_path is distinct from 'exercise-guide-web/' || slug || '.webp';
