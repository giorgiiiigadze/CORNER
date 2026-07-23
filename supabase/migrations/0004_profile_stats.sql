-- The parts of a person the app now asks for: a line about themselves, and the
-- two body measurements a training app can actually use.
--
-- All nullable, same reasoning as `display_name` in `0002`: a fighter signs up
-- with an email and nothing else. Null is "never asked"; the app shows a prompt.
-- A value the user cleared is stored as null too, so there's one empty state,
-- not two.
--
-- Height and weight are the SI units HealthKit hands back — centimetres and
-- kilograms — kept as `numeric` rather than `real` so a value read from Health
-- and written straight back survives the round-trip without float drift. The
-- client converts to the reader's locale (lb/ft-in) for display; the column
-- stays one honest unit so two devices agree on what's stored.
--
-- `birthdate` is a `date`, not a timestamp: a birthday has no time of day, and
-- storing one would invite a timezone bug that shifts someone's age by a day.
--
-- No RLS changes needed. The policies in `0002` are on the row, not the column,
-- so "read/insert/update own profile" already covers everything added here.

alter table public.profiles
  add column if not exists bio text,
  add column if not exists height_cm numeric,
  add column if not exists weight_kg numeric,
  add column if not exists birthdate date;
