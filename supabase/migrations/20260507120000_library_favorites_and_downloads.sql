-- MockVault web library: favorites + download audit log
-- library_favorites: per-user ★ Saved sync across devices
-- library_downloads: audit trail for license-gated downloads (anti-leak)

create table public.library_favorites (
  user_id    uuid not null references auth.users(id) on delete cascade,
  mockup_id  text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, mockup_id)
);

alter table public.library_favorites enable row level security;

create policy "users see own favorites"
  on public.library_favorites for select
  using (user_id = auth.uid());

create policy "users insert own favorites"
  on public.library_favorites for insert
  with check (user_id = auth.uid());

create policy "users delete own favorites"
  on public.library_favorites for delete
  using (user_id = auth.uid());

create index library_favorites_user_idx
  on public.library_favorites(user_id);


create table public.library_downloads (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  mockup_id   text not null,
  side        text not null check (side in ('front','back')),
  file_path   text not null,
  user_agent  text,
  created_at  timestamptz not null default now()
);

alter table public.library_downloads enable row level security;

-- Writes: service-role only (the edge function), so no INSERT policy.
-- Reads: admins (uses existing admin_users table).
create policy "admins read all downloads"
  on public.library_downloads for select
  using (exists (
    select 1 from public.admin_users a where a.user_id = auth.uid()
  ));

create index library_downloads_user_idx
  on public.library_downloads(user_id, created_at desc);

create index library_downloads_mockup_idx
  on public.library_downloads(mockup_id, created_at desc);
