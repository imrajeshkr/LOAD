-- Regression guard for the onboarding failure: an unqualified DELETE or UPDATE
-- inside a function is refused for the role the app connects as, and no test
-- that connects as the table owner will ever notice. So assert on the source.
savepoint nbd;
DO $$
declare r record; v_bad text := '';
begin
  for r in
    select p.proname, p.prosrc from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.prokind = 'f'
  loop
    -- `delete from x;` / `update x set ... ;` with no WHERE before the
    -- statement terminator. Deliberately narrow: it looks only for a bare
    -- table name followed directly by a semicolon.
    if r.prosrc ~* '(^|\s)delete\s+from\s+[a-z_][a-z0-9_]*\s*;' then
      v_bad := v_bad || r.proname || ' (delete), ';
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'unqualified DELETE in: %', rtrim(v_bad, ', ');
  end if;
  raise notice 'no function contains an unqualified DELETE';
  raise notice 'V2_0048 NO BARE DELETE: PASS';
end $$;
rollback to savepoint nbd;
