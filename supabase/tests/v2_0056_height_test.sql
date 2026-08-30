savepoint h;
DO $$
declare v_uid uuid; v_blocked boolean := false;
begin
  select id into v_uid from profiles order by created_at limit 1;
  update profiles set height_cm = 175 where id = v_uid;
  raise notice 'height stored -> %', (select height_cm from profiles where id=v_uid);

  -- The range guard is what stops a ruler-picker bug writing 17.5 or 1750.
  begin
    update profiles set height_cm = 12 where id = v_uid;
  exception when others then v_blocked := true;
  end;
  if not v_blocked then raise exception 'an impossible height was accepted'; end if;
  raise notice 'implausible height -> refused';

  update profiles set height_cm = null where id = v_uid;
  raise notice 'null height -> allowed, BMI is optional';
  raise notice 'V2_0056 HEIGHT: PASS';
end $$;
rollback to savepoint h;
