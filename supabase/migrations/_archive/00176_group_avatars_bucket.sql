-- Mig 00176: Group avatars storage bucket
--
-- Constitution: Layer 1 Subject/Domain. `groups.avatar_url` existed since
-- mig 00036 but no bucket nor RLS allowed clients to upload. This mirror
-- of 00170 (per-user avatars) is scoped per-group: only group admins
-- (per `public.is_group_admin`) may write under `{group_id}/`. Reads are
-- public so the URL works without signing.

-- 1) Bucket
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'group_avatars',
  'group_avatars',
  true,
  2 * 1024 * 1024,
  array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif']
)
on conflict (id) do update
   set public = excluded.public,
       file_size_limit = excluded.file_size_limit,
       allowed_mime_types = excluded.allowed_mime_types;

-- 2) RLS — admin-only write under {group_id}/.
--    `(storage.foldername(name))[1]` casts cleanly to uuid since the
--    folder prefix is the group_id; `is_group_admin` does the auth gate.
drop policy if exists "group_avatars_admin_insert" on storage.objects;
create policy "group_avatars_admin_insert"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'group_avatars'
    and public.is_group_admin(
      ((storage.foldername(name))[1])::uuid,
      auth.uid()
    )
  );

drop policy if exists "group_avatars_admin_update" on storage.objects;
create policy "group_avatars_admin_update"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'group_avatars'
    and public.is_group_admin(
      ((storage.foldername(name))[1])::uuid,
      auth.uid()
    )
  )
  with check (
    bucket_id = 'group_avatars'
    and public.is_group_admin(
      ((storage.foldername(name))[1])::uuid,
      auth.uid()
    )
  );

drop policy if exists "group_avatars_admin_delete" on storage.objects;
create policy "group_avatars_admin_delete"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'group_avatars'
    and public.is_group_admin(
      ((storage.foldername(name))[1])::uuid,
      auth.uid()
    )
  );

-- No SELECT policy: bucket public=true serves direct URLs through the
-- Storage gateway. See mig 00171 — explicit SELECT just enabled bucket
-- enumeration without granting any extra access.
