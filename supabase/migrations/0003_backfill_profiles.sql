-- Profiles for the accounts that already existed.
--
-- `0002` installs a trigger that gives every new account a profile in the same
-- transaction as the signup. What it can't do is reach backwards: anyone who
-- signed up before that migration was applied has a row in `auth.users` and
-- nothing in `public.profiles`, and no amount of signing in will create one.
--
-- Run this once, immediately after `0002`. Running it twice is harmless — the
-- conflict clause makes it a no-op the second time — so it's safe to re-run if
-- you're unsure whether it took.
insert into public.profiles (id, display_name)
select
  u.id,
  -- Same rule the trigger uses, so a backfilled profile is indistinguishable
  -- from one the trigger made. Almost always null: nothing has ever passed
  -- `display_name` at signup.
  nullif(u.raw_user_meta_data ->> 'display_name', '')
from auth.users as u
on conflict (id) do nothing;
