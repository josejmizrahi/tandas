-- ============================================================================
-- AUDIT.3 — Columnas de auditoría en tablas hijas mutables (2026-06-11)
-- ============================================================================
-- Origen: Plans/Active/SupabaseArchitectureAudit.md §11.4. Tablas hijas con
-- estado mutable carecían de created_at/updated_at:
--   · event_participants  (status RSVP/check-in muta)        → +created_at +updated_at
--   · settlement_items    (handshake pending→…→paid muta)    → +created_at +updated_at
--   · decision_options    (status muta; ya tenía created_at) → +updated_at
--   · decision_votes      (upsert de re-voto; voted_at es el created_at
--                          semántico y se conserva canónico) → +updated_at
--   · money_splits        (inmutable, pero sin timestamp)    → +created_at
-- CAVEAT documentado: los rows preexistentes quedan estampados con la fecha de
-- esta migración (default now()); la fecha histórica real vive en
-- activity_events. iOS decodifica por claves conocidas: columnas nuevas son
-- invisibles para el frontend.
-- Touch triggers: reutilizan public.touch_updated_at() (convención del repo).
-- Rollback: drop trigger + drop column de cada adición.
-- ============================================================================

-- event_participants
alter table public.event_participants
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now();

drop trigger if exists trg_event_participants_touch on public.event_participants;
create trigger trg_event_participants_touch
  before update on public.event_participants
  for each row execute function public.touch_updated_at();

-- settlement_items
alter table public.settlement_items
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now();

drop trigger if exists trg_settlement_items_touch on public.settlement_items;
create trigger trg_settlement_items_touch
  before update on public.settlement_items
  for each row execute function public.touch_updated_at();

-- decision_options
alter table public.decision_options
  add column if not exists updated_at timestamptz not null default now();

drop trigger if exists trg_decision_options_touch on public.decision_options;
create trigger trg_decision_options_touch
  before update on public.decision_options
  for each row execute function public.touch_updated_at();

-- decision_votes (voted_at sigue siendo el timestamp canónico de creación)
alter table public.decision_votes
  add column if not exists updated_at timestamptz not null default now();

drop trigger if exists trg_decision_votes_touch on public.decision_votes;
create trigger trg_decision_votes_touch
  before update on public.decision_votes
  for each row execute function public.touch_updated_at();

-- money_splits (filas inmutables: solo created_at)
alter table public.money_splits
  add column if not exists created_at timestamptz not null default now();

comment on column public.event_participants.created_at is
  'AUDIT.3: rows previos a 2026-06-11 estampados con la fecha de la migración; historia real en activity_events.';
comment on column public.settlement_items.created_at is
  'AUDIT.3: rows previos a 2026-06-11 estampados con la fecha de la migración; historia real en activity_events.';
comment on column public.money_splits.created_at is
  'AUDIT.3: rows previos a 2026-06-11 estampados con la fecha de la migración; historia real en activity_events.';
