-- Make a login the shop admin.
-- 1) First create the login: Supabase → Authentication → Users → Add user
--    (tick "Auto Confirm User").
-- 2) Put that exact email below, then run this in SQL Editor.
--    It should say "Success. 1 row". 0 rows = the email doesn't match.

insert into public.admins (user_id)
select id from auth.users where email = 'PUT-THE-EMAIL-HERE'
on conflict (user_id) do nothing;
