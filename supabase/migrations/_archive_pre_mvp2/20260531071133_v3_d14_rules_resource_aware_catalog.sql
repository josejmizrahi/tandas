-- V3 FASE D.14 — Mig A part 1: extend CHECK + insert atom/trigger/condition/consequence shapes
BEGIN;

-- 0) Extend category CHECK to admit 'atom'
ALTER TABLE public.rule_shapes_catalog
  DROP CONSTRAINT IF EXISTS rule_shapes_catalog_category_check;
ALTER TABLE public.rule_shapes_catalog
  ADD CONSTRAINT rule_shapes_catalog_category_check
  CHECK (category = ANY (ARRAY['trigger'::text, 'condition'::text, 'consequence'::text, 'atom'::text]));

-- 1) ATOM CATALOG
INSERT INTO public.rule_shapes_catalog (shape_key, category, display_name, description, schema, resource_types, metadata)
VALUES
  ('atom.resource.id','atom','ID del recurso','UUID del recurso involucrado en el evento',
   jsonb_build_object('atom_key','resource.id','atom_type','string'),
   ARRAY[]::text[],
   jsonb_build_object('source_table','group_resources','source_column','id','nullable',false)),
  ('atom.resource.type','atom','Tipo del recurso','Tipo canónico (asset, vehicle, fund, ...)',
   jsonb_build_object('atom_key','resource.type','atom_type','string'),
   ARRAY[]::text[],
   jsonb_build_object('source_table','group_resources','source_column','resource_type','nullable',false)),
  ('atom.resource.name','atom','Nombre del recurso','Etiqueta humana del recurso',
   jsonb_build_object('atom_key','resource.name','atom_type','string'),
   ARRAY[]::text[],
   jsonb_build_object('source_table','group_resources','source_column','name','nullable',false)),
  ('atom.resource.status','atom','Estado del recurso','Estado de ciclo',
   jsonb_build_object('atom_key','resource.status','atom_type','string'),
   ARRAY[]::text[],
   jsonb_build_object('source_table','group_resources','source_column','status','nullable',false)),
  ('atom.resource.owner_membership_id','atom','Owner del recurso','Membership dueña (si ownership_kind=individual)',
   jsonb_build_object('atom_key','resource.owner_membership_id','atom_type','string'),
   ARRAY[]::text[],
   jsonb_build_object('source_table','group_resources','source_column','owner_membership_id','nullable',true)),
  ('atom.resource.archived_at','atom','Fecha de archivado','Cuándo se archivó',
   jsonb_build_object('atom_key','resource.archived_at','atom_type','timestamp'),
   ARRAY[]::text[],
   jsonb_build_object('source_table','group_resources','source_column','archived_at','nullable',true)),
  ('atom.resource.unit','atom','Unidad','Unidad/moneda asociada',
   jsonb_build_object('atom_key','resource.unit','atom_type','string'),
   ARRAY[]::text[],
   jsonb_build_object('source_table','group_resources','source_column','unit','nullable',true)),
  ('atom.resource.lifecycle_state','atom','Estado de ciclo','Alias de resource.status',
   jsonb_build_object('atom_key','resource.lifecycle_state','atom_type','string'),
   ARRAY[]::text[],
   jsonb_build_object('source_table','group_resources','source_column','status','nullable',false)),
  ('atom.resource.value','atom','Valor del recurso','Valor monetario actual',
   jsonb_build_object('atom_key','resource.value','atom_type','number'),
   ARRAY['asset','vehicle','tool','inventory','real_estate','intellectual_property']::text[],
   jsonb_build_object('source_table','group_resource_assets','source_column','current_value','nullable',true)),
  ('atom.resource.condition','atom','Condición del recurso','good/damaged/repaired/...',
   jsonb_build_object('atom_key','resource.condition','atom_type','string'),
   ARRAY['asset','vehicle','tool','inventory','real_estate','intellectual_property']::text[],
   jsonb_build_object('source_table','group_resource_assets','source_column','condition','nullable',true)),
  ('atom.resource.custodian_membership_id','atom','Custodio del recurso','Membership con custodia actual',
   jsonb_build_object('atom_key','resource.custodian_membership_id','atom_type','string'),
   ARRAY['asset','vehicle','tool','inventory','real_estate','intellectual_property']::text[],
   jsonb_build_object('source_table','group_resource_assets','source_column','custodian_membership_id','nullable',true)),
  ('atom.resource.holder_membership_id','atom','Holder del derecho','Membership con derecho activo',
   jsonb_build_object('atom_key','resource.holder_membership_id','atom_type','string'),
   ARRAY['right']::text[],
   jsonb_build_object('source_table','group_resource_rights','source_column','holder_membership_id','nullable',true)),
  ('atom.resource.is_transferable','atom','Es transferible','Si el derecho se puede transferir',
   jsonb_build_object('atom_key','resource.is_transferable','atom_type','boolean'),
   ARRAY['right']::text[],
   jsonb_build_object('source_table','group_resource_rights','source_column','transferable','nullable',true)),
  ('atom.resource.slot_assignee','atom','Asignado del slot','Membership asignada al slot',
   jsonb_build_object('atom_key','resource.slot_assignee','atom_type','string'),
   ARRAY['slot']::text[],
   jsonb_build_object('source_table','group_resource_slots','source_column','assigned_membership_id','nullable',true)),
  ('atom.resource.threshold','atom','Umbral del fondo','Meta de capitalización del fondo',
   jsonb_build_object('atom_key','resource.threshold','atom_type','number'),
   ARRAY['fund']::text[],
   jsonb_build_object('source_table','group_resource_funds','source_column','threshold_target','nullable',true)),
  ('atom.resource.is_locked','atom','Fondo bloqueado','Derivado de locked_at IS NOT NULL',
   jsonb_build_object('atom_key','resource.is_locked','atom_type','boolean'),
   ARRAY['fund']::text[],
   jsonb_build_object('source_table','group_resource_funds','source_column','locked_at','nullable',true,'derivation','locked_at IS NOT NULL'))
