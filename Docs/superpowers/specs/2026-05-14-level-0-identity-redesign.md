# Nivel 0 — Identity / Usuario individual: gaps + rediseño

**Fecha:** 2026-05-14
**Estado:** Brainstorming → spec
**Decisor:** founder (jose.mizrahi@quimibond.com)
**Constitución:** `Plans/Active/Constitution.md` (canónico 2026-05-13)
**Jerarquía:** `Plans/Active/HierarchyReference.md` §1 — Layer 0 (Identity)
**Migración base:** `supabase/migrations/00174_identity_atoms.sql` + `00001_core_schema.sql` (`profiles`) + `00012_event_layer_v1.sql` (`notification_tokens`)
**Spec hermano:** `docs/superpowers/specs/2026-05-14-frontend-remodel-design.md` (alineación shell ↔ Constitución)

## Problema

`HierarchyReference.md` define **Nivel 0 = Identity**: "auth.users + profiles", scoped al usuario individual sin importar grupo. El BE ya cubre esa capa con superficie rica (timezone, locale, identity_atoms, notification_tokens, atom-ish guard sobre `user_actions`), pero el FE expone solo una rebanada y mezcla responsabilidades de varias capas en una sola pantalla:

1. **`ProfileView.swift` (405 L) confunde Nivel 0 con Nivel 2.** El "status hero" del header (`TODO AL CORRIENTE` / `$300 PENDIENTE`) lee `coordinator.totalOutstanding` que es **fines del grupo activo** (group_member-scoped). Las stat tiles (Pendiente / Pagaste este mes / Multas totales) viven en el mismo header. Resultado: el "Yo" tab no es del yo, es del yo-en-este-grupo. Usuario con 3 grupos no tiene cómo ver su yo cross-group.

2. **`SettingsSheet.swift` (158 L) + `SettingsTabView.swift` (67 L, wrapper que renderiza `ProfileView` con sección "Este Grupo")** duplican lógica y dejan ajustes personales (apariencia + signout) en un sheet *separado* del Profile, mientras meten ajustes group-scoped en una sección dentro del Profile. La capa cero está partida.

3. **Campos del `profiles` no editables aunque el BE los soporte** (verificado en `LiveProfileRepository.loadMine` que ya hace `.select("id, display_name, avatar_url, phone, timezone, locale")`):
   - `timezone` — editable solo via DB. App usa `TimeZone.current` implícito.
   - `locale` — editable solo via DB. Sin UI de idioma.
   - `phone` — visible vía `app.session.user.phone`, sin flujo de cambio (re-OTP).
   - `email` — idem; visible solo en el header del SettingsSheet.

4. **`identity_atoms`** (mig 00174) emite tres tipos (`signup`, `anon_promoted`, `profile_updated`) con RLS self-read activa. El FE no consume nada — no hay vista "actividad de mi cuenta" útil para soporte y para que el usuario *vea* sus cambios.

5. **`notification_tokens`** (mig 00012) es per-device, indexado por `(user_id, token)`. El `NotificationTokenRepository` solo expone `register/revoke` para el dispositivo actual; no hay `listMyDevices()` ni `revoke(deviceId:)`. Resultado: usuario no puede cerrar sesión en otro iPhone perdido sin contactar soporte.

6. **`notifications_outbox`** tiene `dispatch_status` (`pending|sent|failed|skipped`) pero el FE nunca lo lee. Fallos de push son silenciosos para el usuario.

7. **Cross-group personal activity** existe en BE (`system_events`, `ledger_entries`, `vote_casts`, `rsvp_actions` filtrables por user_id vía joins) pero no hay vista. `MyLedgerView` agrega solo dinero; no hay timeline.

8. **GDPR / soberanía de datos**: no hay "exportar mis datos" ni "eliminar cuenta". `auth.users` tiene `on delete cascade` en `profiles` y todas las tablas user-scoped, pero no hay edge function que lo dispare desde el cliente.

9. **Anon → Phone upgrade** está soportado por trigger `handle_identity_promotion` (mig 00174) pero no hay UI dedicada. Los usuarios anónimos quedan huérfanos hasta que crean grupo o aceptan invite (que fuerza OTP en otro flujo).

## Objetivo

Que `Nivel 0` tenga superficie de FE simétrica al BE:

