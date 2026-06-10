-- R.9.F — Replay repair: eliminar overload 9-arg de create_resource.
--
-- Historia: f_resource_4 (20260604140001) dropeó el 8-arg y creó el 9-arg.
-- La migración `subtype_picker_create_resource_accepts_subtype` (aplicada a
-- live vía MCP, NUNCA aterrizó en disco) dropeó el 9-arg en live y creó un
-- 10-arg roto; el fix en disco (20260608110000) dropea ese 10-arg (no-op en
-- replay) y crea el 10-arg bueno — pero en un replay desde cero el 9-arg
-- sigue vivo, y 9-arg + 10-arg = "function create_resource(...) is not
-- unique" (42725) para todas las llamadas antiguas de los smokes.
--
-- En live este DROP es no-op (el 9-arg ya no existe). En replay deja el
-- 10-arg (p_subtype_key default null) como única firma — superset compatible.

drop function if exists public.create_resource(
  uuid, text, text, text, numeric, text, jsonb, text, text
);
