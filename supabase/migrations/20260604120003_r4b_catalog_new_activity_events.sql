
-- R.4B: catalogue activity events emitted by template-driven execute_decision.
insert into public.activity_event_catalog
  (event_type, domain, description, expected_subject_type, expected_payload_schema, is_system_generated)
values
  ('rule.archived', 'rule', 'Se archivó una regla', 'rule', '{}'::jsonb, false),
  ('resource.right_granted', 'resource', 'Se otorgó un derecho sobre un recurso', 'resource_right', '{}'::jsonb, false)
on conflict (event_type) do nothing;