- Una sola entrada ("Yo" tab) que muestra **únicamente** lo individual del usuario, cross-group.
- Toda info de `profiles` editable desde la app (display_name, avatar_url, phone, timezone, locale).
- Visibilidad de identity_atoms como "Historial de cuenta".
- Multi-device management: ver y revocar tokens de otros dispositivos.
- Una vista cross-group de actividad personal (no solo dinero).
- Botones de export y delete que cumplan GDPR.
- Ajustes personales (apariencia, hápticos) viven aquí, no en un sheet desconectado.
- "Este Grupo" desaparece de Profile — pertenece al detalle del grupo (Nivel 1).

## Approach — seis pasadas, cada una un PR mergeable

Cada pasada es independiente y demoable. Order matters solo entre Pass 1 → Pass 2 (el wire-up necesita el shell separado primero).

### Pass 1 · Separar Nivel 0 de Nivel 2 en `ProfileView` (1 sesión)

**Objetivo:** que la pantalla "Yo" muestre solo lo individual cross-group, sin tocar BE.

**Cambios:**

| Archivo | Acción | Notas |
|---|---|---|
| `Features/Profile/Views/ProfileView.swift` (405 L) | Refactor: separar `MyProfileView` (Nivel 0, cross-group) de `ProfileGroupScopeSection` (Nivel 2, mover a detalle de grupo) | El header pierde `statusHero` + `statTiles` que son group-scoped. Queda: avatar + nombre + meta cross-group ("3 grupos activos") |
| `Features/Profile/ProfileCoordinator.swift` (115 L) | Limpiar: quita `fines`, `totalOutstanding`, `paidThisMonth`, `totalFineCount`, `isAllClear` | Esos derivados se mueven al coordinador del detalle de grupo (no en este Pass; se deja un `MyFinesCrossGroupCoordinator` para el botón "Mis multas" que sigue existiendo) |
| `Features/Profile/MyFinesCrossGroupCoordinator.swift` | **NUEVO** (~80 L) | Agrega multas de TODAS las membresías del usuario, no solo del grupo activo. Lee de `fines` con filtro por usuario. **Implementación:** confirmar el FK exacto (probablemente `target_member_id` joined a `group_members.user_id`, no `fines.user_id` directo) inspeccionando schema antes de escribir el query |
| `Features/Settings/SettingsSheet.swift` (158 L) | **DELETE**. Su contenido (apariencia + signout) se absorbe en `MyProfileView` como secciones | El sheet desconectado desaparece. Apariencia + cerrar sesión viven en la pantalla principal |
| `Features/Settings/Views/SettingsTabView.swift` (67 L) | **DELETE**. Era wrapper de `ProfileView` con `groupScope` non-nil | Ya no hay tab Settings; `RootShell` apunta directo a `MyProfileView` |
| `Features/Profile/Views/ProfileView.swift` | Renombrar archivo + tipo a `MyProfileView` | Convención: prefijo `My` para todo lo Nivel 0 cross-group |
| Callers de `ProfileView` (RootShell + SettingsTabView) | Actualizar imports + signaturas | El parámetro `groupScope` desaparece; el callback `onOpenSettings` desaparece (settings inline) |

**Sin cambios de dominio aún.** Pass 1 es puramente structural — extrae responsabilidades sin agregar funcionalidad.

**Acceptance Pass 1:**
- `MyProfileView` no muestra ni un solo dato derivado de "grupo activo".
- `SettingsSheet` no existe.
- Botón "Cerrar sesión" sigue funcionando, ahora desde `MyProfileView`.
- Build + tests existentes verdes.

### Pass 2 · Wire-up de campos `profiles` ya disponibles en BE (1 sesión)

**Objetivo:** exponer `timezone`, `locale`, y phone-change. Cero migraciones.

**Repos:**

`Repositories/ProfileRepository.swift` — extender protocolo:

```swift
public protocol ProfileRepository: Actor {
    func loadMine() async throws -> Profile
    func updateDisplayName(_ name: String) async throws
    func updateAvatar(data: Data, contentType: String) async throws -> URL
    // NEW
    func updateTimezone(_ tz: String) async throws        // IANA string, e.g. "America/Mexico_City"
    func updateLocale(_ locale: String) async throws      // BCP-47, e.g. "es-MX"
}
```

Live: `update().eq("id", userId)`. Mock: muta `_profile`. RLS ya permite (`profiles_self_write`).

