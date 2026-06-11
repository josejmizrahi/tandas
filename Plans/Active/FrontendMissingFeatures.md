# Frontend Missing Features — Ruul iOS (priorizado)

**Fecha:** 2026-06-11
**Fuente:** `FrontendFlowAudit.md` (auditoría completa con file:line).
**Criterio:** P0 = rompe un flujo obligatorio hoy · P1 = core avanzado incompleto ·
P2 = escalabilidad/pulido. "Backend ✅" = el RPC/tabla ya existe en migrations.

---

## P0 — debe funcionar ya

| # | Flow | Pantalla | Estado actual | Backend | RPC | Qué falta | Riesgo | Archivo Swift | Recomendación |
|---|---|---|---|---|---|---|---|---|---|
| P0.1 | C Invitación | PendingInvitationsView | Solo botón "Aceptar"; no hay rechazar | ❌ (sin RPC `decline_invitation` en contrato) | — | RPC backend + swipe/botón "Rechazar" | Invitaciones zombie acumulándose; el invitado no puede limpiar su inbox | `Features/Membership/PendingInvitationsView.swift:100-132` | Crear RPC `decline_invitation(p_context_actor_id)` (o reusar `set_membership_state`) + UI con confirmación |
| P0.2 | C Invitación | InviteMembersView / ContextSettings | `revokeInvite()` existe en cliente y backend pero sin superficie de UI | ✅ | `revoke_invite` | Lista de códigos activos + acción revocar | Un código filtrado no se puede invalidar → cualquiera entra al contexto | `RuulCore/Stores/MembersStore.swift:55-57`, `Features/Membership/InviteMembersView.swift` | Sección "Códigos activos" en InviteMembersView con revoke + confirmación |
| P0.3 | A Auth | RuulAppShell bootstrap | `verifySession()` existe pero nunca se llama | ✅ (Supabase Auth) | `auth.user()` | Llamarla en gate 1 para detectar sesión huérfana | Usuario con JWT inválido ve errores crípticos en todos los RPCs en vez de re-login | `RuulCore/Supabase/AuthService.swift:294-304`, `RuulApp/App/RuulAppShell.swift:40` | Verificar al pasar a `.signedIn`; si falla → signOut limpio |
| P0.4 | E Money | ObligationDetailView | `pay`/`dispute`/`cancel` anunciadas por el descriptor backend; iOS las filtra a "Próximamente" | ⚠️ descriptor las anuncia pero no hay RPC `pay_obligation` dedicada | — | Decidir: o el backend deja de anunciarlas, o se crean las RPCs y se cablean | Botón visible que no hace nada (viola la regla final del MVP); usuarios esperan pagar desde la obligación | `Features/Money/ObligationDetailView.swift:37-45,103-117` | Corto plazo: que el descriptor no emita acciones sin RPC. Mediano: RPC `pay_obligation` que dispare el flujo settlement |
| P0.5 | Permisos | Superficies con acciones disabled | `AvailableAction.reason` no se muestra consistentemente | ✅ (reason viene en el payload) | descriptors | Render uniforme del `reason` cuando una acción está deshabilitada | Usuario no entiende por qué no puede hacer algo (pedido explícito del founder) | `Components/`, vistas de detalle | Componente común `DisabledActionRow(reason:)` aplicado en toolbars/menus |
| P0.6 | F.14 | Todos | Smoke manual end-to-end en iPhone nunca ejecutado (founder) | ✅ | — | Ejecutar los 5 escenarios de F.14 y registrar resultados | Sin validación real en device, cualquier gap de integración pasa desapercibido | `Plans/Active/Frontend_MVP2_Rebuild.md:61-78` | Ejecutar F.14 ANTES de construir más features; archivar resultados en R5Z |

## P1 — core avanzado

