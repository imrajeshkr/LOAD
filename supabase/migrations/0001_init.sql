-- LOAD — initial schema
-- Run this in the Supabase SQL editor (Dashboard > SQL Editor), or via
-- `supabase db push` once the project is linked with the CLI.

create extension if not exists "uuid-ossp";

-- ── profiles ────────────────────────────────────────────────────────────
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  goal text,
  experience text,
  days_per_week int default 4,
  environment text,
  split_pref text,
  injuries text default '',
  current_weight numeric,
  target_weight numeric,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "profiles_select_own" on public.profiles
  for select using (auth.uid() = id);
create policy "profiles_insert_own" on public.profiles
  for insert with check (auth.uid() = id);
create policy "profiles_update_own" on public.profiles
  for update using (auth.uid() = id);

-- Auto-create a blank profile row when a user signs up.
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ── sessions ────────────────────────────────────────────────────────────
create table if not exists public.sessions (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references auth.users(id) on delete cascade,
  label text not null,
  session_date date not null default current_date,
  completed_at timestamptz,
  notes text default '',
  rpe int,
  pain text[] default '{}',
  created_at timestamptz not null default now()
);

alter table public.sessions enable row level security;

create policy "sessions_all_own" on public.sessions
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ── session_sets ────────────────────────────────────────────────────────
create table if not exists public.session_sets (
  id uuid primary key default uuid_generate_v4(),
  session_id uuid not null references public.sessions(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  exercise_name text not null,
  set_number int not null,
  weight numeric not null,
  reps int not null,
  created_at timestamptz not null default now()
);

alter table public.session_sets enable row level security;

create policy "session_sets_all_own" on public.session_sets
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ── weight_logs ─────────────────────────────────────────────────────────
create table if not exists public.weight_logs (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references auth.users(id) on delete cascade,
  weight numeric not null,
  logged_at timestamptz not null default now()
);

alter table public.weight_logs enable row level security;

create policy "weight_logs_all_own" on public.weight_logs
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ── protein_logs ────────────────────────────────────────────────────────
create table if not exists public.protein_logs (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references auth.users(id) on delete cascade,
  grams int not null,
  logged_at timestamptz not null default now()
);

alter table public.protein_logs enable row level security;

create policy "protein_logs_all_own" on public.protein_logs
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ── chat_messages ───────────────────────────────────────────────────────
create table if not exists public.chat_messages (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references auth.users(id) on delete cascade,
  sender text not null check (sender in ('user', 'coach')),
  body text not null,
  created_at timestamptz not null default now()
);

alter table public.chat_messages enable row level security;

create policy "chat_messages_all_own" on public.chat_messages
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ── indexes ─────────────────────────────────────────────────────────────
create index if not exists sessions_user_date_idx on public.sessions (user_id, session_date desc);
create index if not exists session_sets_session_idx on public.session_sets (session_id);
create index if not exists weight_logs_user_idx on public.weight_logs (user_id, logged_at desc);
create index if not exists protein_logs_user_idx on public.protein_logs (user_id, logged_at desc);
create index if not exists chat_messages_user_idx on public.chat_messages (user_id, created_at);