Phone change vive en **AuthService** (no en ProfileRepository — el sync a `profiles.phone` es trigger BE, mig 00174 + previa):

```swift
extension AuthService {
    func startPhoneChange(_ newPhone: String) async throws  // sends OTP to new number
    func confirmPhoneChange(_ otp: String) async throws     // updates auth.users.phone → trigger sync
}
```

Forma esperada: `Supabase.auth.update(user: .init(phone: newPhone))` dispara OTP al nuevo número; `verifyOtp(.phoneChange, otp:)` confirma. **Verificar antes de implementar** que el SDK Swift 2.x exponga `phoneChange` como `OtpType` (en supabase-js sí; en supabase-swift puede llamarse distinto). Si no, fallback a edge function `change-phone` que use el admin SDK.

**Subpantallas nuevas (en `Features/Profile/Subscreens/`):**

| Archivo | Tamaño objetivo | Qué hace |
|---|---|---|
| `LanguagePickerView.swift` | ~120 L | Lista BCP-47 soportados (`es-MX`, `es-ES`, `en-US`, `pt-BR`, `fr-FR`). Tap → `profileRepo.updateLocale(...)` + reload `app.profile`. Aplicar `.environment(\.locale, ...)` en RootShell siguiendo el cambio |
| `TimezonePickerView.swift` | ~140 L | Lista filtrable de IANA timezones (`TimeZone.knownTimeZoneIdentifiers`). Default highlight = `TimeZone.current.identifier`. Tap → `profileRepo.updateTimezone(...)` |
| `ChangePhoneFlow.swift` | ~180 L | Stack 2 steps (`enter new phone` → `verify OTP`). Reusa `PhoneInputField` y `OTPInputField` de Auth/. Errores: número en uso, OTP inválido |
| `ChangeEmailFlow.swift` | ~160 L | Idem para email; `auth.update(user: .init(email: ...))` + verifyOtp `.emailChange` |

**`MyProfileView` añade sección "Identidad":**

```
├─ Identidad ─────────────────────────────┤
│  📱  +52 55 1234 5678        Verificado │ → ChangePhoneFlow
│  ✉️  jose@quimibond.com      Verificado │ → ChangeEmailFlow
│   🍎 Apple ID                  Vinculado │ (read-only por ahora)
```

Y sección "Preferencias":
```
├─ Preferencias ──────────────────────────┤
│  🌐 Idioma                  Español  →  │ → LanguagePickerView
│  🕐 Zona horaria   America/Mexico_City→ │ → TimezonePickerView
│  🎨 Apariencia              Sistema  →  │ (inline picker, ya existe en SettingsSheet)
```

**Acceptance Pass 2:**
- `Profile` model expone `timezone` + `locale` (ya estaban; ahora se *usan*).
- Cambiar idioma rota la app a esa lengua via `\.locale` en RootShell.
- Cambiar timezone se refleja en formateo de fechas (vía `Profile.timezone` consumido por `RuulDateFormatter`).
- Cambiar teléfono dispara OTP al nuevo número y al confirmar el trigger BE espeja a `profiles.phone`.

### Pass 3 · Multi-device + notification token management (1 sesión)

**Objetivo:** ver y revocar tokens de otros dispositivos.

**BE — sin migración, solo extender `NotificationTokenRepository`:**

```swift
public protocol NotificationTokenRepository: Actor {
    func registerToken(_ token: String) async throws
    func revokeToken(_ token: String) async throws
    // NEW
    func listMyDevices() async throws -> [NotificationDevice]
    func revoke(deviceId: UUID) async throws
}

public struct NotificationDevice: Sendable, Codable, Identifiable {
    public let id: UUID                    // notification_tokens.id
    public let token: String               // first 8 + last 4 chars masked
    public let platform: String            // "ios" / "android" / "web"
    public let createdAt: Date
    public let updatedAt: Date
    public var isCurrentDevice: Bool       // matches local APNs token
}
```

Live: `from("notification_tokens").select().eq("user_id", userId).order("updated_at", ascending: false)` — RLS `notif_tokens_self` ya restringe.

**Subpantalla:**

`Features/Profile/Subscreens/DevicesView.swift` (~200 L):