| # | Flow | Pantalla | Estado actual | Backend | RPC | Qué falta | Riesgo | Archivo Swift | Recomendación |
|---|---|---|---|---|---|---|---|---|---|
| P1.1 | Notificaciones | (no existe) | Solo attention_inbox (pull); R.4D sin consumir | ✅ R.4D | `mark_notification_read/archived`, `mark_all_notifications_read` | Centro de notificaciones con leído/no-leído + badge real | Usuarios pierden eventos que no son "atención accionable" | nuevo `Features/Notifications/` | NotificationCenterView + store; integrar con tab Actividad |
| P1.2 | Perfil | EditProfileView | `avatarUrl: nil` hardcoded; solo initials | ✅ (`update_my_profile(p_avatar_url)` + Storage) | `update_my_profile` | PhotosPicker + upload a Storage + URL | Identidad visual pobre en grupos grandes | `Features/Profile/EditProfileView.swift:47,119` | Bucket `avatars` + PhotosPicker + resize client-side |
| P1.3 | Perfil | PersonalSettingsView | Sin UI para cambiar teléfono/email | ✅ | `startPhoneChange`/`confirmPhoneChange` (AuthService:321-335) | Pantalla de cambio con OTP de verificación | Usuario que cambia de número queda bloqueado | `Features/Profile/PersonalSettingsView.swift` | Sheet "Cambiar teléfono/correo" con flujo OTP |
| P1.4 | Grupos | ContextSettingsView | Sin archivar contexto | ⚠️ por confirmar (`update_context` no expone status) | — | RPC de archive + UI gated + governance si aplica | Contextos muertos ensucian la lista para siempre | `Features/ContextShell/ContextSettingsView.swift` | Definir semántica backend primero (archive vs leave-all) |
| P1.5 | Membresías | MemberDetailView | Suspender solo vía governance; `set_membership_state` directo sin UI | ✅ | `set_membership_state` | Acción directa para admins donde la policy no exige decisión | Admin no puede pausar a un miembro problemático rápido | `Features/Membership/MemberDetailView.swift:163-168` | Cablear cuando `member_available_actions` lo emita con mode=execute |
| P1.6 | Reglas | RuleDetailView | Sin historial de versiones ni consecuencias emitidas | ⚠️ parcial (activity registra; sin RPC de versiones) | `list_activity` filtrada | Sección "Historial" + "Consecuencias emitidas" (obligations creadas por la regla) | No se puede auditar qué hizo una regla → desconfianza en el motor R.6 | `Features/Rules/RuleDetailView.swift:112-123` | Filtrar activity por rule_id + linkear obligations generadas |
| P1.7 | Decisiones | DecisionDetailView | Quorum/threshold no visible antes de votar; sin countdown | ✅ (decision_detail trae result/votes) | `decision_detail` | Mostrar regla de aprobación ("mayoría simple, N/M votos") + countdown a closesAt | Votantes no saben cuánto falta para que pase | `Features/Decisions/DecisionDetailView.swift:330-337` | Chip "Se aprueba con X de Y" + TimelineView para el cierre |
| P1.8 | Governance | (no existe) | `governance_action_catalog` no navegable | ✅ | `governance_action_catalog` | Vista "Qué requiere aprobación aquí" en ContextSettings | Miembros no saben qué acciones disparan votación | `Features/ContextShell/ContextSettingsView.swift:119-184` | Lista read-only del catálogo con policy actual por acción |
| P1.9 | Money | (admin) | `void_transaction` (AUDIT.1) sin UI | ✅ | `void_transaction` | Acción admin "Anular transacción" con razón | Errores de captura quedan permanentes en la contabilidad | nuevo en `Features/Money/` | Gated a admin + confirmación + razón obligatoria |
| P1.10 | Pools | PoolDetailView / CreatePoolSheet | Solo 2 políticas (winner_takes_all, equity_target) | ⚠️ por confirmar qué políticas adicionales soporta `resolve_pool` | `create_pool`, `resolve_pool` | Políticas restantes de R.8 si el backend ya las acepta | Pools de viaje (proporcional) no modelables | `Features/Pools/CreatePoolSheet.swift` | Confirmar contra R8_PoolPrimitive.md y extender el picker |
| P1.11 | Recursos | ResourceActionFormView | Campos actor_ref/resource_ref caen a TextField de UUID | ✅ | `execute_resource_action` | Pickers nativos poblados de MembersStore/ResourcesStore | Forms server-driven inutilizables para humanos | `Features/Resources/ResourceActionFormView.swift:228,299` | Resolver `format: actor_ref` → Picker de miembros |
| P1.12 | Navegación | ContextDetailV2 | BreadcrumbView y ContextTreeView definidas, nunca renderizadas | ✅ (`context_ancestors`/`context_tree`) | hierarchy RPCs | Cablear breadcrumb en subcontextos + árbol en tab More, o borrarlas | Código muerto; subcontextos difíciles de navegar hacia arriba | `Features/ContextShell/BreadcrumbView.swift`, `ContextTreeView.swift` | Cablear breadcrumb (ya hay environment `navigateToContext`) |
| P1.13 | Perfil | MainTabShell | "Contexto inicial" se persiste pero no se aplica | ✅ (metadata) | `personal_settings_summary` | Abrir ese contexto al arrancar si está configurado | Setting que no hace nada (viola regla final) | `Features/Shell/MainTabShell.swift` | Leerlo en bootstrap del tab Contextos |
| P1.14 | Reservas | RequestReservationView | `whyCanReserve` se carga pero el render es parcial | ✅ | `why_can_reserve` | Sección completa "Por qué puedes reservar" | Menor — transparencia de derechos | `Features/Reservations/RequestReservationView.swift:33` | Completar la sección con los rights del response |
| P1.15 | Decisiones | MyDecisionsView | No distingue "ya voté" vs "necesito votar" | ✅ | `decision_votes` | Filtro/badge de pendientes de mi voto | Cubierto parcialmente por attention_inbox | `Features/Profile/MyDecisionsView.swift:7-11` | Cruzar con listDecisionVotes en el fan-out |
| P1.16 | Grupos | ContextSettingsView | Roles personalizados placeholder | ❌ (no hay RPCs de role CRUD) | — | Definición backend primero | Bajo — roles canónicos bastan en MVP | `ContextSettingsView.swift:342-353` | Mantener placeholder; diseñar post-MVP |
| P1.17 | Decisiones | CreateDecisionView | Templates R.4B sin UI dedicada | ✅ (execute_decision con templates) | `create_decision` | Picker de plantillas de decisión | Decisiones ejecutables se crean "a mano" | `Features/Decisions/CreateDecisionView.swift` | Exponer templates del catálogo R.4B |
| P1.18 | Activity | ActivityDetailView | Claves de payload de R.6 sin humanizar | ✅ | `list_activity` | Mapear claves nuevas del rule engine | Metadata críptica en eventos automáticos | `Features/Activity/ActivityFeedView.swift:218-240` | Extender `payloadKeyLabel` + fallback legible |

