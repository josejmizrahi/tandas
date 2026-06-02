-- §16. RLS helpers + enables
create or replace function public.is_group_member(p_group_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.group_memberships gm
    where gm.group_id = p_group_id
      and gm.user_id  = (select auth.uid())
      and gm.status   = 'active'
  );
$$;

create or replace function public.has_group_permission(p_group_id uuid, p_permission text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.group_memberships gm
    join public.group_member_roles gmr on gmr.membership_id = gm.id
    join public.group_role_permissions grp on grp.role_id   = gmr.role_id
    where gm.group_id      = p_group_id
      and gm.user_id       = (select auth.uid())
      and gm.status        = 'active'
      and grp.permission_key = p_permission
  );
$$;

alter table public.profiles                       enable row level security;
alter table public.groups                         enable row level security;
alter table public.group_purposes                 enable row level security;
alter table public.group_memberships              enable row level security;
alter table public.group_membership_events        enable row level security;
alter table public.permissions                    enable row level security;
alter table public.group_roles                    enable row level security;
alter table public.group_role_permissions         enable row level security;
alter table public.group_member_roles             enable row level security;
alter table public.group_mandates                 enable row level security;
alter table public.rule_shapes_catalog            enable row level security;
alter table public.group_rules                    enable row level security;
alter table public.group_rule_versions            enable row level security;
alter table public.group_rule_evaluations         enable row level security;
alter table public.group_resources                enable row level security;
alter table public.group_resource_events          enable row level security;
alter table public.group_resource_funds           enable row level security;
alter table public.group_resource_slots           enable row level security;
alter table public.group_resource_spaces          enable row level security;
alter table public.group_resource_assets          enable row level security;
alter table public.group_resource_asset_valuations enable row level security;
alter table public.group_resource_rights          enable row level security;
alter table public.group_resource_capabilities    enable row level security;
alter table public.group_resource_series          enable row level security;
alter table public.group_resource_bookings        enable row level security;
alter table public.group_rsvp_actions             enable row level security;
alter table public.group_check_in_actions         enable row level security;
alter table public.group_resource_transactions    enable row level security;
alter table public.group_obligations              enable row level security;
alter table public.group_settlements              enable row level security;
alter table public.group_settlement_obligations   enable row level security;
alter table public.group_contributions            enable row level security;
alter table public.group_decisions                enable row level security;
alter table public.group_decision_options         enable row level security;
alter table public.group_votes                    enable row level security;
alter table public.group_sanctions                enable row level security;
alter table public.group_disputes                 enable row level security;
alter table public.group_dispute_events           enable row level security;
alter table public.group_reputation_events        enable row level security;
alter table public.group_cultural_norms           enable row level security;
alter table public.group_dissolutions             enable row level security;
alter table public.group_events                   enable row level security;
alter table public.group_invites                  enable row level security;
alter table public.notification_tokens            enable row level security;
alter table public.notification_preferences       enable row level security;
alter table public.notifications_outbox           enable row level security;

