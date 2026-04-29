-- Plugin releases: public read for /changelog, admin write via RPC + storage RLS.
--
-- Apply via Supabase SQL editor or `supabase db push`.

-- ─── Public read on plugin_releases ────────────────────────────────────────
-- The existing "license holders can read" policy stays in place; this one adds
-- public visibility for the marketing-side /changelog page.
drop policy if exists "anyone can read plugin releases" on public.plugin_releases;
create policy "anyone can read plugin releases"
  on public.plugin_releases
  for select
  to anon, authenticated
  using (true);

-- ─── Admin storage policies ────────────────────────────────────────────────
-- Bucket `plugin-releases` is public-read at the object level. We need
-- admin-only insert/update/delete so the admin UI can upload .ccx builds
-- directly from the browser.
drop policy if exists "admin can upload plugin releases" on storage.objects;
create policy "admin can upload plugin releases"
  on storage.objects
  for insert
  to authenticated
  with check (bucket_id = 'plugin-releases' and public.is_admin(auth.uid()));

drop policy if exists "admin can update plugin releases" on storage.objects;
create policy "admin can update plugin releases"
  on storage.objects
  for update
  to authenticated
  using (bucket_id = 'plugin-releases' and public.is_admin(auth.uid()))
  with check (bucket_id = 'plugin-releases' and public.is_admin(auth.uid()));

drop policy if exists "admin can delete plugin releases" on storage.objects;
create policy "admin can delete plugin releases"
  on storage.objects
  for delete
  to authenticated
  using (bucket_id = 'plugin-releases' and public.is_admin(auth.uid()));

-- ─── Admin RPCs ────────────────────────────────────────────────────────────
create or replace function public.admin_publish_release(
  p_version      text,
  p_download_url text,
  p_changelog    text default null,
  p_set_latest   boolean default true
) returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'not authorized';
  end if;
  if p_version is null or length(trim(p_version)) = 0 then
    raise exception 'version is required';
  end if;
  if p_download_url is null or length(trim(p_download_url)) = 0 then
    raise exception 'download_url is required';
  end if;

  if coalesce(p_set_latest, true) then
    update public.plugin_releases set is_latest = false where is_latest = true;
  end if;

  insert into public.plugin_releases (version, download_url, changelog, is_latest)
  values (
    trim(p_version),
    trim(p_download_url),
    nullif(trim(coalesce(p_changelog, '')), ''),
    coalesce(p_set_latest, true)
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.admin_publish_release(text, text, text, boolean) from public;
grant execute on function public.admin_publish_release(text, text, text, boolean) to authenticated;


create or replace function public.admin_set_latest_release(
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
  if not exists (select 1 from public.plugin_releases where id = p_id) then
    raise exception 'release not found';
  end if;
  update public.plugin_releases set is_latest = false where is_latest = true and id <> p_id;
  update public.plugin_releases set is_latest = true  where id = p_id;
end;
$$;

revoke all on function public.admin_set_latest_release(bigint) from public;
grant execute on function public.admin_set_latest_release(bigint) to authenticated;


create or replace function public.admin_delete_release(
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
  delete from public.plugin_releases where id = p_id;
end;
$$;

revoke all on function public.admin_delete_release(bigint) from public;
grant execute on function public.admin_delete_release(bigint) to authenticated;