## P2 — escalabilidad / pulido

| # | Tema | Qué falta | Archivo / área | Nota |
|---|---|---|---|---|
| P2.1 | Search | `.searchable` en Events/Decisions/Members(ya)/Obligations; búsqueda global | listas de features | Solo Contextos/Recursos/Reglas hoy |
| P2.2 | Skeletons | Placeholders `redacted(reason: .placeholder)` en vez de spinner | listas principales | Pulido visual |
| P2.3 | Infinite scroll | Paginación automática en activity (hoy botón "Cargar más") | `ActivityFeedView.swift:84-96` | + paginación en feed personal (hoy 1 página de 50) |
| P2.4 | Integraciones | Google/Apple Calendar, Wise, WhatsApp | `PersonalSettingsView.swift:348-372` | Hoy "Próximamente" |
| P2.5 | Documentos | Sign / Approve / Versions (FQ-2/FQ-4) | `DocumentDetailView.swift:225-226` | Requiere backend |
| P2.6 | Offline/cache | Sin capa de cache; todo refetch | RuulCore | Evaluar solo si duele en device |
| P2.7 | Widgets / Live Activities | No existen | nuevo target | Post-MVP |
| P2.8 | Audit log completo | "Cambios críticos e historial completo llegan después" | `ContextSettingsView.swift:656-660` | Activity ya cubre lo básico |
| P2.9 | Relaciones de recursos (R.0D) | `set/remove/list_resource_relation` sin UI de edición | descriptor ya muestra relaciones read-only | Backend listo |
| P2.10 | Accesibilidad profunda | VoiceOver audit completo, Dynamic Type en heros custom | global | Labels básicos ya existen |
| P2.11 | Push notifications | APNs + emit_notification | — | Fuera de doctrina MVP2 (pull-based) |

---

## Resumen ejecutivo

- **6 ítems P0**, de los cuales 2 requieren decisión/trabajo de backend (P0.1 decline,
  P0.4 pay) y 4 son puramente frontend y pequeños (P0.2, P0.3, P0.5) más el smoke F.14 (P0.6).
- **18 ítems P1**: la mitad son "backend listo, falta UI" (notificaciones R.4D, avatar,
  phone change, void_transaction, set_membership_state, breadcrumb).
- **P2** es cola de pulido sin riesgo.
- Lo que NO hay: pantallas rotas, RPCs inexistentes, drift de contrato, lógica de
  permisos duplicada en cliente. La regla final ("no botones que no hagan nada") se
  viola solo en P0.4 y P1.13 — el resto de los botones inertes están honestamente
  marcados como "Próximamente".