```
┌─ Dispositivos ──────────────────────────┐
│  📱 Este iPhone                         │
│     Registrado hace 3 días              │
│                                          │
│  📱 iPhone 14 (otro)                    │
│     Última actividad: hace 2 semanas    │
│     [Cerrar sesión aquí]                │
│                                          │
│  📱 iPad                                │
│     Última actividad: hace 1 mes        │
│     [Cerrar sesión aquí]                │
└─────────────────────────────────────────┘
```

Heurística "este dispositivo": match por token actual cacheado en `UserDefaults` después de `registerToken`.

**Sub-subpantalla:**

`Features/Profile/Subscreens/NotificationFailuresView.swift` (~150 L) — opcional Pass 3 o deferida:

Lee `notifications_outbox` filtrando `recipient_member_id IN (mis memberships)` y `dispatch_status IN ('failed','skipped')` últimos 7 días. RLS `notif_outbox_self_select` ya cubre. Útil para que el usuario sepa que un push *no* llegó.

**Acceptance Pass 3:**
- Lista de dispositivos muestra al menos el actual + cualquier otro registrado para el `user_id`.
- Botón "Cerrar sesión aquí" revoca el token; el otro dispositivo deja de recibir push (verificable en logs de `dispatch-notifications`).
- Failures view (si se incluye en Pass 3): muestra >=1 fallo simulado.

### Pass 4 · Cross-group personal timeline (1 sesión)

**Objetivo:** una vista única "Mi línea de tiempo" que une atoms del usuario en TODOS sus grupos.

**BE — vista nueva (preferred a hacer 4 queries client-side):**

Migración `00176_my_activity_view.sql`:

```sql
-- Aggregates user-scoped atoms across all groups for cross-group personal feed.
-- RLS: SELECT only when user_id = auth.uid() (each subquery already filters by membership).
create or replace view public.my_activity_v1 as
  select 'rsvp'::text as kind, ra.id::uuid as ref_id, ra.event_id as resource_id,
         ra.user_id, gm.group_id,
         jsonb_build_object('status', ra.status) as payload,
         ra.created_at as occurred_at
  from public.rsvp_actions ra
  join public.group_members gm on gm.id = ra.group_member_id
  union all
  select 'check_in', ca.id, ca.event_id, ca.user_id, gm.group_id,
         jsonb_build_object('method', ca.method),
         ca.created_at
  from public.check_in_actions ca
  join public.group_members gm on gm.id = ca.group_member_id
  union all
  select 'vote_cast', vc.id, vc.vote_id, vc.user_id, gm.group_id,
         jsonb_build_object('choice', vc.choice),
         vc.created_at
  from public.vote_casts vc
  join public.group_members gm on gm.id = vc.group_member_id
  union all
  select 'ledger', le.id, le.resource_id, gm.user_id, le.group_id,
         jsonb_build_object('amount', le.amount, 'kind', le.entry_kind),
         le.created_at
  from public.ledger_entries le
  join public.group_members gm on gm.id = le.actor_member_id
  where gm.user_id is not null;

-- Read via PostgREST: client filters .eq('user_id', auth.uid()).order('occurred_at', desc).limit(N)
-- Existing per-table RLS on rsvp_actions/check_in_actions/vote_casts/ledger_entries
-- already enforces visibility — view is just a transport convenience.
```

Antes de aplicar: validar que cada tabla source tenga RLS que cubra "self read" para el `user_id` derivado. Si alguna depende solo de `group_id IN (...)`, agregar guard en la view.

**Repo:**

`Repositories/MyActivityRepository.swift` (NUEVO, ~80 L):

```swift
public protocol MyActivityRepository: Actor {
    func loadRecent(limit: Int) async throws -> [MyActivityItem]
}

public struct MyActivityItem: Sendable, Identifiable {
    public let id: UUID
    public let kind: Kind
    public let resourceId: UUID?
    public let groupId: UUID
    public let payload: [String: AnyCodable]
    public let occurredAt: Date

    public enum Kind: String, Sendable, Codable {
        case rsvp, checkIn = "check_in", voteCast = "vote_cast", ledger
    }
}
```

**Subpantalla:**

`Features/Profile/Subscreens/MyTimelineView.swift` (~220 L) — feed agrupado por día:

