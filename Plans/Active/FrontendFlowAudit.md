# Frontend Flow Audit — Ruul iOS (MVP 2.0)

**Fecha:** 2026-06-11
**Alcance:** Auditoría completa del frontend iOS/SwiftUI (RuulCore + RuulApp) para detectar
qué falta para que todos los flujos funcionen end-to-end: navegación, estados, conexión
real a Supabase/RPCs, errores, permisos, empty states y UX.
**Método:** Revisión exhaustiva de las ~120 vistas y ~35 stores con referencias `file:line`,
cruzada contra `Plans/Active/MVP2_iOS_Contract.md` y las migrations `supabase/migrations/2026*`.

**Documentos hermanos:**
- `FrontendMissingFeatures.md` — lista priorizada de faltantes (P0/P1/P2)
- `FrontendBackendContractMap.md` — mapeo pantalla → RPC → modelo Swift → tabla
- `FrontendImplementationPlan.md` — fases de implementación

---

## Veredicto global

**La app NO es un prototipo.** El frontend está en un estado mucho más completo de lo que
sugiere el plan F.0–F.14: los 10 dominios principales tienen flujo completo, estados
loading/error/empty consistentes, idempotencia (`p_client_id`), confirmaciones destructivas,
gating por `available_actions[]` del backend y refresh post-mutación. El contrato
backend ↔ iOS tiene **cobertura 167/167 métodos con cero drift**.

Los faltantes reales son **acotados y enumerables** (ver `FrontendMissingFeatures.md`):
~6 gaps que tocan flujos P0, ~18 P1 y una cola P2. No hay pantallas falsas: los únicos
botones inertes están marcados explícitamente como "Próximamente" con `.disabled(true)`.

---

## 1. Arquitectura general — ✅ sólida

### Navegación
- **3 gates** en `RuulAppShell.swift:40-75`: sesión (`SessionStore`) → person actor
  (`CurrentActorStore` + `ensure_person_actor`, con error state y retry) → `MainTabShell`.
  Anónimos bloqueados explícitamente (`RuulAppShell.swift:48-50`). Gate extra:
  `ClaimPlaceholdersGate` (sheet único por sesión, `RuulAppShell.swift:77-112`).
- **5 tabs F.NAV** en `MainTabShell.swift:1-163`: Home / Contextos / Crear (bounce vía
  binding proxy F.NAV.7, nunca tab activo) / Actividad / Yo. `tabViewBottomAccessory`
  con centro de atención global (iOS 26+).
- **Deep links** completos: universal links `ruul.mx/invite/CODE` + scheme `ruul://`;
  `DeepLinkRouter` retiene el código hasta pasar los gates (`RuulAppShell.swift:31-35`,
  `MainTabShell.swift:144-149`).
- **AttentionDispatcher** (`Components/AttentionDispatcher.swift:57-123`) es el punto único
  de ruteo de atención, con fallback por `cta_scope_kind` para kinds desconocidos
  (forward-compatible R.5Z.fix.CC.2) y `.unsupported` honesto (sin crash).
- Refresh al volver a foreground (`MainTabShell.swift:135-143`).

### Estados y componentes
- Patrón `StorePhase` (idle/loading/loaded/failed) aplicado en el **100%** de pantallas
  con carga, siempre vía `RuulLoadingState` / `RuulErrorState` (con retry) / `RuulEmptyState`.
- `ActionRunner` (`Components/StateViews.swift:17-46`): protección doble-tap +
  haptics automáticos (`sensoryFeedback` success/error) + alert de error.
- Pull-to-refresh en 20+ pantallas; dark mode global (`AppearancePreference`);
  confirmaciones destructivas con `role: .destructive` en todos los flujos sensibles.
- **Cero vistas huérfanas** salvo dos definidas y nunca instanciadas:
  `BreadcrumbView.swift` y `ContextTreeView.swift` (ContextShell) — candidatas a
  cablear (jerarquía visible) o borrar.
- Gaps menores: search solo en `ContextsListView` y `ResourcesListView`/`RulesListView`
  (no en eventos/decisiones); sin skeletons (solo `ProgressView`); paginación de
  actividad por botón "Cargar más" (no infinite scroll).

