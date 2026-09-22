-- =====================================================================
-- TradeLens: accounts, cross-device sync and admin, for Supabase.
-- Run this ONCE in your Supabase project: SQL Editor -> New query -> paste -> Run.
-- It is safe to run again; it will not duplicate anything.
-- =====================================================================

-- ---------- tables ----------
create table if not exists public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  email         text not null,
  role          text not null default 'user' check (role in ('user','admin')),
  suspended     boolean not null default false,
  trade_count   integer not null default 0,
  journal_count integer not null default 0,
  created_at    timestamptz not null default now(),
  last_seen     timestamptz
);

create table if not exists public.user_data (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  state      jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.profiles  enable row level security;
alter table public.user_data enable row level security;

-- ---------- helper functions ----------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'admin' and not p.suspended
  );
$$;

create or replace function public.is_active() returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (
    select 1 from public.profiles p where p.id = auth.uid() and p.suspended
  );
$$;

-- ---------- permissions (newer Supabase projects do not expose new tables automatically) ----------
grant usage on schema public to authenticated;
grant select on public.profiles to authenticated;
grant select, insert, update, delete on public.user_data to authenticated;
grant execute on function public.is_admin()  to authenticated;
grant execute on function public.is_active() to authenticated;

-- ---------- row level security ----------
-- profiles: you can read your own row, admins can read everyone's. Nobody writes directly from the browser.
drop policy if exists "read own profile"     on public.profiles;
drop policy if exists "admin reads profiles" on public.profiles;
create policy "read own profile"     on public.profiles for select using (id = auth.uid());
create policy "admin reads profiles" on public.profiles for select using (public.is_admin());

-- user_data: each person reads and writes only their own document (unless suspended).
-- Admins can NOT read anyone's journals.
drop policy if exists "own data select" on public.user_data;
drop policy if exists "own data insert" on public.user_data;
drop policy if exists "own data update" on public.user_data;
drop policy if exists "own data delete" on public.user_data;
create policy "own data select" on public.user_data for select using (user_id = auth.uid() and public.is_active());
create policy "own data insert" on public.user_data for insert with check (user_id = auth.uid() and public.is_active());
create policy "own data update" on public.user_data for update using (user_id = auth.uid() and public.is_active()) with check (user_id = auth.uid() and public.is_active());
create policy "own data delete" on public.user_data for delete using (user_id = auth.uid());

-- ---------- keep updated_at honest (the site uses it to detect changes from other devices) ----------
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
drop trigger if exists user_data_touch on public.user_data;
create trigger user_data_touch before update on public.user_data
  for each row execute function public.touch_updated_at();

-- ---------- create a profile row for every new sign-up ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Back-fill profiles for anyone who signed up before you ran this script.
insert into public.profiles (id, email)
select u.id, u.email from auth.users u
on conflict (id) do nothing;

-- ---------- functions the site calls ----------
-- A signed-in person updates only their own activity numbers.
create or replace function public.touch_profile(p_trades int, p_journals int) returns void
language sql security definer set search_path = public as $$
  update public.profiles
     set trade_count = greatest(p_trades, 0),
         journal_count = greatest(p_journals, 0),
         last_seen = now()
   where id = auth.uid();
$$;

-- Admins suspend or reinstate an account (never their own).
create or replace function public.admin_set_suspended(p_user uuid, p_suspended boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  if p_user = auth.uid() then raise exception 'you cannot suspend yourself'; end if;
  update public.profiles set suspended = p_suspended where id = p_user;
end;
$$;

revoke all on function public.touch_profile(int, int)            from public;
revoke all on function public.admin_set_suspended(uuid, boolean) from public;
grant execute on function public.touch_profile(int, int)            to authenticated;
grant execute on function public.admin_set_suspended(uuid, boolean) to authenticated;

-- ---------- tighten who can call the helper functions (Supabase exposes them through the API by default) ----------
alter function public.touch_updated_at() set search_path = public;
revoke execute on function public.handle_new_user()                  from public, anon, authenticated;
revoke execute on function public.is_admin()                         from public, anon;
revoke execute on function public.is_active()                        from public, anon;
revoke execute on function public.touch_profile(int, int)            from anon;
revoke execute on function public.admin_set_suspended(uuid, boolean) from anon;

-- ---------- private storage for screenshots, icons and videos ----------
insert into storage.buckets (id, name, public)
values ('media', 'media', false)
on conflict (id) do nothing;

drop policy if exists "own media read"   on storage.objects;
drop policy if exists "own media insert" on storage.objects;
drop policy if exists "own media update" on storage.objects;
drop policy if exists "own media delete" on storage.objects;
create policy "own media read"   on storage.objects for select
  using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text and public.is_active());
create policy "own media insert" on storage.objects for insert
  with check (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text and public.is_active());
create policy "own media update" on storage.objects for update
  using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text and public.is_active());
create policy "own media delete" on storage.objects for delete
  using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------- economic calendar (filled automatically by the "news" edge function from Forex Factory) ----------
create table if not exists public.news_events (
  id text primary key, date date not null, time text not null, country text not null, title text not null,
  impact text not null check (impact in ('high','medium','low','holiday')),
  forecast text not null default '', previous text not null default '',
  event_at timestamptz not null, updated_at timestamptz not null default now()
);
create index if not exists news_events_date_idx on public.news_events (date);
create table if not exists public.news_meta (id int primary key, fetched_at timestamptz, checked_at timestamptz, ok boolean, rows int);
alter table public.news_events enable row level security;
alter table public.news_meta   enable row level security;
drop policy if exists "news is public"      on public.news_events;
drop policy if exists "news meta is public" on public.news_meta;
create policy "news is public"      on public.news_events for select using (true);
create policy "news meta is public" on public.news_meta   for select using (true);
grant select on public.news_events, public.news_meta to anon, authenticated;
grant all    on public.news_events, public.news_meta to service_role;
create or replace function public.replace_news(p_from date, p_to date, p_rows jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.news_events where date between p_from and p_to;
  insert into public.news_events (id, date, time, country, title, impact, forecast, previous, event_at, updated_at)
  select distinct on (r->>'id') r->>'id', (r->>'date')::date, r->>'time', r->>'country', r->>'title', r->>'impact',
         coalesce(r->>'forecast',''), coalesce(r->>'previous',''), (r->>'event_at')::timestamptz, now()
    from jsonb_array_elements(p_rows) r
   where r->>'impact' in ('high','medium','low','holiday')
  on conflict (id) do update set date = excluded.date, time = excluded.time, impact = excluded.impact,
     forecast = excluded.forecast, previous = excluded.previous, event_at = excluded.event_at, updated_at = now();
end;
$$;
revoke all on function public.replace_news(date, date, jsonb) from public, anon, authenticated;
grant execute on function public.replace_news(date, date, jsonb) to service_role;

-- =====================================================================
-- MAKE YOURSELF THE ADMIN (do this AFTER you have signed up on the site)
-- 1. Open your TradeLens site and create an account with your Gmail.
-- 2. Confirm the email Supabase sends you, then sign in once.
-- 3. Replace YOUR_GMAIL_HERE below with that same address and run just this line:
--
--    update public.profiles set role = 'admin' where email = 'YOUR_GMAIL_HERE';
--
-- Sign out and back in, and an "Admin" tab appears.
-- =====================================================================