```
HOY
  ✅ RSVP confirmado · Cena de jueves · Cenas con amigos
  💸 Pagaste $300 · Cuenta de cena · Cenas con amigos
AYER
  🗳️  Votaste SÍ · Cambio de regla · Palco Azteca
  ✓  Check-in · Cena de jueves · Cenas con amigos
HACE 3 DÍAS
  ...
```

Cada item navega al detalle correspondiente (resource detail si `resourceId != nil`, vote detail si vote_cast).

**Acceptance Pass 4:**
- View `my_activity_v1` aplicada via MCP migration.
- `MyTimelineView` muestra >=4 kinds distintos en una sesión real.
- Performance: <200ms para `limit=50` con índices existentes.

### Pass 5 · Identity history + Account history (1 sesión)

**Objetivo:** exponer `identity_atoms` como "Historial de cuenta".

**Repo:**

`Repositories/IdentityHistoryRepository.swift` (NUEVO, ~60 L):

```swift
public protocol IdentityHistoryRepository: Actor {
    func loadMine() async throws -> [IdentityAtom]
}

public struct IdentityAtom: Sendable, Identifiable, Codable {
    public let id: UUID
    public let userId: UUID
    public let atomType: AtomType
    public let payload: [String: AnyCodable]
    public let occurredAt: Date

    public enum AtomType: String, Sendable, Codable {
        case signup, anonPromoted = "anon_promoted", profileUpdated = "profile_updated"
    }
}
```

Live: `from("identity_atoms").select().order("occurred_at", ascending: false)` — RLS `identity_atoms_self_read` ya restringe.

**Subpantalla:**

`Features/Profile/Subscreens/AccountHistoryView.swift` (~140 L):

```
┌─ Historial de cuenta ───────────────────┐
│  Cuenta creada                          │
│  14 may 2026 · Cuenta anónima           │
│                                          │
│  Vinculaste tu teléfono                 │
│  14 may 2026 · +52 55 ...               │
│                                          │
│  Cambiaste tu nombre                    │
│  10 may 2026                            │
└─────────────────────────────────────────┘
```

Texto humano por `atomType` + `payload.fields_changed`. Útil para soporte ("¿cuándo cambié mi número?") y forensics.

**Acceptance Pass 5:**
- Vista renderiza al menos `signup` (siempre presente) + `profile_updated` después de Pass 2 cambios.
- Sin acciones — read-only.

### Pass 6 · GDPR: Export + Delete account (1 sesión)

**Objetivo:** cumplir derecho a portabilidad + derecho al olvido.

**BE — dos edge functions nuevas:**

`supabase/functions/export-my-data/index.ts`:
- Auth: `req.headers.authorization` → `client.auth.getUser()`.
- Junta TODA la data del usuario: profiles, group_members (todas sus membresías + grupo), user_actions, identity_atoms, notifications_outbox (filtrado por su member_id), my_activity_v1.
- Genera ZIP con un JSON por tabla + un README.md con esquema.
- Sube a Storage bucket `exports/` con TTL de 24h. Devuelve URL firmada.
- **Pre-req:** crear bucket `exports` con policy "user can read only files prefixed with their user_id" en una migración nueva (`00177_exports_bucket.sql`) si no existe.

`supabase/functions/delete-my-account/index.ts`:
- Auth idem.
- Soft-checks: bloquea si el user es **único admin** de algún grupo activo. Devuelve lista de grupos a transferir admin antes.
- Si pasa: `auth.admin.deleteUser(userId)` — el `on delete cascade` en `profiles + group_members + ...` se encarga del resto (verificado en mig 00001 + posteriores).
- Audit: emite atom `data_deletion_log` (mig 00168) antes del delete.

**Subpantallas:**

`Features/Profile/Subscreens/ExportDataView.swift` (~140 L):
- Botón "Solicitar exportación".
- Loading state mientras la edge function trabaja (~5-15s).
- Resultado: link "Descargar archivo (.zip)" + "Compartir" (UIActivityViewController).
- Disclaimer: "Tu archivo estará disponible 24h".

`Features/Profile/Subscreens/DeleteAccountView.swift` (~200 L):
- Warning grande con lista de consecuencias.
- Si hay grupos donde es único admin: lista bloqueante con CTA "Transferir admin en [grupo]" → navega al detalle del grupo correspondiente.
- Si pasa el check: confirmación con escribir "ELIMINAR" para habilitar el botón.
- Tap → llama `delete-my-account` → cierra sesión + presenta `AccountDeletedView` por 3s → `RootShell` rebota a `SignInView`.