ON CONFLICT (shape_key) DO UPDATE
  SET category=EXCLUDED.category, display_name=EXCLUDED.display_name,
      description=EXCLUDED.description, schema=EXCLUDED.schema,
      resource_types=EXCLUDED.resource_types, metadata=EXCLUDED.metadata;

-- 2) RESOURCE TRIGGERS (10)
INSERT INTO public.rule_shapes_catalog (shape_key, category, display_name, description, schema, resource_types, metadata)
VALUES
  ('trigger.resource.created','trigger','Cuando se crea un recurso',NULL,
   jsonb_build_object('scope','group','event_type','resource.created',
     'payload_keys',jsonb_build_array('resource_type','ownership_kind','visibility'),
     'compatible_conditions',jsonb_build_array('condition.actor_role_in','condition.resource_compare'),
     'compatible_consequences',jsonb_build_array('consequence.send_notification','consequence.start_vote',
       'consequence.update_resource_value','consequence.lock_resource','consequence.unlock_resource')),
   ARRAY[]::text[], jsonb_build_object('icon','plus.app')),
  ('trigger.resource.archived','trigger','Cuando se archiva un recurso',NULL,
   jsonb_build_object('scope','group','event_type','resource.archived',
     'payload_keys',jsonb_build_array('reason'),
     'compatible_conditions',jsonb_build_array('condition.actor_role_in','condition.resource_compare'),
     'compatible_consequences',jsonb_build_array('consequence.send_notification','consequence.start_vote')),
   ARRAY[]::text[], jsonb_build_object('icon','archivebox')),
  ('trigger.resource.assigned','trigger','Cuando se asigna un recurso',NULL,
   jsonb_build_object('scope','group','event_type','resource.assigned',
     'payload_keys',jsonb_build_array('role','membership_id','previous_membership_id','subtype','reason'),
     'compatible_conditions',jsonb_build_array('condition.actor_role_in','condition.resource_compare'),
     'compatible_consequences',jsonb_build_array('consequence.send_notification','consequence.start_vote',
       'consequence.lock_resource','consequence.unlock_resource')),
   ARRAY[]::text[], jsonb_build_object('icon','person.crop.rectangle.badge.plus')),
  ('trigger.resource.returned','trigger','Cuando se devuelve un recurso',NULL,
   jsonb_build_object('scope','group','event_type','resource.returned',
     'payload_keys',jsonb_build_array('role','previous_membership_id','subtype','reason'),
     'compatible_conditions',jsonb_build_array('condition.actor_role_in','condition.resource_compare'),
     'compatible_consequences',jsonb_build_array('consequence.send_notification','consequence.update_resource_value')),
   ARRAY[]::text[], jsonb_build_object('icon','arrow.uturn.left.circle')),
  ('trigger.resource.used','trigger','Cuando se usa un recurso',NULL,
   jsonb_build_object('scope','member','event_type','resource.used',
     'payload_keys',jsonb_build_array('membership_id','client_id'),
     'compatible_conditions',jsonb_build_array('condition.actor_role_in','condition.resource_compare'),
     'compatible_consequences',jsonb_build_array('consequence.send_notification','consequence.create_pool_charge','consequence.start_vote')),
   ARRAY[]::text[], jsonb_build_object('icon','hand.tap')),
  ('trigger.resource.damaged','trigger','Cuando se reporta un recurso dañado',NULL,
   jsonb_build_object('scope','group','event_type','resource.damaged',
     'payload_keys',jsonb_build_array('from','to','reason','subtype'),
     'compatible_conditions',jsonb_build_array('condition.actor_role_in','condition.resource_compare'),
     'compatible_consequences',jsonb_build_array('consequence.send_notification','consequence.issue_sanction',
       'consequence.create_pool_charge','consequence.start_vote',
       'consequence.lock_resource','consequence.update_resource_value')),
   ARRAY['asset','vehicle','tool','inventory','real_estate']::text[],
   jsonb_build_object('icon','exclamationmark.triangle')),
  ('trigger.resource.repaired','trigger','Cuando se repara un recurso',NULL,
   jsonb_build_object('scope','group','event_type','resource.repaired',
     'payload_keys',jsonb_build_array('from','to','reason','subtype'),
     'compatible_conditions',jsonb_build_array('condition.actor_role_in','condition.resource_compare'),
     'compatible_consequences',jsonb_build_array('consequence.send_notification','consequence.unlock_resource','consequence.update_resource_value')),
   ARRAY['asset','vehicle','tool','inventory','real_estate']::text[],
   jsonb_build_object('icon','wrench.and.screwdriver')),
  ('trigger.resource.status_changed','trigger','Cuando cambia el estado del recurso',NULL,
   jsonb_build_object('scope','group','event_type','resource.status_changed',
     'payload_keys',jsonb_build_array('from','to','reason','subtype'),
     'compatible_conditions',jsonb_build_array('condition.actor_role_in','condition.resource_compare'),
     'compatible_consequences',jsonb_build_array('consequence.send_notification','consequence.start_vote',
       'consequence.lock_resource','consequence.unlock_resource')),
   ARRAY[]::text[], jsonb_build_object('icon','arrow.triangle.swap')),
  ('trigger.resource.value_updated','trigger','Cuando se actualiza el valor del recurso',NULL,
   jsonb_build_object('scope','group','event_type','resource.value_updated',
     'payload_keys',jsonb_build_array('value','unit','basis','resource_type'),
     'compatible_conditions',jsonb_build_array('condition.actor_role_in','condition.resource_compare','condition.amount_above','condition.amount_between'),
     'compatible_consequences',jsonb_build_array('consequence.send_notification','consequence.start_vote','consequence.lock_resource')),
   ARRAY['asset','vehicle','tool','inventory','real_estate','intellectual_property']::text[],
   jsonb_build_object('icon','chart.line.uptrend.xyaxis')),
  ('trigger.resource.transferred','trigger','Cuando se transfiere un recurso',NULL,
   jsonb_build_object('scope','group','event_type','resource.transferred',
     'payload_keys',jsonb_build_array('role','from_membership_id','to_membership_id','reason','subtype'),
     'compatible_conditions',jsonb_build_array('condition.actor_role_in','condition.resource_compare'),
     'compatible_consequences',jsonb_build_array('consequence.send_notification','consequence.start_vote','consequence.update_resource_value')),
   ARRAY['right']::text[], jsonb_build_object('icon','arrow.left.arrow.right'))
