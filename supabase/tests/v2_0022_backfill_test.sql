DO $$
declare v_missing int;
begin
  select count(*) into v_missing
    from training_profiles
   where valid_to is null
     and (experience is null or environment is null);

  raise notice 'profiles missing intake: %', v_missing;
  if v_missing > 0 then
    raise exception 'BACKFILL INCOMPLETE: % current profiles still NULL', v_missing;
  end if;
  raise notice 'ALL CURRENT PROFILES HAVE INTAKE';
end $$;