**Acceptance Pass 6:**
- Export devuelve un ZIP con al menos: `profile.json`, `memberships.json`, `activity.json`, `identity_atoms.json`, `README.md`.
- Delete bloquea correctamente cuando el usuario es único admin de un grupo con miembros.
- Delete exitoso desaparece al usuario de `auth.users` y todas sus rows en cascade.

## Arquitectura — diagrama Nivel 0 después de las 6 pasadas

```
ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Profile/
├── Coordinator/
│   ├── MyProfileCoordinator.swift              (slim, ~100 L)
│   ├── MyFinesCrossGroupCoordinator.swift      (NEW Pass 1, ~80 L)
│   └── MyTimelineCoordinator.swift             (NEW Pass 4, ~90 L)
├── Views/
│   ├── MyProfileView.swift                     (renamed from ProfileView, ~280 L)
│   ├── MyLedgerView.swift                      (existing, unchanged)
│   ├── MyFinesCrossGroupView.swift             (NEW Pass 1, ~180 L)
│   └── EditProfileSheet.swift                  (existing)
├── Subscreens/
│   ├── LanguagePickerView.swift                (NEW Pass 2)
│   ├── TimezonePickerView.swift                (NEW Pass 2)
│   ├── ChangePhoneFlow.swift                   (NEW Pass 2)
│   ├── ChangeEmailFlow.swift                   (NEW Pass 2)
│   ├── DevicesView.swift                       (NEW Pass 3)
│   ├── NotificationFailuresView.swift          (NEW Pass 3, optional)
│   ├── MyTimelineView.swift                    (NEW Pass 4)
│   ├── AccountHistoryView.swift                (NEW Pass 5)
│   ├── ExportDataView.swift                    (NEW Pass 6)
│   └── DeleteAccountView.swift                 (NEW Pass 6)
└── (Settings/ folder DELETED — its contents absorbed)

ios/Packages/RuulCore/Sources/RuulCore/Repositories/
├── ProfileRepository.swift                     (extended Pass 2)
├── NotificationTokenRepository.swift           (extended Pass 3)
├── MyActivityRepository.swift                  (NEW Pass 4)
└── IdentityHistoryRepository.swift             (NEW Pass 5)

supabase/migrations/
└── 00176_my_activity_view.sql                  (NEW Pass 4)

supabase/functions/
├── export-my-data/                             (NEW Pass 6)
└── delete-my-account/                          (NEW Pass 6)
```

## Wireframe consolidado de `MyProfileView` post-Pass 6

```
┌─────────────────────────────────────────┐
│  ⟵                                ✏️    │
│                                          │
│         ╭────────────╮                   │
│         │   AVATAR   │                   │
│         ╰────────────╯                   │
│         Jose Mizrahi                     │
│         Miembro de 3 grupos              │
│                                          │
├─ Identidad ─────────────────────────────┤  Pass 2
│  📱  +52 55 1234 5678        Verificado │
│  ✉️  jose@quimibond.com      Verificado │
│                                          │
├─ Tu actividad ──────────────────────────┤
│  📥 Inbox (4 pendientes)             →  │
│  📅 Mi línea de tiempo               →  │  Pass 4
│  💰 Mis movimientos                  →  │
│  ⚖️  Mis multas ($1,240)              →  │  Pass 1
│                                          │
├─ Preferencias ──────────────────────────┤  Pass 2
│  🌐 Idioma                  Español  →  │
│  🕐 Zona horaria   America/Mexico_City→ │
│  🔔 Notificaciones                   →  │  Pass 3
│  🎨 Apariencia              Sistema  →  │  (inline)
│                                          │
├─ Cuenta ────────────────────────────────┤
│  📜 Historial de cuenta              →  │  Pass 5
│  📥 Exportar mis datos               →  │  Pass 6
│  🚪 Cerrar sesión                       │
│  ⚠️  Eliminar cuenta                     │  Pass 6
└─────────────────────────────────────────┘
```

## Decisiones explícitas