### Botones que no hacen nada (inventario completo)
| Dónde | Qué | Estado |
|---|---|---|
| `HomeView.swift:327-338` | "Buscar", "Preguntar a Ruul", "Escanear" | `.disabled(true)` + footer "en desarrollo" — honesto |
| `ObligationDetailView.swift:37-45` | `pay` / `dispute` / `cancel` | El descriptor backend las anuncia; iOS las filtra a alert "Próximamente" |
| `DocumentDetailView.swift:225-226` | Sign / Approve / Versions | Sección disabled marcada FQ-2/FQ-4 |
| `PersonalSettingsView.swift:348-372` | Integraciones (Google/Apple Calendar, Wise, WhatsApp) | Labels "Próximamente", no son botones |
| `ContextSettingsView.swift:342-353` | Roles personalizados | Placeholder explícito |

---

## 2. Auth / onboarding — ✅ completo con 3 gaps

| Ítem | Estado | Evidencia |
|---|---|---|
| Sign in with Apple | ✅ | Nonce + SHA256 + `signInWithIdToken` (`SignedOutView.swift:85-116`, `AuthService.swift:244-255`) |
| OTP teléfono/email | ✅ | Canal seleccionable, validación, errores en español (`SignedOutView.swift:129-237`) |
| Persistencia/restauración de sesión | ✅ | `authStateChanges` stream + bootstrap automático (`AuthService.swift:227-238`) |
| Logout | ✅ | Limpia TODOS los stores (`DependencyContainer.swift:91-101`); resiliente a fallo de red |
| Person actor gate | ✅ | `ensure_person_actor` con retry manual (`RuulAppShell.swift:59-74`) |
| Claim de placeholders | ✅ | `find_placeholder_matches_for_me` + sheet automática post-login |
| Crear/editar perfil | ⚠️ | Nombre completo + corto OK; **sin upload de avatar** (`avatarUrl: nil` hardcoded, `EditProfileView.swift:47,119`) |
| Cambiar teléfono/email | ❌ | RPCs existen (`AuthService.swift:321-335`) pero **sin pantalla** |
| Validación de sesión huérfana | ⚠️ | `verifySession()` existe (`AuthService.swift:294-304`) pero **nunca se llama** en bootstrap |

## 3. Contextos (grupos) — ✅ completo con 2 gaps

- **Crear**: `CreateContextView.swift` — 7 subtypes, guard anti-duplicados (debounce 350ms +
  `context_creation_candidates`), refresh + switch automático post-creación. Subcontextos
  vía `CreateChildContextSheet`. ✅
- **Lista**: solo raíces (`isRoot && !isPersonal`), favoritos + recientes
  (`ContextPreferencesStore`), empty state con CTAs (`NoContextsView`), badge de
  invitaciones pendientes. ✅
- **ContextHome** (`ContextDetailViewV2` + 7 tabs server-driven desde
  `context_detail_descriptor`): overview/events/people/resources/money/governance/more,
  todas con backing real, widgets filtrados, acciones del toolbar desde
  `descriptor.actions` agrupadas por sección. Contexto personal usa
  `ContextDetailV2PersonalSpace` (flujo propio). ✅
- **Editar**: nombre/descripción/visibilidad gated por `can("edit_general")`
  (`ContextSettingsView.swift:667-742`). ✅
- **Salir**: `leave_context` con confirmación (`MemberDetailView.swift:244-258`). ✅
- ❌ **Archivar contexto**: sin UI (backend por confirmar).
- ⚠️ **Jerarquía**: breadcrumb/árbol definidos pero no renderizados.

## 4. Membresías e invitaciones — ⚠️ el gap P0 está aquí

| Flujo | Estado | RPC |
|---|---|---|
| Código compartible + ShareLink ruul.mx/invite | ✅ | `create_invite` (`InviteMembersView.swift:100-180`) |
| Join por código (+ deep link prellenado) | ✅ | `join_by_invite_code` (`JoinByCodeView.swift`) |
| Invitación directa actor→actor | ✅ | `invite_member` (`InviteMembersView.swift:185-269`) |
| Placeholder person (sin app) + claim | ✅ | `create_placeholder_person` / `claim_placeholder_actor` |
| Ver pendientes + aceptar | ✅ | `accept_invitation` (`PendingInvitationsView.swift:115-132`) |
| **Rechazar invitación** | ❌ **P0** | Sin UI ni RPC dedicada en el contrato — invitaciones zombie |
| **Revocar código de invitación** | ❌ | `revokeInvite()` existe en cliente y backend, **nunca cableado en UI** (`MembersStore.swift:55-57`) |
| Remover miembro | ✅ | `remove_member` + confirmación + ruta governance si el catálogo lo exige |
| Cambiar rol | ✅ | `assign_role` gated por `member_available_actions` |
| Suspender/pausar | ⚠️ | Solo vía governance (`member.pause`); `set_membership_state` directo sin UI |

