# Frontend Implementation Plan — cerrar los flujos end-to-end

**Fecha:** 2026-06-11
**Insumos:** `FrontendFlowAudit.md`, `FrontendMissingFeatures.md`, `FrontendBackendContractMap.md`.
**Principio:** Backend = autoridad; cada fase termina con DoD del repo (compila sin
warnings, `xcodebuild test` pasa, smoke en simulador iOS 26) y un commit por slice.

El frontend ya cubre los flujos A–H; este plan NO es un rebuild. Son 4 fases cortas
para eliminar los huecos visibles, en orden de riesgo para el usuario.

---

## Fase 0 — Validación en device (antes de escribir código)

**Objetivo:** confirmar en iPhone real lo que la auditoría afirma desde el código.

1. Ejecutar los 5 smokes F.14 pendientes (`Frontend_MVP2_Rebuild.md:61-78`):
   cena semanal completa, Casa Valle reservable, viaje Japón con gastos, negocio con
   decisión, trust visible.
2. Registrar resultados en `R5Z_FounderFlowsValidation.md` (✅/❌ por paso + screenshots).
3. Cualquier ❌ encontrado se inserta como P0 en la Fase 1.

**Esfuerzo:** 1 sesión de founder con device + backend live. Sin código.

---

## Fase 1 — P0: cerrar flujos obligatorios (1 slice por ítem)

| Slice | Ítem | Trabajo | Dónde |
|---|---|---|---|
| 1.1 | **Rechazar invitación** (P0.1) | Backend: migration `decline_invitation(p_context_actor_id)` (vía MCP `apply_migration`, con review SQL) + RLS/activity. iOS: método en RuulRPCClient + Mock, swipe action + botón "Rechazar" con confirmación en PendingInvitationsView, refresh de InvitationsStore | `supabase/migrations/`, `PendingInvitationsView.swift`, `InvitationsStore.swift` |
| 1.2 | **Revocar invitación** (P0.2) | Sin backend nuevo. Sección "Códigos activos" en InviteMembersView (requiere lectura de invites del contexto — confirmar si `context_settings_summary` los trae o agregar lista) + acción revocar con confirmación | `InviteMembersView.swift`, `MembersStore.swift:55-57` |
| 1.3 | **Sesión huérfana** (P0.3) | Llamar `verifySession()` al transicionar a `.signedIn`; si falla → `signOut()` limpio y volver a SignedOutView | `RuulAppShell.swift:40-54`, `SessionStore.swift` |
| 1.4 | **Obligation pay/dispute/cancel** (P0.4) | Decisión de producto primero. Camino corto recomendado: migration que quita esas acciones del descriptor hasta que existan los RPCs (el botón "Próximamente" desaparece). Camino largo (post-fase): RPC `pay_obligation` que cree el settlement item correspondiente | migration de `obligation_detail`, o nuevos RPCs + `ObligationDetailView.swift` |
| 1.5 | **Razones de acciones deshabilitadas** (P0.5) | Componente `DisabledActionLabel(action:)` que muestre `AvailableAction.reason`; aplicarlo en toolbars/menus de ContextDetailV2, ResourceDetail, EventDetail, DecisionDetail, MemberDetail | `Components/`, vistas de detalle |
| 1.6 | **Eliminación de cuenta** (V.1) | Backend: RPC de delete con pseudonimización de identidad preservando átomos no personales (doctrina de la visión: identidad desacoplada del acto). iOS: botón destructivo en PersonalSettings con doble confirmación + signOut. **Bloquea App Store review (5.1.1(v)) y ARCO** | migration nueva, `PersonalSettingsView.swift` |
| 1.7 | **Aviso de privacidad + términos** (V.2) | Publicar `/legal/privacidad` y `/legal/terminos` en `web/public` (ruul.mx) + `Link` en footer de SignedOutView y sección legal en PersonalSettings | `web/public/`, `SignedOutView.swift`, `PersonalSettingsView.swift` |

**Salida de fase:** Flujo C (invitación) completo en ambas direcciones; cero botones
visibles sin acción; sesión inválida se autorepara; la app es submittable a App Store
(cuenta borrable + privacy policy).

---

## Fase 2 — P1 core: "backend listo, falta UI"

Orden por valor/esfuerzo:

1. **Centro de notificaciones R.4D** (P1.1) — `NotificationsStore` +
   `NotificationCenterView` (leído/no-leído, archivar, marcar todas), RPCs
   `mark_notification_read/archived/all` ya existentes; integrar como sección superior
   de la tab Actividad + badge. *Es el dominio entero menos cubierto.*
2. **Avatar upload** (P1.2) — PhotosPicker + resize + Storage bucket `avatars` +
   `update_my_profile(p_avatar_url)`; render en ActorInitialsView con AsyncImage y
   fallback a initials.
