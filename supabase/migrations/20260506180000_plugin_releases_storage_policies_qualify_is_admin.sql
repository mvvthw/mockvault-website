-- Defensive cleanup: qualify the is_admin() reference in the plugin-releases
-- storage policies as `public.is_admin` so resolution doesn't depend on the
-- search_path of whatever context evaluates the policy.
--
-- (Note: this change alone did NOT fix the upload bug we hit on 2026-05-06 --
-- the browser-side .ccx upload to plugin-releases was rejected even with a
-- fully permissive `to public` policy on storage.objects, indicating something
-- deeper than RLS in the storage path. The actual fix was to route the upload
-- through the admin-publish-release Edge Function using the service_role key.
-- These policies are kept as a defense-in-depth layer.)

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
