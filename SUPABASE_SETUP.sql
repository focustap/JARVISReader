-- JARVIS Reader Supabase setup
-- Run this once in the SQL Editor for the dedicated JARVIS Reader project.

create table if not exists public.jarvis_responses (
  id uuid primary key default gen_random_uuid(),
  session_id text not null,
  answer text not null,
  created_at timestamptz not null default now()
);

create index if not exists jarvis_responses_session_created_idx
  on public.jarvis_responses (session_id, created_at desc);

alter table public.jarvis_responses enable row level security;

-- The project was created with automatic table exposure disabled, so grant
-- only the operations JARVIS Reader actually needs.
revoke all on table public.jarvis_responses from anon, authenticated;
grant select, insert on table public.jarvis_responses to anon;

-- Re-running this file is safe.
drop policy if exists "jarvis_read_session" on public.jarvis_responses;
drop policy if exists "jarvis_insert_session" on public.jarvis_responses;

-- A client can only read rows whose session_id matches its private
-- x-jarvis-session request header.
create policy "jarvis_read_session"
on public.jarvis_responses
for select
to anon
using (
  session_id = coalesce(
    nullif(current_setting('request.headers', true), '')::jsonb ->> 'x-jarvis-session',
    ''
  )
);

-- A client can only create a row for the same session key it sent in the
-- x-jarvis-session request header.
create policy "jarvis_insert_session"
on public.jarvis_responses
for insert
to anon
with check (
  session_id = coalesce(
    nullif(current_setting('request.headers', true), '')::jsonb ->> 'x-jarvis-session',
    ''
  )
);
