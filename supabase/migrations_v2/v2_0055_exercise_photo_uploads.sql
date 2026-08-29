-- =============================================================================
-- v2_0055 — let a lifter upload a photo for an exercise they own
--
-- The `exercise-media` bucket was created read-only: public select, no write
-- policy at all, because until now every illustration in it was ours. The
-- create-exercise and "Add a photo" flows both write to it, so without this
-- they fail with a storage 403 and the feature is inert — the Dart degrades to
-- the placeholder rather than crashing, which means the failure would have
-- been silent.
--
-- Writes are confined to `user/<uid>/…`, mirroring the avatars convention from
-- v2_0019 — except the uid sits at the SECOND path segment here, because the
-- bucket already holds our own catalogue illustrations under
-- `exercise-guide-web/` and lifter uploads need their own namespace rather
-- than the bucket root.
--
-- That confinement is the whole point: a lifter may add their own photos and
-- may not touch `exercise-guide-web/`, so no upload can replace a catalogue
-- illustration every other lifter sees.
-- =============================================================================

drop policy if exists exercise_media_own_insert on storage.objects;
create policy exercise_media_own_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'exercise-media'
    and (storage.foldername(name))[1] = 'user'
    and (storage.foldername(name))[2] = auth.uid()::text);

drop policy if exists exercise_media_own_update on storage.objects;
create policy exercise_media_own_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'exercise-media'
    and (storage.foldername(name))[1] = 'user'
    and (storage.foldername(name))[2] = auth.uid()::text);

drop policy if exists exercise_media_own_delete on storage.objects;
create policy exercise_media_own_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'exercise-media'
    and (storage.foldername(name))[1] = 'user'
    and (storage.foldername(name))[2] = auth.uid()::text);
