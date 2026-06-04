
-- Drop the legacy 8-arg overload that lingered after R.4B added a 9th arg.
-- The 9-arg overload (with p_template_key default null) is fully back-compat:
-- any caller omitting the new arg still works.
drop function if exists public.create_decision(uuid, text, text, text, timestamptz, jsonb, text, text);
