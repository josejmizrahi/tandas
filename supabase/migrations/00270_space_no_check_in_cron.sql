-- 00270 — Schedule emit-space-no-check-in-events cron (every 5 minutes).
--
-- Plans/Active/SpaceRules.md PR-2. Mirror del schedule pattern usado por
-- `emit-asset-overdue-events-5min`. La función edge (deployed en mig
-- 00269's companion deploy step) hace dedup interno con ventana 24h.
--
-- Cron payload: POST con `{}` body. La anon JWT viaja en Authorization
-- header — supabase functions con verify_jwt=true requieren un JWT
-- válido para autorizar; usamos anon role (la lógica SECURITY DEFINER
-- de service_role vive en el supabase client init dentro del handler
-- via SUPABASE_SERVICE_ROLE_KEY env).
--
-- El bearer token de abajo es el mismo que usa
-- `emit-asset-overdue-events-5min` (mismo proyecto, mismo anon JWT
-- canónico). NO es un secret — es la public anon key. Si rota, ambos
-- crons rotan en paralelo.

select cron.schedule(
  'emit-space-no-check-in-events-5min',
  '*/5 * * * *',
  $$
  select net.http_post(
    url := 'https://fpfvlrwcskhgsjuhrjpz.supabase.co/functions/v1/emit-space-no-check-in-events',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZwZnZscndjc2toZ3NqdWhyanB6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc1MTU4NTIsImV4cCI6MjA5MzA5MTg1Mn0.Cy5fWfdPv1cqhPdy2UTI-cY7eApnG9UPoBv94EkGGBc'
    ),
    body := '{}'::jsonb
  );
  $$
);
