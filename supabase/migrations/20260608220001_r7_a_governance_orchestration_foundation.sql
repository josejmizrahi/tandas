-- R.7.A — Governance Orchestration Engine: evolución sobre R.5 base shipped
-- Doctrine: Plans/Active/R7_GovernanceOrchestrationEngine.md (camino A firmado 2026-06-08)
-- Preserva: governance_actions, governance_policies, request_governed_action,
--           _governance_action_approved, _governance_action_policy_key (firma)
-- DoD: gaps en governance_actions + nuevo catalog declarativo + seed v1 con aliases legacy
-- Smoke target: _smoke_r5_governance() sigue verde.

-- §1 — Gaps en governance_actions (idempotency + result + error + failed status)
alter table public.governance_actions
  add column if not exists idempotency_key text,
  add column if not exists client_id text,
  add column if not exists error_message text,
  add column if not exists result jsonb;

create unique index if not exists governance_actions_idempotency_key_uniq
  on public.governance_actions (idempotency_key)
  where idempotency_key is not null;

-- Agregar 'failed' al status CHECK (R.5 enum no lo incluía)
alter table public.governance_actions
  drop constraint if exists governance_actions_status_check;

alter table public.governance_actions
  add constraint governance_actions_status_check
  check (status in (
    'not_required',
    'proposed',
    'approved',
    'rejected',
    'executed',
    'cancelled',
    'failed'
  ));

