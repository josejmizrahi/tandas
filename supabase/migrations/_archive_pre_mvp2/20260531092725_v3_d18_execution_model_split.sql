-- V3-D.18 FASE D
-- Split passed (decided) from executed (effects applied):
--   1. groups_decisions.executed_at timestamptz NULLABLE
--   2. groups_decisions.executed_by uuid → auth.users (who triggered exec)
--   3. groups_decisions.execution_mode text default 'auto' (auto|manual|secondary_approval)
--   4. groups_decisions.template_key text NULL (provenance from catalog)
--   5. CHECK status extend to include 'executed' (keep legacy 'closed')
--   6. finalize_vote: stops doing side effects; writes result + status='passed'/'rejected'.
--      Auto-execution carries on for execution_mode='auto' only (legacy default).
--   7. execute_decision(p_decision_id) SECDEF — gated by decisions.execute. Runs
--      the side-effect branches that used to live inside finalize_vote.
--      Emits decision.executed event + re-runs the engine.
--      resource branch: emits not_implemented in jsonb but does not raise (founder
--      doctrina: keep the door open for D.19 without breaking flow now).

ALTER TABLE public.group_decisions
  ADD COLUMN IF NOT EXISTS executed_at    timestamptz,
  ADD COLUMN IF NOT EXISTS executed_by    uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS execution_mode text NOT NULL DEFAULT 'auto',
  ADD COLUMN IF NOT EXISTS template_key   text REFERENCES public.decision_templates_catalog(template_key);

-- backfill: existing rows keep auto-execution semantics
UPDATE public.group_decisions SET execution_mode = 'auto' WHERE execution_mode IS NULL;

-- Extend status CHECK to include 'executed'. Keep legacy 'closed' alive
-- (compat with old data + iOS clients that may decode it).
ALTER TABLE public.group_decisions
  DROP CONSTRAINT IF EXISTS group_decisions_status_check;
ALTER TABLE public.group_decisions
  ADD  CONSTRAINT group_decisions_status_check CHECK (
    status = ANY (ARRAY[
      'draft','open','closed','passed','rejected','cancelled','executed'
    ])
  );

ALTER TABLE public.group_decisions
  DROP CONSTRAINT IF EXISTS group_decisions_execution_mode_check;
ALTER TABLE public.group_decisions
  ADD  CONSTRAINT group_decisions_execution_mode_check CHECK (
    execution_mode IN ('auto','manual','secondary_approval')
  );
