-- A lifter may write under user/<their uid>/ in exercise-media, and nowhere
-- else in that bucket. The second half matters more than the first: the bucket
-- also holds our catalogue illustrations under exercise-guide-web/.
savepoint photo;
DO $$
declare v_uid uuid; v_blocked boolean := false;
begin
  select id into v_uid from profiles order by created_at limit 1;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role','authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  insert into storage.objects (bucket_id, name, owner)
  values ('exercise-media', 'user/'||v_uid||'/probe.jpg', v_uid);
  raise notice 'own folder             -> upload allowed';

  begin
    insert into storage.objects (bucket_id, name, owner)
    values ('exercise-media', 'exercise-guide-web/bench-press.webp', v_uid);
  exception when others then v_blocked := true;
  end;
  if not v_blocked then
    raise exception 'a lifter overwrote a CATALOGUE illustration';
  end if;
  raise notice 'catalogue folder       -> refused, as it must be';

  v_blocked := false;
  begin
    insert into storage.objects (bucket_id, name, owner)
    values ('exercise-media', 'user/00000000-0000-0000-0000-000000000000/x.jpg', v_uid);
  exception when others then v_blocked := true;
  end;
  if not v_blocked then raise exception 'a lifter wrote into another user folder'; end if;
  raise notice 'another lifter''s folder -> refused';
  raise notice 'V2_0055 PHOTO POLICY: PASS';
end $$;
rollback to savepoint photo;
