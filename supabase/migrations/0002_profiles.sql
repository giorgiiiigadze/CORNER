-- Profiles: the part of a user that isn't a credential.
--
-- Supabase's own pattern, and it's the right one: `auth.users` is managed by
-- the auth service and shouldn't be written to by the app, so anything we want
-- to *know* about a person — their name, their picture, later their belt or
-- their gym — lives in a table of ours keyed to the same id.
--
-- The id is both primary key and foreign key. One profile per account, no
-- separate join, and `on delete cascade` means deleting the account takes the
-- profile with it rather than leaving an orphan pointing at nobody.

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,

  -- Nullable on purpose. A fighter signs up with an email and nothing else, and
  -- an empty string is a name they chose to be empty — null is one they haven't
  -- been asked for yet. Those are different facts and the UI shows different
  -- things for them.
  display_name text,
  avatar_url text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- No delete policy. A profile dies with its account, through the cascade above;
-- nothing in the app should be able to delete one on its own, and a policy that
-- allowed it would be a way to lose a name without losing the login.
create policy "read own profile"
  on public.profiles for select
  to authenticated
  using ((select auth.uid()) = id);

create policy "insert own profile"
  on public.profiles for insert
  to authenticated
  with check ((select auth.uid()) = id);

create policy "update own profile"
  on public.profiles for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- Every account gets a profile the moment it exists.
--
-- A trigger rather than the app creating one after sign-up: the app can crash,
-- lose signal, or be force-quit between those two steps, and an account with no
-- profile row is a state every read afterwards has to defend against forever.
-- Doing it in the same transaction as the insert into `auth.users` means that
-- state can't happen.
--
-- `security definer` because the trigger runs as the auth service, which has no
-- rights on our table. `set search_path = ''` with fully-qualified names is what
-- stops that elevated context resolving a name somewhere unexpected.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    -- Whatever the client passed in `options.data` at sign-up, if anything.
    -- Nothing does yet; this is here so adding a name field to the form is a
    -- client change and not another migration.
    nullif(new.raw_user_meta_data ->> 'display_name', '')
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Keeps `updated_at` honest without the client having to remember.
create function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_touch_updated_at
  before update on public.profiles
  for each row execute function public.touch_updated_at();

-- The two accounts that already exist predate the trigger, so they need theirs
-- backfilled. `on conflict do nothing` makes this safe to run twice.
insert into public.profiles (id)
select id from auth.users
on conflict (id) do nothing;
