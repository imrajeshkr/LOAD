-- =============================================================================
-- LOAD v2 — progress photos
--
-- The Progress tab's last panel is two photo slots, "first" and "latest",
-- each labelled with a date and the bodyweight on that date.
--
-- Bodyweight is NOT stored on the photo. It is joined from body_measurements
-- on the capture date — storing it twice guarantees they eventually disagree,
-- and a corrected weigh-in should correct the photo label too.
--
-- Unlike exercise-media, this bucket is PRIVATE. These are photographs of the
-- user's body; they are served through short-lived signed URLs, never a public
-- CDN path.
-- =============================================================================

create table if not exists progress_photos (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles(id) on delete cascade,
  taken_on    date not null default current_date,
  -- Object path within the private `progress-photos` bucket.
  storage_path text not null,
  -- Front / back / side, for users who take a set. The design shows one photo
  -- per slot, so this is nullable and unused by v1 — but a photo set is the
  -- obvious next ask and retrofitting an angle onto existing rows is worse.
  angle       text check (angle in ('front', 'back', 'side')),
  note        text,
  created_at  timestamptz not null default now(),
  -- One photo per angle per day. Retaking on the same day replaces.
  unique (user_id, taken_on, angle)
);

create index if not exists progress_photos_user_date_idx
  on progress_photos (user_id, taken_on desc);

alter table progress_photos enable row level security;

create policy progress_photos_own on progress_photos
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));


-- ── the panel's query ───────────────────────────────────────────────────
-- Returns the bookend photos for a range, each with the bodyweight recorded on
-- its capture date. "first" is the earliest photo WITHIN the range, not the
-- user's all-time first — the range control changes what it anchors to.
create or replace function progress_photo_pair(p_user_id uuid, p_since date)
returns jsonb
language sql stable security invoker as $$
  with ranked as (
    select p.id, p.taken_on, p.storage_path, p.angle,
           (select bm.weight_kg from body_measurements bm
             where bm.user_id = p.user_id and bm.measured_on = p.taken_on) as weight_kg,
           row_number() over (order by p.taken_on)      as asc_rn,
           row_number() over (order by p.taken_on desc) as desc_rn
      from progress_photos p
     where p.user_id = p_user_id
       and (p_since is null or p.taken_on >= p_since)
  )
  select jsonb_build_object(
    'total', (select count(*) from ranked),
    'first', (select to_jsonb(r) from ranked r where r.asc_rn = 1),
    'latest', (select to_jsonb(r) from ranked r where r.desc_rn = 1 and r.asc_rn <> 1)
  );
$$;

grant execute on function progress_photo_pair(uuid, date) to authenticated;


-- ── storage bucket ──────────────────────────────────────────────────────
-- Private, unlike exercise-media. 15 MB ceiling: phone cameras produce large
-- files and the client should downscale before upload, but a hard reject at a
-- reasonable size beats a silent failure.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'progress-photos',
  'progress-photos',
  false,
  15728640,
  array['image/jpeg', 'image/png', 'image/webp', 'image/heic']
)
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Owner-only, all four verbs, scoped by a user-id path prefix:
-- progress-photos/{user_id}/{uuid}.jpg
drop policy if exists "progress_photos_own_read"   on storage.objects;
drop policy if exists "progress_photos_own_write"  on storage.objects;
drop policy if exists "progress_photos_own_update" on storage.objects;
drop policy if exists "progress_photos_own_delete" on storage.objects;

create policy "progress_photos_own_read" on storage.objects for select to authenticated
  using (bucket_id = 'progress-photos'
         and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "progress_photos_own_write" on storage.objects for insert to authenticated
  with check (bucket_id = 'progress-photos'
              and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "progress_photos_own_update" on storage.objects for update to authenticated
  using (bucket_id = 'progress-photos'
         and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "progress_photos_own_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'progress-photos'
         and (storage.foldername(name))[1] = (select auth.uid())::text);