## 5. Roles y permisos — ✅ doctrina F.2X cumplida

- Doble capa: `context_summary().my_permissions` (gating grueso:
  `MembersStore.swift:39-45`) + `available_actions[]` canónicos con `enabled`,
  `reason`, `mode` (directo vs `request_decision`) en cada descriptor.
- No hay `if resource.type == ...` en routing de acciones; `ActionPresentationCatalog`
  (60+ acciones) solo presenta, `ActionRouter` solo enruta.
- Acciones deshabilitadas se muestran greyed; footers explican falta de permiso
  (p.ej. `ContextSettingsView.swift:302-304`).
- ⚠️ `AvailableAction.reason` no se renderiza consistentemente en todas las superficies
  (a veces solo se oculta/greyea sin explicación).

## 6. Recursos — ✅ el dominio más maduro

- **Taxonomía 100% server-driven**: 17 clases + 42 subtypes desde `list_resource_classes`
  / `list_resource_subtypes`; un tipo nuevo en backend aparece en iOS sin código.
  Cubre los tipos mínimos pedidos (vehicle, fund, pool, space, document, task→obligations,
  asset, service, location vía `location_text`, etc.).
- **Crear**: wizard 3 pasos con auto-skip, guard anti-duplicados, AI hero opcional
  (`CreateResourceFlow.swift`).
- **Detalle**: `resource_detail_descriptor` server-driven — hero + capabilities +
  conflictos abiertos + secciones + widgets + relaciones + linked
  events/obligations/decisions/documents + activity (`ResourceDetailViewV2.swift`).
- **Acciones**: `descriptor.actions` con mode execute/request_decision, forms
  server-driven por JSONSchema (`ResourceActionFormView`), confirmaciones, dangerous flags.
- **Editar/archivar/transferir**: completos; transfer es governance-gated (votación).
- **Derechos**: `GrantRightSheet` (5 derechos grantables con explicación), revoke vía actions.
- Gaps menores: pickers de actor/recurso en forms server-driven caen a **texto UUID**
  (`ResourceActionFormView.swift:228,299`); `ResourceTypeCatalogStore` cargado pero sin uso.

## 7. Eventos — ✅ completo

Crear/editar con ubicación multi-modo (physical/virtual/perHost) + recurrencia con
bounds (count/until) + AI hero; RSVP, check-in (self/delegado, con multa automática por
regla), cancel participation (alerta de multa same-day), close event (rota host, crea
siguiente instancia); next host preview + override + orden de rotación drag-to-reorder;
plus-ones, guests, host confirm; recursos reservados linkeados (R.2T); gasto del evento
con pesos (`preview_event_split` + `split_basis='event_weights'`); calendarios mensual
de contexto y personal cross-context (eventos+reservas+votos+obligaciones).
Archivos: `Features/Events/*`, `EventsStore.swift:37-202`.

## 8. Money — ✅ completo con 1 gap visible

- Gasto: 3 métodos de split (equal/shares estilo Splitwise con ajuste residual/custom
  con validación de suma exacta), AI hero, preview ponderado, idempotencia
  (`RecordExpenseView.swift:490-572`).
- Multa, resultado de juego, obligación manual (non-money con AI), editar obligación,
  forgive (directo o governance), balances + quién-debe-a-quién + historial
  (`MoneyHomeView.swift:173-311`).
- ❌ **`pay` / `dispute` / `cancel` de obligaciones**: el descriptor backend las anuncia
  pero iOS no tiene RPC cableada → whitelist `wiredActionKeys` + alert "Próximamente"
  (`ObligationDetailView.swift:37-45,103-117`). El pago hoy solo fluye vía settlement.
- ❌ `void_transaction` (AUDIT.1, reversar) existe en backend sin UI.

## 9. Settlement — ✅ completo

Generación automática + manual del batch (neteo min-cashflow), handshake de 2 vías
(debtor marca pagado → creditor confirma/rechaza con razón → debtor apela → admin
resuelve), estados pending/pending_confirmation/disputed/paid, secciones por rol,
historial colapsable (`SettlementView.swift`, rediseño R.5Z).

## 10. Pools — ✅ completo para las 2 políticas MVP

Crear (winner_takes_all / equity_target), contribuir, progreso a meta, preview de
resolución, resolve dinámico por política con picker de ganador, idempotencia.
⚠️ Las demás políticas de R.8 (proportional, equal_share, …) no están en UI (por
confirmar si el backend las soporta ya).

## 11. Gobernanza / decisiones — ✅ completo con gaps de visibilidad

