-- =============================================================================
-- v2_0019 — profile avatars + pattern-level weekday swap
--
--   * Public `avatars` storage bucket (profile pictures are low-sensitivity and
--     rendered everywhere, so public read avoids signing every load). Each user
--     owns the folder named by their uid. profiles.avatar_url already exists.
--   * swap_program_weekdays(wf, wt): the Profile "Your plan" strip swaps which
--     session lands on which weekday — a pattern change (every week), rewriting
--     the weekday slots and all future scheduled rows on those two weekdays.
--     Reuses the v2_0018 helpers _set_weekday_slot / _set_scheduled_day.
-- =============================================================================

-- ── avatars bucket ──────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do update set public = true;

drop policy if exists avatars_public_read on storage.objects;
create policy avatars_public_read on storage.objects
  for select using (bucket_id = 'avatars');

drop policy if exists avatars_own_insert on storage.objects;
create policy avatars_own_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists avatars_own_update on storage.objects;
create policy avatars_own_update on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists avatars_own_delete on storage.objects;
create policy avatars_own_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- ── weekday pattern swap ─────────────────────────────────────────────────────
create or replace function swap_program_weekdays(p_wf smallint, p_wt smallint)
returns void
language plpgsql security invoker as $$
declare
  v_uid   uuid := auth.uid();
  v_prog  uuid;
  v_today date;
  v_pdf   uuid;
  v_pdt   uuid;
  v_max   date;
  v_d     date;
  v_wd    smallint;
begin
  if v_uid is null then raise exception 'not authenticated'; end if;
  if p_wf = p_wt then return; end if;

  select id into v_prog from programs
   where user_id = v_uid and status = 'active' limit 1;
  if v_prog is null then raise exception 'no active program'; end if;

  select program_day_id into v_pdf
    from program_weekday_slots where program_id = v_prog and weekday = p_wf;
  select program_day_id into v_pdt
    from program_weekday_slots where program_id = v_prog and weekday = p_wt;
  if v_pdf is null and v_pdt is null then return; end if;

  -- Swap the permanent slots.
  perform _set_weekday_slot(v_uid, v_prog, p_wf, v_pdt);
  perform _set_weekday_slot(v_uid, v_prog, p_wt, v_pdf);

  -- Rewrite every future dated row on those two weekdays to match.
  v_today := user_today(v_uid);
  select max(scheduled_for) into v_max
    from scheduled_workouts where user_id = v_uid;
  if v_max is not null then
    for v_d in
      select gs::date from generate_series(v_today, v_max, interval '1 day') gs
    loop
      v_wd := extract(isodow from v_d)::smallint;
      if v_wd = p_wf then
        perform _set_scheduled_day(v_uid, v_prog, v_d, v_pdt);
      elsif v_wd = p_wt then
        perform _set_scheduled_day(v_uid, v_prog, v_d, v_pdf);
      end if;
    end loop;
  end if;
end $$;

grant execute on function swap_program_weekdays(smallint, smallint) to authenticated;
