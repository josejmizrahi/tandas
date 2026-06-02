-- d24_p9_drop_legacy_role_rpc_overloads
-- Reconstruido desde supabase_migrations.schema_migrations (live DB wyvkqveienzixinonhum)
-- en R.1 para restaurar la replicabilidad del repo (drift fix: la sesion original
-- aplico esta migration via MCP pero no commiteo el archivo al repo).

-- Remove the pre-D24P9 sigs (2-arg). The new 4-arg with defaults takes over.
drop function if exists public.assign_role_to_member(uuid, uuid);
drop function if exists public.revoke_role_from_member(uuid, uuid);
-- Also drop the pre-D24P9 grant_mandate sigs (if a 7-arg overload exists alongside the new 8-arg).
drop function if exists public.grant_mandate(uuid, uuid, text, text, uuid, jsonb, timestamptz);
-- And the 2-arg revoke_mandate (now we have 3-arg with default).
drop function if exists public.revoke_mandate(uuid, text);
