# APNs Deploy Recipe — Día 2-3 del sprint APNs

> Pasos para llevar `dispatch-notifications` de código en repo a push real
> en device de prueba. Asume que las creds Apple ya están listas (key
> nueva uploaded como `APNS_AUTH_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`,
> `APNS_BUNDLE_ID` cargados en Supabase) y que el target Xcode tiene
> Push Notifications + Background Modes (Remote notifications) habilitados.

---

## 1. Verificar env vars en Supabase Dashboard

Project Settings → Edge Functions → Secrets. Confirmar que existen:

```
APNS_AUTH_KEY      = (PEM completo del .p8 nuevo, con BEGIN/END)
APNS_KEY_ID        = (10 chars, p.ej. ABC123DEFG)
APNS_TEAM_ID       = (10 chars, p.ej. ABCDE12345)
APNS_BUNDLE_ID     = com.josejmizrahi.ruul   (o el bundle real)
APNS_USE_SANDBOX   = true                    (Xcode debug = sandbox)
DISPATCH_BATCH_LIMIT = 100                   (opcional, default 100)
```

`APNS_USE_SANDBOX=true` es requerido para builds de Xcode/TestFlight (Apple
los firma para el endpoint sandbox). En App Store production, flippearlo a
`false`.

## 2. Deploy de las dos functions

```bash
cd /Users/jj/code/tandas
supabase functions deploy send-event-notification
supabase functions deploy dispatch-notifications
```

Si `verify_jwt` da problema, usar `--verify-jwt=true` explícito (default).

## 3. Registrar cron de `dispatch-notifications` cada 1min

Supabase Dashboard → Database → Extensions → confirmar `pg_cron` y
`pg_net` enabled.

Después en SQL Editor (o como migration), correr:

```sql
select cron.schedule(
  'dispatch-notifications-every-minute',
  '* * * * *',
  $$
  select net.http_post(
    url := 'https://<PROJECT_REF>.supabase.co/functions/v1/dispatch-notifications',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || current_setting('app.settings.service_role_key'),
      'Content-Type',  'application/json'
    ),
    body := '{}'::jsonb
  );
  $$
);
```

Reemplazar `<PROJECT_REF>` con el ref real del proyecto Supabase. Si el
patrón de los crons existentes (`process-system-events`, `finalize-votes`,
etc.) usa otra forma de inyectar la service_role key, alinear con eso —
los crons existentes son la fuente de verdad del patrón en este proyecto.

## 4. Verificar registro

```sql
select jobid, jobname, schedule, command from cron.job
where jobname = 'dispatch-notifications-every-minute';
```

Debe retornar 1 row.

## 5. Smoke test en device de prueba

### 5.1 Instalar app en device

```bash
cd /Users/jj/code/tandas/ios
xcodegen generate
xcodebuild -scheme Tandas -project Tandas.xcodeproj \
  -destination 'generic/platform=iOS' -configuration Debug build
APP_PATH="/Users/jj/Library/Developer/Xcode/DerivedData/Tandas-boyegkhwdcwcfycscxyuqxpgapwa/Build/Products/Debug-iphoneos/Tandas.app"
xcrun devicectl device install app --device <DEVICE_UDID> "$APP_PATH"
```

### 5.2 Grant push permissions en device

Abrir app → hacer RSVP "Voy" en cualquier evento → app pide permiso
push lazy (es el spec). Aceptar.

Confirmar token registered en DB:

```sql
select user_id, platform, created_at from notification_tokens
order by created_at desc limit 5;
```

Debe aparecer 1 row con el platform=ios.

### 5.3 Disparar una notificación

Desde otro device (o vía dashboard), generar la condición que produce
una notificación. Opciones rápidas:

- **Crear un evento nuevo** en el grupo del device de prueba (si el user
  no es el creator, va a recibir push "Nuevo evento").
- **Cancelar un evento** (recipients = todos los miembros).
- **Llamar directamente** la función desde Supabase Studio:
  ```
  supabase functions invoke send-event-notification \
    --body '{"event_id": "<EVENT_UUID>", "kind": "created"}'
  ```

### 5.4 Verificar outbox + dispatch

Inmediatamente después del trigger:

```sql
select id, recipient_member_id, notification_type, dispatch_status,
       dispatched_at, dispatch_error, created_at
from notifications_outbox
order by created_at desc limit 10;
```

Esperado: 1+ rows con `dispatch_status='pending'`, `dispatched_at IS NULL`.

Esperar 1min (cron interval). Re-correr la query:

Esperado: rows pasan a `dispatch_status='sent'`, `dispatched_at` populado.
Si `dispatch_status='failed'`, leer `dispatch_error` (debugging).
Si `dispatch_status='skipped'`, el user no tiene token en
`notification_tokens` (volver a paso 5.2).

### 5.5 Confirmar push en device

Push debe aparecer en lock screen / notification center del device.
Tap → app abre, deep_link a evento (vía `EventDeepLink` userInfo).

**Si llega push y el deep link funciona, F0 gate cumplido.**

## 6. Troubleshooting

### `dispatch_status='failed'` con error 403 InvalidProviderToken

JWT no válido. Causas comunes:
- `APNS_KEY_ID` o `APNS_TEAM_ID` no coinciden con la key real
- `APNS_AUTH_KEY` truncated o sin BEGIN/END lines
- Key revocada en Apple Developer

### `dispatch_status='failed'` con error 410 BadDeviceToken

- Token registrado contra sandbox APNs pero `APNS_USE_SANDBOX=false`
  (o vice versa)
- Token caducó o el user reinstaló
- Función auto-elimina el token de `notification_tokens` para evitar
  retries — re-grant push permission para re-registrar

### Cron no dispara

```sql
select * from cron.job_run_details
where jobname = 'dispatch-notifications-every-minute'
order by start_time desc limit 5;
```

Si no hay rows, cron no está registrado o está disabled. Si rows tienen
`status='failed'`, leer `return_message`.

### Función deployed pero responde 500

Logs en Supabase Dashboard → Edge Functions → dispatch-notifications →
Logs. Errores comunes: missing env var, supabase client init failed.

---

## 7. Cuando el push real llegue al device de prueba

- F0 gate cumplido. Confirma con el founder.
- El sprint APNs está cerrado. OpenVotesView puede arrancar (si no
  arrancó ya).
- Las creds prod (no sandbox) se configuran cuando se publique a App
  Store — flip `APNS_USE_SANDBOX=false`.

---

## 8. Rollback

Si APNs causa issues en prod:

```sql
select cron.unschedule('dispatch-notifications-every-minute');
```

El outbox sigue acumulando rows pending. Cuando el dispatcher se
reactiva, drena lo acumulado. No hay pérdida de eventos.

Para volver a push-stub-only:

```bash
supabase functions delete dispatch-notifications
```

`send-event-notification` sigue escribiendo al outbox; nadie lo despacha.
Push deja de funcionar pero la app sigue OK (los SystemEvents y
UserActions se siguen registrando).
