-- Mockup updates: announcements for new mockup drops.
--
-- Admin posts a "drop" (optional title + notes + per-category lists of mockup
-- names). Customers see the most recent drops in their account dashboard.
--
-- Apply via Supabase SQL editor or `supabase db push`.

-- ─── Table ─────────────────────────────────────────────────────────────────
create table if not exists public.mockup_updates (
  id           bigint generated always as identity primary key,
  title        text,
  notes        text,
  items        jsonb       not null default '{}'::jsonb,
  is_pinned    boolean     not null default false,
  published_at timestamptz not null default now(),
  created_by   uuid        references auth.users(id) on delete set null
);

create index if not exists mockup_updates_published_at_idx
  on public.mockup_updates (published_at desc);

create index if not exists mockup_updates_pinned_idx
  on public.mockup_updates (is_pinned)
  where is_pinned = true;

alter table public.mockup_updates enable row level security;

-- Public read so the account dashboard + landing page can display drops.
drop policy if exists "anyone can read mockup updates" on public.mockup_updates;
create policy "anyone can read mockup updates"
  on public.mockup_updates
  for select
  to anon, authenticated
  using (true);

-- ─── Admin RPCs ────────────────────────────────────────────────────────────
-- Publish a new mockup update. items must be a JSON object mapping category
-- name -> array of mockup name strings. Empty categories should be omitted by
-- the client, but the RPC tolerates them.
create or replace function public.admin_publish_mockup_update(
  p_title  text,
  p_notes  text,
  p_items  jsonb,
  p_pinned boolean default false
) returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
  v_clean jsonb;
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'not authorized';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'object' then
    raise exception 'items must be a JSON object';
  end if;

  -- Strip empty categories so storage stays clean.
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_clean
  from jsonb_each(p_items)
  where jsonb_typeof(value) = 'array'
    and jsonb_array_length(value) > 0;

  if v_clean = '{}'::jsonb and (p_title is null or length(trim(p_title)) = 0) then
    raise exception 'an update needs at least a title or one mockup item';
  end if;

  -- Pinning is exclusive — only one update can be pinned at a time.
  if coalesce(p_pinned, false) then
    update public.mockup_updates set is_pinned = false where is_pinned = true;
  end if;

  insert into public.mockup_updates (title, notes, items, is_pinned, created_by)
  values (
    nullif(trim(coalesce(p_title, '')), ''),
    nullif(trim(coalesce(p_notes, '')), ''),
    v_clean,
    coalesce(p_pinned, false),
    auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.admin_publish_mockup_update(text, text, jsonb, boolean) from public;
grant execute on function public.admin_publish_mockup_update(text, text, jsonb, boolean) to authenticated;


create or replace function public.admin_pin_mockup_update(
  p_id bigint
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'not authorized';
  end if;
  if not exists (select 1 from public.mockup_updates where id = p_id) then
    raise exception 'mockup update not found';
  end if;
  update public.mockup_updates set is_pinned = false where is_pinned = true and id <> p_id;
  update public.mockup_updates set is_pinned = true  where id = p_id;
end;
$$;

revoke all on function public.admin_pin_mockup_update(bigint) from public;
grant execute on function public.admin_pin_mockup_update(bigint) to authenticated;


create or replace function public.admin_unpin_mockup_update(
  p_id bigint
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'not authorized';
  end if;
  update public.mockup_updates set is_pinned = false where id = p_id;
end;
$$;

revoke all on function public.admin_unpin_mockup_update(bigint) from public;
grant execute on function public.admin_unpin_mockup_update(bigint) to authenticated;


create or replace function public.admin_delete_mockup_update(
  p_id bigint
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'not authorized';
  end if;
  delete from public.mockup_updates where id = p_id;
end;
$$;

revoke all on function public.admin_delete_mockup_update(bigint) from public;
grant execute on function public.admin_delete_mockup_update(bigint) to authenticated;