3. **Cambiar teléfono/email** (P1.3) — sheet en PersonalSettingsView reutilizando el
   flujo OTP de AuthService (`startPhoneChange`/`confirmPhoneChange`).
4. **Quorum + countdown en decisiones** (P1.7) — chip "Se aprueba con X de Y" +
   `TimelineView` para closesAt; datos ya presentes en `decision_detail`.
5. **RuleDetailView conforme a doctrina R.5V** (P1.6 + V.4) — completar el patrón
   universal: widgets KPIs (trigger count / last fired), attention (violations
   recientes), activity (`rule.fired`) + consecuencias emitidas (obligations linkeadas)
   con `list_activity` filtrada por rule_id.
5b. **Export de memoria institucional** (V.3) — "Exportar historial" por contexto
   (CSV vía ShareLink: actividad + balances + decisiones con votos + reglas vigentes);
   es la promesa central de la visión ("historial completo, export simple") y hoy no
   es demostrable.
6. **Breadcrumb en subcontextos** (P1.12) — cablear `BreadcrumbView` (ya existe el
   environment `navigateToContext`); decidir destino de `ContextTreeView` (tab More o
   borrar).
7. **Pickers nativos en forms server-driven** (P1.11) — resolver `actor_ref` →
   Picker de miembros, `resource_ref` → Picker de recursos en ResourceActionFormView.
8. **Contexto inicial aplicado** (P1.13) — leer `default_context_actor_id` en el
   bootstrap del tab Contextos.
9. **Catálogo de governance visible** (P1.8) + **suspensión directa** (P1.5) +
   **void_transaction admin** (P1.9) — superficie en ContextSettings/MemberDetail/Money.

**Requieren confirmación de backend antes de UI:** archivar contexto (P1.4),
políticas adicionales de pools (P1.10), templates de decisión R.4B (P1.17),
roles personalizados (P1.16 — mantener placeholder).

---

### Cierre de Fase 2 (2026-06-11)

Completados: P1.1, P1.2, P1.3, P1.5, P1.6/V.4, P1.7, P1.8, P1.13, V.3.
Falsos positivos de la auditoría descubiertos al implementar: P1.11 (los
pickers nativos de actor/recurso YA existían — el UUID TextField es solo
fallback sin contexto) y P1.12 (BreadcrumbView SÍ se renderiza).
**P1.9 (void_transaction) diferido a P2 con razón:** iOS no tiene superficie
de transacciones individuales; un botón "Anular" sin lista de transacciones
sería una pantalla falsa. Requiere primero un browser de ledger (P2).

## Fase 3 — P1 pulido de confianza

1. `whyCanReserve` render completo (P1.14).
2. Filtro "necesito votar" en MyDecisionsView (P1.15).
3. Humanizar payloads de R.6 en activity (P1.18) — usar `activity_event_catalog`.

## Fase 4 — P2 escalabilidad (cola, sin orden fijo)

Search en eventos/decisiones/obligaciones → búsqueda global; skeletons
(`redacted(.placeholder)`); infinite scroll + paginación del feed personal;
integraciones (Calendar/Wise/WhatsApp); documentos sign/approve/versions (FQ-2/FQ-4,
requiere backend); relaciones de recursos editables (R.0D); audit log completo;
offline/cache; widgets; accesibilidad profunda.

De la visión (V.5–V.7): monetización **por grupo + módulos activables** (nunca por
seat — no construir hasta validar wedges de GTM); MFA promovido para admins de
contextos con fondos; pasada de copy institucional en onboarding/empty states
("vivir, decidir y recordar como institución pequeña").

---

## Reglas de ejecución

1. **Un commit por slice**, DoD completo (build sin warnings + tests + smoke simulador).
2. Toda migration nueva via MCP `apply_migration` con review SQL previa, y replicada
   en `supabase/migrations/` (fuente única).
3. Cada acción nueva nace de `available_actions[]` (F.2X) — nada de gating hardcodeado
   nuevo; los 3 checks legacy de `myPermissions` existentes (`canManageMembers`,
   `canInvite`, `can("edit_general")`) se migran a descriptor cuando se toquen.
4. Mock + preview actualizado por cada vista nueva (`MockRuulRPCClient.demo()`).
5. Errores siempre vía `RPCErrorMapper` → `UserFacingError` (copy en español).
6. Después de cada fase: re-smoke de los flujos A–H afectados en device.

## Métrica de cierre

El frontend se considera "app real y completa" cuando:
- Los 8 flujos A–H pasan el smoke en iPhone sin SQL manual ni mocks.
- Cero acciones visibles sin handler (la búsqueda `disabled(true)` solo devuelve
  superficies marcadas "Próximamente" deliberadas de P2).
- `FrontendMissingFeatures.md` sin ítems P0 abiertos y P1 ≤ 5.