-- §2 — Catálogo declarativo nuevo
create table if not exists public.governance_action_catalog (
  action_key text primary key,
  display_name text not null,
  domain text not null,
  default_requires_decision boolean not null default false,
  policy_key text,
  execution_rpc text,
  push_supported boolean not null default false,
  dangerous boolean not null default false,
  request_permission text references public.permission_catalog(permission_key),
  vote_permission text references public.permission_catalog(permission_key),
  execute_permission text references public.permission_catalog(permission_key),
  legacy_aliases text[] not null default '{}',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.governance_action_catalog is
  'R.7 — Catálogo declarativo de acciones gobernables. Defaults globales que governance_policies (per-context) pueden overridear. NO es fuente UI (available_actions[] sigue siéndolo). NO reemplaza _governance_action_approved (PULL) — lo complementa con metadata para PUSH opt-in y resolución de aliases.';

comment on column public.governance_action_catalog.execution_rpc is
  'Nullable. Solo requerido si push_supported=true. PULL no lo consume.';

comment on column public.governance_action_catalog.legacy_aliases is
  'Array de action_keys snake_case heredados de R.5 (remove_member, member_ban, etc.). request_governance_action resuelve aliases → canonical.';

create index if not exists governance_action_catalog_domain_idx
  on public.governance_action_catalog (domain);

create index if not exists governance_action_catalog_aliases_idx
  on public.governance_action_catalog using gin (legacy_aliases);

-- RLS lectura abierta a authenticated (descriptor F.2X lo consume)
alter table public.governance_action_catalog enable row level security;

drop policy if exists governance_action_catalog_read_all on public.governance_action_catalog;
create policy governance_action_catalog_read_all
  on public.governance_action_catalog
  for select
  to authenticated
  using (true);

-- updated_at trigger
create or replace function public._governance_action_catalog_touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists governance_action_catalog_touch_updated_at on public.governance_action_catalog;
create trigger governance_action_catalog_touch_updated_at
  before update on public.governance_action_catalog
  for each row execute function public._governance_action_catalog_touch_updated_at();

-- §3 — Seed catalog v1 (8 acciones canonical + 4 alias-only rows para R.5 legacy)
-- Idempotente: on conflict (action_key) do update.

insert into public.governance_action_catalog (
  action_key, display_name, domain, default_requires_decision,
  policy_key, execution_rpc, push_supported, dangerous,
  legacy_aliases, metadata
) values
  ('member.remove',
   'Remover miembro',
   'membership',
   true,
   'member_ban_requires_vote',
   'remove_member',
   false,
   true,
   array['remove_member'],
   jsonb_build_object(
     'description', 'Saca a un miembro del contexto. NO es ban.',
     'r7_notes', 'push_supported=false porque remove_member ya consume _governance_action_approved (modelo PULL). PUSH duplicaría.'
   )),

  ('member.pause',
   'Pausar miembro',
   'membership',
   true,
   'member_pause_requires_vote',
   null,
   false,
   true,
   array[]::text[],
   jsonb_build_object(
     'description', 'Suspende temporalmente a un miembro (estado paused).',
     'r7_notes', 'execution_rpc TBD — no existe set_membership_state aún. Catalog row creado para policy lookup.'
   )),

  ('member.promote',
   'Promover a admin',
   'membership',
   true,
   'member_promote_requires_vote',
   'assign_role',
   true,
   false,
   array[]::text[],
   jsonb_build_object(
     'description', 'Promueve a un miembro a role admin.',
     'role_key', 'admin',
     'r7c_notes', 'execution_rpc assign_role con p_role_key=admin.'
   )),

  ('resource.archive',
   'Archivar recurso',
   'resources',
   false,
   'resource_archive_requires_vote',
   'archive_resource',
   true,
   false,
   array[]::text[],
   jsonb_build_object(
     'description', 'Marca el recurso como archivado.',
     'r7_notes', 'default_requires_decision=false: archivar no es destructivo per se.'
   )),

  ('resource.transfer',
   'Transferir recurso',
   'resources',
   true,
   'resource_transfer_requires_vote',
   null,
   false,
   true,
   array['resource_transfer'],
   jsonb_build_object(
     'description', 'Cambia el propietario canónico de un recurso.',
     'r7c_notes', 'execution_rpc TBD — update_resource NO acepta canonical_owner_actor_id. Requiere transfer_resource_ownership() en R.7.x.'
   )),

  ('fine.create',
   'Crear multa',
   'money',
   true,
   'fine_create_requires_vote',
   'record_fine',
   true,
   false,
   array[]::text[],
   jsonb_build_object(
     'description', 'Crea una multa que requiere aprobación colectiva.',
     'r7c_notes', 'execution_rpc record_fine (p_context_actor_id, p_debtor_actor_id, p_amount, p_currency, p_reason).'
   )),

  ('rule.create',
   'Crear regla',
   'rules',
   true,
   'rule_create_requires_vote',
   'create_rule',
   true,
   false,
   array[]::text[],
   jsonb_build_object(
     'description', 'Publica una regla nueva en el contexto.',
     'r7c_notes', 'create_rule activa la regla por default — semánticamente publish.'
   )),

  ('rule.archive',
   'Archivar regla',
   'rules',
   true,
   'rule_change_requires_vote',
   null,
   false,
   false,
   array['rule_change'],
   jsonb_build_object(
     'description', 'Archiva una regla activa.',
     'r7c_notes', 'execution_rpc TBD — no existe archive_rule. rules.archived_at sí existe; falta RPC público.'
   ))
on conflict (action_key) do update set
  display_name = excluded.display_name,
  domain = excluded.domain,
  default_requires_decision = excluded.default_requires_decision,
  policy_key = excluded.policy_key,
  execution_rpc = excluded.execution_rpc,
  push_supported = excluded.push_supported,
  dangerous = excluded.dangerous,
  legacy_aliases = excluded.legacy_aliases,
  metadata = excluded.metadata,
  updated_at = now();

-- 3.2 — Alias-only rows para R.5 legacy action_keys (resolución policy_key)
insert into public.governance_action_catalog (
  action_key, display_name, domain, default_requires_decision,
  policy_key, execution_rpc, push_supported, dangerous,
  legacy_aliases, metadata
) values
  ('member.ban',
   'Banear miembro',
   'membership',
   true,
   'member_ban_requires_vote',
   null,
   false,
   true,
   array['ban_member', 'member_ban'],
   jsonb_build_object(
     'description', 'Bloquea a un miembro definitivamente.',
     'r7_notes', 'Catalog row legacy R.5. execution_rpc TBD — necesita set_membership_state(banned). NO confundir con member.remove.'
   )),

  ('resource.sale',
   'Vender recurso',
   'resources',
   true,
   'resource_transfer_requires_vote',
   null,
   false,
   true,
   array['resource_sale'],
   jsonb_build_object(
     'description', 'Vende un recurso (compuesto: archive + money intent).',
     'r7_notes', 'Catalog row legacy R.5. PUSH no soportado — compuesto.'
   )),

  ('expense.large',
   'Gasto grande',
   'money',
   true,
   'large_expense_requires_vote',
   null,
   false,
   false,
   array['large_expense'],
   jsonb_build_object(
     'description', 'Gasto que supera el umbral del contexto.',
     'r7_notes', 'Catalog row legacy R.5. policy_key heredado.'
   )),

  ('ownership.change',
   'Cambio de propiedad',
   'governance',
   true,
   'ownership_change_requires_vote',
   null,
   false,
   true,
   array['ownership_change'],
   jsonb_build_object(
     'description', 'Cambio en la estructura de propiedad del contexto.',
     'r7_notes', 'Catalog row legacy R.5. policy_key heredado.'
   ))
on conflict (action_key) do update set
  display_name = excluded.display_name,
  domain = excluded.domain,
  default_requires_decision = excluded.default_requires_decision,
  policy_key = excluded.policy_key,
  execution_rpc = excluded.execution_rpc,
  push_supported = excluded.push_supported,
  dangerous = excluded.dangerous,
  legacy_aliases = excluded.legacy_aliases,
  metadata = excluded.metadata,
  updated_at = now();
