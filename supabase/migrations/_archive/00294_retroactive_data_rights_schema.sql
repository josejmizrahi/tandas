-- 00294_retroactive_data_rights_schema.sql
--
-- Closes ConsistencyAudit_2026-05-17 finding F19. data_deletion_log and
-- data_subject_rights_requests tables EXIST in production (verified via
-- live information_schema query 2026-05-18) but no CREATE TABLE for either
-- appeared in the repo migrations directory. Three migs reference them
-- (00172_data_rights_janitor, 00174_identity_atoms, 00260_delete_and_
-- export_my_data) but only consume them — they never created them.
--
-- Root cause unknown — likely a hand-applied DDL on the live project or
-- a removed/abandoned migration. The schema is doctrinally clean
-- (data_deletion_log is append-only via atom_guard, both tables have
-- RLS self-read policies, FK chain to auth.users is correct).
--
-- This migration captures the live schema as a retroactive commit so:
-- - Fresh dev / staging environments get the tables when running
--   `supabase db reset` instead of erroring on the references.
-- - CI can apply the full migration sequence from scratch.
-- - The schema is now version-controlled.
--
-- Every CREATE uses IF NOT EXISTS so production (where the objects
-- already exist) is a no-op; only fresh environments materialize them.

-- =============================================================================
-- 1) Enums
-- =============================================================================
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'data_right_kind') THEN
    CREATE TYPE public.data_right_kind AS ENUM (
      'access', 'rectification', 'cancellation', 'opposition', 'portability'
    );
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'data_right_status') THEN
    CREATE TYPE public.data_right_status AS ENUM (
      'pending', 'executing', 'completed', 'failed'
    );
  END IF;
END $$;

-- =============================================================================
-- 2) data_subject_rights_requests
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.data_subject_rights_requests (
  id            uuid                      PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid                      NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  kind          public.data_right_kind    NOT NULL,
  status        public.data_right_status  NOT NULL DEFAULT 'pending',
  requested_at  timestamptz               NOT NULL DEFAULT now(),
  executed_at   timestamptz               NULL,
  payload       jsonb                     NOT NULL DEFAULT '{}'::jsonb,
  result        jsonb                     NULL,
  error_message text                      NULL,
  executor_id   uuid                      NULL REFERENCES auth.users(id)
);

COMMENT ON TABLE public.data_subject_rights_requests IS
  'GDPR-style data subject rights requests (access / rectification / cancellation / opposition / portability). Status workflow pending → executing → completed/failed. Per mig 00294 retroactive commit (table was created out-of-band; this captures the live schema).';

ALTER TABLE public.data_subject_rights_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS data_rights_self_read ON public.data_subject_rights_requests;
CREATE POLICY data_rights_self_read
  ON public.data_subject_rights_requests
  FOR SELECT
  USING (user_id = auth.uid());

-- =============================================================================
-- 3) data_deletion_log (append-only atom)
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.data_deletion_log (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid        NOT NULL,
  request_id   uuid        NULL REFERENCES public.data_subject_rights_requests(id) ON DELETE SET NULL,
  scope        text[]      NOT NULL,
  executed_at  timestamptz NOT NULL DEFAULT now(),
  evidence     jsonb       NOT NULL DEFAULT '{}'::jsonb
);

COMMENT ON TABLE public.data_deletion_log IS
  'Append-only audit of executed data deletions (GDPR right-to-erasure). Atom-guarded — INSERT only. Per mig 00294 retroactive commit.';

ALTER TABLE public.data_deletion_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS data_deletion_log_self_read ON public.data_deletion_log;
CREATE POLICY data_deletion_log_self_read
  ON public.data_deletion_log
  FOR SELECT
  USING (user_id = auth.uid());

-- =============================================================================
-- 4) data_deletion_log atom guard (append-only, doctrinal)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.data_deletion_log_atom_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'data_deletion_log is append-only (Atom). Use INSERT only.'
    USING errcode = 'check_violation';
END;
$$;

DROP TRIGGER IF EXISTS data_deletion_log_atom_guard_trg ON public.data_deletion_log;
CREATE TRIGGER data_deletion_log_atom_guard_trg
  BEFORE UPDATE OR DELETE ON public.data_deletion_log
  FOR EACH ROW EXECUTE FUNCTION public.data_deletion_log_atom_guard();

COMMENT ON FUNCTION public.data_deletion_log_atom_guard() IS
  'Full atom guard on data_deletion_log: any UPDATE or DELETE raises check_violation. Per Constitution §7 — deletion audit must be append-only. Mig 00294 retroactive.';