1. **`ProfileView` se renombra a `MyProfileView`** para hacer explícito el scope Nivel 0 cross-group. Cumple convención sugerida en `HierarchyReference.md` y refuerza separación cuando aparezca `GroupProfileView` (Nivel 1) en otro spec.
2. **`SettingsSheet` y `SettingsTabView` mueren.** Su contenido vive en `MyProfileView` directamente. El "tab Settings" como entidad separada era un anti-patrón heredado.
3. **"Este Grupo" sale del Profile.** Va al detalle del grupo (Nivel 1) — fuera de scope de este spec. Pass 1 elimina el parámetro `groupScope`; el siguiente spec ("Nivel 1 — Group dashboard") lo absorbe.
4. **`my_activity_v1` es vista, no tabla.** No agrega writes nuevos, no requiere triggers. Cualquier query a una tabla source ya pasa RLS; la view es solo conveniencia de transporte.
5. **GDPR en edge functions, no client-side.** Export requiere agregar data de varias tablas con RLS distintas; delete requiere `auth.admin.deleteUser()` (service role). Cliente no puede.
6. **Notification preferences per-tipo + DnD se difieren** a un spec posterior (`Nivel 0 v2`). Requieren tabla `user_notification_preferences` nueva — fuera del scope "exponer lo que ya hay en BE".
7. **Linked identities (Apple ID separado)** se muestra read-only en Pass 2. Linkear/unlinkear requiere flow nuevo en AuthService — diferido.
8. **El gate `MyProfileView.profile == nil` durante onboarding sigue funcionando** porque `onboarding/FounderIdentityView` setea `displayName` antes de transicionar. Sin cambios de comportamiento ahí.

## Riesgos

| Riesgo | Mitigación |
|---|---|
| Cambiar idioma rota strings hardcoded en español | Auditar `Localizable.strings` antes de Pass 2; si faltan keys, agregar y luego habilitar el picker |
| Phone change requiere SDK 2.x soporte que puede estar atrás | Verificar `Auth.swift` del SDK antes de Pass 2; fallback a edge function `change-phone` si no |
| `my_activity_v1` puede ser lenta con muchos atoms | Limit obligatorio (50 default) + index sobre `user_id` ya existe en cada tabla source. Monitorear con `get_logs` |
| Edge function `delete-my-account` puede fallar mid-cascade | Wrap en transacción; log atom `data_deletion_log` ANTES del delete para auditabilidad |
| El timeline cross-group puede mostrar acciones de un grupo donde el usuario fue removido | Filter en view: `gm.status = 'active'` (validar que la columna exista o ajustar) |
| Múltiples dispositivos con el mismo token (raro pero posible si el SO recicla) | Index único `(user_id, token)` ya en mig 00012 — el upsert lo maneja |

## Tests

| Pass | Tests críticos |
|---|---|
| 1 | `MyProfileViewTests`: snapshot sin `groupScope`. `MyFinesCrossGroupCoordinatorTests`: agrega multas de >=2 grupos |
| 2 | `ProfileRepositoryTests`: updateTimezone/updateLocale persisten. `LanguagePickerViewTests`: tap rota `\.locale` |
| 3 | `NotificationTokenRepositoryTests`: listMyDevices devuelve >=1, revoke borra row. `DevicesViewTests`: highlight "este dispositivo" |
| 4 | `MyActivityRepositoryTests`: 4 kinds en una respuesta. View migration test |
| 5 | `IdentityHistoryRepositoryTests`: signup atom siempre presente |
| 6 | `ExportDataE2E`: zip contiene >=4 archivos. `DeleteAccountE2E`: bloquea cuando único admin |

## Out of scope (próximos specs)

- **Nivel 1 — Group dashboard** (absorbe "Este Grupo" + cosas group-scoped)
- **Nivel 0 v2** — notification preferences per-tipo, DnD, quiet hours, push categories
- **Linked identities management** — link/unlink Apple/Google/email
- **Privacy controls** — quién puede ver mi profile, mi actividad

## Done When

- Las 6 pasadas mergeadas a `main`.
- `MyProfileView` no tiene ninguna referencia a "grupo activo".
- `Settings/` folder eliminada del repo.
- 5 subpantallas nuevas funcionando con repos live.
- Migration 00176 + 2 edge functions desplegadas.
- Tests verdes; `xcodebuild test` pasa.
- Codegen sin diff (Lefthook + CI).
- Demo en simulador iOS 26: cambiar idioma rota app, cambiar timezone rota fechas, revocar dispositivo expulsa la otra sesión, exportar genera zip, eliminar cuenta vacía y rebota a SignIn.
