-- Fase D follow-up: right_kind CHECK constraint matching iOS whitelist.

ALTER TABLE public.group_resource_rights
  ADD CONSTRAINT group_resource_rights_right_kind_check
  CHECK (right_kind IS NULL OR right_kind IN ('access','membership','seat','benefit','other'));

COMMENT ON CONSTRAINT group_resource_rights_right_kind_check
  ON public.group_resource_rights IS
'Mirrors the iOS ResourceRightKind whitelist (access/membership/seat/benefit/other). NULL allowed during transitional states.';