-- §17. Seeds — permissions catalog
insert into public.permissions (key, description, category) values
  ('group.read',           'Ver el grupo',                 'group'),
  ('group.update',         'Editar información del grupo', 'group'),
  ('group.archive',        'Archivar el grupo',            'group'),
  ('group.dissolve',       'Proponer/aprobar disolución',  'group'),
  ('purpose.set',          'Editar el propósito del grupo','group'),
  ('members.read',         'Ver miembros',                 'members'),
  ('members.invite',       'Invitar miembros',             'members'),
  ('members.update',       'Editar membresías',            'members'),
  ('members.remove',       'Remover miembros',             'members'),
  ('members.suspend',      'Suspender miembros',           'members'),
  ('roles.manage',         'Gestionar roles y permisos',   'roles'),
  ('mandates.grant',       'Otorgar mandatos',             'roles'),
  ('mandates.revoke',      'Revocar mandatos',             'roles'),
  ('rules.read',           'Ver reglas',                   'rules'),
  ('rules.create',         'Crear reglas',                 'rules'),
  ('rules.update',         'Editar reglas',                'rules'),
  ('rules.publish',        'Publicar versión de regla',    'rules'),
  ('rules.archive',        'Archivar reglas',              'rules'),
  ('resources.read',       'Ver recursos',                 'resources'),
  ('resources.create',     'Crear recursos',               'resources'),
  ('resources.update',     'Editar recursos',              'resources'),
  ('resources.transfer',   'Transferir propiedad',         'resources'),
  ('resources.archive',    'Archivar recursos',            'resources'),
  ('bookings.create',      'Reservar recursos',            'resources'),
  ('bookings.cancel',      'Cancelar reservas',            'resources'),
  ('rsvp.submit',          'Responder RSVP',               'resources'),
  ('check_in.submit',      'Hacer check-in',               'resources'),
  ('expense.record',       'Registrar gasto',              'money'),
  ('contribution.record',  'Registrar contribución',       'money'),
  ('settlement.record',    'Registrar pago/settlement',    'money'),
  ('payout.record',        'Registrar payout',             'money'),
  ('pool_charge.record',   'Crear cuota / pool charge',    'money'),
  ('decisions.create',     'Abrir decisiones',             'decisions'),
  ('decisions.vote',       'Votar',                        'decisions'),
  ('decisions.resolve',    'Cerrar / finalizar decisiones','decisions'),
  ('sanctions.create',     'Emitir sanciones',             'sanctions'),
  ('sanctions.update',     'Modificar sanciones',          'sanctions'),
  ('sanctions.dispute',    'Disputar sanciones',           'sanctions'),
  ('disputes.open',        'Abrir disputas',               'disputes'),
  ('disputes.mediate',     'Mediar disputas',              'disputes'),
  ('disputes.resolve',     'Resolver disputas',            'disputes'),
  ('reputation.record',    'Registrar evento de reputación','reputation'),
  ('culture.propose',      'Proponer norma cultural',      'culture'),
  ('culture.endorse',      'Endorsar norma cultural',      'culture'),
  ('records.read',         'Ver registros internos',       'audit')
on conflict (key) do nothing;

-- §19. create_group atomic RPC
create or replace function public.create_group(
  p_name             text,
  p_slug             text default null,
  p_category         text default null,
  p_purpose_declared text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id        uuid;
  v_membership_id   uuid;
  v_founder_role_id uuid;
  v_member_role_id  uuid;
begin
  insert into public.groups (name, slug, category, created_by, purpose_summary)
  values (p_name, p_slug, p_category, auth.uid(), p_purpose_declared)
  returning id into v_group_id;

  insert into public.group_memberships (group_id, user_id, status, membership_type, joined_at, joined_via)
  values (v_group_id, auth.uid(), 'active', 'member', now(), 'founder_seed')
  returning id into v_membership_id;

  insert into public.group_membership_events (group_id, membership_id, actor_user_id, event_type, reason)
  values (v_group_id, v_membership_id, auth.uid(), 'joined', 'founder_seed');

  insert into public.group_roles (group_id, key, name, description, is_system, is_default) values
    (v_group_id, 'founder', 'Fundador',    'Autoridad fundacional', true, false),
    (v_group_id, 'admin',   'Administrador','Gestión operativa',     true, false),
    (v_group_id, 'member',  'Miembro',     'Pertenencia plena',     true, true)
  on conflict do nothing;

  select id into v_founder_role_id from public.group_roles where group_id = v_group_id and key = 'founder';
  select id into v_member_role_id  from public.group_roles where group_id = v_group_id and key = 'member';

  insert into public.group_role_permissions (role_id, permission_key)
  select v_founder_role_id, key from public.permissions
  on conflict do nothing;

  insert into public.group_role_permissions (role_id, permission_key) values
    (v_member_role_id, 'group.read'),
    (v_member_role_id, 'members.read'),
    (v_member_role_id, 'rules.read'),
    (v_member_role_id, 'resources.read'),
    (v_member_role_id, 'rsvp.submit'),
    (v_member_role_id, 'check_in.submit'),
    (v_member_role_id, 'expense.record'),
    (v_member_role_id, 'contribution.record'),
    (v_member_role_id, 'settlement.record'),
    (v_member_role_id, 'decisions.vote'),
    (v_member_role_id, 'disputes.open'),
    (v_member_role_id, 'records.read')
  on conflict do nothing;

  insert into public.group_member_roles (membership_id, role_id, assigned_by)
  values (v_membership_id, v_founder_role_id, auth.uid());

  if p_purpose_declared is not null and length(p_purpose_declared) > 0 then
    insert into public.group_purposes (group_id, kind, body, created_by)
    values (v_group_id, 'declared', p_purpose_declared, auth.uid());
  end if;

  insert into public.group_events (group_id, actor_user_id, event_type, entity_kind, entity_id, summary)
  values (v_group_id, auth.uid(), 'group.created', 'group', v_group_id, 'Grupo creado');

  return v_group_id;
end;
$$;
