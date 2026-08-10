-- =============================================================================
-- LOAD — provision rows for accounts that predate the v2 schema
--
-- `handle_new_user` only fires on INSERT into auth.users, so every account
-- that existed before 0003 dropped `profiles` came out the other side with no
-- profile and no preferences row. The app reads both on launch, so without
-- this those users are broken.
--
-- Deliberately does NOT create a training_profiles row: goal, experience and
-- environment are answers only the user can give, and their absence is what
-- correctly routes them into onboarding.
-- =============================================================================

insert into profiles (id)
select u.id from auth.users u
 where not exists (select 1 from profiles p where p.id = u.id);

insert into user_preferences (user_id)
select u.id from auth.users u
 where not exists (select 1 from user_preferences pr where pr.user_id = u.id);
