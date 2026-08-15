-- LOAD — storage bucket for exercise demo media.
--
-- Run once in the Supabase SQL Editor. Idempotent.
--
-- Public bucket on purpose: these are generic catalog demos shared by every
-- user, not personal data. Public means plain CDN URLs, no signed-URL expiry
-- to manage, and normal HTTP caching on device.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'exercise-media',
  'exercise-media',
  true,
  10485760,                                   -- 10 MB ceiling per object
  array['image/webp', 'image/png', 'image/gif']
)
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Anyone may read; only the service role writes (no insert/update/delete
-- policy = no write access for anon or authenticated).
drop policy if exists "exercise_media_public_read" on storage.objects;
create policy "exercise_media_public_read"
  on storage.objects for select
  to public
  using (bucket_id = 'exercise-media');