ON CONFLICT (shape_key) DO UPDATE
  SET category=EXCLUDED.category, display_name=EXCLUDED.display_name,
      description=EXCLUDED.description, schema=EXCLUDED.schema,
      resource_types=EXCLUDED.resource_types, metadata=EXCLUDED.metadata;

-- 3) RESOURCE CONDITION (mini-AST)
INSERT INTO public.rule_shapes_catalog (shape_key, category, display_name, description, schema, resource_types, metadata)
VALUES
  ('condition.resource_compare','condition','Comparar atom del recurso',NULL,
   jsonb_build_object('kind','resource_compare',
     'fields',jsonb_build_array(
       jsonb_build_object('key','atom','type','string','label','Atom (resource.*)','required',true),
       jsonb_build_object('key','op','type','enum','label','Operador',
                          'enum',jsonb_build_array('=','!=','>','<','>=','<='),
                          'required',true),
       jsonb_build_object('key','value','type','string','label','Valor de comparación','required',true))),
   ARRAY[]::text[],
   jsonb_build_object('supports_ops',jsonb_build_array('=','!=','>','<','>=','<=')))
ON CONFLICT (shape_key) DO UPDATE
  SET category=EXCLUDED.category, display_name=EXCLUDED.display_name,
      description=EXCLUDED.description, schema=EXCLUDED.schema,
      resource_types=EXCLUDED.resource_types, metadata=EXCLUDED.metadata;