- Decisiones: crear (AI hero + 3 modelos de votación R.2Q con opciones), votar/desvotar,
  resultados con barras y ganador, participantes (faltantes primero), consecuencias
  ("¿Qué ocurre si gana?"), cerrar/ejecutar/cancelar desde `available_actions`,
  audit section (`DecisionDetailView.swift`, 1,265 líneas).
- Governance R.7: el patrón `request_governance_action` → Decision → backend ejecuta
  está cableado en rule.archive, member promote/pause/remove, resource transfer,
  obligation forgive. iOS correctamente NO llama `execute_governance_action` (interno).
- Gaps: **quorum/threshold no visible** antes de votar (solo conteo); sin countdown
  reactivo al cierre; `governance_action_catalog` no navegable como catálogo;
  decision templates R.4B sin UI dedicada.

## 12. Activity feed — ✅ completo

Feed por contexto con toggle subcontextos (R.2U.2) + paginación; feed personal (R.3A)
con deep links al objeto (resource/event/decision/obligation) + resumen AI on-device;
agrupado por día, metadata humanizada (`payloadKeyLabel`), actores resueltos con
fallback "Tú"/"Sistema". ⚠️ Claves de payload nuevas de R.6 pueden no estar mapeadas.

## 13. Notificaciones — ❌ el dominio menos cubierto

Lo que existe: `attention_inbox()` + dismiss + badge + bottom accessory + cards — el
modelo "pull de atención" funciona bien. Lo que falta: el backend ya tiene
`notifications` R.4D (`mark_notification_read/archived`, `mark_all_notifications_read`,
`emit_notification`) y iOS **no las consume**: no hay centro de notificaciones, ni
leído/no-leído, ni push (APNs fuera de alcance MVP2 por doctrina).

## 14. Perfil / actor personal — ✅ completo con gaps menores

`MeView` consolida 9 vistas My* (resources, obligations, balance, decisions, rules,
documents, reservations, subscriptions, trust network) todas con fan-out paralelo por
contexto (`withTaskGroup`, tolerante a fallos parciales), estados y navegación al
detalle. `PersonalSettingsView`: apariencia, notificaciones (7 categorías), privacidad
(3 pickers), calendario (TZ + primer día), contexto inicial — todo persiste vía
`update_my_profile_metadata`. user_id vs actor_id sin confusión (1:1 vía
`ensure_person_actor`). Gaps: avatar, cambio phone/email, integraciones, y el
"contexto inicial" se persiste pero no se aplica a la navegación.

## 15. UX/UI — ✅ doctrina R.5V aplicada

List + Section Apple-native en todas las pantallas; Liquid Glass solo en heros/CTAs
(`.glassProminent`); jerarquía clara; errores siempre `UserFacingError` en español;
accesibilidad básica (labels/hints); previews con `MockRuulRPCClient.demo()` en todas
las vistas auditadas. Pendiente P2: skeletons, search en más listas, infinite scroll.

## 16. Integración con backend — ✅ ver FrontendBackendContractMap.md

167/167 métodos cubiertos, cero drift, idempotencia consistente en los 11 RPCs que la
soportan, 13 tablas PostgREST read-only con RLS. Los 28 RPCs backend sin método iOS son
internals/deprecados/futuros (detalle en el mapa).

---

## 17. Flujos end-to-end obligatorios — semáforo

| Flujo | Estado | Bloqueo |
|---|---|---|
| A. Usuario nuevo (login → perfil → grupo → invitar) | 🟢 | Smoke en iPhone pendiente (F.14) |
| B. Grupo normal (home, evento, recurso, regla, gasto, activity) | 🟢 | — |
| C. Invitación (invitar → aceptar → permisos) | 🟡 | No se puede **rechazar**; no se puede **revocar** código |
| D. Evento (RSVP, ubicación, gasto, cerrar, recurrente) | 🟢 | — |
| E. Money (gasto → balance → settlement → pagado) | 🟢 | Handshake completo; falta `pay` directo de obligación |
| F. Governance (acción peligrosa → decisión → votar → ejecutar) | 🟢 | Quorum no visible upfront |
| G. Recursos (crear → detalle → transferir → derechos → archivar) | 🟢 | — |
| H. Reglas (crear → activa → archivar → activity) | 🟡 | Sin historial de versiones ni consecuencias emitidas visibles |

**Criterio de éxito:** los 8 flujos son ejecutables en iPhone hoy; C y H tienen huecos
visibles para el usuario. El smoke manual F.14 (founder, device) sigue pendiente y es
el siguiente paso obligado antes de dar el frontend por cerrado.
