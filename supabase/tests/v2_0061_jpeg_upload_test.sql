-- The bucket must accept what a phone camera produces, or the upload path is
-- decorative. This is a config assertion, and config drifts silently.
savepoint t;
DO $$
declare v_types text[];
begin
  select allowed_mime_types into v_types
    from storage.buckets where id = 'exercise-media';
  if v_types is null then
    raise notice 'PHOTO BUCKET: unrestricted, anything uploads';
    return;
  end if;
  if not ('image/jpeg' = any(v_types)) then
    raise exception 'FAIL: exercise-media rejects image/jpeg, which is what '
                    'image_picker produces — photo uploads cannot work';
  end if;
  if not ('image/png' = any(v_types)) then
    raise exception 'FAIL: exercise-media rejects image/png';
  end if;
  raise notice 'PHOTO BUCKET: accepts jpeg and png';
end $$;
rollback to savepoint t;