-- 4) RESOURCE CONSEQUENCES (4)
INSERT INTO public.rule_shapes_catalog (shape_key, category, display_name, description, schema, resource_types, metadata)
VALUES
  ('consequence.lock_resource','consequence','Bloquear recurso','Hoy soportado para fondos',
   jsonb_build_object('action','lock_resource',
     'fields',jsonb_build_array(jsonb_build_object('key','reason','type','string','label','Razón','required',false)),
     'execution','sync','authority_required','funds.lock'),
   ARRAY['fund']::text[], jsonb_build_object('icon','lock')),
  ('consequence.unlock_resource','consequence','Desbloquear recurso','Hoy soportado para fondos',
   jsonb_build_object('action','unlock_resource',
     'fields',jsonb_build_array(jsonb_build_object('key','reason','type','string','label','Razón','required',false)),
     'execution','sync','authority_required','funds.unlock'),
   ARRAY['fund']::text[], jsonb_build_object('icon','lock.open')),
  ('consequence.update_resource_value','consequence','Actualizar valor del recurso',NULL,
   jsonb_build_object('action','update_resource_value',
     'fields',jsonb_build_array(
       jsonb_build_object('key','value','type','number','min',0,'label','Nuevo valor','required',true),
       jsonb_build_object('key','unit','type','string','label','Unidad','default','MXN','required',true),
       jsonb_build_object('key','basis','type','string','label','Base/metodología','required',false)),
     'execution','sync','authority_required','resources.update_value'),
   ARRAY['asset','vehicle','tool','inventory','real_estate','intellectual_property']::text[],
   jsonb_build_object('icon','dollarsign.arrow.circlepath')),
  ('consequence.transfer_resource','consequence','Transferir recurso','Hoy soportado para derechos',
   jsonb_build_object('action','transfer_resource',
     'fields',jsonb_build_array(
       jsonb_build_object('key','to_membership_id','type','string','label','Membership destino','required',true),
       jsonb_build_object('key','reason','type','string','label','Razón','required',false)),
     'execution','sync','authority_required','rights.transfer'),
   ARRAY['right']::text[], jsonb_build_object('icon','arrow.left.arrow.right.circle'))
ON CONFLICT (shape_key) DO UPDATE
  SET category=EXCLUDED.category, display_name=EXCLUDED.display_name,
      description=EXCLUDED.description, schema=EXCLUDED.schema,
      resource_types=EXCLUDED.resource_types, metadata=EXCLUDED.metadata;

-- 5) Extend consequence.send_notification audience enum (target/owner/custodian/holder)
UPDATE public.rule_shapes_catalog
SET schema = jsonb_set(
  schema, '{fields}',
  (SELECT jsonb_agg(
     CASE WHEN f->>'key'='audience'
       THEN jsonb_set(f,'{enum}',jsonb_build_array('actor','admins','group','target','owner','custodian','holder'))
       ELSE f
     END)
   FROM jsonb_array_elements(schema->'fields') f))
WHERE shape_key='consequence.send_notification';

COMMIT;
