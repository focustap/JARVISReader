create table if not exists public.jarvis_photo_sessions (
  sender text primary key,
  context_media_id text,
  context_mime_type text,
  context_caption text,
  context_message_id text,
  context_created_at timestamptz,
  last_question_message_id text,
  updated_at timestamptz not null default now()
);

alter table public.jarvis_photo_sessions enable row level security;

revoke all on table public.jarvis_photo_sessions from anon, authenticated;
grant select, insert, update, delete on table public.jarvis_photo_sessions to service_role;

comment on table public.jarvis_photo_sessions is
  'Server-only temporary state for JARVIS Reader context-photo -> question-photo pairing.';
